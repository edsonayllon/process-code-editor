import AppKit
import SwiftTerm
import SwiftUI

@main
@MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

/// One window on one folder.
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let workspace: Workspace
    var onClose: ((WorkspaceWindowController) -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = workspace.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty toolbar makes the title bar as tall as the app's own bars, which centres the
        // window's buttons in them.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.backgroundColor = Theme.backgroundNS
        window.minSize = NSSize(width: 720, height: 420)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.representedURL = workspace.root
        window.contentView = NSHostingView(rootView: WorkspaceView(workspace: workspace))
        window.center()
        if Workspace.remembersState { window.setFrameAutosaveName("workspace." + workspace.root.path) }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Asks about unsaved files and running terminals before the window goes.
    func confirmClose() -> Bool {
        for document in workspace.documents where document.isDirty {
            workspace.activate(document)
            if !workspace.close(document) { return false }
        }
        let busy = workspace.busyTerminalCount
        if busy > 0 {
            let alert = NSAlert()
            alert.messageText = "Close “\(workspace.name)”?"
            alert.informativeText = busy == 1 ? "A terminal still has something running. Closing the window will end it."
                : "\(busy) terminals still have something running. Closing the window will end them."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return false }
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }

    // In full screen a toolbar stays on screen as a band of its own over the top of the content,
    // which hid the app's bars. This one is empty and only sizes the title bar, so it goes while
    // the window is full screen, and the title bar then slides down over the content on demand.
    func windowWillEnterFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = false
        workspace.isFullScreen = true
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        workspace.isFullScreen = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = true
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        window.toolbar?.isVisible = true
        workspace.isFullScreen = false
    }

    func windowWillClose(_ notification: Notification) {
        workspace.close()
        onClose?(self)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controllers: [WorkspaceWindowController] = []
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let defaults = UserDefaults.standard
    private var launchOptions = LaunchOptions()
    private var terminating = false

    private var workspace: Workspace? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        // Only the window in front: with Settings or the welcome window in front, ⌘W and ⌘S do nothing here.
        return (window?.windowController as? WorkspaceWindowController)?.workspace
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchOptions = LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        // A window set up for a picture leaves no trace in what the app remembers.
        Workspace.remembersState = launchOptions.snapshot == nil
        Settings.shared.applyAppearance()
        if let appearance = launchOptions.appearance {
            NSApp.appearance = appearance == .system ? nil : NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        }
        NSApp.mainMenu = buildMenu()
        LeanTerminalView.installShiftReturn()

        for folder in launchOptions.folders { open(folder) }
        if controllers.isEmpty {
            for path in defaults.stringArray(forKey: "openFolders") ?? [] where FileManager.default.fileExists(atPath: path) {
                open(URL(fileURLWithPath: path))
            }
        }
        if controllers.isEmpty { showWelcome() }
        NSApp.activate(ignoringOtherApps: true)
        launchOptions.run(with: controllers.first)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWelcome() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in controllers where !controller.confirmClose() { return .terminateCancel }
        terminating = true
        if Workspace.remembersState { defaults.set(controllers.map(\.workspace.root.path), forKey: "openFolders") }
        controllers.forEach { $0.workspace.close() }
        return .terminateNow
    }

    // MARK: Windows

    /// Opens a folder in its own window, or a file in its folder's window.
    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        let folder = (isDirectory.boolValue ? url : url.deletingLastPathComponent()).standardizedFileURL
        let controller: WorkspaceWindowController
        if let existing = controllers.first(where: { $0.workspace.root == folder })
            ?? (isDirectory.boolValue ? nil : controllers.first { url.standardizedFileURL.path.hasPrefix($0.workspace.root.path + "/") }) {
            controller = existing
        } else {
            controller = WorkspaceWindowController(workspace: Workspace(root: folder, launchAgent: Settings.shared.startAgentOnOpen && !launchOptions.plainShell))
            controller.onClose = { [weak self] closed in
                guard let self, !self.terminating else { return }
                self.controllers.removeAll { $0 === closed }
                if self.controllers.isEmpty { self.showWelcome() }
            }
            controllers.append(controller)
        }
        noteRecent(folder)
        welcomeWindow?.close()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if !isDirectory.boolValue { controller.workspace.open(url) }
    }

    private var recents: [URL] {
        (defaults.stringArray(forKey: "recentFolders") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func noteRecent(_ folder: URL) {
        guard Workspace.remembersState else { return }
        var paths = defaults.stringArray(forKey: "recentFolders") ?? []
        paths.removeAll { $0 == folder.path }
        paths.insert(folder.path, at: 0)
        defaults.set(Array(paths.prefix(12)), forKey: "recentFolders")
        ProjectStore.shared.noteOpened(folder)
    }

    /// The window a new window is: the projects on this Mac, to pick one from.
    private func showWelcome() {
        if welcomeWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Projects"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = Theme.backgroundNS
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 560, height: 360)
            window.contentView = NSHostingView(rootView: ProjectsView(
                isOpen: { [weak self] path in self?.controllers.contains { $0.workspace.root.path == path } ?? false },
                open: { [weak self] in self?.open($0) },
                chooseFolder: { [weak self] in self?.openFolder(nil) }))
            window.setContentSize(NSSize(width: 680, height: 560))
            window.center()
            if Workspace.remembersState { window.setFrameAutosaveName("projects") }
            welcomeWindow = window
        }
        ProjectStore.shared.search = ""
        ProjectStore.shared.refresh()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func newWindow(_ sender: Any?) { showWelcome() }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
            main.addItem(item)
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            return item
        }

        menu("Lean Code") { m in
            add(m, "About Lean Code", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            m.addItem(.separator())
            add(m, "Settings…", #selector(showSettings(_:)), ",")
            m.addItem(.separator())
            add(m, "Hide Lean Code", #selector(NSApplication.hide(_:)), "h")
            add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            add(m, "Quit Lean Code", #selector(NSApplication.terminate(_:)), "q")
        }
        menu("File") { m in
            add(m, "New Window", #selector(newWindow(_:)), "n", [.command, .shift])
            add(m, "New File…", #selector(newFile(_:)), "n")
            add(m, "Open Folder…", #selector(openFolder(_:)), "o")
            let recent = add(m, "Open Recent", nil)
            recent.submenu = NSMenu(title: "Open Recent")
            recent.submenu?.delegate = recentMenuDelegate
            m.addItem(.separator())
            add(m, "Go to File…", #selector(goToFile(_:)), "p")
            m.addItem(.separator())
            add(m, "Save", #selector(save(_:)), "s")
            add(m, "Close Tab", #selector(closeTab(_:)), "w")
            add(m, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        }
        menu("Edit") { m in
            add(m, "Undo", Selector(("undo:")), "z")
            add(m, "Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            add(m, "Cut", #selector(NSText.cut(_:)), "x")
            add(m, "Copy", #selector(NSText.copy(_:)), "c")
            add(m, "Paste", #selector(NSText.paste(_:)), "v")
            add(m, "Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            add(m, "Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: 1)
            add(m, "Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: 2)
            add(m, "Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift], tag: 3)
            m.addItem(.separator())
            add(m, "Toggle Comment", #selector(CodeTextView.toggleComment(_:)), "/")
        }
        menu("View") { m in
            add(m, "Fill Window with Terminal", #selector(toggleTerminalMaximized(_:)), "j")
            add(m, "Show Terminal", #selector(toggleTerminal(_:)), "j", [.command, .shift])
            add(m, "Show Sidebar", #selector(toggleSidebar(_:)), "b")
            add(m, "Show Changes", #selector(toggleChanges(_:)), "g", [.command, .control])
            m.addItem(.separator())
            add(m, "Cycle Source and Preview", #selector(cyclePreview(_:)), "v", [.command, .shift])
            m.addItem(.separator())
            add(m, "Next Tab", #selector(nextTab(_:)), "]", [.command, .shift])
            add(m, "Previous Tab", #selector(previousTab(_:)), "[", [.command, .shift])
            m.addItem(.separator())
            add(m, "Bigger Text", #selector(biggerText(_:)), "+")
            add(m, "Smaller Text", #selector(smallerText(_:)), "-")
            add(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }
        menu("Terminal") { m in
            add(m, "Start Agent", #selector(startAgent(_:)), "a", [.command, .shift])
            add(m, "New Terminal Tab", #selector(newTerminal(_:)), "t")
            add(m, "Close Terminal Tab", #selector(closeTerminal(_:)))
            m.addItem(.separator())
            add(m, "Clear", #selector(clearTerminal(_:)), "k")
        }
        menu("Window") { m in
            add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(m, "Zoom", #selector(NSWindow.performZoom(_:)))
            NSApp.windowsMenu = m
        }
        return main
    }

    private lazy var recentMenuDelegate = RecentMenuDelegate { [weak self] in self?.recents ?? [] } open: { [weak self] in self?.open($0) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let workspace = self.workspace
        switch item.action {
        case #selector(toggleTerminalMaximized(_:)):
            item.title = workspace?.terminalMaximized == true && workspace?.terminalVisible == true ? "Bring Back the Editor" : "Fill Window with Terminal"
            return workspace.map { !$0.documents.isEmpty } ?? false
        case #selector(toggleTerminal(_:)):
            item.title = workspace?.terminalVisible == true ? "Hide Terminal" : "Show Terminal"
            return workspace.map { !$0.documents.isEmpty } ?? false
        case #selector(toggleSidebar(_:)):
            item.title = workspace?.sidebarVisible == true ? "Hide Sidebar" : "Show Sidebar"
            return workspace != nil
        case #selector(toggleChanges(_:)):
            item.title = workspace?.sidebarMode == .changes ? "Show Files" : "Show Changes"
            return workspace != nil
        case #selector(startAgent(_:)):
            item.title = "Start \(Settings.shared.agent?.name ?? "Agent")"
            return workspace != nil
        case #selector(save(_:)):
            return workspace?.activeDocument?.kind == .text
        case #selector(closeTab(_:)):
            return workspace?.activeDocument != nil
        case #selector(cyclePreview(_:)):
            return workspace?.activeDocument?.hasPreview == true
        case #selector(closeTerminal(_:)), #selector(clearTerminal(_:)):
            return workspace?.activeTerminal != nil
        case #selector(newFile(_:)), #selector(goToFile(_:)), #selector(newTerminal(_:)), #selector(nextTab(_:)), #selector(previousTab(_:)):
            return workspace != nil
        default:
            return true
        }
    }

    // MARK: Actions

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 460, height: 420))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        let projects = URL(fileURLWithPath: ProjectStore.shared.rootPath)
        if recents.isEmpty, FileManager.default.fileExists(atPath: projects.path) { panel.directoryURL = projects }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    @objc func newFile(_ sender: Any?) { workspace?.newItem(directory: false) }

    @objc func goToFile(_ sender: Any?) {
        guard let workspace else { return }
        workspace.sidebarVisible = true
        DispatchQueue.main.async { workspace.filterFocusToken += 1 }
    }

    @objc func save(_ sender: Any?) { workspace?.saveActive() }

    @objc func closeTab(_ sender: Any?) {
        if let workspace, let document = workspace.activeDocument { workspace.close(document) }
    }

    @objc func toggleTerminalMaximized(_ sender: Any?) { workspace?.toggleTerminalMaximized() }
    @objc func toggleTerminal(_ sender: Any?) { workspace?.toggleTerminal() }
    @objc func toggleSidebar(_ sender: Any?) { workspace?.sidebarVisible.toggle() }

    @objc func toggleChanges(_ sender: Any?) {
        guard let workspace else { return }
        workspace.sidebarVisible = true
        workspace.sidebarMode = workspace.sidebarMode == .changes ? .files : .changes
    }

    @objc func cyclePreview(_ sender: Any?) {
        guard let document = workspace?.activeDocument, document.hasPreview else { return }
        let modes = Document.Mode.allCases
        document.mode = modes[(modes.firstIndex(of: document.mode)! + 1) % modes.count]
    }

    private var terminalHasFocus: Bool { NSApp.keyWindow?.firstResponder is LeanTerminalView }

    /// ⇧⌘] and ⇧⌘[ move through the tabs of whichever pane has the keyboard.
    @objc func nextTab(_ sender: Any?) { cycleTab(1) }
    @objc func previousTab(_ sender: Any?) { cycleTab(-1) }

    private func cycleTab(_ offset: Int) {
        guard let workspace else { return }
        if terminalHasFocus || !workspace.editorShown { workspace.selectAdjacentTerminal(offset) } else { workspace.selectAdjacentDocument(offset) }
    }

    @objc func biggerText(_ sender: Any?) { Settings.shared.changeFontSize(by: 1) }
    @objc func smallerText(_ sender: Any?) { Settings.shared.changeFontSize(by: -1) }

    @objc func startAgent(_ sender: Any?) { workspace?.startAgent() }
    @objc func newTerminal(_ sender: Any?) { workspace?.newTerminal() }

    @objc func closeTerminal(_ sender: Any?) {
        if let workspace, let session = workspace.activeTerminal { workspace.close(session) }
    }

    /// Clears the screen and its history, then has the program redraw (Control-L).
    @objc func clearTerminal(_ sender: Any?) {
        guard let session = workspace?.activeTerminal else { return }
        session.view.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
        session.view.send(data: [0x0c][...])
    }
}

/// Fills File › Open Recent each time it opens.
final class RecentMenuDelegate: NSObject, NSMenuDelegate {
    private let recents: () -> [URL]
    private let open: (URL) -> Void

    init(recents: @escaping () -> [URL], open: @escaping (URL) -> Void) {
        self.recents = recents
        self.open = open
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in recents() {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
        }
    }

    @objc private func pick(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { open(url) }
    }
}
