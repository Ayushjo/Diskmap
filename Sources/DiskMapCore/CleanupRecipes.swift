import Foundation

/// A tool's own cleanup command for a folder (TASK-055). DiskMap shows the
/// command and never runs it: `CleanupQueue.commit()` remains the only way
/// DiskMap removes anything, and it only moves to the Trash.
public struct CleanupRecipe: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    public var title: String
    public var command: String
    public var why: String
    /// Moving the folder to the Trash damages the tool's state (Docker's disk
    /// image, simctl's device store) — steer to the command instead.
    public var trashIsUnsafe: Bool
    var names: [String]
    var pathSuffixes: [String]
    var pathContains: [String]

    func matches(path: String) -> Bool {
        let last = (path as NSString).lastPathComponent
        return names.contains(last)
            || pathSuffixes.contains { path.hasSuffix($0) }
            || pathContains.contains { path.contains($0) }
    }
}

public enum CleanupRecipes {
    private struct File: Decodable { var recipes: [CleanupRecipe] }

    public static let bundled: [CleanupRecipe] = load()

    static func load(from data: Data? = nil) -> [CleanupRecipe] {
        let bytes = data ?? Bundle.module.url(forResource: "cleanup-recipes", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        guard let bytes, let file = try? JSONDecoder().decode(File.self, from: bytes) else { return [] }
        return file.recipes
    }

    /// The first recipe for `path`, if a tool owns it.
    public static func recipe(forPath path: String, in recipes: [CleanupRecipe] = bundled) -> CleanupRecipe? {
        recipes.first { $0.matches(path: path) }
    }
}
