using System.Text;

namespace DiskMap.Core;

/// <summary>
/// A compact, cache-friendly representation of a scanned filesystem tree.
///
/// This is the single biggest lever on scan memory, same as the macOS build:
/// a class-per-file pays ~48+ bytes of object overhead before a single field
/// is stored, and every string is its own heap allocation. Multiply by a few
/// million files and you're well into gigabytes for metadata that should fit
/// in tens of megabytes.
///
/// The fix is a struct-of-arrays layout: every field lives in its own packed
/// array, nodes are referenced by int index instead of pointer, and repeated
/// strings (folder names like "node_modules", ".git") are interned once
/// instead of re-allocated per occurrence.
/// </summary>
public sealed class FileTree
{
    // MARK: Name interning

    private readonly List<string> _nameTable = [];
    private readonly Dictionary<string, int> _nameLookup = [];

    /// <summary>Interned names, indexed by name id.</summary>
    public IReadOnlyList<string> NameTable => _nameTable;

    // MARK: Struct-of-arrays node storage, indexed by node id

    private List<int> _nameIndex;
    private List<int> _parent;        // -1 for root
    private List<int> _firstChild;    // -1 if none
    private List<int> _nextSibling;   // -1 if none
    private List<long> _logicalSize;  // logical file size
    private List<long> _allocatedSize; // size-on-disk (reflects compression/sparse)
    private List<int> _modifiedDay;   // days since epoch, not a full DateTime (8 bytes -> 4)
    private List<int> _createdDay;    // birth days since epoch; 0 = unknown
    private List<bool> _isDirectory;
    private List<byte> _flags;        // see NodeFlags
    private List<long> _fileId;       // filesystem file identity (NTFS record); 0 = unknown

    /// <summary>
    /// <paramref name="capacity"/>: expected node count when the caller
    /// knows it (the MFT scan does) — skips ~20 doubling copies of every
    /// packed list on a multi-million-node tree.
    /// </summary>
    public FileTree(int capacity = 0)
    {
        _nameIndex = new(capacity);
        _parent = new(capacity);
        _firstChild = new(capacity);
        _nextSibling = new(capacity);
        _logicalSize = new(capacity);
        _allocatedSize = new(capacity);
        _modifiedDay = new(capacity);
        _createdDay = new(capacity);
        _isDirectory = new(capacity);
        _flags = new(capacity);
        _fileId = new(capacity);
    }

    public int Count => _nameIndex.Count;

    // Read-only views the UI and codecs consume without copying.
    public IReadOnlyList<int> NameIndex => _nameIndex;
    public IReadOnlyList<int> Parent => _parent;
    public IReadOnlyList<int> FirstChild => _firstChild;
    public IReadOnlyList<int> NextSibling => _nextSibling;
    public IReadOnlyList<long> LogicalSize => _logicalSize;
    public IReadOnlyList<long> AllocatedSize => _allocatedSize;
    public IReadOnlyList<int> ModifiedDay => _modifiedDay;
    public IReadOnlyList<int> CreatedDay => _createdDay;
    public IReadOnlyList<bool> IsDirectory => _isDirectory;
    public IReadOnlyList<byte> Flags => _flags;

    /// <summary>
    /// The filesystem's own identity for a file — the NTFS file reference
    /// on NTFS, whatever the volume reports elsewhere. Two names of one
    /// file share an id; 0 means "not known" (a backend that can't see
    /// identity, or an old snapshot) and never dedupes.
    /// </summary>
    public IReadOnlyList<long> FileId => _fileId;

    /// <summary>
    /// Bytes per node of the packed arrays only: index, parent links,
    /// sizes, days, directory bit, flags, file id. No spare capacity, no
    /// interned string heap. Kept in sync with the stored field types.
    /// </summary>
    public const int PackedNodeStride = sizeof(int) * 6 + sizeof(long) * 3 + 1 + 1;

    /// <summary>
    /// Packed-array bytes if every list's count equals <paramref name="nodeCount"/>
    /// and there is no spare capacity. Name strings are not included.
    /// </summary>
    public static long PackedNodeBytesExact(int nodeCount) => (long)nodeCount * PackedNodeStride;

    public readonly record struct StorageFootprint(
        int NodeCount,
        int UniqueNameCount,
        long PackedNodeBytesExact,
        long PackedNodeBytesReserved,
        long NameUTF8Bytes);

    public StorageFootprint GetStorageFootprint()
    {
        long reserved = (long)(_nameIndex.Capacity + _parent.Capacity + _firstChild.Capacity
            + _nextSibling.Capacity + _modifiedDay.Capacity + _createdDay.Capacity) * sizeof(int)
            + (long)(_logicalSize.Capacity + _allocatedSize.Capacity + _fileId.Capacity) * sizeof(long)
            + _isDirectory.Capacity + _flags.Capacity;
        long utf8 = 0;
        foreach (var name in _nameTable) utf8 += Encoding.UTF8.GetByteCount(name);
        return new StorageFootprint(
            NodeCount: Count,
            UniqueNameCount: _nameTable.Count,
            PackedNodeBytesExact: PackedNodeBytesExact(Count),
            PackedNodeBytesReserved: reserved,
            NameUTF8Bytes: utf8);
    }

    /// <summary>
    /// Drop amortized-doubling slack so each packed list is sized for its
    /// count. Call once after a scan, not during inserts — AddNode stays
    /// O(1) amortized.
    /// </summary>
    public void Compact()
    {
        // Setting Capacity = Count reallocates to exact size — TrimExcess()
        // no-ops above a 90% fill ratio, which isn't what we want here.
        _nameIndex.Capacity = _nameIndex.Count;
        _parent.Capacity = _parent.Count;
        _firstChild.Capacity = _firstChild.Count;
        _nextSibling.Capacity = _nextSibling.Count;
        _logicalSize.Capacity = _logicalSize.Count;
        _allocatedSize.Capacity = _allocatedSize.Count;
        _modifiedDay.Capacity = _modifiedDay.Count;
        _createdDay.Capacity = _createdDay.Count;
        _isDirectory.Capacity = _isDirectory.Count;
        _flags.Capacity = _flags.Count;
        _fileId.Capacity = _fileId.Count;
        _nameTable.Capacity = _nameTable.Count;
    }

    public int AddNode(
        string name,
        int parentId,
        bool isDirectory,
        long logicalSize,
        long allocatedSize,
        int modifiedDaysSinceEpoch,
        byte flags = 0,
        int createdDaysSinceEpoch = 0,
        long fileId = 0)
    {
        return AppendNode(
            InternName(name), parentId, isDirectory,
            logicalSize, allocatedSize, modifiedDaysSinceEpoch, flags,
            createdDaysSinceEpoch, fileId);
    }

    /// <summary>
    /// Same as <see cref="AddNode(string,...)"/> but the name is a span from a
    /// scan buffer — no string allocation on an intern hit.
    /// </summary>
    public int AddNode(
        ReadOnlySpan<char> name,
        int parentId,
        bool isDirectory,
        long logicalSize,
        long allocatedSize,
        int modifiedDaysSinceEpoch,
        byte flags = 0,
        int createdDaysSinceEpoch = 0,
        long fileId = 0)
    {
        return AppendNode(
            InternName(name), parentId, isDirectory,
            logicalSize, allocatedSize, modifiedDaysSinceEpoch, flags,
            createdDaysSinceEpoch, fileId);
    }

    private int AppendNode(
        int nameId,
        int parentId,
        bool isDirectory,
        long logicalSize,
        long allocatedSize,
        int modifiedDaysSinceEpoch,
        byte flags,
        int createdDaysSinceEpoch,
        long fileId)
    {
        int id = _nameIndex.Count;
        _nameIndex.Add(nameId);
        _parent.Add(parentId);
        _firstChild.Add(-1);
        _nextSibling.Add(-1);
        _logicalSize.Add(logicalSize);
        _allocatedSize.Add(allocatedSize);
        _modifiedDay.Add(modifiedDaysSinceEpoch);
        _createdDay.Add(createdDaysSinceEpoch);
        _isDirectory.Add(isDirectory);
        _flags.Add(flags);
        _fileId.Add(fileId);
        if (parentId >= 0)
        {
            // Prepend to the parent's child list — O(1) insert. Child
            // order doesn't matter for a treemap since layout algorithms
            // re-sort by size anyway.
            _nextSibling[id] = _firstChild[parentId];
            _firstChild[parentId] = id;
        }
        return id;
    }

    /// <summary>ORs bits into a node's flag byte — the scanner's post-pass marks hard links this way.</summary>
    public void AddFlags(int id, byte flags) => _flags[id] |= flags;

    private int InternName(ReadOnlySpan<char> name)
    {
        // AlternateLookup: span-keyed probe, allocates a string only on miss.
        var lookup = _nameLookup.GetAlternateLookup<ReadOnlySpan<char>>();
        if (lookup.TryGetValue(name, out int existing)) return existing;
        string str = name.ToString();
        int id = _nameTable.Count;
        _nameTable.Add(str);
        _nameLookup[str] = id;
        return id;
    }

    private int InternName(string name)
    {
        if (_nameLookup.TryGetValue(name, out int existing)) return existing;
        int id = _nameTable.Count;
        _nameTable.Add(name);
        _nameLookup[name] = id;
        return id;
    }

    public string NameOf(int id) => _nameTable[_nameIndex[id]];

    /// <summary>
    /// Root first, <paramref name="id"/> last. Used by the treemap breadcrumb.
    /// Stops if a parent pointer cycles so a corrupt scan can't hang the UI.
    /// </summary>
    public List<int> AncestorIds(int id)
    {
        var chain = new List<int>();
        if (id < 0 || id >= Count) return chain;
        int current = id;
        int seen = 0;
        while (current >= 0 && seen < Count)
        {
            chain.Add(current);
            int parentId = _parent[current];
            if (parentId == current) break;
            current = parentId;
            seen++;
        }
        chain.Reverse();
        return chain;
    }

    /// <summary>
    /// Reconstructs the full path of a node by walking parent pointers.
    /// O(depth) — fine for on-demand UI lookups, don't call in a tight loop
    /// over every node.
    /// </summary>
    public string PathOf(int id, string rootPath)
    {
        var components = new List<string>();
        int current = id;
        while (current != 0)
        {
            components.Add(NameOf(current));
            current = _parent[current];
        }
        components.Reverse();
        return Path.Join([rootPath, .. components]);
    }

    /// <summary>
    /// Post-order rollup of every node's subtree in <paramref name="basis"/>.
    /// Call once after a scan rather than maintaining running totals on
    /// every insert.
    ///
    /// Child ids are always greater than their parent's id (a node is
    /// appended only when its parent's listing is processed), so a plain
    /// reverse pass is a valid post-order — no recursion, no stack depth
    /// risk on very deep trees.
    ///
    /// A normal directory contributes only its children — its own size is
    /// directory metadata, not subtree bytes. A not-downloaded directory is
    /// the exception: descendants were not enumerated, so the cloud size,
    /// if the filesystem reported one, lives on that node.
    ///
    /// Hard links: every name of a multiply-linked file carries its size
    /// in the tree, and the rollup suppresses all but the elected name —
    /// so N names of one inode can't inflate an ancestor's total. A file
    /// whose other names live outside the scan keeps its full size: its
    /// bytes really are in this folder.
    /// </summary>
    public long[] RollUpSizes(SizeBasis basis = SizeBasis.Allocated)
    {
        var totals = new long[Count];
        var suppressed = SuppressedHardLinkNames();
        for (int id = Count - 1; id >= 0; id--)
        {
            long total = OwnSize(id, basis, suppressed);
            int child = _firstChild[id];
            while (child != -1)
            {
                total += totals[child];
                child = _nextSibling[child];
            }
            totals[id] = total;
        }
        return totals;
    }

    /// <summary>One post-order walk filling both bases — prefer over two RollUpSizes calls.</summary>
    public (long[] Logical, long[] Allocated) RollUpBoth()
    {
        var logical = new long[Count];
        var allocated = new long[Count];
        var suppressed = SuppressedHardLinkNames();
        for (int id = Count - 1; id >= 0; id--)
        {
            long l = OwnSize(id, SizeBasis.Logical, suppressed);
            long a = OwnSize(id, SizeBasis.Allocated, suppressed);
            int child = _firstChild[id];
            while (child != -1)
            {
                l += logical[child];
                a += allocated[child];
                child = _nextSibling[child];
            }
            logical[id] = l;
            allocated[id] = a;
        }
        return (logical, allocated);
    }

    private long OwnSize(int id, SizeBasis basis, bool[]? suppressed = null)
    {
        // A second name for a file already charged elsewhere in this tree
        // contributes nothing: the blocks are the same blocks. Deleting
        // this name frees nothing until the last name goes.
        if (suppressed is not null && suppressed[id]) return 0;
        long selected = basis == SizeBasis.Logical ? _logicalSize[id] : _allocatedSize[id];
        if (!_isDirectory[id]) return selected;
        bool evictedWithoutChildren =
            (_flags[id] & NodeFlags.NotDownloaded) != 0 && _firstChild[id] == -1;
        return evictedWithoutChildren ? selected : 0;
    }

    /// <summary>
    /// What hard-link de-duplication removed from the totals, so a caller
    /// can explain the difference instead of silently reporting less than
    /// the sum of the parts.
    /// </summary>
    public readonly record struct HardLinkCorrection(
        int InodeCount, int DuplicateNameCount, long LogicalBytes, long AllocatedBytes)
    {
        public bool IsEmpty => DuplicateNameCount == 0;
        public static readonly HardLinkCorrection None = new(0, 0, 0, 0);
    }

    /// <summary>Bytes that would have been counted more than once without the rollup's de-duplication.</summary>
    public HardLinkCorrection GetHardLinkCorrection()
    {
        var groups = HardLinkGroups();
        if (groups is null) return HardLinkCorrection.None;
        int inodes = 0, dupNames = 0;
        long logical = 0, allocated = 0;
        foreach (var (_, ids) in groups)
        {
            inodes++;
            int keeper = ElectedName(ids);
            foreach (int id in ids)
            {
                if (id == keeper) continue;
                dupNames++;
                logical += _logicalSize[id];
                allocated += _allocatedSize[id];
            }
        }
        return new HardLinkCorrection(inodes, dupNames, logical, allocated);
    }

    /// <summary>
    /// Multiply-linked files with more than one name inside this tree.
    /// A file whose other name lives outside the scan is not
    /// double-counted here, so it is deliberately not a group.
    /// </summary>
    private Dictionary<long, List<int>>? HardLinkGroups()
    {
        List<int>? flagged = null;
        for (int i = 0; i < Count; i++)
        {
            if ((_flags[i] & NodeFlags.HardLink) != 0 && _fileId[i] != 0 && !_isDirectory[i])
                (flagged ??= []).Add(i);
        }
        if (flagged is null || flagged.Count < 2) return null;
        var byFile = new Dictionary<long, List<int>>();
        foreach (int id in flagged)
        {
            if (!byFile.TryGetValue(_fileId[id], out var list))
                byFile[_fileId[id]] = list = [];
            list.Add(id);
        }
        var groups = byFile.Where(kv => kv.Value.Count > 1)
            .ToDictionary(kv => kv.Key, kv => kv.Value);
        return groups.Count == 0 ? null : groups;
    }

    /// <summary>
    /// The one name that carries the bytes. Elected by lowest path, NOT by
    /// node id: ids and sibling order both fall out of how the scan's
    /// worker threads interleaved, so neither is stable between two scans
    /// of the same disk — and an unstable choice would make snapshot diffs
    /// show a file moving from one folder to another when nothing changed.
    /// </summary>
    private int ElectedName(List<int> ids)
    {
        int keeper = ids[0];
        string keeperKey = PathKeyOf(keeper);
        for (int i = 1; i < ids.Count; i++)
        {
            string key = PathKeyOf(ids[i]);
            if (string.CompareOrdinal(key, keeperKey) < 0)
            {
                keeper = ids[i];
                keeperKey = key;
            }
        }
        return keeper;
    }

    /// <summary>
    /// Root-relative "a/b/c". Built only for hard-linked nodes (a fraction
    /// of a percent of a real tree), never on the rollup hot path.
    /// </summary>
    private string PathKeyOf(int id)
    {
        var parts = new List<string>();
        int current = id;
        while (current > 0)
        {
            parts.Add(NameOf(current));
            current = _parent[current];
        }
        parts.Reverse();
        return string.Join('/', parts);
    }

    /// <summary>
    /// True at every node whose bytes another name already accounts for.
    /// Null — the overwhelmingly common case — means nothing to suppress
    /// and costs one linear pass over the flags array, no allocation.
    /// </summary>
    private bool[]? SuppressedHardLinkNames()
    {
        var groups = HardLinkGroups();
        if (groups is null) return null;
        var mask = new bool[Count];
        foreach (var (_, ids) in groups)
        {
            int keeper = ElectedName(ids);
            foreach (int id in ids)
                if (id != keeper) mask[id] = true;
        }
        return mask;
    }

    /// <summary>
    /// Post-order descendant counts: files[id] = number of file nodes in
    /// the subtree (a file counts itself), folders[id] = directory count
    /// not counting the node itself. Same reverse-pass trick as
    /// <see cref="RollUpSizes"/> — child ids are always greater than
    /// their parent's.
    /// </summary>
    public (int[] Files, int[] Folders) RollUpCounts()
    {
        var files = new int[Count];
        var folders = new int[Count];
        for (int id = Count - 1; id >= 0; id--)
        {
            int child = _firstChild[id];
            while (child != -1)
            {
                files[id] += files[child];
                folders[id] += folders[child];
                child = _nextSibling[child];
            }
            if (_isDirectory[id]) folders[id] += 1;
            else files[id] += 1;
        }
        // folders[id] counted the node itself; report descendants only.
        for (int id = 0; id < Count; id++)
            if (_isDirectory[id]) folders[id] -= 1;
        return (files, folders);
    }

    /// <summary>
    /// Replaces packed storage after a snapshot load and rebuilds the
    /// name lookup. Arrays must all have <c>nameIndex.Count</c> elements;
    /// <paramref name="fileId"/> may be empty (pre-v3 file) and is then
    /// zero-filled. Returns false and leaves the tree unchanged if the
    /// counts disagree.
    /// </summary>
    public bool ReplacePacked(
        List<string> nameTable,
        int[] nameIndex,
        int[] parent,
        int[] firstChild,
        int[] nextSibling,
        long[] logicalSize,
        long[] allocatedSize,
        int[] modifiedDay,
        int[] createdDay,
        bool[] isDirectory,
        byte[] flags,
        long[]? fileId = null)
    {
        int n = nameIndex.Length;
        if (parent.Length != n || firstChild.Length != n || nextSibling.Length != n
            || logicalSize.Length != n || allocatedSize.Length != n || modifiedDay.Length != n
            || createdDay.Length != n || isDirectory.Length != n || flags.Length != n
            || (fileId is not null && fileId.Length != n))
        {
            return false;
        }
        foreach (int index in nameIndex)
            if (index < 0 || index >= nameTable.Count) return false;

        _nameTable.Clear();
        _nameTable.AddRange(nameTable);
        _nameLookup.Clear();
        for (int i = 0; i < _nameTable.Count; i++)
            _nameLookup.TryAdd(_nameTable[i], i);

        _nameIndex = [.. nameIndex];
        _parent = [.. parent];
        _firstChild = [.. firstChild];
        _nextSibling = [.. nextSibling];
        _logicalSize = [.. logicalSize];
        _allocatedSize = [.. allocatedSize];
        _modifiedDay = [.. modifiedDay];
        _createdDay = [.. createdDay];
        _isDirectory = [.. isDirectory];
        _flags = [.. flags];
        _fileId = fileId is null ? new List<long>(new long[n]) : [.. fileId];
        return true;
    }

    /// <summary>
    /// Convenience for building treemap input at any node: direct
    /// children with their rolled-up sizes.
    /// </summary>
    public List<(int Id, long Size)> ChildrenOf(int id, long[] totals)
    {
        var result = new List<(int, long)>();
        int child = _firstChild[id];
        while (child != -1)
        {
            result.Add((child, totals[child]));
            child = _nextSibling[child];
        }
        return result;
    }
}
