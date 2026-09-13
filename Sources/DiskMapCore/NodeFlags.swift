/// Which stored size the treemap and header should sum.
public enum SizeBasis: String, Sendable, CaseIterable, Identifiable {
    case logical
    case allocated

    public var id: String { rawValue }
}

/// Bit flags stored in `FileTree.flags`. Packed into a `UInt8` so a scan
/// of a few million files doesn't grow an option-set object per node.
public enum NodeFlags {
    public static let apfsClone: UInt8 = 1 << 0
    public static let hardLink: UInt8 = 1 << 1
    public static let excludedFromCleanup: UInt8 = 1 << 2
    /// Content is not on disk (iCloud / File Provider, status
    /// `notDownloaded`). Logical size is the cloud size; allocated size
    /// is whatever the filesystem reports locally (0 for a fully evicted
    /// file). Set so a later view can tell "in the cloud" from "empty"
    /// without opening the file.
    public static let notDownloaded: UInt8 = 1 << 3
}
