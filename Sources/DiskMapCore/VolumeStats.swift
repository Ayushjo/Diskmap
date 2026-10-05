import Darwin
import Foundation

/// Volume capacity from `statfs(2)` on the scan root's filesystem —
/// not from FileTree rollups (those are scan-subtree totals).
public struct VolumeStats: Sendable, Equatable {
    public var volumeName: String
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var usedBytes: UInt64
    /// Space macOS can reclaim on demand (purgeable: caches, iCloud copies,
    /// some snapshots). Finder's "available" is `freeBytes` plus this, so
    /// it reads higher than statfs — 84.35 GB against 74.55 GB measured on a
    /// real Mac. 0 when the system doesn't say.
    public var purgeableBytes: UInt64 = 0

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    /// Visual regression only (TASK-084): when set, every lookup returns it,
    /// so renders do not depend on how full the machine's disk is today.
    nonisolated(unsafe) public static var fixed: VolumeStats?

    public init(volumeName: String, totalBytes: UInt64, freeBytes: UInt64, usedBytes: UInt64) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
    }

    /// `includePurgeable` asks the system for purgeable space too: 20–90 ms
    /// measured, so only off the main thread (Overview's build).
    public static func forPath(_ path: String, includePurgeable: Bool = false) -> VolumeStats? {
        if let fixed { return fixed }
        var fs = statfs()
        let rc = path.withCString { statfs($0, &fs) }
        guard rc == 0 else { return nil }
        let block = UInt64(fs.f_bsize)
        let total = UInt64(fs.f_blocks) * block
        // Prefer non-privileged free space for what the user can actually use.
        let free = UInt64(fs.f_bavail) * block
        let used = total > free ? total - free : 0
        let name = withUnsafePointer(to: fs.f_mntonname) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: fs.f_mntonname)) {
                String(cString: $0)
            }
        }
        let display: String
        if name == "/" {
            display = "Macintosh HD"
        } else {
            display = URL(fileURLWithPath: name).lastPathComponent
        }
        var stats = VolumeStats(volumeName: display, totalBytes: total, freeBytes: free, usedBytes: used)
        // The same figure Finder shows as available; local, no I/O beyond a
        // volume query.
        guard includePurgeable else { return stats }
        let important = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        if important > 0, UInt64(important) > free { stats.purgeableBytes = UInt64(important) - free }
        return stats
    }
}
