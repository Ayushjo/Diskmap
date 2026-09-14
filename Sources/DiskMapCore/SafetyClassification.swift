import Foundation

public enum SafetyLevel: String, Sendable, Equatable, CaseIterable {
    case safe
    case review
    case protected

    public var title: String {
        switch self {
        case .safe: return "Safe to review"
        case .review: return "Review first"
        case .protected: return "Protected"
        }
    }
}

public struct SafetyAssessment: Sendable, Equatable {
    public var level: SafetyLevel
    public var reason: String
    public var title: String

    public init(level: SafetyLevel, reason: String, title: String) {
        self.level = level
        self.reason = reason
        self.title = title
    }
}

/// Deterministic path/name rules. Unknown paths default to `.review` — never confident-green.
public enum SafetyClassifier {
    public static func assess(path: String, name: String, isDirectory: Bool) -> SafetyAssessment {
        let lower = path.lowercased()
        let n = name.lowercased()

        // Protected system
        if lower.hasPrefix("/system") || lower.hasPrefix("/library") && !lower.contains("/users/") {
            return SafetyAssessment(level: .protected, reason: "System location. Removing items here can break macOS.", title: name)
        }
        if n == "library" && (lower.hasSuffix("/library") || lower.hasSuffix("/library/")) && lower.contains("/users/") {
            return SafetyAssessment(level: .review, reason: "User Library holds app data, preferences, and caches. Review carefully before removing anything.", title: "Library")
        }

        // Known regenerable caches
        if n == ".npm" || lower.hasSuffix("/.npm") || lower.contains("/.npm/") {
            return SafetyAssessment(
                level: .safe,
                reason: "npm cache stores downloaded packages so installs are faster. npm can recreate it.",
                title: "npm cache"
            )
        }
        if n == "caches" || lower.contains("/library/caches") {
            return SafetyAssessment(
                level: .safe,
                reason: "Application caches. Apps usually recreate them; you may need to re-download some data.",
                title: "Caches"
            )
        }
        if n == "deriveddata" || lower.contains("/developer/xcode/deriveddata") {
            return SafetyAssessment(
                level: .safe,
                reason: "Xcode DerivedData holds build products. Xcode regenerates it on the next build.",
                title: "Xcode DerivedData"
            )
        }
        if n == "node_modules" {
            return SafetyAssessment(
                level: .review,
                reason: "Project dependencies. Safe to delete if you can reinstall with npm/yarn/pnpm, but the project won't run until you do.",
                title: "node_modules"
            )
        }
        if lower.contains("coresimulator") || lower.contains("ios deviceSupport".lowercased()) {
            return SafetyAssessment(
                level: .review,
                reason: "Simulator or device support files. Usually regenerable but may force Xcode to re-download.",
                title: name
            )
        }
        if n == "downloads" {
            return SafetyAssessment(
                level: .review,
                reason: "User Downloads. May contain installers you can remove and unique files you need to keep.",
                title: "Downloads"
            )
        }

        if n == ".cursor" || lower.contains("/.cursor") {
            return SafetyAssessment(
                level: .review,
                reason: "Cursor IDE data (caches, indexes, or agent state). Clearing caches is usually safe; review project data carefully.",
                title: "Cursor data"
            )
        }
        if n == ".codex" || lower.contains("/.codex") {
            return SafetyAssessment(
                level: .review,
                reason: "Codex / AI coding tool data. Confirm you don't need session history before removing.",
                title: "Codex data"
            )
        }
        if n == "coresimulator" || lower.contains("/coresimulator") {
            return SafetyAssessment(
                level: .review,
                reason: "iOS Simulator data. Usually regenerable, but Xcode may re-download runtimes.",
                title: "iOS Simulator data"
            )
        }

        if !isDirectory, n.hasSuffix(".dmg") || n.hasSuffix(".pkg") || n.hasSuffix(".zip") {
            return SafetyAssessment(
                level: .review,
                reason: "Installer or archive. Often safe after the software is installed — confirm you don't need it.",
                title: name
            )
        }

        return SafetyAssessment(
            level: .review,
            reason: "No confident rule for this path. Inspect contents before removing.",
            title: name
        )
    }
}
