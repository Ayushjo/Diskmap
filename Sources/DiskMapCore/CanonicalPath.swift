import Foundation

/// Separates **display path** (what the user should see) from raw APFS namespace paths.
/// Also encodes known macOS firmlink twins so a `/` scan does not descend the
/// Data-volume copy after the firmlink path was already queued.
public enum CanonicalPath {
    /// Paths under `/System/Volumes/Data/...` that mirror firmlinks from `/`.
    /// Prefer the firmlink (`/Users`, `/Applications`, …) and skip descending
    /// these when the scan root is the system volume root.
    public static let dataVolumeFirmlinkSuffixes: [String] = [
        "/System/Volumes/Data/Users",
        "/System/Volumes/Data/Applications",
        "/System/Volumes/Data/Library",
        "/System/Volumes/Data/System/Library/Caches",
        "/System/Volumes/Data/System/Library/Assets",
        "/System/Volumes/Data/System/Library/PreinstalledAssets",
        "/System/Volumes/Data/System/Library/PreinstalledAssetsV2",
        "/System/Volumes/Data/System/Library/CoreServices",
        "/System/Volumes/Data/System/Library/Speech",
        "/System/Volumes/Data/private",
        "/System/Volumes/Data/Volumes",
        "/System/Volumes/Data/home",
        "/System/Volumes/Data/opt",
        "/System/Volumes/Data/srv",
        "/System/Volumes/Data/Users/Shared",
    ]

    /// True when `absolutePath` is exactly a Data-volume firmlink target (or a
    /// known twin). Used to avoid double-walking the same physical tree.
    public static func shouldSkipDescend(absolutePath: String, scanRootPath: String) -> Bool {
        let root = scanRootPath.hasSuffix("/") && scanRootPath != "/"
            ? String(scanRootPath.dropLast())
            : scanRootPath
        // Only meaningful when walking the boot volume root (or above Data).
        guard root == "/" || root == "/System" || root == "/System/Volumes" || root.hasPrefix("/System/Volumes") else {
            return false
        }
        let path = absolutePath.hasSuffix("/") && absolutePath != "/"
            ? String(absolutePath.dropLast())
            : absolutePath
        for suffix in dataVolumeFirmlinkSuffixes {
            if path == suffix { return true }
        }
        return false
    }

    /// Map Data-volume user paths to the firmlink presentation users expect.
    public static func displayPath(absolutePath: String, home: String = NSHomeDirectory()) -> String {
        var path = absolutePath
        let dataUsers = "/System/Volumes/Data/Users"
        if path == dataUsers || path.hasPrefix(dataUsers + "/") {
            path = "/Users" + String(path.dropFirst(dataUsers.count))
        }
        let dataApps = "/System/Volumes/Data/Applications"
        if path == dataApps || path.hasPrefix(dataApps + "/") {
            path = "/Applications" + String(path.dropFirst(dataApps.count))
        }
        let dataLibrary = "/System/Volumes/Data/Library"
        if path == dataLibrary || path.hasPrefix(dataLibrary + "/") {
            path = "/Library" + String(path.dropFirst(dataLibrary.count))
        }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    /// Truncate for list rows: keep `~/…/parent/` + emphasize that the filename is separate.
    public static func truncatedDirectory(displayPath: String, maxChars: Int = 48) -> String {
        var p = displayPath
        if let slash = p.lastIndex(of: "/") {
            p = String(p[..<slash]) // drop filename if present
            if !p.hasSuffix("/") { p += "/" }
        }
        if p.count <= maxChars { return p }
        // Keep start (~ /Users) and end
        let head = 18
        let tail = max(12, maxChars - head - 1)
        let prefix = String(p.prefix(head))
        let suffix = String(p.suffix(tail))
        return prefix + "…" + suffix
    }

    public static func parentDisplay(of absolutePath: String, home: String = NSHomeDirectory()) -> String {
        let url = URL(fileURLWithPath: absolutePath)
        let parent = url.deletingLastPathComponent().path
        var d = displayPath(absolutePath: parent, home: home)
        if !d.hasSuffix("/") { d += "/" }
        return truncatedDirectory(displayPath: d)
    }
}
