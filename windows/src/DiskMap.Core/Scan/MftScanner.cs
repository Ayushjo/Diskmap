using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using DiskMap.Core.Native;
using Microsoft.Win32.SafeHandles;

namespace DiskMap.Core;

/// <summary>
/// Primary scan path: parses the NTFS Master File Table directly — the
/// same approach WizTree uses. One streaming pass over $MFT yields every
/// file's name, parent, sizes, and timestamps, versus one directory open
/// plus FindNextFileW per file.
///
/// Requirements: NTFS volume + admin (raw reads of \\?\X: need
/// SeBackupPrivilege). Anything missing returns null with a reason so the
/// caller falls back to the FindFirstFileExW scanner.
///
/// $MFT's own extents come from the run list of FILE record 0's $DATA
/// (continued through its $ATTRIBUTE_LIST when the MFT is fragmented) —
/// OpenFileById(0) fails with ERROR_INVALID_PARAMETER even elevated, which
/// silently forced every scan onto the slow path before.
///
/// Reads are I/O-bound: a 1 TB NVMe volume streams its 8 GB $MFT at
/// ~1.3 GB/s whatever the handle (volume, unbuffered, physical disk),
/// queue depth or request size. Names go to per-chunk pools on the pinned
/// heap; interning them in the workers instead tripled the read phase
/// (GC pauses over millions of young dictionary nodes).
///
/// Hard links follow the macOS rule: every name is a node, the bytes are
/// charged once — to the first name the breadth-first build reaches — and
/// later names read 0 with NodeFlags.HardLink.
///
/// Verified 2026-10-03, elevated, against a live 1 TB NTFS system volume
/// (8.1M records, 56 $MFT extents): extents from record 0, fixups, names,
/// parents, sizes and links. C:\Windows\System32 through the MFT lists
/// 33,389 items against the FindFirstFileExW walk's 33,404 (files created
/// between the two scans); remaining size gaps are links charged once and
/// logs being written. Run decoding and fixups also have unit tests.
///
/// Layout notes (little-endian; FILE_RECORD_SEGMENT_HEADER and
/// ATTRIBUTE_RECORD_HEADER):
/// - FILE record: "FILE" @0, update-sequence offset @4 u16, count @6 u16,
///   first attribute @20 u16, flags @22 u16 (1 in use, 2 directory), base
///   record @32 u64 (0 for a base record).
/// - Update sequence: the last 2 bytes of every 512-byte stride hold the
///   sequence number; the real bytes sit in the array after it.
/// - Attribute: type @0, length @4, non-resident @8, name length @9, flags
///   @12 (0x0001 compressed, 0x8000 sparse). Resident: value length @16,
///   value offset @20. Non-resident: lowest VCN @16, run list offset @32,
///   allocated @40, data size @48, compressed size @64.
/// - $STANDARD_INFORMATION (0x10): modified @8, file attributes @32.
/// - $FILE_NAME (0x30): parent @0 (low 48 bits = record), modified @16,
///   allocated @40, size @48, attributes @56, name length @64, namespace
///   @65 (0 POSIX, 1 Win32, 2 DOS, 3 Win32+DOS), UTF-16 name @66.
/// - $ATTRIBUTE_LIST (0x20) entry: type @0, length @4 u16, name length @6,
///   segment @16 (low 48 bits = record).
/// </summary>
internal static class MftScanner
{
    private const uint FileSignature = 0x454C4946; // "FILE"
    private const uint AttributeStandardInformation = 0x10;
    private const uint AttributeAttributeList = 0x20;
    private const uint AttributeFileName = 0x30;
    private const uint AttributeData = 0x80;
    private const uint AttributeEnd = 0xFFFFFFFF;
    private const long RecordMask = 0x0000FFFFFFFFFFFF;
    private const int RootRecord = 5;

    /// <summary>Records below this are NTFS metadata ($MFT, $LogFile, $Extend…) — never listed, like FindFirstFile.</summary>
    private const int FirstUserRecord = 24;

    /// <summary>Records per read: 1 MiB at the usual 1 KiB record (bigger reads measured slower).</summary>
    private const int RecordsPerChunk = 1024;

    internal readonly record struct Extent(long Vcn, long Lcn, long Clusters);

    private struct Record
    {
        public long Logical;
        public long Allocated;
        public int Parent;      // directory of the primary name
        public int NameOffset;  // primary name, in pool frn / RecordsPerChunk
        public uint Attributes;
        public int Day;
        public byte NameLength; // 0 when only extension records name it
        public bool Live;       // an in-use base record was parsed here
        public bool HasData;    // sizes came from the unnamed $DATA, not $FILE_NAME
    }

    /// <summary>A name beyond the record's primary one: a hard link. Its chars sit in pool <see cref="Pool"/>.</summary>
    private readonly record struct Link(int Frn, int Parent, int Pool, int NameOffset, byte NameLength);

    public static WalkResult? Walk(string root, IProgress<int>? progress, out string? whyNot)
    {
        string? volumeRoot = Path.GetPathRoot(Path.GetFullPath(root));
        whyNot = "not a local drive";
        if (volumeRoot is null || volumeRoot.Length < 3 || volumeRoot[1] != ':') return null;
        string volumePath = @"\\?\" + char.ToUpperInvariant(volumeRoot[0]) + ":";

        // Raw volume reads need SeBackupPrivilege *enabled* — admin tokens
        // hold it disabled by default.
        whyNot = "needs administrator";
        if (!Win32.EnableBackupPrivileges()) return null;
        using var volume = OpenVolume(volumePath);
        if (volume.IsInvalid) return null;

        whyNot = "not NTFS";
        if (!GetVolumeData(volume, out var data)) return null;
        int recordSize = (int)data.BytesPerFileRecordSegment;
        long clusterSize = data.BytesPerCluster;
        long recordCount = data.MftValidDataLength / Math.Max(1, recordSize);
        whyNot = "unsupported MFT geometry";
        if (recordSize < 512 || clusterSize < 512 || recordCount <= FirstUserRecord || recordCount > 500_000_000)
            return null;
        whyNot = "scan root not found";
        if (!TryGetFileRecordIndex(root, out long rootFrn) || rootFrn >= recordCount) return null;
        whyNot = "$MFT layout unreadable";
        var extents = ReadMftExtents(volume, recordSize, clusterSize, data.MftStartLcn, data.MftValidDataLength);
        if (extents is null) return null;

        var records = new Record[recordCount];
        long chunks = (recordCount + RecordsPerChunk - 1) / RecordsPerChunk;
        var pools = new char[chunks][];
        var links = new Link[chunks][];
        var extensionSizes = new ConcurrentDictionary<int, (long Logical, long Allocated)>();
        whyNot = "$MFT read failed";
        if (!ReadAllRecords(volumePath, extents, recordSize, clusterSize, records, pools, links, extensionSizes, progress))
            return null;

        whyNot = null;
        return BuildTree(root, (int)rootFrn, records, pools, links, extensionSizes, progress);
    }

    private static SafeFileHandle OpenVolume(string volumePath) => Win32.CreateFileW(
        volumePath, Win32.GENERIC_READ,
        Win32.FILE_SHARE_READ | Win32.FILE_SHARE_WRITE | Win32.FILE_SHARE_DELETE,
        IntPtr.Zero, Win32.OPEN_EXISTING, 0, IntPtr.Zero);

    private static unsafe bool GetVolumeData(SafeFileHandle volume, out Win32.NTFS_VOLUME_DATA_BUFFER data)
    {
        fixed (void* outBuf = &data)
        {
            return Win32.DeviceIoControl(
                volume, Win32.FSCTL_GET_NTFS_VOLUME_DATA,
                null, 0, outBuf, sizeof(Win32.NTFS_VOLUME_DATA_BUFFER),
                out _, IntPtr.Zero);
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
        frn = (((long)info.nFileIndexHigh << 32) | info.nFileIndexLow) & RecordMask;
        return true;
    }

    /// <summary>
    /// $MFT's layout: the run list of FILE record 0's unnamed $DATA. A
    /// fragmented $MFT continues that list in extension records named by
    /// record 0's $ATTRIBUTE_LIST. Null unless the runs cover the valid MFT.
    /// </summary>
    private static List<Extent>? ReadMftExtents(
        SafeFileHandle volume, int recordSize, long clusterSize, long startLcn, long validBytes)
    {
        var record = AlignedBuffer(recordSize);
        if (!ReadExact(volume, startLcn * clusterSize, record) || !PrepareRecord(record)) return null;
        var extents = new List<Extent>();
        if (!AddDataRuns(record, extents)) return null;

        long needed = (validBytes + clusterSize - 1) / clusterSize;
        if (Covered(extents) < needed)
        {
            var list = ResidentValue(FindAttribute(record, AttributeAttributeList));
            var extension = AlignedBuffer(recordSize);
            var seen = new HashSet<long>();
            for (int p = 0; p + 24 <= list.Length;)
            {
                int length = U16(list, p + 4);
                if (length < 24) break;
                long segment = I64(list, p + 16) & RecordMask;
                if (U32(list, p) == AttributeData && list[p + 6] == 0 && segment != 0 && seen.Add(segment)
                    && (VolumeOffset(extents, segment * recordSize, recordSize, clusterSize) is not { } offset
                        || !ReadExact(volume, offset, extension) || !PrepareRecord(extension)
                        || !AddDataRuns(extension, extents)))
                {
                    return null;
                }
                p += length;
            }
        }
        extents.Sort((a, b) => a.Vcn.CompareTo(b.Vcn));
        return Covered(extents) >= needed ? extents : null;
    }

    private static long Covered(List<Extent> extents) => extents.Sum(e => e.Clusters);

    private static long? VolumeOffset(List<Extent> extents, long streamOffset, int length, long clusterSize)
    {
        foreach (var e in extents)
        {
            long start = e.Vcn * clusterSize;
            if (streamOffset >= start && streamOffset + length <= start + e.Clusters * clusterSize)
                return e.Lcn * clusterSize + (streamOffset - start);
        }
        return null;
    }

    private static bool AddDataRuns(ReadOnlySpan<byte> record, List<Extent> extents)
    {
        int pos = U16(record, 20);
        while (TryNextAttribute(record, ref pos, out uint type, out var attr))
        {
            if (type == AttributeData && attr[8] != 0 && attr[9] == 0 && !DecodeRuns(attr, extents))
                return false;
        }
        return true;
    }

    /// <summary>
    /// Mapping pairs: a header byte (low nibble = length bytes, high nibble
    /// = offset bytes), the run length, then a signed LCN delta from the
    /// previous run. Offset size 0 is a sparse run. 0 terminates.
    /// </summary>
    internal static bool DecodeRuns(ReadOnlySpan<byte> attr, List<Extent> extents)
    {
        if (attr.Length < 64) return false;
        long vcn = I64(attr, 16), lcn = 0;
        for (int p = U16(attr, 32); p < attr.Length;)
        {
            int header = attr[p++];
            if (header == 0) return true;
            int lengthBytes = header & 0xF, offsetBytes = header >> 4;
            if (lengthBytes == 0 || lengthBytes > 8 || offsetBytes > 8 || p + lengthBytes + offsetBytes > attr.Length)
                return false;
            long clusters = LittleEndian(attr.Slice(p, lengthBytes), signed: false);
            p += lengthBytes;
            if (offsetBytes > 0)
            {
                lcn += LittleEndian(attr.Slice(p, offsetBytes), signed: true);
                p += offsetBytes;
                extents.Add(new Extent(vcn, lcn, clusters));
            }
            vcn += clusters;
        }
        return false;
    }

    private static long LittleEndian(ReadOnlySpan<byte> bytes, bool signed)
    {
        long value = 0;
        for (int i = bytes.Length - 1; i >= 0; i--) value = (value << 8) | bytes[i];
        if (signed && bytes.Length < 8 && (bytes[^1] & 0x80) != 0) value |= -1L << (8 * bytes.Length);
        return value;
    }

    /// <summary>
    /// Workers each own a volume handle (I/O on one synchronous handle is
    /// serialized) and claim chunks in order, so reads stay near-sequential
    /// while parsing overlaps the other workers' reads.
    /// </summary>
    private static bool ReadAllRecords(
        string volumePath, List<Extent> extents, int recordSize, long clusterSize,
        Record[] records, char[][] pools, Link[][] links,
        ConcurrentDictionary<int, (long Logical, long Allocated)> extensionSizes,
        IProgress<int>? progress)
    {
        int next = -1, failed = 0;
        long parsed = 0;
        var workers = new Task[Math.Clamp(Environment.ProcessorCount, 2, 16)];
        for (int w = 0; w < workers.Length; w++)
        {
            workers[w] = Task.Run(() =>
            {
                using var volume = OpenVolume(volumePath);
                if (volume.IsInvalid) { Volatile.Write(ref failed, 1); return; }
                var buffer = AlignedBuffer(RecordsPerChunk * recordSize);
                // Names can't outgrow the records holding them: UTF-16, so half the bytes.
                var names = new char[RecordsPerChunk * recordSize / 2];
                var extra = new List<Link>();
                int chunk;
                while (Volatile.Read(ref failed) == 0 && (chunk = Interlocked.Increment(ref next)) < pools.Length)
                {
                    long first = (long)chunk * RecordsPerChunk;
                    int count = (int)Math.Min(RecordsPerChunk, records.Length - first);
                    var span = buffer[..(count * recordSize)];
                    if (!ReadChunk(volume, extents, clusterSize, first * recordSize, span))
                    {
                        Volatile.Write(ref failed, 1);
                        return;
                    }
                    var pool = new ChunkNames(chunk, names);
                    extra.Clear();
                    for (int i = 0; i < count; i++)
                        ParseRecord(span.Slice(i * recordSize, recordSize), (int)(first + i), records, ref pool, extra, extensionSizes);
                    // Pinned heap: these live for the whole scan, and gen0/gen1
                    // GCs would otherwise copy every chunk's names twice.
                    var chars = GC.AllocateUninitializedArray<char>(pool.Used, pinned: true);
                    names.AsSpan(0, pool.Used).CopyTo(chars);
                    pools[chunk] = chars;
                    links[chunk] = extra.Count == 0 ? [] : [.. extra];

                    long total = Interlocked.Add(ref parsed, count);
                    if (total / 262_144 != (total - count) / 262_144) progress?.Report((int)total);
                }
            });
        }
        Task.WaitAll(workers);
        return failed == 0;
    }

    /// <summary>The worker's name scratch for one chunk; copied to that chunk's pool when the chunk is done.</summary>
    private struct ChunkNames(int chunk, char[] chars)
    {
        public readonly int Chunk = chunk;
        public int Used;

        /// <summary>Copies the $FILE_NAME value's name; returns its offset in the pool.</summary>
        public int Add(ReadOnlySpan<byte> rec, int fileName)
        {
            int at = Used;
            int length = rec[fileName + 64];
            MemoryMarshal.Cast<byte, char>(rec.Slice(fileName + 66, length * 2)).CopyTo(chars.AsSpan(at));
            Used += length;
            return at;
        }
    }

    /// <summary>
    /// Fills <paramref name="dest"/> with MFT bytes [start, start+length):
    /// the buffer is indexed by MFT offset, so a record split across two
    /// extents reassembles. Gaps (sparse/unallocated) are zeroed so no
    /// stale record from the previous chunk survives.
    /// </summary>
    private static bool ReadChunk(SafeFileHandle volume, List<Extent> extents, long clusterSize, long start, Span<byte> dest)
    {
        long end = start + dest.Length, filled = start;
        foreach (var e in extents)
        {
            long extentStart = e.Vcn * clusterSize, extentEnd = extentStart + e.Clusters * clusterSize;
            long from = Math.Max(start, extentStart), to = Math.Min(end, extentEnd);
            if (from >= to) continue;
            if (from > filled) dest[(int)(filled - start)..(int)(from - start)].Clear();
            if (!ReadExact(volume, e.Lcn * clusterSize + (from - extentStart), dest[(int)(from - start)..(int)(to - start)]))
                return false;
            filled = to;
        }
        if (filled < end) dest[(int)(filled - start)..].Clear();
        return true;
    }

    private static bool ReadExact(SafeFileHandle volume, long offset, Span<byte> dest)
    {
        try
        {
            while (!dest.IsEmpty)
            {
                int read = RandomAccess.Read(volume, dest, offset);
                if (read <= 0) return false;
                dest = dest[read..];
                offset += read;
            }
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    /// <summary>Raw volume reads are non-cached: buffer, offset and length must be sector-aligned.</summary>
    private static unsafe Span<byte> AlignedBuffer(int length)
    {
        const int alignment = 4096;
        var array = GC.AllocateUninitializedArray<byte>(length + alignment, pinned: true);
        fixed (byte* p = array)
        {
            int pad = (int)((alignment - ((nint)p & (alignment - 1))) & (alignment - 1));
            return array.AsSpan(pad, length);
        }
    }

    /// <summary>
    /// Checks the FILE signature and undoes the update-sequence fixup.
    /// False for a torn or stale record (a stride not ending in the
    /// sequence number).
    /// </summary>
    internal static bool PrepareRecord(Span<byte> rec)
    {
        if (rec.Length < 48 || U32(rec, 0) != FileSignature) return false;
        int usaOffset = U16(rec, 4), usaCount = U16(rec, 6);
        if (usaCount < 2 || usaOffset + usaCount * 2 > rec.Length || rec.Length % (usaCount - 1) != 0) return false;
        int stride = rec.Length / (usaCount - 1);
        ushort sequence = U16(rec, usaOffset);
        for (int i = 1; i < usaCount; i++)
        {
            int end = i * stride - 2;
            if (U16(rec, end) != sequence) return false;
            rec[end] = rec[usaOffset + i * 2];
            rec[end + 1] = rec[usaOffset + i * 2 + 1];
        }
        return true;
    }

    private static void ParseRecord(
        Span<byte> rec, int frn, Record[] records, ref ChunkNames names, List<Link> extraLinks,
        ConcurrentDictionary<int, (long Logical, long Allocated)> extensionSizes)
    {
        if (U32(rec, 0) != FileSignature || (U16(rec, 22) & 1) == 0 || !PrepareRecord(rec)) return;
        bool isDirectory = (U16(rec, 22) & 2) != 0;
        long baseRecord = I64(rec, 32) & RecordMask;

        uint attributes = 0;
        long modified = 0, logical = 0, allocated = 0;
        bool hasInfo = false, hasData = false;
        // Every non-DOS $FILE_NAME is a hard link: offsets of their values in rec.
        Span<int> fileNames = stackalloc int[16];
        int nameCount = 0, primary = -1;

        int pos = U16(rec, 20);
        while (TryNextAttribute(rec, ref pos, out uint type, out var attr))
        {
            if (type == AttributeStandardInformation)
            {
                var value = ResidentValue(attr);
                if (value.Length >= 36)
                {
                    modified = I64(value, 8);
                    attributes = U32(value, 32);
                    hasInfo = true;
                }
            }
            else if (type == AttributeFileName)
            {
                var value = ResidentValue(attr);
                // DOS 8.3 alias: not a link, never shown.
                if (value.Length < 66 || value[65] == 2 || 66 + value[64] * 2 > value.Length || nameCount == fileNames.Length)
                    continue;
                // Primary name: the first Win32 one, else the first POSIX one.
                if (primary < 0 || (value[65] != 0 && rec[fileNames[primary] + 65] == 0)) primary = nameCount;
                fileNames[nameCount++] = pos - attr.Length + U16(attr, 20);
            }
            else if (type == AttributeData && attr[9] == 0) // the unnamed stream; ADS don't count, like FindFirstFile
            {
                if (attr[8] == 0 && attr.Length >= 24)
                {
                    logical = U32(attr, 16); // resident: lives in the record, no clusters
                    allocated = 0;
                    hasData = true;
                }
                else if (attr[8] != 0 && attr.Length >= 64 && I64(attr, 16) == 0) // first segment carries the sizes
                {
                    logical = I64(attr, 48);
                    allocated = (U16(attr, 12) & 0x8001) != 0 && attr.Length >= 72 ? I64(attr, 64) : I64(attr, 40);
                    hasData = true;
                }
            }
        }

        if (baseRecord != 0)
        {
            // Extension record: holds what overflowed the base — the moved
            // $DATA's sizes, and names of heavily hard-linked files.
            if (baseRecord >= records.Length) return;
            if (hasData) extensionSizes[(int)baseRecord] = (logical, allocated);
            for (int i = 0; i < nameCount; i++) AddLink(rec, fileNames[i], (int)baseRecord, records.Length, ref names, extraLinks);
            return;
        }

        int parent = -1, nameOffset = 0, nameLength = 0;
        if (primary >= 0)
        {
            int fileName = fileNames[primary];
            long parentRecord = I64(rec, fileName) & RecordMask;
            if (parentRecord < records.Length)
            {
                parent = (int)parentRecord;
                nameLength = rec[fileName + 64];
                nameOffset = names.Add(rec, fileName);
            }
            if (!hasInfo) { attributes = U32(rec, fileName + 56); modified = I64(rec, fileName + 16); }
            if (!hasData) { allocated = I64(rec, fileName + 40); logical = I64(rec, fileName + 48); }
        }
        if (isDirectory) attributes |= Win32.FILE_ATTRIBUTE_DIRECTORY;
        records[frn] = new Record
        {
            Logical = logical,
            Allocated = allocated,
            Parent = parent,
            NameOffset = nameOffset,
            NameLength = (byte)nameLength,
            Attributes = attributes,
            Day = Win32.FileTimeToModifiedDay(modified),
            Live = true,
            HasData = hasData,
        };
        for (int i = 0; i < nameCount; i++)
            if (i != primary) AddLink(rec, fileNames[i], frn, records.Length, ref names, extraLinks);
    }

    private static void AddLink(ReadOnlySpan<byte> rec, int fileName, int frn, int recordCount, ref ChunkNames names, List<Link> links)
    {
        long parent = I64(rec, fileName) & RecordMask;
        if (parent < recordCount)
            links.Add(new Link(frn, (int)parent, names.Chunk, names.Add(rec, fileName), rec[fileName + 64]));
    }

    /// <summary>Next attribute, or false at the end marker or a malformed length.</summary>
    private static bool TryNextAttribute(ReadOnlySpan<byte> record, scoped ref int pos, out uint type, out ReadOnlySpan<byte> attr)
    {
        type = 0;
        attr = default;
        if (pos < 0 || pos + 16 > record.Length) return false;
        type = U32(record, pos);
        uint length = U32(record, pos + 4);
        if (type == AttributeEnd || length < 16 || length > (uint)(record.Length - pos)) return false;
        attr = record.Slice(pos, (int)length);
        pos += (int)length;
        return true;
    }

    private static ReadOnlySpan<byte> FindAttribute(ReadOnlySpan<byte> record, uint wanted)
    {
        int pos = U16(record, 20);
        while (TryNextAttribute(record, ref pos, out uint type, out var attr))
            if (type == wanted) return attr;
        return default;
    }

    private static ReadOnlySpan<byte> ResidentValue(ReadOnlySpan<byte> attr)
    {
        if (attr.Length < 24 || attr[8] != 0) return default;
        uint length = U32(attr, 16);
        int offset = U16(attr, 20);
        return offset + (long)length <= attr.Length ? attr.Slice(offset, (int)length) : default;
    }

    /// <summary>
    /// Rebuilds the FileTree under rootFrn from a CSR (compressed sparse
    /// row) children index. BFS order keeps every child id above its
    /// parent's, which RollUpSizes relies on.
    /// </summary>
    private static WalkResult BuildTree(
        string rootPath, int rootFrn, Record[] records, char[][] pools, Link[][] linkChunks,
        ConcurrentDictionary<int, (long Logical, long Allocated)> extensionSizes, IProgress<int>? progress)
    {
        int n = records.Length;
        var links = linkChunks.SelectMany(chunk => chunk).Where(l => IsChild(records, l.Frn, l.Parent)).ToArray();
        // 0: one name. 1: hard-linked, bytes not charged yet. 2: charged.
        var linkState = new byte[n];
        foreach (var link in links) linkState[link.Frn] = 1;

        // Child entries: e >= 0 is record e's primary name, e < 0 is link ~e.
        var start = new int[n + 1];
        for (int i = 0; i < n; i++)
            if (records[i].NameLength > 0 && IsChild(records, i, records[i].Parent)) start[records[i].Parent + 1]++;
        foreach (var link in links) start[link.Parent + 1]++;
        for (int i = 0; i < n; i++) start[i + 1] += start[i];
        var children = new int[start[n]];
        var cursor = start[..n];
        for (int i = 0; i < n; i++)
            if (records[i].NameLength > 0 && IsChild(records, i, records[i].Parent)) children[cursor[records[i].Parent]++] = i;
        for (int i = 0; i < links.Length; i++) children[cursor[links[i].Parent]++] = ~i;

        // A drive-root scan reaches nearly every entry; size the tree once.
        var tree = new FileTree(rootFrn == RootRecord ? children.Length + 1 : 0);
        int itemCount = 0, notDownloaded = 0;
        ulong peak = ProcessMemory.Current()?.ResidentBytes ?? 0;
        var queue = new Queue<(int Frn, int Node)>();
        queue.Enqueue((rootFrn, tree.AddNode(
            Win32Scanner.RootName(rootPath).AsSpan(), parentId: -1, isDirectory: true,
            logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)));

        // The count guard stops a corrupt parent cycle from looping forever.
        while (queue.TryDequeue(out var dir) && tree.Count <= children.Length + 1)
        {
            for (int i = start[dir.Frn]; i < start[dir.Frn + 1]; i++)
            {
                int entry = children[i];
                int frn = entry >= 0 ? entry : links[~entry].Frn;
                ref readonly var rec = ref records[frn];
                long logical = rec.Logical, allocated = rec.Allocated;
                if (!rec.HasData && extensionSizes.TryGetValue(frn, out var moved))
                    (logical, allocated) = moved;
                var decision = ScanEngine.DecideFromAttributes(rec.Attributes, logical, allocated);
                if (!decision.Include) continue;

                // NTFS has no directory hard links: a link is always a file.
                bool isDirectory = entry >= 0 && (rec.Attributes & Win32.FILE_ATTRIBUTE_DIRECTORY) != 0;
                byte flags = 0;
                if (decision.NotDownloaded)
                {
                    flags |= NodeFlags.NotDownloaded;
                    notDownloaded++;
                }
                bool alreadyCharged = false;
                if (linkState[frn] != 0)
                {
                    flags |= NodeFlags.HardLink;
                    alreadyCharged = linkState[frn] == 2;
                    linkState[frn] = 2;
                }

                var name = entry >= 0
                    ? pools[frn / RecordsPerChunk].AsSpan(rec.NameOffset, rec.NameLength)
                    : pools[links[~entry].Pool].AsSpan(links[~entry].NameOffset, links[~entry].NameLength);
                int id = tree.AddNode(
                    name, parentId: dir.Node,
                    isDirectory: isDirectory,
                    logicalSize: alreadyCharged ? 0 : decision.LogicalSize,
                    allocatedSize: alreadyCharged ? 0 : decision.AllocatedSize,
                    modifiedDaysSinceEpoch: rec.Day,
                    flags: flags);
                if (isDirectory && !decision.SkipDescendants) queue.Enqueue((frn, id));

                if (++itemCount % 262_144 == 0)
                {
                    progress?.Report(itemCount);
                    if (ProcessMemory.Current() is { } mem && mem.ResidentBytes > peak) peak = mem.ResidentBytes;
                }
            }
        }
        return new WalkResult
        {
            Tree = tree,
            ItemCount = itemCount,
            NotDownloadedCount = notDownloaded,
            PeakResidentBytesDuringWalk = Math.Max(peak, ProcessMemory.Current()?.ResidentBytes ?? 0),
            Backend = "mft",
        };
    }

    /// <summary>
    /// A name of a live user record under a real parent — the root names
    /// itself as parent, and metadata records never show.
    /// </summary>
    private static bool IsChild(Record[] records, int frn, int parent) =>
        frn >= FirstUserRecord && records[frn].Live && (uint)parent < (uint)records.Length && parent != frn;

    private static ushort U16(ReadOnlySpan<byte> s, int offset) => BinaryPrimitives.ReadUInt16LittleEndian(s[offset..]);
    private static uint U32(ReadOnlySpan<byte> s, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(s[offset..]);
    private static long I64(ReadOnlySpan<byte> s, int offset) => BinaryPrimitives.ReadInt64LittleEndian(s[offset..]);
}
