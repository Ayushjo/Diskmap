namespace DiskMap.Core;

/// <summary>Which stored size the treemap and header should sum.</summary>
public enum SizeBasis
{
    Logical,
    Allocated,
}

/// <summary>
/// Bit flags stored in <see cref="FileTree.Flags"/>. Packed into a byte so a
/// scan of a few million files doesn't grow an option-set object per node.
/// Bit layout matches the macOS build so the DMAP snapshot format stays
/// byte-compatible.
/// </summary>
public static class NodeFlags
{
    /// <summary>Shares backing extents with another file (ReFS block clone).</summary>
    public const byte FileClone = 1 << 0;
    public const byte HardLink = 1 << 1;
    public const byte ExcludedFromCleanup = 1 << 2;

    /// <summary>
    /// Content is not on disk (OneDrive / cloud placeholder: FILE_ATTRIBUTE_OFFLINE,
    /// RECALL_ON_DATA_ACCESS or RECALL_ON_OPEN). Logical size is the cloud size;
    /// allocated size is whatever the filesystem reports locally (0 for a fully
    /// evicted file). Set so a later view can tell "in the cloud" from "empty"
    /// without opening the file.
    /// </summary>
    public const byte NotDownloaded = 1 << 3;
}
