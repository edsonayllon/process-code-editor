import AppKit
import Combine

/// A folder that can be opened: a git repository in the projects folder, or any folder opened before.
/// The repository reading, cloning and creating here come from the Lean GitHub app, which stays
/// the place for publishing, privacy and moving repositories to the Trash.
struct Project: Identifiable, Equatable {
    let path: String
    var isRepository = true
    /// Lives outside the projects folder, and is listed because it was opened here.
    var isExternal = false
    var branch: String?
    var remote: String?
    var changes = 0
    var ahead = 0
    var behind = 0
    var lastCommit: Date?
    var lastOpened: Date?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }

    /// When it was last worked on: opened here or committed to, whichever is later.
    var activity: Date { max(lastOpened ?? .distantPast, lastCommit ?? .distantPast) }

    /// "owner/name" taken from the remote URL.
    var slug: String? {
        guard let url = webURL else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return parts.suffix(2).joined(separator: "/")
    }

    /// The remote as a page a browser can open.
    var webURL: URL? {
        guard var s = remote?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix(".git") { s.removeLast(4) }
        if s.hasPrefix("git@"), let colon = s.firstIndex(of: ":") {
            let host = s[s.index(s.startIndex, offsetBy: 4)..<colon]
            s = "https://\(host)/\(s[s.index(after: colon)...])"
        } else if s.hasPrefix("ssh://") {
            s = "https://" + s.dropFirst(6)
        }
        guard var parts = URLComponents(string: s), parts.host != nil else { return nil }
        parts.scheme = "https"
        parts.user = nil
        parts.password = nil
        parts.port = nil
        return parts.url
    }

    /// Fills in branch, change count and ahead/behind from `git status --porcelain=v2 --branch`.
    mutating func read(status: String) {
        branch = nil
        changes = 0
        ahead = 0
        behind = 0
        for line in status.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                branch = head == "(detached)" ? "detached" : head
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") {
                changes += 1
            }
        }
    }

    /// The remote named origin, or the first one, from `git remote -v`.
    static func remote(in output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.split(whereSeparator: { $0 == "\t" || $0 == " " }) }
        let pick = lines.first { $0.first == "origin" } ?? lines.first
        return pick.flatMap { $0.count >= 2 ? String($0[1]) : nil }
    }

    /// Reads a repository's state with git. Runs off the main thread.
    func inspected() -> Project {
        var project = self
        guard isRepository else { return project }
        let status = Shell.run("/usr/bin/env", ["git", "status", "--porcelain=v2", "--branch"], in: url)
        guard status.status == 0 else { return project }
        project.read(status: status.output)
        project.remote = Project.remote(in: Shell.run("/usr/bin/env", ["git", "remote", "-v"], in: url).output)
        let log = Shell.run("/usr/bin/env", ["git", "log", "-1", "--format=%ct"], in: url)
        if log.status == 0, let seconds = TimeInterval(log.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            project.lastCommit = Date(timeIntervalSince1970: seconds)
        }
        return project
    }

    /// "now", "5m", "3h", "2d", "6w", "4mo", "2y".
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
        case ..<(86_400 * 61): return "\(Int(seconds / (86_400 * 7)))w"
        case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30.44)))mo"
        default: return "\(Int(seconds / (86_400 * 365.25)))y"
        }
    }
}

/// One of your repositories on GitHub, as `gh repo list` reports it.
struct RemoteRepository: Identifiable, Equatable, Decodable {
    let nameWithOwner: String
    let isPrivate: Bool
    var id: String { nameWithOwner }
}

struct ProjectError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The list of projects on this Mac, shown when no folder is open.
@MainActor
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()
    nonisolated static let defaultRoot = NSHomeDirectory() + "/Documents/GitHub"

    @Published var projects: [Project] = []
    @Published var search = "" { didSet { keepSelectionVisible() } }
    @Published var selection: String?
    @Published var isLoading = false
    @Published var rootPath: String {
        didSet {
            defaults.set(rootPath, forKey: "projectsFolder")
            refresh()
        }
    }

    private let defaults: UserDefaults
    private var generation = 0
    /// When each folder was last opened here, by path.
    private var opened: [String: Double]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rootPath = defaults.string(forKey: "projectsFolder") ?? ProjectStore.defaultRoot
        opened = defaults.dictionary(forKey: "lastOpened") as? [String: Double] ?? [:]
    }

    /// The projects that match the filter, most recently worked on first.
    var visible: [Project] { ProjectStore.filter(projects, by: search) }

    nonisolated static func filter(_ projects: [Project], by search: String) -> [Project] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = query.isEmpty ? projects : projects.filter {
            $0.name.lowercased().contains(query) || ($0.slug?.lowercased().contains(query) ?? false)
        }
        return matches.sorted {
            if $0.activity != $1.activity { return $0.activity > $1.activity }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func keepSelectionVisible() {
        let list = visible
        if !list.contains(where: { $0.path == selection }) { selection = list.first?.path }
    }

    func moveSelection(_ delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        guard let index = list.firstIndex(where: { $0.path == selection }) else {
            selection = list.first?.path
            return
        }
        selection = list[min(max(index + delta, 0), list.count - 1)].path
    }

    /// Records that a folder was opened, so it leads the list (and stays on it if it lives elsewhere).
    func noteOpened(_ folder: URL) {
        guard Workspace.remembersState else { return }
        opened[folder.path] = Date().timeIntervalSince1970
        defaults.set(opened, forKey: "lastOpened")
        if let index = projects.firstIndex(where: { $0.path == folder.path }) {
            projects[index].lastOpened = Date()
        }
    }

    /// Takes a folder from elsewhere off the list. Nothing on disk is touched.
    func forget(_ project: Project) {
        opened[project.path] = nil
        defaults.set(opened, forKey: "lastOpened")
        projects.removeAll { $0.path == project.path }
        keepSelectionVisible()
    }

    /// The folders to list: every git repository in the projects folder, and anything opened
    /// here from somewhere else.
    nonisolated static func scan(root: String, opened: [String: Double]) -> [Project] {
        let fm = FileManager.default
        var found: [Project] = []
        for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") {
            let path = root + "/" + name
            if fm.fileExists(atPath: path + "/.git") { found.append(Project(path: path)) }
        }
        for path in opened.keys where !found.contains(where: { $0.path == path }) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            found.append(Project(path: path, isRepository: fm.fileExists(atPath: path + "/.git"), isExternal: true))
        }
        return found.map { project in
            var project = project
            project.lastOpened = opened[project.path].map(Date.init(timeIntervalSince1970:))
            return project
        }
    }

    /// Rescans the folder, then reads each repository's state a few at a time.
    func refresh() {
        generation += 1
        let current = generation
        // Keep what's known, and last time's commit dates, so the list doesn't reshuffle while git runs.
        let known = Dictionary(projects.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let cachedDates = defaults.dictionary(forKey: "lastCommits") as? [String: Double] ?? [:]
        projects = ProjectStore.scan(root: rootPath, opened: opened).map { fresh in
            var project = known[fresh.path] ?? fresh
            project.lastOpened = fresh.lastOpened
            project.isExternal = fresh.isExternal
            if project.lastCommit == nil { project.lastCommit = cachedDates[fresh.path].map(Date.init(timeIntervalSince1970:)) }
            return project
        }
        keepSelectionVisible()

        let queue = projects
        guard !queue.isEmpty else { isLoading = false; return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let lock = NSLock()
            var results: [Project] = []
            DispatchQueue.concurrentPerform(iterations: queue.count) { index in
                let project = queue[index].inspected()
                lock.lock()
                results.append(project)
                lock.unlock()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, current == self.generation else { return }
                let fresh = Dictionary(results.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                self.projects = self.projects.map { old in
                    guard var project = fresh[old.path] else { return old }
                    project.lastOpened = old.lastOpened
                    return project
                }
                self.isLoading = false
                self.keepSelectionVisible()
                let dates = Dictionary(self.projects.compactMap { p in p.lastCommit.map { (p.path, $0.timeIntervalSince1970) } },
                                       uniquingKeysWith: { a, _ in a })
                self.defaults.set(dates, forKey: "lastCommits")
            }
        }
    }

    // MARK: Clone and create

    /// The folder name a clone of `source` gets ("owner/name", or any git URL).
    nonisolated static func cloneName(for source: String) -> String {
        var name = (source.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.removingPercentEncoding ?? name
    }

    /// Clones into the projects folder and returns the new folder. Runs off the main thread.
    nonisolated static func clone(_ rawSource: String, into root: String) -> Result<URL, ProjectError> {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cloneName(for: source)
        guard !source.isEmpty, !name.isEmpty else { return .failure(ProjectError(message: "Enter a repository URL or owner/name.")) }
        let path = root + "/" + name
        guard !FileManager.default.fileExists(atPath: path) else {
            return .failure(ProjectError(message: "There's already something named “\(name)” in \((root as NSString).abbreviatingWithTildeInPath)."))
        }
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let isURL = source.contains("://") || source.hasPrefix("git@")
        let result = isURL
            ? Shell.run("/usr/bin/env", ["git", "clone", source, path])
            : Shell.run("/usr/bin/env", ["gh", "repo", "clone", source, path])
        guard result.status == 0 else { return .failure(ProjectError(message: explain(result, tool: isURL ? "git" : "gh"))) }
        return .success(URL(fileURLWithPath: path))
    }

    /// Makes a new repository in the projects folder, with a first commit if it gets a README.
    nonisolated static func create(name rawName: String, readme: Bool, in root: String) -> Result<URL, ProjectError> {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            return .failure(ProjectError(message: "A name can't be empty, start with a dot or contain a slash."))
        }
        let path = root + "/" + name
        guard !FileManager.default.fileExists(atPath: path) else {
            return .failure(ProjectError(message: "There's already something named “\(name)” in \((root as NSString).abbreviatingWithTildeInPath)."))
        }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            return .failure(ProjectError(message: error.localizedDescription))
        }
        let url = URL(fileURLWithPath: path)
        let initialized = Shell.run("/usr/bin/env", ["git", "init", "-b", "main"], in: url)
        guard initialized.status == 0 else { return .failure(ProjectError(message: explain(initialized, tool: "git"))) }
        if readme {
            try? "# \(name)\n".write(toFile: path + "/README.md", atomically: true, encoding: .utf8)
            Shell.run("/usr/bin/env", ["git", "add", "-A"], in: url)
            Shell.run("/usr/bin/env", ["git", "commit", "-m", "Initial commit"], in: url)
        }
        return .success(url)
    }

    /// Your repositories on GitHub, through the GitHub CLI's sign-in.
    nonisolated static func remoteRepositories() -> Result<[RemoteRepository], ProjectError> {
        let result = Shell.run("/usr/bin/env", ["gh", "repo", "list", "--limit", "300", "--json", "nameWithOwner,isPrivate"], mergingErrors: false)
        guard result.status == 0 else { return .failure(ProjectError(message: explain(result, tool: "gh"))) }
        return .success((try? JSONDecoder().decode([RemoteRepository].self, from: Data(result.output.utf8))) ?? [])
    }

    private nonisolated static func explain(_ result: Shell.Result, tool: String) -> String {
        if result.status == 127 || result.output.contains("No such file or directory") && result.output.contains("env:") {
            return tool == "gh"
                ? "The GitHub CLI isn't installed. Install it with Homebrew (brew install gh), then run: gh auth login"
                : "git isn't installed. Install it with Homebrew: brew install git"
        }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "\(tool) failed." : text
    }
}
