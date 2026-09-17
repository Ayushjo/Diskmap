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

    private List<int> _nameIndex = [];
    private List<int> _parent = [];        // -1 for root
    private List<int> _firstChild = [];    // -1 if none
    private List<int> _nextSibling = [];   // -1 if none
    private List<long> _logicalSize = [];  // logical file size
    private List<long> _allocatedSize = []; // size-on-disk (reflects compression/sparse)
    private List<int> _modifiedDay = [];   // days since epoch, not a full DateTime (8 bytes -> 4)
    private List<bool> _isDirectory = [];
    private List<byte> _flags = [];        // see NodeFlags

    public int Count => _nameIndex.Count;

    // Read-only views the UI and codecs consume without copying.
    public IReadOnlyList<int> NameIndex => _nameIndex;
    public IReadOnlyList<int> Parent => _parent;
    public IReadOnlyList<int> FirstChild => _firstChild;
    public IReadOnlyList<int> NextSibling => _nextSibling;
    public IReadOnlyList<long> LogicalSize => _logicalSize;
    public IReadOnlyList<long> AllocatedSize => _allocatedSize;
    public IReadOnlyList<int> ModifiedDay => _modifiedDay;
    public IReadOnlyList<bool> IsDirectory => _isDirectory;
    public IReadOnlyList<byte> Flags => _flags;

    /// <summary>
    /// Bytes per node of the packed arrays only: index, parent links,
    /// sizes, day, directory bit, flags. No spare capacity, no interned
    /// string heap. Kept in sync with the stored field types.
    /// </summary>
    public const int PackedNodeStride = sizeof(int) * 5 + sizeof(long) * 2 + 1 + 1;

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
            + _nextSibling.Capacity + _modifiedDay.Capacity) * sizeof(int)
            + (long)(_logicalSize.Capacity + _allocatedSize.Capacity) * sizeof(long)
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
        _isDirectory.Capacity = _isDirectory.Count;
        _flags.Capacity = _flags.Count;
        _nameTable.Capacity = _nameTable.Count;
    }

    public int AddNode(
        string name,
        int parentId,
        bool isDirectory,
        long logicalSize,
        long allocatedSize,
        int modifiedDaysSinceEpoch,
        byte flags = 0)
    {
        return AppendNode(
            InternName(name), parentId, isDirectory,
            logicalSize, allocatedSize, modifiedDaysSinceEpoch, flags);
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
        byte flags = 0)
    {
        return AppendNode(
            InternName(name), parentId, isDirectory,
            logicalSize, allocatedSize, modifiedDaysSinceEpoch, flags);
    }

    private int AppendNode(
        int nameId,
        int parentId,
        bool isDirectory,
        long logicalSize,
        long allocatedSize,
        int modifiedDaysSinceEpoch,
        byte flags)
    {
        int id = _nameIndex.Count;
        _nameIndex.Add(nameId);
        _parent.Add(parentId);
        _firstChild.Add(-1);
        _nextSibling.Add(-1);
        _logicalSize.Add(logicalSize);
        _allocatedSize.Add(allocatedSize);
        _modifiedDay.Add(modifiedDaysSinceEpoch);
        _isDirectory.Add(isDirectory);
        _flags.Add(flags);
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
    /// </summary>
    public long[] RollUpSizes(SizeBasis basis = SizeBasis.Allocated)
    {
        var totals = new long[Count];
        for (int id = Count - 1; id >= 0; id--)
        {
            long total = OwnSize(id, basis);
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

    private long OwnSize(int id, SizeBasis basis)
    {
        long selected = basis == SizeBasis.Logical ? _logicalSize[id] : _allocatedSize[id];
        if (!_isDirectory[id]) return selected;
        bool evictedWithoutChildren =
            (_flags[id] & NodeFlags.NotDownloaded) != 0 && _firstChild[id] == -1;
        return evictedWithoutChildren ? selected : 0;
    }

    /// <summary>
    /// Replaces packed storage after a snapshot load and rebuilds the
    /// name lookup. Arrays must all have <c>nameIndex.Count</c> elements.
    /// Returns false and leaves the tree unchanged if the counts disagree.
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
        bool[] isDirectory,
        byte[] flags)
    {
        int n = nameIndex.Length;
        if (parent.Length != n || firstChild.Length != n || nextSibling.Length != n
            || logicalSize.Length != n || allocatedSize.Length != n || modifiedDay.Length != n
            || isDirectory.Length != n || flags.Length != n)
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
        _isDirectory = [.. isDirectory];
        _flags = [.. flags];
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
