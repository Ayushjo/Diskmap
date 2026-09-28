import Foundation

public struct CleanupPreflightResult: Sendable, Equatable {
    public var allowed: Bool
    public var assessment: SafetyAssessment
    public var message: String

    public init(allowed: Bool, assessment: SafetyAssessment, message: String) {
        self.allowed = allowed
        self.assessment = assessment
        self.message = message
    }
}

public struct CleanupLogEntry: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var path: String
    public var bytes: Int64
    public var reason: String
    public var succeeded: Bool
    public var errorDescription: String?
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        path: String,
        bytes: Int64,
        reason: String,
        succeeded: Bool,
        errorDescription: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.bytes = bytes
        self.reason = reason
        self.succeeded = succeeded
        self.errorDescription = errorDescription
        self.timestamp = timestamp
    }
}

/// Second safety gate before staging: refuse protected paths; warn on review.
public enum CleanupPreflight {
    public static func evaluate(url: URL, isDirectory: Bool? = nil) -> CleanupPreflightResult {
        let path = url.path
        let name = url.lastPathComponent
        var isDir = isDirectory ?? false
        if isDirectory == nil {
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &dir) {
                isDir = dir.boolValue
            }
        }
        let assessment = SafetyClassifier.assess(path: path, name: name, isDirectory: isDir)
        switch assessment.level {
        case .protected:
            return CleanupPreflightResult(
                allowed: false,
                assessment: assessment,
                message: "Blocked: \(assessment.reason)"
            )
        case .safe, .review:
            return CleanupPreflightResult(
                allowed: true,
                assessment: assessment,
                message: assessment.recommendedAction
            )
        }
    }

    /// One receipt line per staged item. `bytes` is the item's share of what
    /// the commit actually freed (TASK-038), not its apparent size — the old
    /// `item.size` re-inflated clones and hard links to N × size in the
    /// receipt even when the pre-commit estimate had them right. Lines sum to
    /// `report.freedWhenTrashEmptied`.
    public static func logEntries(from report: CleanupQueue.CommitReport) -> [CleanupLogEntry] {
        report.entries.map { entry in
            CleanupLogEntry(
                path: entry.item.url.path,
                bytes: entry.freedBytes,
                reason: entry.movedWithFolder ? entry.item.reason + " (moved with its folder)" : entry.item.reason,
                succeeded: entry.error == nil,
                errorDescription: entry.error?.localizedDescription
            )
        }
    }
}
