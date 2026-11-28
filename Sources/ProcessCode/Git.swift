import Foundation

enum GitState: Equatable {
    case modified, added, untracked, deleted, renamed, conflicted, ignored

    /// The letter shown next to a file, as in `git status --short`.
    var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .untracked: return "U"
        case .deleted: return "D"
        case .renamed: return "R"
        case .conflicted: return "!"
        case .ignored: return ""
        }
    }
}

/// What `git status` says about a working tree.
struct GitStatus: Equatable {
    var isRepository = false
    var branch: String?
    var ahead = 0
    var behind = 0
    /// State by path relative to the repository root. Directories end in "/".
    var entries: [String: GitState] = [:]
    /// Directories that hold a change somewhere below them (no trailing slash).
    var changedDirectories: Set<String> = []
    /// The state of everything here when the opened folder lies inside an untracked or ignored
    /// folder of the repository, which git reports as that one folder, above the opened one.
    var enclosingState: GitState?

    /// The changed files, without ignored ones, sorted by path.
    var changes: [(path: String, state: GitState)] {
        entries.filter { $0.value != .ignored }
            .map { (path: $0.key, state: $0.value) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var changeCount: Int { entries.values.reduce(0) { $0 + ($1 == .ignored ? 0 : 1) } }

    /// The state of a file or folder at `path` (relative, no trailing slash).
    func state(of path: String, isDirectory: Bool) -> GitState? {
        if let state = entries[isDirectory ? path + "/" : path] ?? entries[path] { return state }
        if let enclosingState { return enclosingState }
        // Inside an untracked or ignored folder, which git reports as one entry.
        var prefix = ""
        for part in path.split(separator: "/").dropLast() {
            prefix += part + "/"
            if let state = entries[prefix], state == .untracked || state == .ignored { return state }
        }
        if isDirectory, changedDirectories.contains(path) { return .modified }
        return nil
    }

    /// Parses `git status --porcelain=v1 -z --branch`.
    static func parse(_ output: String) -> GitStatus {
        var status = GitStatus(isRepository: true)
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count >= 3 else { continue }
            let x = field[field.startIndex]
            let y = field[field.index(after: field.startIndex)]
            let path = String(field.dropFirst(3))

            if x == "#", y == "#" {
                status.parseBranch(path)
                continue
            }
            let state: GitState
            if x == "?" { state = .untracked }
            else if x == "!" { state = .ignored }
            else if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") { state = .conflicted }
            else if x == "D" || y == "D" { state = .deleted }
            else if x == "R" || y == "R" || x == "C" || y == "C" {
                state = .renamed
                _ = fields.next() // the path it was renamed from
            }
            else if x == "A" { state = .added }
            else { state = .modified }

            status.entries[path] = state
            guard state != .ignored else { continue }
            var directory = (path.hasSuffix("/") ? String(path.dropLast()) : path) as NSString
            while true {
                directory = directory.deletingLastPathComponent as NSString
                if directory.length == 0 || !status.changedDirectories.insert(directory as String).inserted { break }
            }
        }
        return status
    }

    private mutating func parseBranch(_ line: String) {
        // "main...origin/main [ahead 1, behind 2]", "No commits yet on main", "HEAD (no branch)"
        var text = line
        if let range = text.range(of: " [") {
            let counts = text[range.upperBound...].dropLast()
            for part in counts.split(separator: ",") {
                let words = part.split(separator: " ")
                guard words.count == 2, let n = Int(words[1]) else { continue }
                if words[0] == "ahead" { ahead = n } else if words[0] == "behind" { behind = n }
            }
            text = String(text[..<range.lowerBound])
        }
        if text.hasPrefix("No commits yet on ") { text = String(text.dropFirst("No commits yet on ".count)) }
        if let range = text.range(of: "...") { text = String(text[..<range.lowerBound]) }
        branch = text.hasPrefix("HEAD (no branch)") ? "detached" : text
    }
}

enum Git {
    /// Reads the status of the repository holding `root`. Never takes git's index lock, so it can
    /// run while a commit or another git command is in progress.
    static func status(root: URL) -> GitStatus {
        status(root: root, timeout: nil) ?? GitStatus()
    }

    /// The same, but nil if git didn't answer within `timeout` seconds, so the caller can tell a
    /// slow repository from a folder that isn't one. The two calls share the time.
    static func status(root: URL, timeout: TimeInterval?) -> GitStatus? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        let result = Shell.run("/usr/bin/env", ["git", "--no-optional-locks", "status", "--porcelain=v1", "-z", "--branch", "--ignored=matching"],
                               in: root, timeout: timeout)
        if result.status == 124 { return nil }
        guard result.status == 0 else { return GitStatus() }
        var status = GitStatus.parse(result.output)
        // Paths are relative to the repository's top level, which may be above the opened folder.
        let left = deadline.map { $0.timeIntervalSinceNow }
        if let left, left <= 0 { return nil }
        let top = Shell.run("/usr/bin/env", ["git", "rev-parse", "--show-prefix"], in: root, timeout: left)
        if top.status == 124 { return nil }
        let prefix = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty { status = status.relative(to: prefix) }
        return status
    }

    /// Every file git knows about or would add, relative to `root`; nil outside a repository.
    static func files(root: URL) -> [String]? {
        let result = Shell.run("/usr/bin/env", ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root)
        guard result.status == 0 else { return nil }
        return result.output.split(separator: "\0").map(String.init)
    }
}

extension GitStatus {
    /// Rebases the paths onto a subfolder of the repository (`prefix` ends in "/").
    func relative(to prefix: String) -> GitStatus {
        var copy = self
        copy.entries = [:]
        copy.changedDirectories = []
        for (path, state) in entries {
            if path.hasPrefix(prefix) && path.count > prefix.count {
                copy.entries[String(path.dropFirst(prefix.count))] = state
            } else if path.hasSuffix("/"), prefix.hasPrefix(path), state == .untracked || state == .ignored {
                // The opened folder is inside this one, so all of it shares its state.
                copy.enclosingState = state
            }
        }
        for directory in changedDirectories where directory.hasPrefix(prefix) {
            copy.changedDirectories.insert(String(directory.dropFirst(prefix.count)))
        }
        return copy
    }
}

enum Shell {
    struct Result {
        var status: Int32
        var output: String
    }

    /// Homebrew and MacTeX, which an app started from the Finder doesn't have on its PATH.
    static let extraPath = "/opt/homebrew/bin:/usr/local/bin:/Library/TeX/texbin"

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "/usr/bin:/bin:/usr/sbin:/sbin:") + extraPath
        // Nothing run from here may stop to ask a question, or take git's index lock.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }

    /// Runs a tool to completion and returns what it printed: stdout and stderr together, or with
    /// `mergingErrors` off, stdout alone (and stderr alone if it failed). With a `timeout`, a tool still
    /// running after that many seconds is stopped and the result has status 124.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil, mergingErrors: Bool = true,
                    timeout: TimeInterval? = nil, environment: [String: String]? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment ?? self.environment
        let pipe = Pipe()
        let errorPipe = mergingErrors ? pipe : Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        // Whether the watchdog stopped it, as opposed to a crash or a signal from elsewhere.
        let stopped = Flag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            stopped.set()
            process.terminate()
        }
        if let timeout { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog) }
        // Drain both pipes at once so a chatty stderr can't block the child.
        var errorData = Data()
        let group = DispatchGroup()
        if !mergingErrors {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        watchdog.cancel()
        // Stopped by the watchdog, it was too slow, whether it died of the signal or caught it and
        // exited with a status of its own (a shell's 143).
        if let timeout, stopped.isSet {
            let name = arguments.first.map { tool.hasSuffix("/env") ? $0 : tool } ?? tool
            return Result(status: 124, output: "\(name) didn't answer within \(Int(timeout)) seconds and was stopped.")
        }
        let failedApart = !mergingErrors && process.terminationStatus != 0
        return Result(status: process.terminationStatus, output: String(decoding: failedApart ? errorData : data, as: UTF8.self))
    }
}

/// A yes-or-no that one thread sets and another reads.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
