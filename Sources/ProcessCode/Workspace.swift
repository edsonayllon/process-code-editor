import AppKit
import Combine

/// One visible line of the file tree.
struct TreeRow: Identifiable, Equatable {
    let url: URL
    let relativePath: String
    let isDirectory: Bool
    let depth: Int
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// Which file each pane shows: the main pane, and the one beside it when two files are being
/// compared. A file is in one pane at most, since a text file has a single editor.
struct Panes: Equatable {
    var active: String?
    var side: String?

    /// Shows a file, in the main pane or at the side. `ids` are the open files, in tab order.
    mutating func show(_ id: String, toSide: Bool, among ids: [String]) {
        guard toSide, let active else {
            // A file already at the side stays there: it's on screen.
            if side != id { active = id }
            return
        }
        if active == id {
            // It moves across, and the main pane takes what was at the side, or the tab next to
            // it. With no other file open there's nothing to put beside it.
            guard let other = side ?? Panes.neighbour(of: id, in: ids) else { return }
            self.active = other
        }
        side = id
    }

    /// Takes a file that's being closed out of its pane. `ids` still has it.
    mutating func remove(_ id: String, from ids: [String]) {
        if side == id { side = nil }
        guard active == id else { return }
        // The tab next to it, or with no other, the file at the side, which is then alone.
        active = Panes.neighbour(of: id, in: ids.filter { $0 != side }) ?? side
        if active == side { side = nil }
    }

    /// The tab that takes a closing tab's place: the one after it, or the last.
    private static func neighbour(of id: String, in ids: [String]) -> String? {
        guard let index = ids.firstIndex(of: id) else { return ids.last }
        let rest = ids.filter { $0 != id }
        return rest.isEmpty ? nil : rest[min(index, rest.count - 1)]
    }
}

enum SidebarMode: String {
    case files, changes
}

/// Everything about one open folder: its file tree and git status, the open files, the terminal
/// tabs and how the window is divided.
@MainActor
final class Workspace: ObservableObject {
    let root: URL
    var name: String { root.lastPathComponent }

    // Sidebar
    @Published var rows: [TreeRow] = []
    @Published var git = GitStatus()
    @Published var sidebarMode = SidebarMode.files
    @Published var sidebarVisible = true
    @Published var sidebarWidth: CGFloat = 256
    /// In full screen the window's buttons and the top bar are in a strip above the content.
    @Published var isFullScreen = false
    @Published var selectedPath: String?
    @Published var filter = "" { didSet { updateFilter() } }
    @Published var filterResults: [String] = []
    @Published var filterFocusToken = 0
    private var expanded: Set<String> = []
    private var allFiles: [String]?

    // Files
    @Published var documents: [Document] = []
    @Published var activeDocumentID: String?
    /// The file shown beside the active one, to compare the two.
    @Published var sideDocumentID: String?

    // Terminal
    @Published var terminals: [TerminalSession] = []
    @Published var activeTerminalID: UUID?
    @Published var terminalVisible = true
    /// The terminal fills the window and the editor is put away.
    @Published var terminalMaximized = false
    /// The terminal's share of the height when it's shown with the editor.
    @Published var terminalFraction: CGFloat = 0.4
    @Published var terminalFocusToken = 0

    private var watcher: FileWatcher?
    private var gitRefreshing = false
    private var gitRefreshPending = false
    private var documentObservers: [String: AnyCancellable] = [:]
    private let defaults = UserDefaults.standard

    var activeDocument: Document? { documents.first { $0.id == activeDocumentID } }
    var sideDocument: Document? { documents.first { $0.id == sideDocumentID } }
    /// The file the keyboard is in: the one at the side while its editor is being typed in,
    /// otherwise the active one. Save and Close Tab act on it.
    var focusedDocument: Document? {
        if let side = sideDocument, let view = side.editor?.textView, view.window?.firstResponder === view { return side }
        return activeDocument
    }
    private var panes: Panes {
        get { Panes(active: activeDocumentID, side: sideDocumentID) }
        set {
            if newValue.active != activeDocumentID { activeDocumentID = newValue.active }
            if newValue.side != sideDocumentID { sideDocumentID = newValue.side }
        }
    }
    var activeTerminal: TerminalSession? { terminals.first { $0.id == activeTerminalID } }
    /// The editor is on screen: there's a file open and the terminal isn't covering it.
    var editorShown: Bool { !documents.isEmpty && !(terminalVisible && terminalMaximized) }

    // Focus mode

    /// Focus mode: with the sidebar hidden and the terminal filling the window or the screen,
    /// the bars fade away and the terminal is all there is, until the pointer goes to them. The
    /// spotlight setting turns it off.
    nonisolated static func focusMode(sidebarVisible: Bool, editorShown: Bool, spotlight: Bool = true) -> Bool {
        spotlight && !sidebarVisible && !editorShown
    }

    /// The terminal is alone, where the spotlight button does something.
    var focusModePossible: Bool { Workspace.focusMode(sidebarVisible: sidebarVisible, editorShown: editorShown) }
    var inFocusMode: Bool { focusModePossible && Settings.shared.spotlight }
    /// The pointer is on one of the bars (or was a moment ago), which shows them in focus mode.
    @Published var barsRevealed = false
    /// The bars are faded out. They keep their places, so the terminal never changes size.
    var barsHidden: Bool { inFocusMode && !barsRevealed }
    /// Keeps the bars shown whatever the pointer does, to compare focus mode with them shown.
    var keepBarsShown = false
    private let barAreas = NSHashTable<BarHoverView>.weakObjects()
    private var barCheck: Timer?

    init(root: URL, launchAgent: Bool = Settings.shared.startAgentOnOpen) {
        self.root = root.standardizedFileURL
        let saved = Workspace.remembersState ? defaults.dictionary(forKey: stateKey) ?? [:] : [:]
        expanded = Set(saved["expanded"] as? [String] ?? [])
        if let width = defaults.object(forKey: "sidebarWidth") as? Double { sidebarWidth = width }
        if let fraction = defaults.object(forKey: "terminalFraction") as? Double { terminalFraction = fraction }

        reloadTree()
        refreshGit()
        watcher = FileWatcher(root: self.root) { [weak self] paths in self?.filesChanged(paths) }

        for path in saved["documents"] as? [String] ?? [] {
            let url = self.root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { add(Document(url: url)) }
        }
        activeDocumentID = (saved["active"] as? String).flatMap { path in documents.first { relativePath(of: $0.url) == path }?.id } ?? documents.first?.id
        if let side = (saved["side"] as? String).flatMap({ path in documents.first { relativePath(of: $0.url) == path }?.id }), side != activeDocumentID {
            sideDocumentID = side
        }
        terminalMaximized = documents.isEmpty || (saved["terminalMaximized"] as? Bool ?? false)
        newTerminal(agent: launchAgent ? Settings.shared.agent : nil)
    }

    func close() {
        barCheck?.invalidate()
        saveState()
        watcher?.stop()
        terminals.forEach { $0.terminate() }
        terminals = []
    }

    // MARK: Showing the bars in focus mode

    func registerBarArea(_ area: BarHoverView) {
        barAreas.add(area)
        if area.containsPointer { pointerEnteredBar() }
    }

    /// Shows the bars, and from then on looks every moment for the pointer to have left them.
    /// The look, not the bars' own exit events, is what hides them: an exit can go missing, as
    /// when the strip goes with the pointer in it. Leaving one bar for the other in between two
    /// looks doesn't flicker, and the look runs only in the run loop's default mode, so it waits
    /// while a menu from a bar is open.
    func pointerEnteredBar() {
        if !barsRevealed { barsRevealed = true }
        guard barCheck == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBars() }
        }
        RunLoop.main.add(timer, forMode: .default)
        barCheck = timer
    }

    private func checkBars() {
        if keepBarsShown || barAreas.allObjects.contains(where: \.containsPointer) { return }
        barCheck?.invalidate()
        barCheck = nil
        barsRevealed = false
    }

    // MARK: State kept between launches

    private var stateKey: String { "workspace." + root.path }

    /// False while the app is only being photographed.
    static var remembersState = true

    func saveState() {
        guard Workspace.remembersState else { return }
        defaults.set([
            "expanded": Array(expanded),
            "documents": documents.map { relativePath(of: $0.url) },
            "active": activeDocument.map { relativePath(of: $0.url) } ?? "",
            "side": sideDocument.map { relativePath(of: $0.url) } ?? "",
            "terminalMaximized": terminalMaximized,
        ] as [String: Any], forKey: stateKey)
        defaults.set(Double(sidebarWidth), forKey: "sidebarWidth")
        defaults.set(Double(terminalFraction), forKey: "terminalFraction")
    }

    func relativePath(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
    }

    // MARK: File tree

    nonisolated static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    func isExpanded(_ row: TreeRow) -> Bool { expanded.contains(row.relativePath) }

    func toggle(_ row: TreeRow) {
        if !expanded.insert(row.relativePath).inserted { expanded.remove(row.relativePath) }
        reloadTree()
    }

    /// Rebuilds the visible rows: the root's contents, and those of every expanded folder.
    func reloadTree() {
        var rows: [TreeRow] = []
        func list(_ directory: URL, depth: Int) {
            let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            let entries = contents
                .filter { !Workspace.hiddenNames.contains($0.lastPathComponent) }
                .map { (url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
                .sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                }
            for entry in entries {
                let row = TreeRow(url: entry.url, relativePath: relativePath(of: entry.url), isDirectory: entry.isDirectory, depth: depth)
                rows.append(row)
                if entry.isDirectory, expanded.contains(row.relativePath) { list(entry.url, depth: depth + 1) }
            }
        }
        list(root, depth: 0)
        if rows != self.rows { self.rows = rows }
    }

    /// Expands the folders above a file so its row is visible.
    func reveal(_ url: URL) {
        var path = (relativePath(of: url) as NSString).deletingLastPathComponent
        var changed = false
        while !path.isEmpty {
            if expanded.insert(path).inserted { changed = true }
            path = (path as NSString).deletingLastPathComponent
        }
        if changed { reloadTree() }
        selectedPath = url.path
    }

    private func filesChanged(_ paths: Set<String>) {
        // In the form the open files' paths have ("/tmp", not "/private/tmp").
        let paths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        allFiles = nil
        reloadTree()
        refreshGit()
        documents.forEach { $0.filesChanged(paths) }
    }

    /// Reads git status in the background; at most one at a time, and once more if asked meanwhile.
    func refreshGit() {
        guard !gitRefreshing else { gitRefreshPending = true; return }
        gitRefreshing = true
        let root = self.root
        DispatchQueue.global(qos: .utility).async {
            let status = Git.status(root: root)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                if status != self.git { self.git = status }
                self.gitRefreshing = false
                if self.gitRefreshPending {
                    self.gitRefreshPending = false
                    self.refreshGit()
                }
            }
        }
    }

    // MARK: Go to file

    private func updateFilter() {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { filterResults = []; return }
        if let allFiles {
            filterResults = Workspace.match(query, in: allFiles)
            return
        }
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
            let files = Git.files(root: root) ?? Workspace.enumerate(root)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.allFiles = files
                let query = self.filter.trimmingCharacters(in: .whitespaces).lowercased()
                self.filterResults = query.isEmpty ? [] : Workspace.match(query, in: files)
            }
        }
    }

    /// Every file under a folder that isn't a git repository (bounded, skipping the usual bulk).
    nonisolated static func enumerate(_ root: URL) -> [String] {
        let skipped: Set<String> = ["node_modules", ".build", "build", "dist", "DerivedData", "Pods", "__pycache__", ".venv", "venv"]
        var files: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL, files.count < 30_000 {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if skipped.contains(url.lastPathComponent) { enumerator?.skipDescendants() }
            } else {
                files.append(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        return files
    }

    /// The best matches for a query: its letters in order in the path, a hit in the file's name
    /// first, shorter paths before longer.
    nonisolated static func match(_ query: String, in files: [String], limit: Int = 60) -> [String] {
        let needle = Array(query.lowercased().filter { $0 != " " })
        guard !needle.isEmpty else { return [] }
        var scored: [(path: String, score: Int)] = []
        for path in files {
            let lower = path.lowercased()
            let name = (lower as NSString).lastPathComponent
            var score: Int
            if name.hasPrefix(query) { score = 0 }
            else if name.contains(query) { score = 1000 }
            else if lower.contains(query) { score = 2000 }
            else {
                var index = 0
                for character in lower where character == needle[index] {
                    index += 1
                    if index == needle.count { break }
                }
                guard index == needle.count else { continue }
                score = 3000
            }
            score += path.count
            scored.append((path, score))
        }
        return scored.sorted { $0.score < $1.score }.prefix(limit).map(\.path)
    }

    // MARK: Documents

    private func add(_ document: Document) {
        documents.append(document)
        // A change inside a document (its dirty mark) redraws the tab bar.
        documentObservers[document.id] = document.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// Opens a file in the main pane, or `toSide`, beside the file that's there.
    func open(_ url: URL, line: Int? = nil, toSide: Bool = false) {
        let url = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        let document: Document
        if let existing = documents.first(where: { $0.url == url }) {
            document = existing
        } else {
            document = Document(url: url)
            add(document)
        }
        panes.show(document.id, toSide: toSide, among: documents.map(\.id))
        selectedPath = url.path
        if terminalMaximized { terminalMaximized = false }
        DispatchQueue.main.async {
            if let line { document.editor?.reveal(line: line) }
            document.editor?.focus()
        }
        saveState()
    }

    func activate(_ document: Document) {
        panes.show(document.id, toSide: false, among: documents.map(\.id))
        selectedPath = document.url.path
        if terminalMaximized { terminalMaximized = false }
        DispatchQueue.main.async { document.editor?.focus() }
    }

    /// Closes a tab, asking first if it has unsaved changes. Returns false if the user cancelled.
    @discardableResult
    func close(_ document: Document) -> Bool {
        if document.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save the changes to “\(document.name)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn: if !save(document) { return false }
            case .alertSecondButtonReturn: return false
            default: break
            }
        }
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return true }
        var panes = self.panes
        panes.remove(document.id, from: documents.map(\.id))
        documents.remove(at: index)
        documentObservers[document.id] = nil
        self.panes = panes
        if documents.isEmpty {
            terminalVisible = true
            focusTerminal()
        } else {
            DispatchQueue.main.async { self.activeDocument?.editor?.focus() }
        }
        saveState()
        return true
    }

    @discardableResult
    func save(_ document: Document) -> Bool {
        do {
            try document.save()
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        if document.isTeX { build(document) }
        return true
    }

    func saveActive() {
        if let document = focusedDocument, document.kind == .text { save(document) }
    }

    /// Puts the side pane away. Its file stays open, as a tab.
    func closeSide() {
        sideDocumentID = nil
        DispatchQueue.main.async { self.activeDocument?.editor?.focus() }
        saveState()
    }

    /// Builds a LaTeX file to PDF, off the main thread.
    func build(_ document: Document) {
        guard document.isTeX, document.build != .running else { return }
        document.build = .running
        let root = self.root, url = document.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Latex.build(tex: url, root: root)
            DispatchQueue.main.async {
                if let pdf = result.pdf { document.pdfURL = pdf }
                document.build = result.succeeded ? .succeeded : .failed(result.log)
                document.revision += 1
            }
        }
    }

    /// Any tab with unsaved changes.
    var hasUnsavedChanges: Bool { documents.contains { $0.isDirty } }

    func selectAdjacentDocument(_ offset: Int) {
        // The file at the side keeps its place; the main pane steps through the rest.
        let others = documents.filter { $0.id != sideDocumentID }
        guard let index = others.firstIndex(where: { $0.id == activeDocumentID }), others.count > 1 else { return }
        activate(others[(index + offset + others.count) % others.count])
    }

    // MARK: Terminal

    @discardableResult
    func newTerminal(agent: Agent? = nil) -> TerminalSession {
        let session = TerminalSession(directory: root, agent: agent)
        session.onExit = { [weak self, weak session] in
            if let session { self?.remove(session) }
        }
        terminals.append(session)
        activeTerminalID = session.id
        terminalVisible = true
        focusTerminal()
        return session
    }

    /// Starts the chosen agent in a new tab, or points at Settings if none is set.
    func startAgent() {
        guard let agent = Settings.shared.agent else {
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
            return
        }
        newTerminal(agent: agent)
    }

    /// Closes a terminal tab, asking first if something is still running in it.
    func close(_ session: TerminalSession) {
        if session.isBusy {
            let alert = NSAlert()
            alert.messageText = "Close “\(session.title)”?"
            alert.informativeText = "Something is still running in this terminal. Closing it will end it."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        session.terminate()
        remove(session)
    }

    private func remove(_ session: TerminalSession) {
        guard let index = terminals.firstIndex(where: { $0.id == session.id }) else { return }
        terminals.remove(at: index)
        if activeTerminalID == session.id {
            activeTerminalID = terminals.isEmpty ? nil : terminals[min(index, terminals.count - 1)].id
        }
        if terminals.isEmpty {
            // With nothing to show, the panel steps aside for the editor.
            if !documents.isEmpty { terminalVisible = false; terminalMaximized = false }
        } else {
            focusTerminal()
        }
    }

    func select(_ session: TerminalSession) {
        activeTerminalID = session.id
        focusTerminal()
    }

    func selectAdjacentTerminal(_ offset: Int) {
        guard let index = terminals.firstIndex(where: { $0.id == activeTerminalID }), terminals.count > 1 else { return }
        select(terminals[(index + offset + terminals.count) % terminals.count])
    }

    func focusTerminal() {
        terminalFocusToken += 1
    }

    /// Shows or hides the terminal panel.
    func toggleTerminal() {
        if terminalVisible, !documents.isEmpty {
            terminalVisible = false
            terminalMaximized = false
            DispatchQueue.main.async { self.activeDocument?.editor?.focus() }
        } else {
            terminalVisible = true
            if terminals.isEmpty { newTerminal() }
            focusTerminal()
        }
    }

    /// Gives the terminal the whole window, or brings the editor back.
    func toggleTerminalMaximized() {
        if !terminalVisible {
            terminalVisible = true
            terminalMaximized = true
        } else {
            terminalMaximized.toggle()
        }
        if terminals.isEmpty { newTerminal() }
        if terminalMaximized || documents.isEmpty {
            focusTerminal()
        } else {
            DispatchQueue.main.async { self.activeDocument?.editor?.focus() }
        }
        saveState()
    }

    var busyTerminalCount: Int { terminals.filter(\.isBusy).count }

    // MARK: File operations

    /// The folder a new item goes into: the selected folder, or the selected file's folder.
    private var targetDirectory: URL {
        guard let selectedPath else { return root }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selectedPath, isDirectory: &isDirectory) else { return root }
        return isDirectory.boolValue ? URL(fileURLWithPath: selectedPath) : URL(fileURLWithPath: selectedPath).deletingLastPathComponent()
    }

    func newItem(directory: Bool, in folder: URL? = nil) {
        let parent = folder ?? targetDirectory
        guard let name = Workspace.ask(directory ? "New Folder" : "New File", detail: "In \(parent.lastPathComponent)", value: "", action: "Create") else { return }
        let url = parent.appendingPathComponent(name)
        do {
            if directory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        reveal(url)
        if directory, expanded.insert(relativePath(of: url)).inserted { reloadTree() } else { reloadTree() }
        if !directory { open(url) }
    }

    func rename(_ url: URL) {
        guard let name = Workspace.ask("Rename", detail: url.lastPathComponent, value: url.lastPathComponent, action: "Rename"),
              name != url.lastPathComponent else { return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do { try FileManager.default.moveItem(at: url, to: destination) } catch { NSAlert(error: error).runModal(); return }
        if let document = documents.first(where: { $0.url == url }), close(document) { open(destination) }
        reloadTree()
    }

    func trash(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { NSAlert(error: error).runModal(); return }
        for document in documents where document.url.path == url.path || document.url.path.hasPrefix(url.path + "/") {
            document.isDirty = false
            close(document)
        }
        reloadTree()
    }

    /// Asks for a name in a small dialog; nil if cancelled or left empty.
    static func ask(_ title: String, detail: String, value: String, action: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
