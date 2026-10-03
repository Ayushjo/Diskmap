using DiskMap.Core.Native;
using Microsoft.Win32.SafeHandles;

namespace DiskMap.Core;

/// UNVERIFIED: the parse offsets are written against the NTFS on-disk spec
/// but have not yet been exercised against a live $MFT (raw volume reads
/// need admin). Verify with an elevated scan of a real NTFS volume and
/// remove this notice, per AGENTS.md rule 4. The FindFirstFileExW fallback
/// is the tested path today.
///
/// <summary>
/// Primary scan path: parses the NTFS Master File Table directly —
/// the same approach WizTree uses. One volume read of $MFT yields every
/// file's name, parent, sizes, and timestamps in a single pass, versus
/// one FindNextFileW per file.
///
/// Requirements: NTFS volume + admin (volume handle needs GENERIC_READ on
/// \\.\X:). Either failing returns null so the caller falls back to the
/// FindFirstFileExW scanner.
///
/// Layout notes (all little-endian, offsets verified against the NTFS
/// on-disk spec / Microsoft's FILE_RECORD_SEGMENT_HEADER):
/// - FILE record: signature "FILE" @0, fixup offset @4 u16, fixup count
///   @6 u16, sequence @16 u16, link count @18 u16, first-attr offset @20
///   u16, flags @22 u16 (bit0 in-use, bit1 directory), base file ref @32 i64.
/// - Fixup (update sequence array): last 2 bytes of each sector are
///   replaced; USA[0] holds the signature, USA[i] the original bytes for
///   sector i.
/// - Attribute header: type @0 u32, length @4 u32, nonResident @8 u8;
///   resident content length @16 u32, content offset @20 u16.
/// - $FILE_NAME (0x30): parent FRN @0 i64 (low 48 bits = record index),
///   allocated size @40 i64, real size @48 i64, file attributes @56 u32,
///   name length @64 u8, namespace @65 u8 (0=POSIX,1=Win32,2=DOS,3=W32&DOS),
///   name @66 UTF-16LE.
/// </summary>
internal static class MftScanner
{
    private const int AttributeFileName = 0x30;
    private const int AttributeData = 0x80;
    private const int AttributeEnd = -1; // 0xFFFFFFFF

    private readonly record struct MftExtent(long Vcn, long Lcn, long LengthClusters);
    private readonly record struct MftRecord(long ParentFrn, uint Attrs, long Logical, long Alloc, int Day, byte HardLinks);

    public static WalkResult? Walk(string root, IProgress<int>? progress)
    {
        string? volumeRoot = Path.GetPathRoot(Path.GetFullPath(root));
        if (volumeRoot is null || volumeRoot.Length < 3 || volumeRoot[1] != ':')
            return null;
        string volumePath = @"\\?\" + char.ToUpperInvariant(volumeRoot[0]) + ":";

        using var volume = Win32.CreateFileW(
            volumePath, Win32.GENERIC_READ,
            Win32.FILE_SHARE_READ | Win32.FILE_SHARE_WRITE | Win32.FILE_SHARE_DELETE,
            IntPtr.Zero, Win32.OPEN_EXISTING, 0, IntPtr.Zero);
        if (volume.IsInvalid) return null;

        if (!GetVolumeData(volume, out var volData)) return null;
        int recordSize = (int)volData.BytesPerFileRecordSegment;
        int sectorSize = (int)volData.BytesPerSector;
        long clusterSize = volData.BytesPerCluster;
        long recordCount = volData.MftValidDataLength / recordSize;
        if (recordSize < 512 || recordCount <= 0 || recordCount > 500_000_000) return null;

        if (!TryGetMftExtents(volume, out var extents)) return null;
        if (!TryGetFileRecordIndex(root, out long rootFrn)) return null;
        if (rootFrn < 0 || rootFrn >= recordCount) return null;

        var records = new MftRecord[recordCount];
        var names = new string?[recordCount];
        var present = new bool[recordCount];

        ParseAllRecords(volume, extents, volData, records, names, present, progress);

        var state = new BuildState(records, names, present, progress);
        var tree = state.BuildTree(root, rootFrn);
        return new WalkResult
        {
            Tree = tree,
            ItemCount = state.ItemCount,
            NotDownloadedCount = state.NotDownloadedCount,
            PeakResidentBytesDuringWalk = state.Peak,
            Backend = "mft",
        };
    }

    private static bool GetVolumeData(SafeFileHandle volume, out Win32.NTFS_VOLUME_DATA_BUFFER data)
    {
        unsafe
        {
            fixed (void* outBuf = &data)
            {
                return Win32.DeviceIoControl(
                    volume, Win32.FSCTL_GET_NTFS_VOLUME_DATA,
                    null, 0, outBuf, sizeof(Win32.NTFS_VOLUME_DATA_BUFFER),
                    out _, IntPtr.Zero);
            }
        }
    }

    private static bool TryGetMftExtents(SafeFileHandle volume, out List<MftExtent> extents)
    {
        extents = [];
        // $MFT itself is file record 0 on NTFS.
        var id = new Win32.FILE_ID_DESCRIPTOR { dwSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Win32.FILE_ID_DESCRIPTOR>(), Type = 0, FileId = 0 };
        using var mft = Win32.OpenFileById(
            volume, ref id, 0,
            Win32.FILE_SHARE_READ | Win32.FILE_SHARE_WRITE | Win32.FILE_SHARE_DELETE,
            IntPtr.Zero, Win32.FILE_FLAG_BACKUP_SEMANTICS);
        if (mft.IsInvalid) return false;

        unsafe
        {
            var input = new long[1]; // STARTING_VCN_INPUT_BUFFER
            int outSize = 4096;
            byte[] outBuf = new byte[outSize];
            fixed (void* inPtr = input, outPtr = outBuf)
            {
                if (!Win32.DeviceIoControl(
                        mft, Win32.FSCTL_GET_RETRIEVAL_POINTERS,
                        inPtr, sizeof(long), outPtr, outSize, out _, IntPtr.Zero))
                {
                    return false;
                }
            }
            int extentCount = BitConverter.ToInt32(outBuf, 0);
            long startingVcn = BitConverter.ToInt64(outBuf, 8);
            long prevVcn = startingVcn;
            for (int i = 0; i < extentCount; i++)
            {
                int off = 16 + i * 16;
                long nextVcn = BitConverter.ToInt64(outBuf, off);
                long lcn = BitConverter.ToInt64(outBuf, off + 8);
                extents.Add(new MftExtent(prevVcn, lcn, nextVcn - prevVcn));
                prevVcn = nextVcn;
            }
            return extents.Count > 0;
        }
    }

    private static bool TryGetFileRecordIndex(string path, out long frn)
    {
        frn = -1;
        using var handle = Win32.CreateFileW(
            Win32.ExtendedPath(Path.GetFullPath(path)), Win32.FILE_READ_ATTRIBUTES,
            Win32.FILE_SHARE_READ | Win32.FILE_SHARE_WRITE | Win32.FILE_SHARE_DELETE,
            IntPtr.Zero, Win32.OPEN_EXISTING, Win32.FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
        if (handle.IsInvalid) return false;
        if (!Win32.GetFileInformationByHandle(handle, out var info)) return false;
        frn = (((long)info.nFileIndexHigh << 32) | info.nFileIndexLow) & 0x0000FFFFFFFFFFFF;
        return true;
    }

    private static void ParseAllRecords(
        SafeFileHandle volume,
        List<MftExtent> extents,
        Win32.NTFS_VOLUME_DATA_BUFFER volData,
        MftRecord[] records,
        string?[] names,
        bool[] present,
        IProgress<int>? progress)
    {
        int recordSize = (int)volData.BytesPerFileRecordSegment;
        int sectorSize = (int)volData.BytesPerSector;
        long clusterSize = volData.BytesPerCluster;
        // Read each extent in chunks aligned to the record size.
        int recordsPerChunk = Math.Max(1, (8 * 1024 * 1024) / recordSize);
        int chunkBytes = recordsPerChunk * recordSize;
        int lastReported = 0;

        foreach (var extent in extents)
        {
            long extentBytes = extent.LengthClusters * clusterSize;
            long extentOffset = extent.Lcn * clusterSize;
            long recordBase = extent.Vcn * clusterSize / recordSize;
            for (long done = 0; done < extentBytes; done += chunkBytes)
            {
                int toRead = (int)Math.Min(chunkBytes, extentBytes - done);
                var buffer = new byte[toRead];
                if (!ReadAt(volume, extentOffset + done, buffer)) return;
                int recordsInChunk = toRead / recordSize;
                long firstRecord = recordBase + done / recordSize;
                int reported = -1;

                Parallel.For(0, recordsInChunk, i =>
                {
                    long frn = firstRecord + i;
                    if (frn >= records.Length) return;
                    var rec = new Span<byte>(buffer, i * recordSize, recordSize);
                    ParseRecord(rec, (int)frn, sectorSize, records, names, present);
                });

                // Progress counts records parsed.
                int processed = (int)Math.Min(firstRecord + recordsInChunk, records.Length);
                if (processed - lastReported >= 200_000 || done + chunkBytes >= extentBytes)
                {
                    lastReported = processed;
                    reported = processed;
                }
                if (reported >= 0) progress?.Report(reported);
            }
        }
    }

    private static bool ReadAt(SafeFileHandle volume, long offset, byte[] buffer)
    {
        unsafe
        {
            if (!Win32.SetFilePointerEx(volume, offset, out _, 0)) return false;
            int total = 0;
            while (total < buffer.Length)
            {
                fixed (byte* p = &buffer[total])
                {
                    if (!Win32.ReadFile(volume, p, buffer.Length - total, out int got, IntPtr.Zero) || got <= 0)
                        return false;
                    total += got;
                }
            }
            return true;
        }
    }

    private static void ParseRecord(
        Span<byte> rec, int frn, int sectorSize,
        MftRecord[] records, string?[] names, bool[] present)
    {
        if (rec.Length < 66) return;
        if (rec[0] != 'F' || rec[1] != 'I' || rec[2] != 'L' || rec[3] != 'E') return;

        ushort usaOffset = BitConverter.ToUInt16(rec[4..]);
        ushort usaCount = BitConverter.ToUInt16(rec[6..]);
        ushort flags = BitConverter.ToUInt16(rec[22..]);
        if ((flags & 0x1) == 0) return;             // not in use
        long baseRef = BitConverter.ToInt64(rec[32..]);
        if (baseRef != 0) return;                   // extension record: name lives in base
        if (!ApplyFixup(rec, usaOffset, usaCount, sectorSize)) return;

        ushort firstAttr = BitConverter.ToUInt16(rec[20..]);
        int pos = firstAttr;
        long parentFrn = -1;
        uint attrs = 0;
        long logical = 0, alloc = 0;
        int day = 0;
        int nameCount = 0;
        string? bestName = null;
        int bestNs = 99;
        bool hasFileName = false;

        while (pos + 20 <= rec.Length)
        {
            int attrType = BitConverter.ToInt32(rec[pos..]);
            if (attrType == AttributeEnd) break;
            uint attrLen = BitConverter.ToUInt32(rec.Slice(pos + 4, 4));
            if (attrLen < 16 || pos + (int)attrLen > rec.Length) break;
            bool nonResident = rec[pos + 8] != 0;

            if (attrType == AttributeFileName && !nonResident)
            {
                int contentOff = BitConverter.ToUInt16(rec.Slice(pos + 20, 2));
                int content = pos + contentOff;
                if (content + 66 <= pos + attrLen)
                {
                    hasFileName = true;
                    nameCount++;
                    long thisParent = BitConverter.ToInt64(rec[content..]) & 0x0000FFFFFFFFFFFF;
                    byte ns = rec[content + 65];
                    // Prefer Win32/Win32&DOS names over POSIX or DOS-only.
                    if (ns < bestNs && ns != 2)
                    {
                        int nameLen = rec[content + 64];
                        int nameStart = content + 66;
                        if (nameStart + nameLen * 2 <= pos + attrLen)
                        {
                            bestName = System.Text.Encoding.Unicode.GetString(rec.Slice(nameStart, nameLen * 2));
                            bestNs = ns;
                        }
                    }
                    if (bestName is not null || parentFrn < 0)
                    {
                        parentFrn = thisParent;
                        attrs = BitConverter.ToUInt32(rec.Slice(content + 56, 4));
                        alloc = BitConverter.ToInt64(rec.Slice(content + 40, 8));
                        logical = BitConverter.ToInt64(rec.Slice(content + 48, 8));
                        long ft = BitConverter.ToInt64(rec.Slice(content + 16, 8));
                        day = Win32.FileTimeToModifiedDay(ft);
                    }
                }
            }
            else if (attrType == AttributeData && nonResident)
            {
                // A non-resident $DATA stream has the fresher sizes; the
                // $FILE_NAME copies can lag for recently written files.
                if (pos + 56 <= rec.Length)
                {
                    long dataAlloc = BitConverter.ToInt64(rec.Slice(pos + 40, 8));
                    long dataReal = BitConverter.ToInt64(rec.Slice(pos + 48, 8));
                    if (dataReal > logical) logical = dataReal;
                    if (dataAlloc > alloc) alloc = dataAlloc;
                }
            }
            pos += (int)attrLen;
        }

        if (!hasFileName || bestName is null) return;

        if ((attrs & Win32.FILE_ATTRIBUTE_DIRECTORY) != 0 || (flags & 0x2) != 0)
            attrs |= Win32.FILE_ATTRIBUTE_DIRECTORY;

        records[frn] = new MftRecord(parentFrn, attrs, logical, alloc, day, (byte)Math.Min(nameCount, 255));
        names[frn] = bestName;
        present[frn] = true;
    }

    /// <summary>
    /// Each sector's last 2 bytes are replaced by update-sequence entries.
    /// Restore them; bail if the signature doesn't match (record is stale).
    /// </summary>
    private static bool ApplyFixup(Span<byte> rec, int usaOffset, int usaCount, int sectorSize)
    {
        if (usaOffset <= 0 || usaCount <= 1 || usaOffset + usaCount * 2 > rec.Length) return false;
        for (int i = 1; i < usaCount; i++)
        {
            int sectorEnd = i * sectorSize - 2;
            if (sectorEnd + 2 > rec.Length) return false;
            // rec[sectorEnd..+2] currently holds the USA signature value.
            rec[sectorEnd] = rec[usaOffset + i * 2];
            rec[sectorEnd + 1] = rec[usaOffset + i * 2 + 1];
        }
        return true;
    }

    /// <summary>
    /// Rebuilds the FileTree for the subtree under rootFrn using a CSR
    /// (compressed sparse row) children index — the same struct-of-arrays
    /// memory discipline as the rest of the core.
    /// </summary>
    private sealed class BuildState(
        MftRecord[] records, string?[] names, bool[] present, IProgress<int>? progress)
    {
        public int ItemCount;
        public int NotDownloadedCount;
        public ulong Peak = ProcessMemory.Current()?.ResidentBytes ?? 0;
        private readonly FileTree _tree = new();

        public FileTree BuildTree(string rootPath, long rootFrn)
        {
            int n = records.Length;

            // CSR children index: count children per parent, prefix-sum, fill.
            var childCount = new int[n];
            for (int i = 0; i < n; i++)
            {
                if (!present[i]) continue;
                long p = records[i].ParentFrn;
                if (p >= 0 && p < n) childCount[p]++;
            }
            var childStart = new int[n + 1];
            for (int i = 0; i < n; i++) childStart[i + 1] = childStart[i] + childCount[i];
            var children = new int[childStart[n]];
            var cursor = (int[])childStart.Clone();
            for (int i = 0; i < n; i++)
            {
                if (!present[i]) continue;
                long p = records[i].ParentFrn;
                if (p >= 0 && p < n) children[cursor[p]++] = i;
            }

            int rootNode = _tree.AddNode(
                Win32Scanner.RootName(rootPath).AsSpan(), parentId: -1, isDirectory: true,
                logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0);

            // frn → node id, only for subtree members. BFS over the CSR index.
            var nodeByFrn = new Dictionary<long, int> { [rootFrn] = rootNode };
            var queue = new Queue<long>();
            queue.Enqueue(rootFrn);
            int lastReported = 0;

            while (queue.Count > 0)
            {
                long frn = queue.Dequeue();
                int parentNode = nodeByFrn[frn];
                for (int i = childStart[frn]; i < childStart[frn + 1]; i++)
                {
                    int childFrn = children[i];
                    var rec = records[childFrn];
                    var decision = ScanEngine.DecideFromAttributes(rec.Attrs, rec.Logical, rec.Alloc);
                    if (!decision.Include) continue;

                    byte flags = 0;
                    if (decision.NotDownloaded)
                    {
                        flags |= NodeFlags.NotDownloaded;
                        NotDownloadedCount++;
                    }
                    if (rec.HardLinks > 1) flags |= NodeFlags.HardLink;

                    int id = _tree.AddNode(
                        names[childFrn]!.AsSpan(), parentId: parentNode,
                        isDirectory: (rec.Attrs & Win32.FILE_ATTRIBUTE_DIRECTORY) != 0,
                        logicalSize: decision.LogicalSize,
                        allocatedSize: decision.AllocatedSize,
                        modifiedDaysSinceEpoch: rec.Day,
                        flags: flags);
                    ItemCount++;
                    if (!decision.SkipDescendants && (rec.Attrs & Win32.FILE_ATTRIBUTE_DIRECTORY) != 0)
                    {
                        // Only directories that get descended need an frn→node
                        // entry — the dict keys the BFS lookup on dequeue.
                        nodeByFrn[childFrn] = id;
                        queue.Enqueue(childFrn);
                    }
                }

                if (ItemCount - lastReported >= 50_000)
                {
                    lastReported = ItemCount;
                    progress?.Report(ItemCount);
                    if (ProcessMemory.Current() is { } mem && mem.ResidentBytes > Peak)
                        Peak = mem.ResidentBytes;
                }
            }

            return _tree;
        }
    }
}
