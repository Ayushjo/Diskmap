import Foundation

public struct AppLeftoverEntry: Sendable, Equatable {
    public let url: URL
    public let bytes: Int64

    public init(url: URL, bytes: Int64) {
        self.url = url
        self.bytes = bytes
    }
}

public struct AppLeftovers: Sendable {
    public let bundleID: String?
    public let appName: String
    public let bundlePath: URL
    public let bundleSize: Int64
    public let leftoverPaths: [URL]
    public let leftoverEntries: [AppLeftoverEntry]
    public let leftoverSize: Int64

    public init(
        bundleID: String?,
        appName: String,
        bundlePath: URL,
        bundleSize: Int64,
        leftoverPaths: [URL],
        leftoverEntries: [AppLeftoverEntry] = [],
        leftoverSize: Int64
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.bundlePath = bundlePath
        self.bundleSize = bundleSize
        self.leftoverPaths = leftoverPaths
        self.leftoverEntries = leftoverEntries.isEmpty
            ? leftoverPaths.map { AppLeftoverEntry(url: $0, bytes: 0) }
            : leftoverEntries
        self.leftoverSize = leftoverSize
    }
}

/// Finds files an app scattered outside its own .app bundle when it was
/// installed/run — caches, preferences, saved state, containers, logs.
///
/// There is no Apple API that enumerates "everything this app touched."
/// Every open-source uninstaller in this space (AppCleaner, Pearcleaner,
/// this one) does the same heuristic: search known Library locations for
/// items whose name contains the app's bundle identifier (reverse-DNS,
/// e.g. "com.example.app" — rarely collides by accident) or, failing
/// that, the app's display name (fuzzier, more false-positive risk).
///
/// Because it's heuristic, leftovers should always land in a *staged*
/// cleanup list for the user to review — never delete automatically.
public enum AppLeftoverFinder {

    static let searchLocations: [String] = [
        "~/Library/Caches",
        "~/Library/Application Support",
        "~/Library/Preferences",
        "~/Library/Saved Application State",
        "~/Library/Containers",
        "~/Library/Group Containers",
        "~/Library/HTTPStorages",
        "~/Library/WebKit",
        "~/Library/Logs",
        "~/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/Library/Application Support",
    ]

    public static func defaultApplicationDirectories() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true),
        ]
    }

    public static func applicationBundles(in directories: [URL]) -> [URL] {
        let fm = FileManager.default
        var apps: [URL] = []
        for directory in directories {
            guard let contents = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            apps.append(contentsOf: contents.filter { $0.pathExtension == "app" })
        }
        return apps.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func findLeftovers(for appURL: URL, measureRelated: Bool = true) -> AppLeftovers {
        let bundle = Bundle(url: appURL)
        let bundleID = bundle?.bundleIdentifier
        let appName = appURL.deletingPathExtension().lastPathComponent

        var matches: [URL] = []
        let fm = FileManager.default

        for location in searchLocations {
            let expanded = (location as NSString).expandingTildeInPath
            let dirURL = URL(fileURLWithPath: expanded)
            guard let contents = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) else {
                continue
            }

            for item in contents {
                let itemName = item.lastPathComponent

                if let bid = bundleID, itemName.localizedCaseInsensitiveContains(bid) {
                    matches.append(item)
                } else if bundleID == nil, appName.count > 3,
                          itemName.localizedCaseInsensitiveContains(appName) {
                    matches.append(item)
                }
            }
        }

        let bundleSize = allocatedSize(of: appURL)
        var entries: [AppLeftoverEntry] = []
        var leftoverSize: Int64 = 0
        if measureRelated {
            for url in matches {
                let bytes = allocatedSize(of: url)
                leftoverSize += bytes
                entries.append(AppLeftoverEntry(url: url, bytes: bytes))
            }
        } else {
            entries = matches.map { AppLeftoverEntry(url: $0, bytes: 0) }
        }

        return AppLeftovers(
            bundleID: bundleID,
            appName: appName,
            bundlePath: appURL,
            bundleSize: bundleSize,
            leftoverPaths: matches,
            leftoverEntries: entries,
            leftoverSize: leftoverSize
        )
    }

    public static func allocatedSize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }
}
