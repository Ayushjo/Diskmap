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
    public var consequences: String
    public var recommendedAction: String

    public init(
        level: SafetyLevel,
        reason: String,
        title: String,
        consequences: String = "",
        recommendedAction: String = ""
    ) {
        self.level = level
        self.reason = reason
        self.title = title
        self.consequences = consequences.isEmpty ? Self.defaultConsequences(level) : consequences
        self.recommendedAction = recommendedAction.isEmpty ? Self.defaultAction(level) : recommendedAction
    }

    private static func defaultConsequences(_ level: SafetyLevel) -> String {
        switch level {
        case .safe: return "Apps or tools can usually recreate this data. You may see slower first runs."
        case .review: return "Removing the wrong item could delete personal files or break a project until you restore it."
        case .protected: return "Removing this can break macOS or lock you out of critical data."
        }
    }

    private static func defaultAction(_ level: SafetyLevel) -> String {
        switch level {
        case .safe: return "Add to Cleanup, then review it before moving it to Trash."
        case .review: return "Inspect contents, reveal in Finder, then stage only what you recognize."
        case .protected: return "Do not remove. Leave system and keychain data alone."
        }
    }
}

/// Deterministic path/name rules. Unknown paths default to `.review` — never confident-green.
public enum SafetyClassifier {
    public static func assess(path: String, name: String, isDirectory: Bool) -> SafetyAssessment {
        let lower = path.lowercased()
        let n = name.lowercased()

        // Protected system / secrets
        if lower.hasPrefix("/system") || (lower.hasPrefix("/library") && !lower.contains("/users/")) {
            return SafetyAssessment(
                level: .protected,
                reason: "System location. Removing items here can break macOS.",
                title: name,
                consequences: "macOS may fail to boot or update; SIP may also block the delete.",
                recommendedAction: "Do not stage. Use System Settings if you need disk space."
            )
        }
        if lower.contains("/library/keychains") || n == "keychains" {
            return SafetyAssessment(
                level: .protected,
                reason: "Keychain stores passwords and certificates.",
                title: "Keychains",
                consequences: "You can lose saved passwords and break app logins.",
                recommendedAction: "Never remove via DiskMap."
            )
        }
        if lower.hasPrefix("/private/var/db") || lower.hasPrefix("/private/var/folders") && lower.contains("com.apple") {
            return SafetyAssessment(
                level: .protected,
                reason: "Private system database / Apple runtime data.",
                title: name
            )
        }
        if n == "library" && (lower.hasSuffix("/library") || lower.hasSuffix("/library/")) && lower.contains("/users/") {
            return SafetyAssessment(
                level: .review,
                reason: "User Library holds app data, preferences, and caches. Review carefully before removing anything.",
                title: "Library"
            )
        }

        // Known regenerable caches / build products
        if n == ".npm" || lower.hasSuffix("/.npm") || lower.contains("/.npm/") {
            return SafetyAssessment(
                level: .safe,
                reason: "npm cache stores downloaded packages so installs are faster. npm can recreate it.",
                title: "npm cache",
                consequences: "Next npm install may re-download packages (slower once).",
                recommendedAction: "Add to Cleanup and review before removing."
            )
        }
        if n == ".pnpm-store" || lower.contains("/.pnpm-store") || n == ".pnpm" {
            return SafetyAssessment(
                level: .safe,
                reason: "pnpm content-addressable store. pnpm can rehydrate packages after a clear.",
                title: "pnpm store",
                consequences: "Projects may need `pnpm install` again.",
                recommendedAction: "Safe to clear if you can reinstall dependencies."
            )
        }
        if n == ".yarn" || lower.contains("/.yarn/cache") || n == "yarn-cache" {
            return SafetyAssessment(
                level: .safe,
                reason: "Yarn package cache. Yarn recreates it on the next install.",
                title: "Yarn cache"
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
                title: "Xcode DerivedData",
                consequences: "Next Xcode build will be slower until DerivedData rebuilds.",
                recommendedAction: "Safe to clear when you are not mid-build."
            )
        }
        if n == ".cargo" || lower.contains("/.cargo/registry") {
            return SafetyAssessment(
                level: .safe,
                reason: "Cargo registry/cache for Rust crates. Cargo re-downloads as needed.",
                title: "Cargo cache"
            )
        }
        if n == ".gradle" || lower.contains("/.gradle/caches") {
            return SafetyAssessment(
                level: .safe,
                reason: "Gradle caches. Builds re-download dependencies afterward.",
                title: "Gradle cache"
            )
        }
        if n == ".pub-cache" {
            return SafetyAssessment(
                level: .safe,
                reason: "Dart/Flutter pub cache. `flutter pub get` restores packages.",
                title: "Pub cache"
            )
        }
        if n == "cocoapods" || n == ".cocoapods" || lower.contains("/caches/cocoapods") {
            return SafetyAssessment(
                level: .safe,
                reason: "CocoaPods cache. `pod install` can restore specs and downloads.",
                title: "CocoaPods cache"
            )
        }
        if n == "node_modules" {
            return SafetyAssessment(
                level: .review,
                reason: "Project dependencies. Safe to delete if you can reinstall with npm/yarn/pnpm, but the project won't run until you do.",
                title: "node_modules",
                consequences: "Project won't build or run until you reinstall dependencies.",
                recommendedAction: "Stage only unused project folders you recognize."
            )
        }
        if lower.contains("coresimulator") || lower.contains("ios devicesupport") || n == "coresimulator" {
            return SafetyAssessment(
                level: .review,
                reason: "iOS Simulator or device support files. Usually regenerable but may force Xcode to re-download.",
                title: "iOS Simulator / DeviceSupport",
                consequences: "Xcode may re-download runtimes or device symbols.",
                recommendedAction: "Review size in Developer Storage before staging."
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
        if n == ".docker" || lower.contains("/library/containers/com.docker") {
            return SafetyAssessment(
                level: .review,
                reason: "Docker images, volumes, or VM data. Removing volumes can delete containerized databases.",
                title: "Docker data",
                consequences: "Images and named volumes may need to be pulled or recreated.",
                recommendedAction: "Prefer Docker Desktop's cleanup UI for volumes; stage only caches you recognize."
            )
        }
        if n == ".rustup" {
            return SafetyAssessment(
                level: .review,
                reason: "Rust toolchains installed via rustup. Removing them uninstalls compilers until you reinstall.",
                title: "rustup toolchains"
            )
        }
        if n == "venv" || n == ".venv" || n == "__pycache__" || n == ".mypy_cache" {
            return SafetyAssessment(
                level: .review,
                reason: "Python environment or bytecode cache. Recreatable if you have requirements/lockfiles.",
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
        if n == "documents" || n == "desktop" || n == "pictures" || n == "movies" || n == "music" {
            return SafetyAssessment(
                level: .review,
                reason: "User documents folder. Treat contents as personal data until proven otherwise.",
                title: name
            )
        }
        if !isDirectory, n.hasSuffix(".dmg") || n.hasSuffix(".pkg") || n.hasSuffix(".zip") || n.hasSuffix(".iso") {
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
