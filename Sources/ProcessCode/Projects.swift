import AppKit
import Combine

/// A folder that can be opened: a git repository in the projects folder, or any folder opened before.
struct Project: Identifiable, Equatable {
    let path: String
    var isRepository = true
    /// Lives outside the projects folder, and is listed because it was opened here.
    var isExternal = false
    var branch: String?
    /// The names a repository's main branch usually has, which the list leaves out.
    static let usualBranches: Set<String> = ["main", "master"]
    var remote: String?
    var changes = 0
    var ahead = 0
    var behind = 0
    /// False for a repository with no commits yet, which GitHub can't be sent.
    var hasCommits = true
    /// Commits on any local branch that no remote has, and stashed changes. Read only before a
    /// move to the Trash (`inspectedForTrash`), since it costs two more git runs.
    var unpushed = 0
    var stashes = 0
    /// Counting those failed, so what only exists in this folder isn't known.
    var uncounted = false
    /// A remote couldn't be asked which of its branches are gone, so a branch deleted there since
    /// the last fetch may still count as pushed.
    var remoteUnchecked = false
    /// Whether git has been read yet. Until then the remote is unknown, not missing.
    var isRead = false
    var lastCommit: Date?
    var lastOpened: Date?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }

    /// Has a remote to push to, so it's somewhere besides this Mac.
    var isPublished: Bool { remote != nil }
    /// A repository known to have no remote: one that can be published.
    var canPublish: Bool { isRepository && isRead && !isPublished }

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
        hasCommits = true
        for line in status.split(separator: "\n") {
            if line == "# branch.oid (initial)" {
                hasCommits = false
            } else if line.hasPrefix("# branch.head ") {
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
        project.isRead = true
        project.remote = Project.remote(in: Shell.run("/usr/bin/env", ["git", "remote", "-v"], in: url).output)
        let log = Shell.run("/usr/bin/env", ["git", "log", "-1", "--format=%ct"], in: url)
        if log.status == 0, let seconds = TimeInterval(log.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            project.lastCommit = Date(timeIntervalSince1970: seconds)
        }
        return project
    }

    /// `inspected()`, plus what only exists in this folder: commits on any branch, or on a detached
    /// HEAD, that no branch on a remote has, and stashes. Each remote is asked which branches it has
    /// deleted since the last fetch, and those don't count as pushed. Runs off the main thread, and
    /// can take as long as the slowest remote, as they're asked side by side.
    func inspectedForTrash() -> Project {
        var project = inspected()
        guard project.isRead else { return project }
        let listed = Shell.run("/usr/bin/env", ["git", "remote"], in: url, mergingErrors: false)
        let remotes = listed.status == 0 ? listed.output.split(separator: "\n").map(String.init) : []
        var answers = [Shell.Result?](repeating: nil, count: remotes.count)
        let lock = NSLock()
        let url = self.url
        DispatchQueue.concurrentPerform(iterations: remotes.count) { index in
            let pruned = Shell.run("/usr/bin/env", ["git", "remote", "prune", "--dry-run", remotes[index]], in: url,
                                   mergingErrors: false, timeout: Project.remoteTimeout)
            lock.withLock { answers[index] = pruned }
        }
        var gone: [String] = []
        for case let pruned? in answers {
            if pruned.status == 0 { gone += Project.goneBranches(inPruneOutput: pruned.output) } else { project.remoteUnchecked = true }
        }
        // A repository with no commits has no HEAD to count from.
        let heads = project.hasCommits ? ["HEAD", "--branches"] : ["--branches"]
        let pushed = gone.map { "--exclude=" + $0 } + ["--remotes"]
        let count = Shell.run("/usr/bin/env", ["git", "rev-list", "--count"] + heads + ["--not"] + pushed, in: url, mergingErrors: false)
        let stashes = Shell.run("/usr/bin/env", ["git", "stash", "list"], in: url, mergingErrors: false)
        if count.status == 0, let unpushed = Int(count.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            project.unpushed = unpushed
        } else {
            project.uncounted = true
        }
        if stashes.status == 0 {
            project.stashes = stashes.output.split(separator: "\n").count
        } else {
            project.uncounted = true
        }
        return project
    }

    /// How long a remote may take to say which branches it has.
    static let remoteTimeout: TimeInterval = 10

    /// The remote-tracking branches `git remote prune --dry-run` would remove ("origin/feature"),
    /// which are gone from the remote.
    static func goneBranches(inPruneOutput output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard let marker = line.range(of: "[would prune] ") else { return nil }
            return line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        }
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
    /// Set when the GitHub CLI can't be used at all, rather than one thing having failed.
    var setup: GitHubSetup? = nil
    var errorDescription: String? { message }
}

/// Why the GitHub CLI can't be used, for the note in the projects window.
enum GitHubSetup: Equatable {
    case notInstalled, signedOut
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
    /// Which GitHub repositories are private, by lowercased "owner/name". Kept between launches so the
    /// locks show at once; GitHub is asked again after the list has been read.
    @Published private(set) var privacy: [String: Bool]
    /// Why the GitHub CLI can't be used, as last found, or nil if it can (or nothing's known yet).
    @Published var githubSetup: GitHubSetup?
    /// Where installing the CLI or signing in to it has got to.
    @Published var setupStep = GitHubSetupStep.idle
    /// The `gh auth login` under way, and whether it was cancelled.
    var signIn: Process?
    var signInCancelled = false
    /// Ends the sign-in under way if gh has exited, so a Cancel then needn't wait for its output.
    var finishSignIn: (() -> Void)?
    /// Opens a page in the browser, and puts text on the clipboard. Tests watch them instead.
    var openPage: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var copyText: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// The note about it was closed, and isn't shown again.
    @Published var githubNoticeDismissed: Bool { didSet { defaults.set(githubNoticeDismissed, forKey: "githubNoticeDismissed") } }
    /// The folders that have a window open, set by the app.
    var openFolders: () -> [String] = { [] }
    /// How many files inside a folder have unsaved changes in the open windows, set by the app.
    var unsavedInWindows: (URL) -> Int = { _ in 0 }
    /// Closes the tabs of files inside a folder that went to the Trash, in the open windows, set by the app.
    var closeInWindows: (URL) -> Void = { _ in }
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
    private var privacyLoadedAt: Date?
    private var privacyLoading = false
    /// A forced load asked for while one was running, to run when it ends.
    private var privacyAgain = false
    /// A forced load to run once the refresh under way has read every remote.
    private var privacyDue = false
    /// Repositories owned by someone else, already asked about one by one this session. Each is asked
    /// once per launch, so a change on GitHub shows by the next one.
    private var privacyAsked: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rootPath = defaults.string(forKey: "projectsFolder") ?? ProjectStore.defaultRoot
        opened = defaults.dictionary(forKey: "lastOpened") as? [String: Double] ?? [:]
        privacy = defaults.dictionary(forKey: "privacy") as? [String: Bool] ?? [:]
        githubNoticeDismissed = defaults.bool(forKey: "githubNoticeDismissed")
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

    /// Rescans the folder, then reads each repository's state a few at a time. With `askGitHub`, the
    /// privacy load after it is forced, for a repository that has just been cloned or published.
    func refresh(askGitHub: Bool = false) {
        if askGitHub { privacyDue = true }
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
        guard !queue.isEmpty else {
            isLoading = false
            // Nothing to put locks on, but whether the GitHub CLI works is still worth knowing.
            loadPrivacy(force: privacyDue)
            privacyDue = false
            return
        }
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
                self.loadPrivacy(force: self.privacyDue)
                self.privacyDue = false
            }
        }
    }

    // MARK: Private or public

    /// nil when the repository isn't on GitHub, or GitHub hasn't said yet.
    func isPrivate(_ project: Project) -> Bool? {
        guard project.webURL?.host == "github.com", let slug = project.slug else { return nil }
        return privacy[slug.lowercased()]
    }

    /// Asks GitHub which repositories are private. It's the only thing here that uses the network
    /// unasked, so it runs in the background after the list is up, at most every 15 seconds unless forced.
    func loadPrivacy(force: Bool = false) {
        guard !privacyLoading else {
            if force { privacyAgain = true }
            return
        }
        if !force, let last = privacyLoadedAt, Date().timeIntervalSince(last) < 15 { return }
        privacyLoadedAt = Date()
        privacyLoading = true
        let slugs = Set(projects.filter { $0.webURL?.host == "github.com" }.compactMap { $0.slug?.lowercased() })
        let skip = privacyAsked
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let answer = ProjectStore.fetchPrivacy(for: slugs, skipping: skip)
            DispatchQueue.main.async {
                guard let self else { return }
                self.privacyLoading = false
                switch answer {
                case .failure(let failure):
                    // A slow network says nothing about whether the CLI is set up, so it changes nothing.
                    if let setup = failure.setup { self.githubSetup = setup }
                case .success(let answer):
                    if self.githubSetup != nil { self.githubSetup = nil }
                    self.privacyAsked.formUnion(answer.asked)
                    var map = self.privacy
                    map.merge(answer.found) { _, new in new }
                    if map != self.privacy {
                        self.privacy = map
                        self.defaults.set(map, forKey: "privacy")
                    }
                }
                if self.privacyAgain {
                    self.privacyAgain = false
                    self.loadPrivacy(force: true)
                }
            }
        }
    }

    /// Your own repositories in one call, then each one owned by someone else that hasn't been asked
    /// about yet, on its own. A failure when gh can't answer at all (not installed, not signed in, or
    /// no answer within the time limit).
    nonisolated static func fetchPrivacy(for slugs: Set<String>, skipping asked: Set<String>)
        -> Result<(found: [String: Bool], asked: Set<String>), ProjectError> {
        let remotes: [RemoteRepository]
        switch remoteRepositories() {
        case .success(let list): remotes = list
        case .failure(let failure): return .failure(failure)
        }
        var map: [String: Bool] = [:]
        for remote in remotes { map[remote.nameWithOwner.lowercased()] = remote.isPrivate }
        let others = Array(slugs.filter { map[$0] == nil && !asked.contains($0) })
        // Side by side (as many at a time as there are cores), so a slow network costs a time limit
        // per batch, not one per repository.
        var answers = [Bool?](repeating: nil, count: others.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: others.count) { index in
            let result = Shell.run("/usr/bin/env", ["gh", "repo", "view", others[index], "--json", "isPrivate", "--jq", ".isPrivate"],
                                   mergingErrors: false, timeout: ghTimeout)
            guard result.status == 0 else { return }
            let isPrivate = result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            lock.withLock { answers[index] = isPrivate }
        }
        for (slug, answer) in zip(others, answers) { if let answer { map[slug] = answer } }
        return .success((map, Set(others)))
    }

    /// How long a quick question to GitHub may take before it's given up on.
    nonisolated static let ghTimeout: TimeInterval = 30

    // MARK: Trash

    /// What would be lost, spelled out for the confirmation.
    /// `drafts` is how many of its files have unsaved changes kept from a window that closed, and
    /// `unsavedOpen` how many have them in a window still open (on a folder above the project).
    nonisolated static func trashWarning(for project: Project, drafts: Int = 0, unsavedOpen: Int = 0) -> String {
        var risks: [String] = []
        if unsavedOpen > 0 {
            risks.append(unsavedOpen == 1
                         ? "1 file in it has unsaved changes in an open window. Its tab will close, and the changes will be lost."
                         : "\(unsavedOpen) files in it have unsaved changes in an open window. Their tabs will close, and the changes will be lost.")
        }
        if drafts > 0 {
            risks.append(drafts == 1 ? "1 file in it has unsaved changes, kept from when its window closed. They'll be lost."
                         : "\(drafts) files in it have unsaved changes, kept from when its window closed. They'll be lost.")
        }
        if project.isRepository && !project.isPublished {
            risks.append("It isn't on GitHub, so the Trash will hold the only copy.")
        } else if project.isRepository {
            if project.changes > 0 {
                risks.append(project.changes == 1 ? "It has 1 uncommitted change." : "It has \(project.changes) uncommitted changes.")
            }
            if project.unpushed > 0 {
                risks.append(project.unpushed == 1
                             ? "It has 1 commit that isn't on GitHub, on one of its branches."
                             : "It has \(project.unpushed) commits that aren't on GitHub, across its branches.")
            }
            if project.stashes > 0 {
                risks.append(project.stashes == 1 ? "It has 1 stash." : "It has \(project.stashes) stashes.")
            }
            if project.uncounted {
                risks.append("Git couldn't count its commits that aren't on GitHub or its stashes, so it may hold work that's nowhere else.")
            } else if project.remoteUnchecked {
                risks.append("GitHub couldn't be reached, so commits on a branch deleted there since this Mac last fetched aren't counted.")
            }
        }
        let base = project.isPublished
            ? "The folder moves to the Trash, where you can put it back. The repository on GitHub isn't touched."
            : "The folder moves to the Trash, where you can put it back."
        return (risks + [base]).joined(separator: "\n\n")
    }

    /// Why a folder can't go to the Trash from here, or nil if it can. Only repositories go, and
    /// never the projects folder itself, a folder holding another project on the list, or one with
    /// a window open on it or on a folder inside it (in `open`).
    nonisolated static func trashRefusal(for project: Project, root: String, listed: [String], open: [String] = []) -> String? {
        let path = (project.path as NSString).standardizingPath
        guard project.isRepository else { return "Only a git repository can be moved to the Trash from here." }
        if let window = open.map({ ($0 as NSString).standardizingPath }).first(where: { $0 == path || $0.hasPrefix(path + "/") }) {
            return window == path ? "It's open in a window. Close the window first."
                : "“\((window as NSString).lastPathComponent)” in it is open in a window. Close the window first."
        }
        // Never the projects folder or the home folder, or anything holding either of them.
        let root = (root as NSString).standardizingPath
        for (kept, name) in [(root, "projects"), (NSHomeDirectory(), "home")] {
            if kept == path { return "That's the \(name) folder itself." }
            if path == "/" || kept.hasPrefix(path + "/") { return "It holds the \(name) folder." }
        }
        if let inside = listed.first(where: { ($0 as NSString).standardizingPath.hasPrefix(path + "/") }) {
            return "It holds another project, “\((inside as NSString).lastPathComponent)”."
        }
        return nil
    }

    /// How many unsaved drafts inside the project would go with it: those kept from windows that
    /// have closed.
    func keptDrafts(in project: Project) -> Int {
        Drafts.all(under: project.url, except: openFolders()).count
    }

    /// Why this project can't go to the Trash, given what's on the list now.
    func trashRefusal(for project: Project) -> String? {
        ProjectStore.trashRefusal(for: project, root: rootPath, listed: projects.map(\.path), open: openFolders())
    }

    /// Moves the folder to the Trash and takes it off the list. Never deletes outright, and never
    /// touches GitHub. Returns why it couldn't, if it couldn't.
    func moveToTrash(_ project: Project) -> String? {
        if let refusal = trashRefusal(for: project) { return refusal }
        do {
            _ = try Trash.move(project.url)
        } catch {
            return error.localizedDescription
        }
        // The warning said its unsaved changes would be lost, so they're not kept to come back
        // if the folder is put back or cloned again at the same place. A window open on a folder
        // above closes its tabs for them and lets their drafts go first.
        closeInWindows(project.url)
        Drafts.removeAll(under: project.url, except: openFolders())
        let list = visible
        if selection == project.path, let index = list.firstIndex(where: { $0.path == project.path }) {
            selection = (index + 1 < list.count ? list[index + 1] : (index > 0 ? list[index - 1] : nil))?.path
        }
        opened[project.path] = nil
        defaults.set(opened, forKey: "lastOpened")
        projects.removeAll { $0.path == project.path }
        keepSelectionVisible()
        return nil
    }

    /// Asks, then moves it to the Trash. A failure is reported after the question has closed, so
    /// the two dialogs never overlap.
    func trash(_ project: Project, confirm: (Project) -> Bool, report: (String) -> Void) {
        guard confirm(project) else { return }
        if let error = moveToTrash(project) { report(error) }
    }

    // MARK: Clone, create and publish

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
        guard result.status == 0 else {
            return .failure(ProjectError(message: explain(result, tool: isURL ? "git" : "gh"), setup: isURL ? nil : githubSetup(from: result)))
        }
        return .success(URL(fileURLWithPath: path))
    }

    /// Makes a new repository in the projects folder, with a first commit if it gets a README, and
    /// publishes it to GitHub if asked.
    nonisolated static func create(name rawName: String, readme: Bool, publish: Bool = false, isPrivate: Bool = true,
                                   in root: String) -> Result<URL, ProjectError> {
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
        guard publish else { return .success(url) }
        switch ProjectStore.publish(Project(path: path), name: name, description: "", isPrivate: isPrivate) {
        case .success: return .success(url)
        case .failure(let failure):
            return .failure(ProjectError(message: "“\(name)” was created on this Mac. \(failure.message)", setup: failure.setup))
        }
    }

    /// A folder name made into one GitHub accepts: anything besides letters, digits, ".", "_" and "-"
    /// becomes a dash, and it doesn't start with a dash (which gh would read as an option).
    nonisolated static func githubName(for name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = name.trimmingCharacters(in: .whitespaces).unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let single = mapped.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return String(single.drop { $0 == "-" })
    }

    /// What to say when publishing failed, and how to finish. gh makes the GitHub repository, then
    /// adds origin, then pushes. A failure after the first step leaves a repository on GitHub that
    /// publishing again would collide with, so the way on is to finish by hand: add origin if it's
    /// missing (`madeAt` is the new repository's address), then push.
    nonisolated static func publishFailure(_ output: String, remoteAdded: Bool, madeAt: String? = nil, branch: String?) -> String {
        // read(status:) names a detached HEAD "detached"; there's no branch to push until one is made.
        // Any new name will do, but not one that's taken, as main usually is.
        let onBranch = branch != nil && branch != "detached"
        let push = onBranch ? "git push -u origin \(branch ?? "")" : "git switch -c <new-branch> && git push -u origin <new-branch>"
        if remoteAdded {
            return "GitHub made the repository and set it as origin, but the push didn't finish: \(output)\n\n"
                + (onBranch ? "Push it from the terminal: " : "You're not on a branch. Make one and push it from the terminal: ") + push
        }
        if let madeAt {
            return "GitHub made the repository, but it wasn't set as origin: \(output)\n\n"
                + "Finish from the terminal: git remote add origin \(madeAt) && " + push
        }
        return "Publishing failed: \(output)\n\nPublish it again from its right-click menu in Projects."
    }

    /// The address of your repository on GitHub with this name, or nil if there's none (or gh can't say).
    nonisolated static func gitHubRepository(named name: String) -> String? {
        let result = Shell.run("/usr/bin/env", ["gh", "repo", "view", name, "--json", "url", "--jq", ".url"],
                               mergingErrors: false, timeout: ghTimeout)
        let address = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !address.isEmpty ? address : nil
    }

    /// The `gh` arguments that make the GitHub repository, point origin at it and, if there's
    /// anything to send, push.
    nonisolated static func publishArguments(path: String, name: String, description: String, isPrivate: Bool, hasCommits: Bool) -> [String] {
        var arguments = ["gh", "repo", "create", name, isPrivate ? "--private" : "--public", "--source", path, "--remote", "origin"]
        let description = description.trimmingCharacters(in: .whitespaces)
        if !description.isEmpty { arguments += ["--description", description] }
        // gh can't push a repository that has no commits yet.
        if hasCommits { arguments.append("--push") }
        return arguments
    }

    /// Makes a GitHub repository for a local one and pushes it. Runs off the main thread.
    nonisolated static func publish(_ project: Project, name rawName: String, description: String, isPrivate: Bool) -> Result<URL, ProjectError> {
        let name = githubName(for: rawName)
        guard !name.isEmpty else { return .failure(ProjectError(message: "The repository needs a name on GitHub.")) }
        let fresh = project.inspected()
        guard !fresh.isPublished else { return .failure(ProjectError(message: "This repository already has a remote.")) }
        // A name that's taken is refused before anything is made, so a repository found under it
        // after a failure is one this publish made.
        if gitHubRepository(named: name) != nil {
            return .failure(ProjectError(message: "You already have a repository named “\(name)” on GitHub. Choose another name."))
        }
        let arguments = publishArguments(path: project.path, name: name, description: description, isPrivate: isPrivate, hasCommits: fresh.hasCommits)
        let result = Shell.run("/usr/bin/env", arguments, in: project.url)
        guard result.status == 0 else {
            let after = project.inspected()
            let made = after.isPublished ? nil : gitHubRepository(named: name)
            return .failure(ProjectError(message: publishFailure(explain(result, tool: "gh"), remoteAdded: after.isPublished,
                                                                 madeAt: made, branch: after.branch),
                                         setup: githubSetup(from: result)))
        }
        return .success(project.url)
    }

    /// Your repositories on GitHub, through the GitHub CLI's sign-in.
    nonisolated static func remoteRepositories() -> Result<[RemoteRepository], ProjectError> {
        let result = Shell.run("/usr/bin/env", ["gh", "repo", "list", "--limit", "300", "--json", "nameWithOwner,isPrivate"],
                               mergingErrors: false, timeout: ghTimeout)
        guard result.status == 0 else { return .failure(ProjectError(message: explain(result, tool: "gh"), setup: githubSetup(from: result))) }
        return .success((try? JSONDecoder().decode([RemoteRepository].self, from: Data(result.output.utf8))) ?? [])
    }

    nonisolated static func isMissingTool(_ result: Shell.Result) -> Bool {
        result.status == 127 || result.output.contains("No such file or directory") && result.output.contains("env:")
    }

    /// Whether a failed gh command means the CLI isn't installed or isn't signed in.
    nonisolated static func githubSetup(from result: Shell.Result) -> GitHubSetup? {
        if isMissingTool(result) { return .notInstalled }
        let text = result.output.lowercased()
        return text.contains("gh auth login") || text.contains("not logged in") ? .signedOut : nil
    }

    /// What a failed git or gh command said, and what to do next when that's clear from it.
    nonisolated static func explain(_ result: Shell.Result, tool: String) -> String {
        if isMissingTool(result) {
            return tool == "gh"
                ? "The GitHub CLI isn't installed. Install it with Homebrew (brew install gh), then run: gh auth login"
                : "git isn't installed. Install it with Homebrew: brew install git"
        }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = text.isEmpty ? "\(tool) stopped without saying why." : text
        guard let step = nextStep(after: text, status: result.status) else { return said }
        return said + "\n\n" + step
    }

    /// The way out of the failures git and gh commonly report, or nil for anything else.
    nonisolated static func nextStep(after output: String, status: Int32) -> String? {
        let text = output.lowercased()
        if text.contains("gh auth login") || text.contains("not logged in") || text.contains("bad credentials")
            || text.contains("authentication failed") {
            return "The GitHub CLI isn't signed in, or its sign-in has expired. Run gh auth login in a terminal, then try again."
        }
        if status == 124 || text.contains("could not resolve host") || text.contains("error connecting to")
            || text.contains("network is unreachable") || text.contains("timed out") {
            return "GitHub couldn't be reached. Check the internet connection, then try again."
        }
        if text.contains("name already exists") {
            return "You already have a repository with this name on GitHub. Choose another name, or rename that one on GitHub first."
        }
        if text.contains("could not resolve to a repository") || text.contains("repository not found") {
            return "Check the owner and the name. A private repository shows only to an account that can see it: gh auth status says which account the GitHub CLI is using."
        }
        if text.contains("permission denied (publickey)") {
            return "Git couldn't sign in to GitHub over SSH. Use the repository's HTTPS address instead, or add an SSH key to your GitHub account."
        }
        return nil
    }
}
