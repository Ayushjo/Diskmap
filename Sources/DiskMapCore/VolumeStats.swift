import Darwin
import Foundation

/// Volume capacity from `statfs(2)` on the scan root's filesystem —
/// not from FileTree rollups (those are scan-subtree totals).
public struct VolumeStats: Sendable, Equatable {
    public var volumeName: String
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var usedBytes: UInt64

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    public static func forPath(_ path: String) -> VolumeStats? {
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
        return VolumeStats(volumeName: display, totalBytes: total, freeBytes: free, usedBytes: used)
    }
}
