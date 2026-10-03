import Foundation

/// Whether deleting a repository's folder would lose committed work
/// (TASK-053). Read from `.git` directly — no `git` subprocess, no network,
/// consistent with the offline promise. Remote-tracking refs are as of the
/// last fetch, so "differs" cannot tell unpushed from not-yet-pulled; the copy
/// says so. Uncommitted working-tree changes are not detected at all.
public enum GitState: Sendable, Equatable {
    case notARepository
    /// A repository with no remote: this folder may be the only copy.
    case noRemote
    /// Every local branch matches its remote-tracking branch.
    case inSync
    /// These local branches are missing from, or differ from, the remote.
    case differs(branches: [String])
    /// `.git` is a file (worktree or submodule), or could not be read.
    case unknown(reason: String)

    public var title: String {
        switch self {
        case .notARepository: return "Not a git repository"
        case .noRemote: return "No remote — may be the only copy"
        case .inSync: return "Committed work is on the remote"
        case .differs(let branches):
            return branches.count == 1
                ? "Branch “\(branches[0])” isn’t on the remote"
                : "\(branches.count) branches aren’t on the remote"
        case .unknown: return "Git status unknown"
        }
    }

    public var detail: String {
        switch self {
        case .notARepository:
            return "No version control found, so nothing guarantees this folder can be recovered."
        case .noRemote:
            return "The repository has no remote to push to. Deleting the folder deletes its history."
        case .inSync:
            return "Every local branch matches the remote as of the last fetch. Uncommitted changes are not checked."
        case .differs:
            return "These branches have commits that differ from the remote — unpushed work, or changes not yet pulled. Uncommitted changes are not checked."
        case .unknown(let reason):
            return reason
        }
    }

    /// Only this state says the folder's committed history exists elsewhere.
    public var isBackedUp: Bool { self == .inSync }
}

public enum GitInspector {
    public static func inspect(repositoryPath: String) -> GitState {
        let git = repositoryPath + "/.git"
        var info = stat()
        guard lstat(git, &info) == 0 else { return .notARepository }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            return .unknown(reason: "This is a git worktree or submodule; its status lives in another repository.")
        }
        guard let config = read(git + "/config") else {
            return .unknown(reason: "The repository’s configuration could not be read.")
        }
        let remotes = remoteNames(inConfig: config)
        guard !remotes.isEmpty else { return .noRemote }
        let remote = remotes.contains("origin") ? "origin" : (remotes.sorted().first ?? "origin")

        let packed = packedRefs(git + "/packed-refs")
        var local = packed.filter { $0.key.hasPrefix("refs/heads/") }
        var tracking = packed.filter { $0.key.hasPrefix("refs/remotes/\(remote)/") }
        for (ref, sha) in looseRefs(git, prefix: "refs/heads") { local[ref] = sha }
        for (ref, sha) in looseRefs(git, prefix: "refs/remotes/\(remote)") { tracking[ref] = sha }

        guard !local.isEmpty else {
            return .unknown(reason: "The repository has no branches yet.")
        }
        var differing: [String] = []
        for (ref, sha) in local {
            let branch = String(ref.dropFirst("refs/heads/".count))
            if tracking["refs/remotes/\(remote)/\(branch)"] != sha { differing.append(branch) }
        }
        return differing.isEmpty ? .inSync : .differs(branches: differing.sorted())
    }

    /// `[remote "name"]` section headers.
    static func remoteNames(inConfig config: String) -> [String] {
        config.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[remote \""), trimmed.hasSuffix("\"]") else { return nil }
            return String(trimmed.dropFirst("[remote \"".count).dropLast(2))
        }
    }

    static func packedRefs(_ path: String) -> [String: String] {
        guard let text = read(path) else { return [:] }
        var refs: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            refs[String(parts[1])] = String(parts[0])
        }
        return refs
    }

    /// Loose ref files under `.git/<prefix>`, recursively (branch names may
    /// contain slashes).
    static func looseRefs(_ git: String, prefix: String) -> [String: String] {
        // `subpathsOfDirectory` returns paths relative to the base. An
        // enumerator returns symlink-resolved absolute URLs (/private/var/…),
        // and trimming a /var/… base off those by length misnamed branches.
        let base = git + "/" + prefix
        guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: base) else { return [:] }
        var refs: [String: String] = [:]
        for relative in subpaths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base + "/" + relative, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let sha = read(base + "/" + relative)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  sha.count >= 40, !sha.hasPrefix("ref:") else { continue }
            refs[prefix + "/" + relative] = sha
        }
        return refs
    }

    static func read(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), data.count < 16 * 1024 * 1024 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `.gitignore` evaluation over the scan tree (TASK-054): how many bytes in a
/// repository git itself treats as disposable. Anything ignored is, by the
/// repository author's own declaration, generated or local — a stronger
/// signal than any name list, and it covers tools DiskMap has no rule for.
///
/// Supported: nested `.gitignore` files and `.git/info/exclude`; blank lines
/// and `#` comments; `!` negation; trailing `/` (directories only); leading or
/// inner `/` (anchored to the file's folder); `*`, `?`, `[...]`, `**`; `\`
/// escapes. Not supported: the global excludes file (`core.excludesFile`).
/// As in git, an ignored folder is not descended into, so a negation inside
/// it cannot re-include anything.
public struct GitIgnoreRules {
    struct Rule {
        enum Matcher {
            case literalName(String)
            case nameSuffix(String)
            case regex(NSRegularExpression)
        }
        let matcher: Matcher
        let anchored: Bool
        let directoryOnly: Bool
        let negated: Bool
        /// Folder of the file this rule came from, relative to the repository
        /// root ("" for the root).
        let base: String
        /// For regex rules: a literal run every match must contain. A cheap
        /// `contains` check skips the regex for almost every path.
        var requiredLiteral: String? = nil
        /// For regex rules whose last path segment has no wildcard: the exact
        /// name the path must end in ("lib/**/tsconfig.json" → tsconfig.json).
        /// Without it, every file under a large un-ignored folder that shares
        /// the rule's literal prefix ran the regex (stdlib: ~150k entries).
        var requiredName: String? = nil
    }

    /// Lookup structure over a rule list, so evaluating a path costs O(1)
    /// dictionary hits plus the few genuine globs — not a loop over every
    /// rule. Measured: a 123-rule, ~200k-entry repository took 1.5 s with the
    /// plain loop.
    struct Index {
        var byName: [String: [Int]] = [:]
        var byExtension: [String: [Int]] = [:]
        var scanned: [Int] = []

        init(_ rules: [Rule]) {
            for (i, rule) in rules.enumerated() {
                switch rule.matcher {
                case .literalName(let name):
                    byName[name, default: []].append(i)
                case .nameSuffix(let suffix) where suffix.hasPrefix(".") && !suffix.dropFirst().contains("."):
                    byExtension[suffix, default: []].append(i)
                default:
                    scanned.append(i)
                }
            }
        }
    }

    var rules: [Rule] = []

    /// Parses one ignore file whose folder is `base` (relative to the repo root).
    static func parse(_ text: String, base: String) -> [Rule] {
        var out: [Rule] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String(rawLine)
            // Trailing spaces are ignored unless escaped.
            while line.hasSuffix(" ") && !line.hasSuffix("\\ ") { line.removeLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }
            var negated = false
            if line.hasPrefix("!") { negated = true; line.removeFirst() }
            else if line.hasPrefix("\\!") || line.hasPrefix("\\#") { line.removeFirst() }
            var directoryOnly = false
            if line.hasSuffix("/") { directoryOnly = true; line.removeLast() }
            guard !line.isEmpty else { continue }
            let anchored = line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            guard let matcher = matcher(for: line, anchored: anchored) else { continue }
            var rule = Rule(matcher: matcher, anchored: anchored, directoryOnly: directoryOnly, negated: negated, base: base)
            if case .regex = matcher {
                rule.requiredLiteral = longestLiteral(line)
                if let last = line.split(separator: "/").last.map(String.init),
                   last != "**", last.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[")) == nil {
                    rule.requiredName = last.replacingOccurrences(of: "\\", with: "")
                }
            }
            out.append(rule)
        }
        return out
    }

    private static func matcher(for pattern: String, anchored: Bool) -> Rule.Matcher? {
        let special = CharacterSet(charactersIn: "*?[\\")
        if !anchored, pattern.rangeOfCharacter(from: special) == nil {
            return .literalName(pattern)
        }
        if !anchored, pattern.hasPrefix("*"), pattern.dropFirst().rangeOfCharacter(from: special) == nil {
            return .nameSuffix(String(pattern.dropFirst()))
        }
        guard let regex = try? NSRegularExpression(pattern: "^" + regexBody(pattern) + "$") else { return nil }
        return .regex(regex)
    }

    /// Longest run of literal characters in a glob (outside `*`, `?` and
    /// `[...]`, honouring `\` escapes). Empty runs yield nil.
    static func longestLiteral(_ glob: String) -> String? {
        var best = "", current = ""
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" || c == "?" {
                if current.count > best.count { best = current }
                current = ""
                // "**/" can match zero folders ("**/cache" matches "cache"),
                // so the slash after "**" is not required.
                if c == "*", i + 2 < chars.count, chars[i + 1] == "*", chars[i + 2] == "/" { i += 2 }
            } else if c == "[", let close = chars[(i + 1)...].firstIndex(of: "]") {
                if current.count > best.count { best = current }
                current = ""
                i = close
            } else if c == "\\", i + 1 < chars.count {
                current.append(chars[i + 1])
                i += 1
            } else {
                current.append(c)
            }
            i += 1
        }
        if current.count > best.count { best = current }
        return best.isEmpty ? nil : best
    }

    /// Glob → regex, per gitignore(5).
    static func regexBody(_ glob: String) -> String {
        var out = ""
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                let doubleStar = i + 1 < chars.count && chars[i + 1] == "*"
                if doubleStar {
                    let atStart = i == 0
                    let followedBySlash = i + 2 < chars.count && chars[i + 2] == "/"
                    let atEnd = i + 2 == chars.count
                    if atStart && followedBySlash { out += "(?:.*/)?"; i += 3; continue }
                    if atEnd { out += ".*"; i += 2; continue }
                    if followedBySlash { out += "(?:.*/)?"; i += 3; continue }
                    out += ".*"; i += 2; continue
                }
                out += "[^/]*"
            } else if c == "?" {
                out += "[^/]"
            } else if c == "[" , let close = chars[(i + 1)...].firstIndex(of: "]") {
                var cls = String(chars[(i + 1)..<close])
                if cls.hasPrefix("!") { cls = "^" + cls.dropFirst() }
                out += "[" + cls.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                i = close
            } else if c == "\\", i + 1 < chars.count {
                out += NSRegularExpression.escapedPattern(for: String(chars[i + 1]))
                i += 1
            } else {
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        return out
    }

    /// nil when no rule mentions the path; otherwise whether the last
    /// matching rule ignores it.
    func verdict(relativePath: String, name: String, isDirectory: Bool) -> Bool? {
        verdict(relativePath: relativePath, name: name, isDirectory: isDirectory, index: Index(rules), limit: rules.count)
    }

    /// Same, using a prebuilt index. Rules at positions >= `limit` are
    /// ignored, so an index built for a longer list stays valid after the
    /// list is truncated (leaving a folder whose `.gitignore` added rules).
    func verdict(relativePath: String, name: String, isDirectory: Bool, index: Index, limit: Int) -> Bool? {
        var best = -1
        func consider(_ i: Int) {
            guard i < limit, i > best, matches(rules[i], relativePath: relativePath, name: name, isDirectory: isDirectory) else { return }
            best = i
        }
        index.byName[name]?.forEach(consider)
        if let dot = name.lastIndex(of: ".") { index.byExtension[String(name[dot...])]?.forEach(consider) }
        index.scanned.forEach(consider)
        return best >= 0 ? !rules[best].negated : nil
    }

    private func matches(_ rule: Rule, relativePath: String, name: String, isDirectory: Bool) -> Bool {
        if rule.directoryOnly && !isDirectory { return false }
        guard rule.base.isEmpty || relativePath.hasPrefix(rule.base + "/") else { return false }
        let subject = rule.anchored
            ? (rule.base.isEmpty ? relativePath : String(relativePath.dropFirst(rule.base.count + 1)))
            : name
        switch rule.matcher {
        case .literalName(let literal): return subject == literal
        case .nameSuffix(let suffix): return subject.hasSuffix(suffix)
        case .regex(let regex):
            if let required = rule.requiredName, name != required { return false }
            if let literal = rule.requiredLiteral, !subject.contains(literal) { return false }
            return regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
        }
    }

    /// Bytes ignored under a repository, using the scan tree for structure
    /// and sizes and reading only `.gitignore` files from disk.
    public struct Result: Sendable, Equatable {
        public var ignoredBytes: Int64
        public var ignoreFileCount: Int
    }

    static func ignoredBytes(
        tree: FileTree, repositoryID: Int32, repositoryPath: String, totals: [Int64]
    ) -> Result {
        var rules = GitIgnoreRules()
        if let exclude = GitInspector.read(repositoryPath + "/.git/info/exclude") {
            rules.rules += parse(exclude, base: "")
        }
        var files = 0
        var ignored: Int64 = 0
        // Rule scoping: each frame records the rule count its PARENT had, and
        // popping it truncates back to that before adding its own file. The
        // stack is LIFO, so a folder's whole subtree is processed before any
        // sibling is popped — rules from one branch never leak into another.
        var stack: [(id: Int32, relative: String, restoreTo: Int)] = [(repositoryID, "", rules.rules.count)]
        var active = rules
        // Rebuilt only when a `.gitignore` adds rules; truncation needs no
        // rebuild because lookups cap at the current rule count.
        var ruleIndex = Index(active.rules)
        var indexStale = false
        while let frame = stack.popLast() {
            active.rules.removeSubrange(frame.restoreTo...)
            // Load this folder's own .gitignore, if the scan saw one.
            var child = tree.firstChild[Int(frame.id)]
            while child != -1 {
                if !tree.isDirectory[Int(child)], tree.name(of: child) == ".gitignore" {
                    let folderPath = frame.relative.isEmpty ? repositoryPath : repositoryPath + "/" + frame.relative
                    if let text = GitInspector.read(folderPath + "/.gitignore") {
                        active.rules += parse(text, base: frame.relative)
                        files += 1
                        indexStale = true
                    }
                }
                child = tree.nextSibling[Int(child)]
            }
            let depthRules = active.rules.count
            if indexStale {
                ruleIndex = Index(active.rules)
                indexStale = false
            }
            child = tree.firstChild[Int(frame.id)]
            while child != -1 {
                let index = Int(child)
                let name = tree.name(of: child)
                let isDir = tree.isDirectory[index]
                let relative = frame.relative.isEmpty ? name : frame.relative + "/" + name
                defer { child = tree.nextSibling[index] }
                if name == ".git" { continue }
                if active.verdict(relativePath: relative, name: name, isDirectory: isDir, index: ruleIndex, limit: depthRules) == true {
                    ignored += totals[index]
                    continue
                }
                if isDir {
                    // A nested repository is its own gitignore domain.
                    var nested = false
                    var grandchild = tree.firstChild[index]
                    while grandchild != -1 {
                        if tree.name(of: grandchild) == ".git" { nested = true; break }
                        grandchild = tree.nextSibling[Int(grandchild)]
                    }
                    if !nested { stack.append((child, relative, depthRules)) }
                }
            }
        }
        return Result(ignoredBytes: ignored, ignoreFileCount: files)
    }
}
