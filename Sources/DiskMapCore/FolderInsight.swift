import Foundation

public struct FolderLargestFile: Sendable, Equatable {
    public var id: Int32
    public var name: String
    public var bytes: Int64
}

/// Deterministic folder summary for Biggest Folders inspector.
public struct FolderInsight: Sendable, Equatable {
    public var nodeID: Int32
    public var name: String
    public var absolutePath: String
    public var displayPath: String
    public var bytes: Int64
    public var fileCount: Int
    public var folderCount: Int
    public var composition: [FileTypeTotals]
    public var safety: SafetyAssessment
    public var reviewableBytes: Int64
    public var whyLarge: String
    public var largestFiles: [FolderLargestFile]

    public var itemCount: Int { fileCount + folderCount }

    public static func build(
        nodeID: Int32,
        tree: FileTree,
        root: URL,
        totals: [Int64],
        fileCounts: [Int],
        folderCounts: [Int],
        categories: [FileTypeCategory],
        today: Int32 = AgeMap.today()
    ) -> FolderInsight? {
        guard nodeID >= 0,
              Int(nodeID) < tree.count,
              totals.count == tree.count,
              tree.isDirectory[Int(nodeID)] else { return nil }
        let i = Int(nodeID)
        let abs = tree.path(of: nodeID, root: root).path
        let name = tree.name(of: nodeID)
        let safety = SafetyClassifier.assess(path: abs, name: name, isDirectory: true)
        let composition = FileTypeCatalog.totals(under: nodeID, in: tree, sizes: totals, categories: categories)
        let files = fileCounts.indices.contains(i) ? fileCounts[i] : 0
        let folders = folderCounts.indices.contains(i) ? folderCounts[i] : 0
        let reviewable = reviewableBytes(under: nodeID, tree: tree, totals: totals, today: today, safety: safety)
        let largest = FileTypeCatalog.largestFiles(under: nodeID, in: tree, sizes: totals, limit: 5)
        return FolderInsight(
            nodeID: nodeID,
            name: name,
            absolutePath: abs,
            displayPath: CanonicalPath.displayPath(absolutePath: abs),
            bytes: totals[i],
            fileCount: files,
            folderCount: folders,
            composition: composition,
            safety: safety,
            reviewableBytes: reviewable,
            whyLarge: whyLarge(name: name, composition: composition, bytes: totals[i], safety: safety),
            largestFiles: largest.map { FolderLargestFile(id: $0.id, name: $0.name, bytes: $0.bytes) }
        )
    }

    /// Honest estimate: old files (>1y) under this folder, or full size for known-safe caches.
    /// Never claims the whole folder is reclaimable unless safety is `.safe`.
    private static func reviewableBytes(
        under nodeID: Int32,
        tree: FileTree,
        totals: [Int64],
        today: Int32,
        safety: SafetyAssessment
    ) -> Int64 {
        if safety.level == .protected { return 0 }
        if safety.level == .safe {
            return totals[Int(nodeID)]
        }
        var sum: Int64 = 0
        var stack: [Int32] = [nodeID]
        while let id = stack.popLast() {
            let index = Int(id)
            if !tree.isDirectory[index] {
                let day = tree.modifiedDay[index]
                if day > 0, today - day > 365, totals[index] > 0 {
                    sum += totals[index]
                }
            } else {
                var child = tree.firstChild[index]
                while child != -1 {
                    stack.append(child)
                    child = tree.nextSibling[Int(child)]
                }
            }
        }
        return sum
    }

    private static func whyLarge(
        name: String,
        composition: [FileTypeTotals],
        bytes: Int64,
        safety: SafetyAssessment
    ) -> String {
        if safety.level == .protected {
            return "This space is used by macOS and system components. DiskMap does not recommend cleaning it from here."
        }
        if composition.isEmpty {
            return "This folder holds \(byteString(bytes)) across its contents. Open it to inspect what is inside."
        }
        let top = composition.prefix(3).map { "\($0.label.lowercased()) (\(byteString($0.bytes)))" }
        if top.count == 1 {
            return "Mostly \(top[0])."
        }
        if top.count == 2 {
            return "Mostly \(top[0]) and \(top[1])."
        }
        return "Mostly \(top[0]), \(top[1]), and \(top[2])."
    }

    private static func byteString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        f.includesUnit = true
        f.isAdaptive = true
        return f.string(fromByteCount: bytes)
    }
}
