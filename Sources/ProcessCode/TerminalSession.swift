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
    /// The agent tab the folder opened with, the one whose conversation carries on when it opens again.
    let startedWithFolder: Bool
    @Published var title: String
    /// The agent this tab was to start isn't installed, so the tab offers to install it.
    @Published var agentMissing = false
    var onExit: (() -> Void)?
    private var observers: Set<AnyCancellable> = []

    nonisolated static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// A home folder for terminals other than the user's own, set by `--terminal-home` to try the
    /// app as someone who has nothing installed there yet (no agent, no shell setup).
    nonisolated(unsafe) static var homeOverride: String?

    /// The home folder terminals start with.
    nonisolated static var home: String { homeOverride ?? NSHomeDirectory() }

    /// The environment for a shell: this app's, minus what belongs to whatever started the app,
    /// plus what a terminal is expected to set.
    nonisolated static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment, shell: String) -> [String] {
        variables(base, shell: shell).map { "\($0.key)=\($0.value)" }.sorted()
    }

    nonisolated static func variables(_ base: [String: String] = ProcessInfo.processInfo.environment, shell: String) -> [String: String] {
        var env = base.filter { key, _ in
            !key.hasPrefix("CLAUDE") && !key.hasPrefix("VSCODE") && !key.hasPrefix("TERM_PROGRAM") && key != "TERM_SESSION_ID"
        }
        if let homeOverride {
            // As a new user's terminal: the system's PATH, and nothing set up by anyone's shell.
            env["HOME"] = homeOverride
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            env = env.filter { key, _ in key != "ZDOTDIR" && !key.hasPrefix("NVM_") && !key.hasPrefix("HOMEBREW_") }
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ProcessCode"
        env["SHELL"] = shell
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        return env
    }

    /// The arguments that start the shell: a login shell, so the PATH is the one Terminal has
    /// (nvm, Homebrew), and with an agent, the agent first and the shell once it exits. With
    /// `resume`, the agent carries on its last conversation, if it knows how.
    nonisolated static func arguments(shell: String, agent: Agent?, resume: Bool = false) -> [String] {
        guard let agent else { return ["-l"] }
        let command = startCommand(agent: agent, resume: resume, shell: shell)
        return ["-l", "-i", "-c", "\(command); exec \(LeanTerminalView.shellEscaped(shell)) -l"]
    }

    /// The shells whose `$SECONDS`, `[ ]` and `{ }` the fallback below is written in.
    nonisolated static let posixShells: Set<String> = ["zsh", "bash", "sh", "ksh", "dash"]

    /// How soon after starting a failed resume counts as finding nothing to carry on.
    nonisolated static let resumeGrace = 10

    /// What the agent's tab runs. A resume that fails within a few seconds found nothing to carry on
    /// (Claude Code says so and exits 1 at once), so the agent starts fresh instead. One that fails
    /// later was a conversation that ended, and isn't started again.
    nonisolated static func startCommand(agent: Agent, resume: Bool, shell: String, grace: Int = resumeGrace) -> String {
        guard resume, let resumeCommand = agent.resumeCommand else { return agent.command }
        guard posixShells.contains((shell as NSString).lastPathComponent) else { return resumeCommand }
        return "__pc_started=$SECONDS; \(resumeCommand) || { [ $((SECONDS - __pc_started)) -lt \(grace) ] && \(agent.command); }"
    }

    init(directory: URL, agent: Agent?, resume: Bool = false, startedWithFolder: Bool = false) {
        self.agent = agent
        self.startedWithFolder = startedWithFolder
        let shell = TerminalSession.userShell
        title = agent?.name ?? (shell as NSString).lastPathComponent
        super.init()
        view.processDelegate = self
        view.startProcess(executable: shell, args: TerminalSession.arguments(shell: shell, agent: agent, resume: resume),
                          environment: TerminalSession.environment(shell: shell), currentDirectory: directory.path)
        Settings.shared.$fontName.merge(with: Settings.shared.$fontSize.map { _ in "" }).dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.view.font = Settings.shared.codeFont }
            .store(in: &observers)
        // Only the agents it knows how to install: a custom command may not start with a program's name.
        if let agent, agent.installCommand != nil { checkInstalled(agent, shell: shell, directory: directory) }
    }

    /// Looks for the agent the way its terminal will, in a login shell, alongside the terminal
    /// starting rather than before it. A check that can't finish says nothing.
    private func checkInstalled(_ agent: Agent, shell: String, directory: URL) {
        let environment = TerminalSession.variables(shell: shell)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = TerminalSession.isInstalled(agent.program, shell: shell, directory: directory, environment: environment)
            // Only at the shell's prompt: anything running in the tab means the agent did start.
            if found == false { DispatchQueue.main.async { if let self, !self.isBusy { self.agentMissing = true } } }
        }
    }

    /// Whether a login shell finds `program`; nil if the shell couldn't say within 15 seconds.
    nonisolated static func isInstalled(_ program: String, shell: String, directory: URL, environment: [String: String]) -> Bool? {
        let result = Shell.run(shell, ["-l", "-i", "-c", "command -v -- \(LeanTerminalView.shellEscaped(program)) >/dev/null 2>&1"],
                               in: directory, timeout: 15, environment: environment)
        switch result.status {
        case 0: return true
        case 1, 127: return false
        default: return nil
        }
    }

    /// Types the agent's installer into the terminal, at the shell's prompt where the missing agent
    /// left it, so the install runs in sight and the agent starts once it's done.
    func installAgent() {
        guard let command = agent?.installCommand else { return }
        // Typed only at the prompt, never into a program that's running. Until then the offer stays.
        guard !isBusy else {
            NSSound.beep()
            focus()
            return
        }
        agentMissing = false
        view.send(txt: command + "\r")
        focus()
    }

    /// True while something other than the shell's prompt is running (an agent, a server, a build).
    var isBusy: Bool { foregroundGroup != nil }

    /// The process group running in the foreground, or nil at the shell's prompt.
    private var foregroundGroup: pid_t? {
        guard let process = view.process, process.running else { return nil }
        let foreground = tcgetpgrp(process.childfd)
        return foreground > 0 && foreground != process.shellPid ? foreground : nil
    }

    /// What closing the tab would cut short, in a few words, to name it first: "npm run dev", or
    /// "Claude Code (“✳ Fix the login”), running a command" with the title it gave its tab. Nil at
    /// the prompt, and nil for Claude Code waiting for its next prompt in the folder's agent tab when
    /// the folder will carry its conversation on as it opens again, so closing it then loses nothing.
    var running: String? {
        guard let group = foregroundGroup else { return nil }
        let arguments = TerminalSession.commandLine(of: group)
        let name = TerminalSession.summary(arguments: arguments, agent: agent, title: title,
                                           shell: (TerminalSession.userShell as NSString).lastPathComponent)
        guard TerminalSession.isClaudeCode(arguments) else { return name }
        switch ClaudeActivity(children: TerminalSession.children(of: group), group: group) {
        case .waiting:
            let settings = Settings.shared
            return TerminalSession.carriesOn(tabAgent: agent, startedWithFolder: startedWithFolder, folderAgent: settings.agent,
                                             remembers: Workspace.remembersState,
                                             startsAgent: settings.startAgentOnOpen, continues: settings.continueConversation) ? nil : name
        case .unknown: return name
        case .commands(1): return "\(name), running a command"
        case .commands(let count): return "\(name), running \(count) commands"
        case .replying: return "\(name), working on a reply"
        }
    }

    /// Whether a waiting agent in a tab started with `tabAgent` picks its conversation up again when
    /// the folder next opens: only the tab the folder opened with continues, and only with every
    /// setting that brings it back on. A later agent tab, or Claude Code typed into a shell tab, doesn't.
    nonisolated static func carriesOn(tabAgent: Agent?, startedWithFolder: Bool, folderAgent: Agent?, remembers: Bool,
                                      startsAgent: Bool, continues: Bool) -> Bool {
        guard startedWithFolder, let tabAgent, tabAgent.resumeCommand != nil, tabAgent.id == folderAgent?.id else { return false }
        return remembers && startsAgent && continues
    }

    /// One process a program started: its process group and its program's name.
    struct Child: Equatable {
        let group: pid_t
        let program: String
    }

    /// Whether a command line is Claude Code's.
    nonisolated static func isClaudeCode(_ arguments: [String]?) -> Bool {
        arguments.map(describe)?.split(separator: " ").first == "claude"
    }

    /// What Claude Code is doing, read from the processes it started. It runs each shell command
    /// in a process group of its own, background ones included, while its MCP servers stay in its
    /// group; and it keeps the Mac awake with `caffeinate` while it works on a reply, which also
    /// covers thinking and subagents, as they start no process.
    enum ClaudeActivity: Equatable {
        /// At its prompt with nothing running: closing loses nothing.
        case waiting
        /// Its processes couldn't be read, so it might be doing anything.
        case unknown
        /// Shell commands still running, in the foreground or the background.
        case commands(Int)
        /// Working on a reply, with no command running.
        case replying

        init(children: [Child]?, group: pid_t) {
            guard let children else { self = .unknown; return }
            let commands = children.filter { $0.group != group }.count
            if commands > 0 { self = .commands(commands) }
            else if children.contains(where: { $0.program == "caffeinate" }) { self = .replying }
            else { self = .waiting }
        }
    }

    /// The processes `parent` started, or nil if the system won't say.
    nonisolated static func children(of parent: pid_t) -> [Child]? {
        // Asked with no room, it gives a count big enough for every process.
        let room = proc_listchildpids(parent, nil, 0)
        guard room > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(room))
        let count = pids.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
        guard count >= 0 else { return nil }
        return pids.prefix(Int(count)).compactMap { pid in
            let group = getpgid(pid)
            // One that has just ended is no longer anything to warn about.
            guard group > 0 else { return nil }
            let program = commandLine(of: pid).map(describe)?.split(separator: " ").first.map(String.init) ?? ""
            return Child(group: group, program: program)
        }
    }

    /// The agent goes by its name, anything else by its command, and the tab's title is added when
    /// it says something the name doesn't.
    nonisolated static func summary(arguments: [String]?, agent: Agent?, title: String, shell: String) -> String {
        let command = arguments.map(describe) ?? "a program"
        let program = command.split(separator: " ").first.map(String.init)
        let isAgent = agent.map { $0.command.split(separator: " ").first.map { ($0 as NSString).lastPathComponent } == program } ?? false
        let name = isAgent ? agent?.name ?? command : command
        // Titles often lead with a mark of their own ("✳ Claude Code"), which says nothing.
        let plain = String(title.drop { !$0.isLetter && !$0.isNumber })
        guard !plain.isEmpty, plain != agent?.name, plain != shell, !name.hasPrefix(plain), !command.hasPrefix(plain) else { return name }
        return "\(name) (“\(title)”)"
    }

    /// The arguments a process was started with, as the system keeps them.
    nonisolated static func commandLine(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // The argument count, the path it was run from, padding, then the arguments, each ending in a zero.
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.isEmpty ? nil : arguments
    }

    /// A command line made short enough to read at a glance: programs go by their names, not their
    /// paths, and a script run by its interpreter goes by the script ("node …/bin/npm run dev" is
    /// "npm run dev").
    nonisolated static func describe(_ arguments: [String]) -> String {
        var words = arguments.map { $0.hasPrefix("/") ? ($0 as NSString).lastPathComponent : $0 }
        let interpreters: Set = ["node", "python", "python3", "ruby", "bun", "deno", "perl"]
        if words.count > 1, interpreters.contains(words[0]), arguments[1].contains("/") { words.removeFirst() }
        let text = words.joined(separator: " ")
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
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
