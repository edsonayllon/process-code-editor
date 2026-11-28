import SwiftTerm
import SwiftUI
import WebKit
import XCTest
@testable import ProcessCode

/// Whole features run end to end, as the release PR's manual steps try them: real terminals
/// running a stand-in Claude Code, a real WebKit preview, and the questions the app asks,
/// recorded and answered. Every terminal gets a home folder of its own, so the real ~/.claude is
/// never read or written. `swift test --filter IntegrationTests` runs only these.
///
/// The stand-in behaves the way the app expects Claude Code 2.1 to, so these prove the app's side.
/// Whether Claude Code itself still behaves that way is for a try with the real thing.
final class IntegrationTests: AppTestCase {
    private var folder: URL!
    private var home: URL!
    private var savedDrafts: URL!
    private var savedSettings: (agent: String, starts: Bool, continues: Bool)!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("pc-integration-\(UUID().uuidString)")
        home = folder.appendingPathComponent("home")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        savedDrafts = Drafts.folder
        Drafts.folder = folder.appendingPathComponent("drafts")
        TerminalSession.homeOverride = home.path
        let settings = Settings.shared
        savedSettings = (settings.agentID, settings.startAgentOnOpen, settings.continueConversation)
        settings.agentID = "claude"
        settings.startAgentOnOpen = true
        settings.continueConversation = true
    }

    override func tearDown() {
        TerminalSession.homeOverride = nil
        let settings = Settings.shared
        settings.agentID = savedSettings.agent
        settings.startAgentOnOpen = savedSettings.starts
        settings.continueConversation = savedSettings.continues
        Drafts.flush()
        Drafts.folder = savedDrafts
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// Runs the main run loop until `done` holds, failing after `timeout` seconds.
    @MainActor
    private func wait(_ what: String, timeout: TimeInterval = 15, until done: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        if !done() { XCTFail("timed out waiting for \(what)", file: file, line: line) }
    }

    /// Lets the run loop turn for a moment, for output that should change nothing.
    private func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Claude Code's close question

    /// A stand-in for Claude Code 2.1, on the terminals' PATH. Like the real one it keeps a note on
    /// itself in ~/.claude/sessions/<pid>.json, writes its conversation to
    /// ~/.claude/projects/<folder>/<session>.jsonl, says there's nothing to continue and exits 1
    /// when asked to continue with none, and keeps its session through /clear. It waits at its
    /// prompt with no process of its own running. "redraw" prints without writing the conversation,
    /// as a resize does, and "quit" ends it.
    private func installStandInClaude() throws {
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = #"""
        #!/usr/bin/perl
        use strict; use Cwd 'getcwd';
        $| = 1;
        my $home = $ENV{HOME};
        my $cwd = getcwd();
        (my $name = $cwd) =~ s/[^A-Za-z0-9]/-/g;
        my $store = "$home/.claude/projects/$name";
        my $session;
        if (grep { $_ eq '--continue' } @ARGV) {
            my @files = sort { -M $a <=> -M $b } glob("$store/*.jsonl");
            unless (@files) { print "No conversation found to continue\n"; exit 1; }
            ($session) = $files[0] =~ m{([^/]+)\.jsonl$};
        } else {
            $session = sprintf("%08x-%d-%d", int(rand(2**32)), $$, time);
        }
        system("mkdir", "-p", $store, "$home/.claude/sessions");
        my $note = "$home/.claude/sessions/$$.json";
        open(my $n, '>', $note) or die; print $n qq({"pid":$$,"sessionId":"$session","cwd":"$cwd"}); close $n;
        print "> ";
        while (my $line = <STDIN>) {
            $line =~ s/[\r\n]+$//;
            if ($line eq 'quit') { unlink $note; exit 0; }
            if ($line eq 'redraw') { print "\e[2J> "; next; }
            if ($line ne '/clear') { open(my $f, '>>', "$store/$session.jsonl") or die; print $f qq({"text":"$line"}\n); close $f; }
            print "reply\n> ";
        }
        """#
        let claude = bin.appendingPathComponent("claude")
        try script.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        // The terminals' shell starts with this home and the system's PATH; its start-up files put
        // the stand-in first. A login shell's /etc/zprofile (path_helper) moves /usr/local/bin and
        // /opt/homebrew/bin ahead of what .zshenv set, so .zprofile and .zshrc, read after it, say it again.
        let path = "export PATH=\"$HOME/bin:$PATH\"\n"
        for file in [".zshenv", ".zprofile", ".zshrc", ".bash_profile", ".profile"] {
            try path.write(to: home.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    /// The folder's conversation files, by session.
    private func conversations(in project: URL) -> [Agent.Conversation] {
        Agent.presets[0].conversations(in: project, home: home.path)
    }

    /// Types a line into a terminal, as if at the keyboard.
    @MainActor
    private func type(_ line: String, in session: TerminalSession) {
        session.view.send(txt: line + "\r")
    }

    /// Steps 12, 19 and 20: when closing the folder's first Claude Code tab asks, run for real in
    /// terminals, through Workspace.close(_:) and its question.
    @MainActor
    func testTheFirstAgentTabAsksBeforeClosingOnlyWhenTheFolderWouldLoseItsConversation() throws {
        try installStandInClaude()
        let project = folder.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let workspace = Workspace(root: project, launchAgent: true)
        defer { workspace.close() }
        let first = try XCTUnwrap(workspace.terminals.first, "the folder opened with its agent tab")
        XCTAssertTrue(first.startedWithFolder)
        wait("Claude Code to start in the first tab", until: { first.runsClaudeCode })
        let running = TerminalSession.commandLine(of: tcgetpgrp(try XCTUnwrap(first.view.process).childfd)) ?? []
        XCTAssertTrue(running.contains { $0.hasPrefix(home.path) }, "the stand-in, not an installed Claude Code: \(running)")

        // Its own conversation is the folder's latest: closing it loses nothing, so it doesn't ask.
        type("hello", in: first)
        wait("the first conversation", until: { conversations(in: project).count == 1 })
        settle()
        XCTAssertNil(first.running, "idle, and the folder carries its conversation on")
        workspace.close(first)
        XCTAssertEqual(AppTestCase.asked, [], "no question")
        XCTAssertFalse(workspace.terminals.contains { $0 === first }, "and the tab closed")

        // Open the folder's agent tab again, as reopening the folder does: it continues that conversation.
        let again = workspace.newTerminal(agent: Agent.presets[0], resume: true, startedWithFolder: true)
        wait("Claude Code to continue", until: { again.runsClaudeCode })
        type("more", in: again)
        settle()
        XCTAssertEqual(conversations(in: project).count, 1, "it carried the same conversation on")
        XCTAssertNil(again.running)

        // Claude Code typed into a shell tab writes a newer conversation, then quits.
        let shell = workspace.newTerminal()
        wait("the shell tab's prompt", until: { !shell.isBusy && shell.view.process?.running == true })
        settle(1)
        type("claude", in: shell)
        wait("Claude Code in the shell tab", until: { shell.runsClaudeCode })
        XCTAssertNotNil(again.running, "while another Claude Code runs in the window, closing would ask")
        type("in the shell", in: shell)
        wait("the shell's conversation", until: { conversations(in: project).count == 2 })
        type("quit", in: shell)
        wait("the shell tab's Claude Code to quit", until: { !shell.runsClaudeCode })
        workspace.close(shell)
        XCTAssertEqual(AppTestCase.asked, [], "a shell at its prompt closes without asking")

        // The folder would now carry the shell's conversation on, so closing the first tab asks,
        // even after it prints again (a redraw on resize), which hid this before cc7071e.
        type("redraw", in: again)
        settle()
        let asks = try XCTUnwrap(again.running, "the folder's latest conversation is the other one")
        XCTAssertTrue(asks.hasPrefix("Claude Code"), asks)
        workspace.close(again)
        XCTAssertEqual(AppTestCase.asked.count, 1)
        XCTAssertTrue(AppTestCase.asked.first?.hasPrefix("Close “") == true, AppTestCase.asked.first ?? "")
        XCTAssertTrue(workspace.terminals.contains { $0 === again }, "Cancel keeps the tab")

        // /clear keeps its session, and what it writes next makes its own the latest again.
        type("/clear", in: again)
        type("after clearing", in: again)
        wait("its own conversation to be the latest", until: {
            let all = conversations(in: project)
            return all.max { $0.written < $1.written }?.session == Agent.claudeSession(pid: tcgetpgrp(again.view.process!.childfd), home: home.path)
        })
        settle()
        XCTAssertNil(again.running, "after /clear and a prompt, its own conversation is the folder's latest again")

        // A second agent tab means the folder may carry either one on, so the first asks.
        let second = workspace.newTerminal(agent: Agent.presets[0])
        defer { second.terminate() }
        XCTAssertNotNil(again.running, "a later agent tab opened")
    }

    // MARK: Markdown preview

    /// Every WKWebView inside `view`.
    @MainActor
    private func webViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }

    /// Asks the page for a number; nil until it answers.
    @MainActor
    private func evaluate(_ script: String, in webView: WKWebView) -> Double? {
        var answer: Double?, done = false
        webView.evaluateJavaScript(script) { value, _ in
            answer = (value as? NSNumber)?.doubleValue
            done = true
        }
        wait("the page to answer", timeout: 5, until: { done })
        return answer
    }

    /// Step 21: a Markdown file's preview shows its relative picture, and still does after the
    /// folder holding it is renamed (0b243d5, fc869ef), in a real WebKit view.
    @MainActor
    func testAMarkdownPreviewKeepsItsPictureThroughAFolderRename() throws {
        let root = folder.appendingPathComponent("site")
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("img"), withIntermediateDirectories: true)
        // A 1×1 PNG.
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="))
        try png.write(to: docs.appendingPathComponent("img/a.png"))
        let page = docs.appendingPathComponent("read.md")
        try "# Title\n\n![dot](img/a.png)\n".write(to: page, atomically: true, encoding: .utf8)
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        workspace.open(page)
        let document = try XCTUnwrap(workspace.documents.first)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: MarkdownPreview(document: document, openFile: { _ in }))
        let content = try XCTUnwrap(window.contentView)
        wait("the preview's web view", until: { content.layoutSubtreeIfNeeded(); return !webViews(in: content).isEmpty })
        let webView = try XCTUnwrap(webViews(in: content).first)
        let pictureShows = "(() => { const i = document.images[0]; return i && i.complete ? i.naturalWidth : 0 })()"

        wait("the picture to show", until: { (evaluate(pictureShows, in: webView) ?? 0) > 0 })
        XCTAssertEqual(evaluate("document.querySelectorAll('h1').length", in: webView), 1, "the page has the file's text")

        workspace.rename(docs, to: "guide")
        XCTAssertEqual(document.url.deletingLastPathComponent().lastPathComponent, "guide", "the tab followed the file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.path), "the old folder is gone, so the picture can only come from the new one")
        window.contentView?.layoutSubtreeIfNeeded()
        wait("the page to reload from the new folder", until: { webView.url?.absoluteString.contains("/guide") == true })
        wait("the picture to show again", until: { (evaluate(pictureShows, in: webView) ?? 0) > 0 })
        XCTAssertEqual(evaluate("document.querySelectorAll('h1').length", in: webView), 1, "with the file's text, not a blank page")
    }

    // MARK: Questions

    /// Step 15: Close Other Tabs asks about each unsaved tab in turn, and a Cancel stops there,
    /// keeping that tab and every one after it.
    @MainActor
    func testCloseOtherTabsAsksAboutEachUnsavedTabAndStopsAtCancel() throws {
        let root = folder.appendingPathComponent("tabs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = ["a.txt", "b.txt", "c.txt", "d.txt"].map { root.appendingPathComponent($0) }
        for file in files { try "x".write(to: file, atomically: true, encoding: .utf8) }
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        files.forEach { workspace.open($0) }
        for name in ["b.txt", "c.txt"] {
            let document = try XCTUnwrap(workspace.documents.first { $0.name == name })
            try XCTUnwrap(document.editor).textView.insertText("!", replacementRange: NSRange(location: 1, length: 0))
        }
        let a = try XCTUnwrap(workspace.documents.first)

        AppTestCase.answer(["Don't Save", "Cancel"])
        XCTAssertFalse(workspace.closeTabs(keeping: a), "cancelled")
        XCTAssertEqual(AppTestCase.asked.map { $0.components(separatedBy: "\n")[0] },
                       ["Save the changes to “b.txt”?", "Save the changes to “c.txt”?"], "each unsaved tab in turn")
        XCTAssertEqual(workspace.documents.map(\.name), ["a.txt", "c.txt", "d.txt"], "b.txt closed; c.txt and the tab after it stayed")
        XCTAssertEqual(try String(contentsOf: files[1], encoding: .utf8), "x", "Don't Save left b.txt as it was")
        for document in workspace.documents where document.isDirty { document.reload() }
    }

    /// Step 17: a folder rename with an unsaved file in it asks first, and Cancel leaves the
    /// folder, the tabs and the edit as they were.
    @MainActor
    func testACancelledRenameAsksAndChangesNothing() throws {
        let root = folder.appendingPathComponent("rename-cancel")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("src/a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        workspace.open(file)
        let document = try XCTUnwrap(workspace.documents.first)
        try XCTUnwrap(document.editor).textView.insertText("!", replacementRange: NSRange(location: 1, length: 0))

        AppTestCase.answer(["Cancel"])
        workspace.rename(root.appendingPathComponent("src"), to: "lib")
        XCTAssertEqual(AppTestCase.asked.map { $0.components(separatedBy: "\n")[0] }, ["Save the changes to “a.txt”?"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the folder kept its name")
        XCTAssertEqual(document.url, file)
        XCTAssertTrue(document.isDirty, "the edit is still there, unsaved")
        XCTAssertEqual(document.text, "x!")
        document.reload()
    }

    /// Steps 23 and 25: moving a project to the Trash from Projects, with a window open on the
    /// folder above and a file of the project unsaved there: the question names it, and after the
    /// move that window closes the project's tab and keeps its others.
    @MainActor
    func testTrashingAProjectAsksAboutAWindowAboveAndClosesItsTabs() throws {
        let suite = "ProcessCodeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = folder.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(root.path, forKey: "projectsFolder")
        let made = try ProjectStore.create(name: "doomed", readme: true, in: root.path).get()
        let notes = root.appendingPathComponent("notes.txt")
        try "x".write(to: notes, atomically: true, encoding: .utf8)
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        workspace.open(made.appendingPathComponent("README.md"))
        workspace.open(notes)
        try XCTUnwrap(workspace.documents.first?.editor).textView.insertText("typed", replacementRange: NSRange(location: 0, length: 0))

        // Wired as the app wires its windows to the Projects window.
        let store = ProjectStore(defaults: defaults)
        store.openFolders = { [root.path] }
        store.unsavedInWindows = { Workspace.unsavedCount(under: $0, in: [workspace]) }
        store.closeInWindows = { workspace.closeTrashed($0) }
        let project = Project(path: made.path).inspected()
        store.projects = [project]
        // The Projects window's own question.
        let ask = { ProjectsView.confirmTrash($0, store: store) }

        AppTestCase.answer(["Cancel"])
        store.trash(project, confirm: ask, report: { XCTFail($0) })
        XCTAssertEqual(AppTestCase.asked.count, 1)
        XCTAssertTrue(AppTestCase.asked[0].contains("1 file in it has unsaved changes in an open window. Its tab will close"), AppTestCase.asked[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path), "Cancel keeps it")
        XCTAssertEqual(workspace.documents.count, 2)

        AppTestCase.answer(["Move to Trash"])
        store.trash(project, confirm: ask, report: { XCTFail($0) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path), "in the Trash")
        XCTAssertEqual(workspace.documents.map(\.name), ["notes.txt"], "the project's tab closed; the other stayed")
        XCTAssertEqual(Drafts.all(under: made).count, 0, "no draft left to come back")
    }

    /// A file sent to the Trash from one window's sidebar, while another window, on a folder inside
    /// this one, has it open and unsaved: the question names it, and after the move that window
    /// closes its tab too. ⌘Z puts it back in both windows' sidebars, and ⇧⌘Z asks again once the
    /// other window has unsaved text in it.
    @MainActor
    func testTrashingAFileAsksAboutAndClosesItsTabInEveryWindow() throws {
        let outer = folder.appendingPathComponent("outer")
        let inner = outer.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let file = inner.appendingPathComponent("x.txt"), kept = inner.appendingPathComponent("y.txt")
        for url in [file, kept] { try "x".write(to: url, atomically: true, encoding: .utf8) }
        let a = Workspace(root: outer, launchAgent: false), b = Workspace(root: inner, launchAgent: false)
        Workspace.openWorkspaces = { [a, b] }
        defer { Workspace.openWorkspaces = { [] }; a.close(); b.close() }
        b.open(file)
        b.open(kept)
        try XCTUnwrap(b.documents.first?.editor).textView.insertText("!", replacementRange: NSRange(location: 1, length: 0))

        AppTestCase.answer(["Move to Trash"])
        a.trash(outer.appendingPathComponent("inner/../inner/x.txt"))   // spelled another way, as a path can be
        wait("the move", until: { a.trashing.isEmpty })
        XCTAssertEqual(AppTestCase.asked.count, 1, "the unsaved edit in the other window is asked about")
        XCTAssertTrue(AppTestCase.asked.first?.contains("“x.txt” has unsaved changes") == true, AppTestCase.asked.first ?? "")
        XCTAssertFalse(Workspace.exists(file), "moved")
        XCTAssertEqual(b.documents.map(\.name), ["y.txt"], "the other window closed its tab, and kept the rest")
        XCTAssertEqual(Drafts.all(under: inner).count, 0, "no draft left to bring it back")
        XCTAssertFalse(b.rows.contains { $0.url.lastPathComponent == "x.txt" }, "gone from the other window's sidebar")

        a.fileUndo.undo()
        XCTAssertTrue(Workspace.exists(file), "⌘Z put it back")
        XCTAssertTrue(b.rows.contains { $0.url.lastPathComponent == "x.txt" }, "and the other window's sidebar shows it again")

        b.open(file)
        let reopened = try XCTUnwrap(b.documents.first { $0.name == "x.txt" })
        try XCTUnwrap(reopened.editor).textView.insertText("?", replacementRange: NSRange(location: 1, length: 0))
        AppTestCase.answer(["Cancel"])
        a.fileUndo.redo()
        XCTAssertEqual(AppTestCase.asked.count, 1, "⇧⌘Z asks first, now that the other window has unsaved text in it")
        XCTAssertTrue(AppTestCase.asked.first?.contains("“x.txt” has unsaved changes") == true, AppTestCase.asked.first ?? "")
        XCTAssertTrue(Workspace.exists(file), "Cancel leaves it")
        XCTAssertTrue(reopened.isDirty, "with the typing still there")
        reopened.reload()
    }
}
