import Foundation

public struct StorageStory: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var bytes: Int64
    public var kind: Kind

    public enum Kind: String, Sendable, Equatable {
        case capacity
        case quickWin
        case forgotten
        case category
        case developer
        case biggest
    }

    public init(id: String, title: String, detail: String, bytes: Int64, kind: Kind) {
        self.id = id
        self.title = title
        self.detail = detail
        self.bytes = bytes
        self.kind = kind
    }
}

public struct StorageRecommendation: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var bytes: Int64
    public var confidence: Confidence
    public var safety: SafetyLevel

    public enum Confidence: String, Sendable, Equatable {
        case high
        case medium
        case low
    }

    /// Higher is better. Deterministic ranking helper.
    public var score: Double {
        let impact = log1p(Double(max(0, bytes)))
        let conf: Double = {
            switch confidence {
            case .high: return 1.0
            case .medium: return 0.55
            case .low: return 0.25
            }
        }()
        let safe: Double = {
            switch safety {
            case .safe: return 1.0
            case .review: return 0.45
            case .protected: return 0.0
            }
        }()
        return impact * conf * safe
    }

    public init(id: String, title: String, detail: String, bytes: Int64, confidence: Confidence, safety: SafetyLevel) {
        self.id = id
        self.title = title
        self.detail = detail
        self.bytes = bytes
        self.confidence = confidence
        self.safety = safety
    }
}

/// Rules layer: turns AnalysisSnapshot facts into a few high-value stories + recommendations.
public enum StorageNarrator {
    public static func stories(from snap: AnalysisSnapshot, limit: Int = 5) -> [StorageStory] {
        var out: [StorageStory] = []
        if let vol = snap.volume, snap.health == .low || snap.health == .critical || snap.health == .tight {
            out.append(StorageStory(
                id: "capacity",
                title: "Disk is \(snap.health.title.lowercased())",
                detail: "\(format(Int64(vol.freeBytes))) free of \(format(Int64(vol.totalBytes))). Focus on high-confidence cleanup first.",
                bytes: Int64(vol.usedBytes),
                kind: .capacity
            ))
        }
        if snap.quickWinBytes > 0 {
            out.append(StorageStory(
                id: "quickwins",
                title: "Known regenerable data",
                detail: "About \(format(snap.quickWinBytes)) sits in caches and build artifacts DiskMap recognizes.",
                bytes: snap.quickWinBytes,
                kind: .quickWin
            ))
        }
        if snap.forgottenBytes > 0 {
            out.append(StorageStory(
                id: "forgotten",
                title: "Forgotten files",
                detail: "\(format(snap.forgottenBytes)) in files not modified in over a year.",
                bytes: snap.forgottenBytes,
                kind: .forgotten
            ))
        }
        if let top = snap.categories.first, top.bytes > 0 {
            out.append(StorageStory(
                id: "cat-\(top.key)",
                title: "\(top.title) leads this scan",
                detail: "\(format(top.bytes)) — open Find or Explore to investigate the largest items.",
                bytes: top.bytes,
                kind: .category
            ))
        }
        if let dev = snap.categories.first(where: { $0.key == "developer" }), dev.bytes > 8_000_000 {
            out.append(StorageStory(
                id: "developer",
                title: "Developer tool data is large",
                detail: "\(format(dev.bytes)) in known developer locations (Xcode, npm, caches, and similar).",
                bytes: dev.bytes,
                kind: .developer
            ))
        }
        if let big = snap.topFiles.first {
            out.append(StorageStory(
                id: "biggest-\(big.nodeID)",
                title: "Largest file: \(big.name)",
                detail: "\(format(big.bytes)) at \(big.relativePath).",
                bytes: big.bytes,
                kind: .biggest
            ))
        }
        return Array(out.prefix(limit))
    }

    public static func recommendations(from snap: AnalysisSnapshot, limit: Int = 5) -> [StorageRecommendation] {
        var out: [StorageRecommendation] = []
        if snap.quickWinBytes > 0 {
            out.append(StorageRecommendation(
                id: "rec-quickwins",
                title: "Review regenerable caches",
                detail: "High confidence — known package/build caches DiskMap can explain.",
                bytes: snap.quickWinBytes,
                confidence: .high,
                safety: .safe
            ))
        }
        if let downloads = snap.categories.first(where: { $0.key == "downloads" }), downloads.bytes > 0 {
            out.append(StorageRecommendation(
                id: "rec-downloads",
                title: "Review Downloads",
                detail: "Mixed personal files and installers — inspect before staging.",
                bytes: downloads.bytes,
                confidence: .medium,
                safety: .review
            ))
        }
        if snap.forgottenBytes > 0 {
            out.append(StorageRecommendation(
                id: "rec-forgotten",
                title: "Review forgotten files",
                detail: "Old by last-modified date only — confirm you still need them.",
                bytes: snap.forgottenBytes,
                confidence: .medium,
                safety: .review
            ))
        }
        if let caches = snap.categories.first(where: { $0.key == "caches" }), caches.bytes > 0 {
            out.append(StorageRecommendation(
                id: "rec-caches",
                title: "Clear application caches",
                detail: "Usually regenerable; apps may re-download assets.",
                bytes: caches.bytes,
                confidence: .high,
                safety: .safe
            ))
        }
        if let media = snap.topFiles.first(where: {
            let n = $0.name.lowercased()
            return n.hasSuffix(".mkv") || n.hasSuffix(".mp4") || n.hasSuffix(".mov") || n.hasSuffix(".iso")
        }) {
            out.append(StorageRecommendation(
                id: "rec-media-\(media.nodeID)",
                title: "Large media: \(media.name)",
                detail: "Confirm you have another copy before removing.",
                bytes: media.bytes,
                confidence: .low,
                safety: .review
            ))
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(limit))
    }

    private static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        f.includesUnit = true
        f.isAdaptive = true
        return f.string(fromByteCount: bytes)
    }
}
