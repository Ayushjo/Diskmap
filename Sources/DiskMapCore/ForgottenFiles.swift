import Foundation

public enum ForgottenConfidence: String, Sendable, Equatable, CaseIterable, Identifiable {
    case likelyForgotten
    case worthReviewing
    case oldImportant

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .likelyForgotten: return "Likely forgotten"
        case .worthReviewing: return "Worth reviewing"
        case .oldImportant: return "Old, but probably important"
        }
    }

    public var shortTitle: String { title }
}

/// Age buckets used only for Forgotten candidates (≥ 1 year).
public enum ForgottenAgeBucket: String, Sendable, Equatable, CaseIterable, Identifiable {
    case oneToTwoYears
    case twoToThreeYears
    case threeToFiveYears
    case overFiveYears

    public var id: String { rawValue }

    public var shortTitle: String {
        switch self {
        case .oneToTwoYears: return "1–2y"
        case .twoToThreeYears: return "2–3y"
        case .threeToFiveYears: return "3–5y"
        case .overFiveYears: return "5y+"
        }
    }

    public var title: String {
        switch self {
        case .oneToTwoYears: return "1–2 years"
        case .twoToThreeYears: return "2–3 years"
        case .threeToFiveYears: return "3–5 years"
        case .overFiveYears: return "Over 5 years"
        }
    }

    public static func bucket(ageDays: Int32) -> ForgottenAgeBucket? {
        guard ageDays > 365 else { return nil }
        if ageDays < 730 { return .oneToTwoYears }
        if ageDays < 1095 { return .twoToThreeYears }
        if ageDays < 1825 { return .threeToFiveYears }
        return .overFiveYears
    }
}

public struct ForgottenCandidate: Sendable, Equatable, Identifiable {
    public var id: Int32
    public var name: String
    public var absolutePath: String
    public var displayPath: String
    public var parentDisplay: String
    public var bytes: Int64
    public var modifiedDay: Int32
    public var ageDays: Int32
    public var kind: FileKind
    public var confidence: ForgottenConfidence
    public var safety: SafetyAssessment
    public var reasons: [String]
    public var score: Double

    public var isReviewable: Bool {
        confidence == .likelyForgotten || confidence == .worthReviewing
    }
}

public struct ForgottenSummary: Sendable, Equatable {
    public var reviewableBytes: Int64
    public var likelyBytes: Int64
    public var worthBytes: Int64
    public var excludedBytes: Int64
    public var reviewableCount: Int
    public var likelyCount: Int
    public var worthCount: Int
    public var excludedCount: Int
    public var ageDistribution: [ForgottenAgeBucket: Int64]

    public static let empty = ForgottenSummary(
        reviewableBytes: 0, likelyBytes: 0, worthBytes: 0, excludedBytes: 0,
        reviewableCount: 0, likelyCount: 0, worthCount: 0, excludedCount: 0,
        ageDistribution: [:]
    )

    public init(
        reviewableBytes: Int64,
        likelyBytes: Int64,
        worthBytes: Int64,
        excludedBytes: Int64,
        reviewableCount: Int,
        likelyCount: Int,
        worthCount: Int,
        excludedCount: Int,
        ageDistribution: [ForgottenAgeBucket: Int64]
    ) {
        self.reviewableBytes = reviewableBytes
        self.likelyBytes = likelyBytes
        self.worthBytes = worthBytes
        self.excludedBytes = excludedBytes
        self.reviewableCount = reviewableCount
        self.likelyCount = likelyCount
        self.worthCount = worthCount
        self.excludedCount = excludedCount
        self.ageDistribution = ageDistribution
    }
}

public enum ForgottenFiles {
    /// Minimum age (days) to be considered forgotten.
    public static let minAgeDays: Int32 = 365
    /// Tiny files are noise even if ancient.
    public static let minBytes: Int64 = 1_000_000 // 1 MB floor
    /// Default list prefers meaningful storage impact for medium confidence.
    public static let worthMinBytes: Int64 = 25_000_000

    public static func candidates(
        tree: FileTree,
        root: URL,
        totals: [Int64],
        today: Int32 = AgeMap.today(),
        limit: Int = 500
    ) -> [ForgottenCandidate] {
        guard tree.count == totals.count, limit > 0 else { return [] }
        var out: [ForgottenCandidate] = []
        out.reserveCapacity(min(limit, 256))
        for id in 1..<Int32(tree.count) {
            let index = Int(id)
            guard !tree.isDirectory[index] else { continue }
            let bytes = totals[index]
            guard bytes >= minBytes else { continue }
            let day = tree.modifiedDay[index]
            guard day > 0 else { continue }
            let age = today - day
            guard age > minAgeDays else { continue }

            let name = tree.name(of: id)
            let abs = tree.path(of: id, root: root).path
            let safety = SafetyClassifier.assess(path: abs, name: name, isDirectory: false)
            let kind = FileKind.classify(fileName: name, path: abs)
            let confidence = classifyConfidence(
                path: abs,
                name: name,
                kind: kind,
                safety: safety,
                bytes: bytes
            )
            let reasons = buildReasons(
                ageDays: age,
                bytes: bytes,
                path: abs,
                kind: kind,
                confidence: confidence,
                safety: safety
            )
            let score = reviewScore(
                ageDays: age,
                bytes: bytes,
                confidence: confidence,
                kind: kind,
                safety: safety
            )
            out.append(
                ForgottenCandidate(
                    id: id,
                    name: name,
                    absolutePath: abs,
                    displayPath: CanonicalPath.displayPath(absolutePath: abs),
                    parentDisplay: CanonicalPath.parentDisplay(of: abs),
                    bytes: bytes,
                    modifiedDay: day,
                    ageDays: age,
                    kind: kind,
                    confidence: confidence,
                    safety: safety,
                    reasons: reasons,
                    score: score
                )
            )
        }
        out.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.bytes > rhs.bytes
        }
        if out.count > limit {
            out = Array(out.prefix(limit))
        }
        return out
    }

    public static func summary(from candidates: [ForgottenCandidate]) -> ForgottenSummary {
        var likely: Int64 = 0
        var worth: Int64 = 0
        var excluded: Int64 = 0
        var likelyN = 0
        var worthN = 0
        var excludedN = 0
        var dist: [ForgottenAgeBucket: Int64] = [:]
        for c in candidates {
            switch c.confidence {
            case .likelyForgotten:
                likely += c.bytes
                likelyN += 1
            case .worthReviewing:
                worth += c.bytes
                worthN += 1
            case .oldImportant:
                excluded += c.bytes
                excludedN += 1
            }
            if c.isReviewable, let bucket = ForgottenAgeBucket.bucket(ageDays: c.ageDays) {
                dist[bucket, default: 0] += c.bytes
            }
        }
        return ForgottenSummary(
            reviewableBytes: likely + worth,
            likelyBytes: likely,
            worthBytes: worth,
            excludedBytes: excluded,
            reviewableCount: likelyN + worthN,
            likelyCount: likelyN,
            worthCount: worthN,
            excludedCount: excludedN,
            ageDistribution: dist
        )
    }

    // MARK: - Classification

    public static func classifyConfidence(
        path: String,
        name: String,
        kind: FileKind,
        safety: SafetyAssessment,
        bytes: Int64
    ) -> ForgottenConfidence {
        let lower = path.lowercased()

        if safety.level == .protected {
            return .oldImportant
        }
        if kind == .virtualDisk || name.lowercased().hasSuffix(".raw") {
            return .oldImportant
        }
        if isInsideApplicationBundle(lower) {
            return .oldImportant
        }
        if isDeveloperOrToolchain(lower) {
            return .oldImportant
        }
        if isManagedData(lower, name: name.lowercased()) {
            return .oldImportant
        }

        let personal = isPersonalLocation(lower)
        let highType = isHighSignalType(kind)

        if personal && highType {
            return .likelyForgotten
        }
        if personal && bytes >= 50_000_000 {
            return .likelyForgotten
        }
        if personal {
            return bytes >= worthMinBytes ? .worthReviewing : .oldImportant
        }
        // Regenerable caches (npm, etc.) are cleaned via Caches — not Forgotten recommendations.
        if safety.level == .safe {
            return .oldImportant
        }
        if safety.level == .review && bytes >= 100_000_000 && !lower.contains("/library/") {
            return .worthReviewing
        }
        return .oldImportant
    }

    private static func isInsideApplicationBundle(_ lower: String) -> Bool {
        lower.contains(".app/contents/") || lower.contains(".app/frameworks/")
    }

    private static func isDeveloperOrToolchain(_ lower: String) -> Bool {
        if lower.contains("/library/developer/") { return true }
        if lower.contains("/xcode.app/") { return true }
        if lower.contains("/commandlinetools/") { return true }
        if lower.contains("/.swiftpm/") { return true }
        if lower.contains("/deriveddata/") { return true }
        // Package-manager sources preserve ancient packaging mtimes — not "forgotten".
        if lower.contains("/.cargo/") { return true }
        if lower.contains("/.rustup/") { return true }
        if lower.contains("/.gradle/") { return true }
        if lower.contains("/.m2/") { return true }
        if lower.contains("/go/pkg/mod/") { return true }
        if lower.contains("/.nuget/") { return true }
        if lower.contains("/.cocoapods/") { return true }
        if lower.contains("/.pub-cache/") { return true }
        if lower.contains("/library/caches/cocoapods/") { return true }
        if lower.contains("/node_modules/") { return true }
        if lower.contains("/.npm/") { return true }
        if lower.contains("/.pnpm-store/") { return true }
        if lower.contains("/.yarn/") { return true }
        if lower.contains("/.cache/pip/") { return true }
        return false
    }

    private static func isManagedData(_ lower: String, name: String) -> Bool {
        if lower.contains("/docker.raw") || name == "docker.raw" { return true }
        if lower.contains("/library/containers/com.docker") { return true }
        if lower.contains("/library/group containers/group.com.docker") { return true }
        if lower.contains("/virtualbox vms/") { return true }
        if lower.contains("/parallels/") && lower.contains(".pvm") { return true }
        return false
    }

    private static func isPersonalLocation(_ lower: String) -> Bool {
        // Prefer user firmlink paths and Data twins.
        let markers = [
            "/downloads/", "/movies/", "/desktop/", "/documents/",
            "/pictures/", "/music/", "/public/",
        ]
        if markers.contains(where: { lower.contains($0) }) { return true }
        // Home root loose files: /Users/x/file
        if let range = lower.range(of: "/users/") {
            let rest = lower[range.upperBound...]
            let parts = rest.split(separator: "/")
            // users / name / file  → personal; users / name / library → not
            if parts.count == 2 { return true }
        }
        return false
    }

    private static func isHighSignalType(_ kind: FileKind) -> Bool {
        switch kind {
        case .video, .diskImage, .archive, .deviceBackup:
            return true
        default:
            return false
        }
    }

    private static func buildReasons(
        ageDays: Int32,
        bytes: Int64,
        path: String,
        kind: FileKind,
        confidence: ForgottenConfidence,
        safety: SafetyAssessment
    ) -> [String] {
        var reasons: [String] = []
        let years = max(1, ageDays / 365)
        if years >= 15 {
            reasons.append("Very old modification date (often preserved from packaging)")
        } else if years == 1 {
            reasons.append("Not modified in over a year")
        } else {
            reasons.append("Not modified in \(years) years")
        }
        if bytes >= 1_000_000_000 {
            reasons.append("Very large file")
        } else if bytes >= 100_000_000 {
            reasons.append("Large file")
        }
        let lower = path.lowercased()
        if lower.contains("/downloads/") {
            reasons.append("Located in Downloads")
        } else if lower.contains("/movies/") {
            reasons.append("Located in Movies")
        } else if lower.contains("/desktop/") {
            reasons.append("Located in Desktop")
        } else if lower.contains("/documents/") {
            reasons.append("Located in Documents")
        }
        switch kind {
        case .video: reasons.append("Personal media file")
        case .diskImage: reasons.append("Disk image / installer")
        case .archive: reasons.append("Archive")
        case .deviceBackup: reasons.append("Device backup")
        default: break
        }
        if confidence == .oldImportant {
            reasons.append(safety.reason)
        }
        return reasons
    }

    private static func reviewScore(
        ageDays: Int32,
        bytes: Int64,
        confidence: ForgottenConfidence,
        kind: FileKind,
        safety: SafetyAssessment
    ) -> Double {
        let sizeSignal = min(40.0, log2(Double(max(bytes, 1)) / 1_000_000.0 + 1.0) * 6.0)
        let ageSignal = min(25.0, Double(ageDays - 365) / 365.0 * 8.0)
        var typeBoost = 0.0
        if isHighSignalType(kind) { typeBoost = 12.0 }
        var confBoost = 0.0
        switch confidence {
        case .likelyForgotten: confBoost = 30.0
        case .worthReviewing: confBoost = 12.0
        case .oldImportant: confBoost = -40.0
        }
        var risk = 0.0
        if safety.level == .protected { risk = 50.0 }
        if safety.level == .review && confidence != .likelyForgotten { risk += 5.0 }
        return sizeSignal + ageSignal + typeBoost + confBoost - risk
    }
}
