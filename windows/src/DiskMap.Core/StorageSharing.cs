using System.Buffers.Binary;
using System.Runtime.InteropServices;
using DiskMap.Core.Native;

namespace DiskMap.Core;

/// <summary>
/// What deleting a set of paths would actually free, from the
/// filesystem's own per-file accounting instead of apparent size — the
/// Windows port of the macOS StorageSharing probe (TASK-038).
///
/// Windows differences, honestly stated:
/// - File identity is (volume serial, file index) from
///   GetFileInformationByHandle; link count is nNumberOfLinks. A
///   multiply-linked file counts once, and only when every one of its
///   names is staged — deleting the last name frees the bytes, deleting
///   fewer frees nothing. This is authoritative: Windows always knows
///   the link count.
/// - There is no clone-refcount API. ReFS block-clone sharing is
///   detectable between two paths by extent-map compare (CloneDetector)
///   but the *family size* is not — a shared extent might be held by a
///   third, unstaged copy. So extent sharing is never counted as
///   reclaimable here; it only marks the estimate a lower bound.
///   Hard links are the measurable sharing class on Windows.
/// - Directory measurement walks with NtQueryDirectoryFile so file id
///   and on-disk AllocationSize come inline; the per-file handle is
///   opened only for the link count the listing can't carry.
/// </summary>
public static class StorageSharing
{
    /// <summary>(volume serial, file index) — one file's identity.</summary>
    internal readonly record struct InodeKey(uint Volume, long FileId);

    /// <summary>One file's facts, as the filesystem reports them.</summary>
    internal readonly record struct FileFacts(
        uint Volume,
        long FileId,
        bool IsDirectory,
        uint LinkCount,
        long Allocated);

    /// <summary>Per-inode sharing fact carried out of a profile.</summary>
    internal sealed class HardLinkShare
    {
        public uint LinkCount;
        public long Bytes;
        public int NamesStaged;
    }

    /// <summary>
    /// Everything reclaim math needs to know about one staged path, kept
    /// compact: ordinary files collapse into sums; only hard-linked files
    /// are remembered individually, and those are rare.
    /// </summary>
    public sealed class Profile
    {
        public int FileCount { get; internal set; }
        /// <summary>What the path occupies on disk, shared or not.</summary>
        public long AllocatedBytes { get; internal set; }
        /// <summary>
        /// Freed by deleting this path, excluding hard-linked data — the
        /// group rule across the whole queue decides those.
        /// </summary>
        internal long OwnedBytes { get; set; }
        /// <summary>Blocks shared with something unidentifiable — never counted, flags a lower bound.</summary>
        public long SharedUnattributedBytes { get; internal set; }
        internal Dictionary<InodeKey, HardLinkShare> HardLinks { get; } = new();
        /// <summary>False when part of a directory could not be read, or a mount point lay inside it.</summary>
        public bool IsComplete { get; internal set; } = true;

        internal void Add(in FileFacts facts, int namesStaged = 1)
        {
            if (facts.IsDirectory) return;
            FileCount++;
            AllocatedBytes += facts.Allocated;
            if (facts.LinkCount > 1)
            {
                // A name is only worth its bytes once every name of the
                // inode is going — node_modules linked into a store frees
                // almost nothing on its own.
                var key = new InodeKey(facts.Volume, facts.FileId);
                if (!HardLinks.TryGetValue(key, out var share))
                    HardLinks[key] = share = new HardLinkShare
                    {
                        LinkCount = facts.LinkCount,
                        Bytes = facts.Allocated,
                    };
                share.NamesStaged += namesStaged;
                return;
            }
            OwnedBytes += facts.Allocated;
        }
    }

    /// <summary>
    /// Profiles a file or a whole directory tree. Returns null when the
    /// path cannot be examined at all, so callers fall back to the size
    /// they were given.
    /// </summary>
    public static Profile? ProfileAt(string path)
    {
        var profile = new Profile();
        var rootFacts = FactsOf(path);
        if (rootFacts is null) return null;
        if (!rootFacts.Value.IsDirectory)
        {
            profile.Add(rootFacts.Value);
            return profile;
        }
        Walk(path, rootFacts.Value.Volume, profile);
        return profile;
    }

    /// <summary>
    /// One open + two info queries: link count and identity from
    /// GetFileInformationByHandle, real on-disk bytes from the standard
    /// info class. Reparse points are opened without following and skipped
    /// by the caller — a staged symlink frees its own bytes, never its
    /// target's.
    /// </summary>
    /// <summary>Public name for <see cref="FactsOf"/> — the seeded-staging path (WIN-013) asks for one file's facts.</summary>
    internal static FileFacts? FactsOfPublic(string path) => FactsOf(path);

    private static FileFacts? FactsOf(string path)
    {
        using var handle = Win32.CreateFileW(
            Win32.ExtendedPath(path), Win32.FILE_READ_ATTRIBUTES,
            Win32.FILE_SHARE_READ | Win32.FILE_SHARE_WRITE | Win32.FILE_SHARE_DELETE,
            IntPtr.Zero, Win32.OPEN_EXISTING,
            Win32.FILE_FLAG_BACKUP_SEMANTICS | Win32.FILE_FLAG_OPEN_REPARSE_POINT,
            IntPtr.Zero);
        if (handle.IsInvalid) return null;
        if (!Win32.GetFileInformationByHandle(handle, out var info)) return null;
        long allocated = info.dwFileAttributes is 0 ? 0
            : ((long)info.nFileSizeHigh << 32) | info.nFileSizeLow;
        bool isDir = (info.dwFileAttributes & Win32.FILE_ATTRIBUTE_DIRECTORY) != 0;
        if (!isDir && Win32.GetFileInformationByHandleEx(
                handle, Win32.FileStandardInfo, out var standard,
                Marshal.SizeOf<Win32.FILE_STANDARD_INFO>()))
        {
            allocated = standard.AllocationSize;
        }
        else if (!isDir)
        {
            allocated = RoundUp(allocated, 4096); // no standard info: cluster-rounded guess
        }
        long fileId = (((long)info.nFileIndexHigh << 32) | info.nFileIndexLow) & 0x0000FFFFFFFFFFFF;
        return new FileFacts(
            Volume: info.dwVolumeSerialNumber,
            FileId: fileId,
            IsDirectory: isDir,
            LinkCount: info.nNumberOfLinks,
            Allocated: Math.Max(0, allocated));
    }

    private static long RoundUp(long bytes, long unit) => bytes <= 0 ? 0 : (bytes + unit - 1) / unit * unit;

    /// <summary>
    /// Depth-first listing of one staged folder via NtQueryDirectoryFile,
    /// then one handle per file for the link count. Reparse points and
    /// cloud placeholders are respected exactly like the scan's Decide —
    /// a staged folder's measured bytes should equal what its tree
    /// subtree showed. A directory it can't list flags the profile
    /// incomplete rather than shrinking the figure quietly.
    /// </summary>
    private static unsafe void Walk(string directory, uint rootVolume, Profile profile)
    {
        var buffer = new byte[128 * 1024];
        var pending = new Stack<string>();
        pending.Push(directory);
        while (pending.Count > 0)
        {
            string current = pending.Pop();
            using var handle = Win32.CreateFileW(
                Win32.ExtendedPath(current),
                Win32.FILE_LIST_DIRECTORY | Win32.FILE_READ_ATTRIBUTES | Win32.SYNCHRONIZE,
                Win32.FILE_SHARE_READ | Win32.FILE_SHARE_WRITE | Win32.FILE_SHARE_DELETE,
                IntPtr.Zero, Win32.OPEN_EXISTING,
                Win32.FILE_FLAG_BACKUP_SEMANTICS | Win32.FILE_SYNCHRONOUS_IO_NONALERT,
                IntPtr.Zero);
            if (handle.IsInvalid) { profile.IsComplete = false; continue; }

            bool restart = true;
            fixed (byte* p = buffer)
            {
                while (true)
                {
                    int status = Win32.NtQueryDirectoryFile(
                        handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out _,
                        p, buffer.Length, Win32.FileIdBothDirectoryInformation,
                        ReturnSingleEntry: false, IntPtr.Zero, RestartScan: restart);
                    restart = false;
                    if (status == Win32.STATUS_NO_MORE_FILES || status == Win32.STATUS_NO_SUCH_FILE
                        || status == Win32.STATUS_OBJECT_NAME_NOT_FOUND)
                    {
                        break;
                    }
                    if (status != Win32.STATUS_SUCCESS)
                    {
                        profile.IsComplete = false;
                        break;
                    }
                    int offset = 0;
                    while (true)
                    {
                        var rec = new ReadOnlySpan<byte>(p + offset, buffer.Length - offset);
                        int next = BinaryPrimitives.ReadInt32LittleEndian(rec);
                        int nameLen = BinaryPrimitives.ReadInt32LittleEndian(rec[60..]);
                        if (nameLen < 0 || 104 + nameLen > rec.Length) { profile.IsComplete = false; break; }
                        string name = System.Text.Encoding.Unicode.GetString(rec.Slice(104, nameLen));
                        uint attrs = BinaryPrimitives.ReadUInt32LittleEndian(rec[56..]);
                        long allocated = BinaryPrimitives.ReadInt64LittleEndian(rec[48..]);
                        if (next <= 0) { offset = -1; }
                        else offset += next;

                        if (name is not ("." or ".."))
                        {
                            var decision = ScanEngine.DecideFromAttributes(attrs, 0, allocated);
                            bool isDir = (attrs & Win32.FILE_ATTRIBUTE_DIRECTORY) != 0;
                            if (decision.Include)
                            {
                                string child = current + '\\' + name;
                                if (isDir)
                                {
                                    if (!decision.SkipDescendants) pending.Push(child);
                                }
                                else if (decision.NotDownloaded)
                                {
                                    // A cloud placeholder frees what it
                                    // actually holds locally — usually 0.
                                    profile.Add(new FileFacts(rootVolume, 0, false, 1, allocated));
                                }
                                else if (FactsOf(child) is { } facts)
                                {
                                    // A mount point inside the staged
                                    // folder is not part of this reclaim.
                                    if (facts.Volume == rootVolume) profile.Add(facts);
                                    else profile.IsComplete = false;
                                }
                                else profile.IsComplete = false;
                            }
                        }
                        if (offset < 0) break;
                    }
                }
            }
        }
    }
}
