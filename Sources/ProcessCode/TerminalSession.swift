import AppKit
import Combine
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// The terminal view, with the app's colours and a paste that understands images and files.
final class LeanTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = Theme.backgroundNS.usingColorSpace(.sRGB) ?? .black
            nativeForegroundColor = Theme.textNS.usingColorSpace(.sRGB) ?? .white
            caretColor = Theme.accentNS.usingColorSpace(.sRGB) ?? .white
            selectedTextBackgroundColor = Theme.selectionNS.usingColorSpace(.sRGB) ?? .selectedTextBackgroundColor
        }
        installColors(Theme.ansiColors(dark: dark).map { hex in
            SwiftTerm.Color(red: UInt16((hex >> 16) & 0xff) * 257, green: UInt16((hex >> 8) & 0xff) * 257, blue: UInt16(hex & 0xff) * 257)
        })
        font = Settings.shared.codeFont
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// ⌘V. Text pastes as text. Copied files paste as their paths. A copied image has no text
    /// to paste, so the agent is sent Control-V, which is how Claude Code (and Codex and Gemini)
    /// are told to take an image from the clipboard.
    override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            insert(files: files)
        } else if pasteboard.string(forType: .string) == nil,
                  pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier]) {
            send(data: [0x16][...])
        } else {
            super.paste(sender)
        }
    }

    private func insert(files: [URL]) {
        send(txt: files.map { LeanTerminalView.shellEscaped($0.path) }.joined(separator: " ") + " ")
    }

    static func shellEscaped(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+:@%,="))
        if path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Files dropped on the terminal are typed as paths.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let files = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !files.isEmpty else { return false }
        insert(files: files)
        window?.makeFirstResponder(self)
        return true
    }

    /// Shift-Return starts a new line in an agent's prompt instead of sending it. Programs that
    /// turn on the enhanced keyboard protocol get the real key; the rest get Escape-Return, which
    /// they read as the same thing.
    static func installShiftReturn() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 36,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift,
                  let terminal = event.window?.firstResponder as? LeanTerminalView,
                  terminal.keyboardEnhancementFlags.isEmpty else { return event }
            terminal.send(txt: "\u{1b}\r")
            return nil
        }
    }
}

/// One terminal tab: a shell, optionally started with an agent running in it. The view and its
/// process live here, outside SwiftUI, so nothing the interface does can end a session.
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let view = LeanTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let agent: Agent?
    @Published var title: String
    var onExit: (() -> Void)?
    private var observers: Set<AnyCancellable> = []

    nonisolated static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// The environment for a shell: this app's, minus what belongs to whatever started the app,
    /// plus what a terminal is expected to set.
    nonisolated static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment, shell: String) -> [String] {
        var env = base.filter { key, _ in
            !key.hasPrefix("CLAUDE") && !key.hasPrefix("VSCODE") && !key.hasPrefix("TERM_PROGRAM") && key != "TERM_SESSION_ID"
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ProcessCode"
        env["SHELL"] = shell
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// The arguments that start the shell: a login shell, so the PATH is the one Terminal has
    /// (nvm, Homebrew), and with an agent, the agent first and the shell once it exits.
    nonisolated static func arguments(shell: String, agent: Agent?) -> [String] {
        guard let agent else { return ["-l"] }
        return ["-l", "-i", "-c", "\(agent.command); exec \(LeanTerminalView.shellEscaped(shell)) -l"]
    }

    init(directory: URL, agent: Agent?) {
        self.agent = agent
        let shell = TerminalSession.userShell
        title = agent?.name ?? (shell as NSString).lastPathComponent
        super.init()
        view.processDelegate = self
        view.startProcess(executable: shell, args: TerminalSession.arguments(shell: shell, agent: agent),
                          environment: TerminalSession.environment(shell: shell), currentDirectory: directory.path)
        Settings.shared.$fontName.merge(with: Settings.shared.$fontSize.map { _ in "" }).dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.view.font = Settings.shared.codeFont }
            .store(in: &observers)
    }

    /// True while something other than the shell's prompt is running (an agent, a server, a build).
    var isBusy: Bool {
        guard let process = view.process, process.running else { return false }
        let foreground = tcgetpgrp(process.childfd)
        return foreground > 0 && foreground != process.shellPid
    }

    func terminate() {
        onExit = nil
        view.terminate()
    }

    func focus() { view.window?.makeFirstResponder(view) }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { self.title = trimmed }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in self?.onExit?() }
    }
}

/// Shows the view of whichever terminal session is active, and gives it the keyboard.
struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    /// Changes when the terminal should take focus again.
    let focusToken: Int

    final class Coordinator { var focusToken = -1 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FillingHostView { FillingHostView() }

    func updateNSView(_ host: FillingHostView, context: Context) {
        let view = session.view
        let changed = host.show(view)
        if changed || context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
}
