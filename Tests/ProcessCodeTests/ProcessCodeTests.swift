import XCTest
@testable import ProcessCode

/// What every test class here builds on. A question or file panel can't be answered in a test, and
/// would stay on screen and hang the run, so each one gets an answer that changes nothing: Don't
/// Save or Cancel where the question has one, and Cancel for a panel. A test that needs another
/// answer sets `NSAlert.answering` itself; the next test starts over.
class AppTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        NSAlert.answering = { AppTestCase.press(["Don't Save", "Cancel"], in: $0) }
        NSSavePanel.choosing = { _ in .cancel }
    }

    /// The first of `titles` that the question has as a button, or else its first button.
    @MainActor static func press(_ titles: [String], in alert: NSAlert) -> NSApplication.ModalResponse {
        let buttons = alert.buttons.map(\.title)
        let index = titles.lazy.compactMap { buttons.firstIndex(of: $0) }.first ?? 0
        return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }
}

final class GitStatusTests: AppTestCase {
    func testParsesBranchAndStates() {
        let output = ["## main...origin/main [ahead 2, behind 1]", " M Sources/App.swift", "?? notes/", "A  new.txt",
                      "R  renamed.swift", "old.swift", " D gone.md", "UU both.txt", "!! build/"].joined(separator: "\0") + "\0"
        let status = GitStatus.parse(output)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.entries["Sources/App.swift"], .modified)
        XCTAssertEqual(status.entries["notes/"], .untracked)
        XCTAssertEqual(status.entries["new.txt"], .added)
        XCTAssertEqual(status.entries["renamed.swift"], .renamed)
        XCTAssertNil(status.entries["old.swift"], "the old name of a rename is not an entry")
        XCTAssertEqual(status.entries["gone.md"], .deleted)
        XCTAssertEqual(status.entries["both.txt"], .conflicted)
        XCTAssertEqual(status.changeCount, 6, "ignored files are not changes")
    }

    func testStatesOfFoldersAndFilesInsideThem() {
        let status = GitStatus.parse(["## main", " M a/b/c.swift", "?? notes/", "!! build/"].joined(separator: "\0") + "\0")
        XCTAssertEqual(status.state(of: "a", isDirectory: true), .modified)
        XCTAssertEqual(status.state(of: "a/b", isDirectory: true), .modified)
        XCTAssertEqual(status.state(of: "a/b/c.swift", isDirectory: false), .modified)
        XCTAssertNil(status.state(of: "a/b/other.swift", isDirectory: false))
        XCTAssertEqual(status.state(of: "notes", isDirectory: true), .untracked)
        XCTAssertEqual(status.state(of: "notes/deep/todo.md", isDirectory: false), .untracked)
        XCTAssertEqual(status.state(of: "build/out.o", isDirectory: false), .ignored)
    }

    func testBranchBeforeFirstCommitAndDetached() {
        XCTAssertEqual(GitStatus.parse("## No commits yet on main\0").branch, "main")
        XCTAssertEqual(GitStatus.parse("## HEAD (no branch)\0").branch, "detached")
    }

    func testRelativeToSubfolder() {
        let status = GitStatus.parse(["## main", " M app/src/a.swift", " M other/b.swift"].joined(separator: "\0") + "\0").relative(to: "app/")
        XCTAssertEqual(status.entries, ["src/a.swift": .modified])
        XCTAssertTrue(status.changedDirectories.contains("src"))
    }
}

final class LexerTests: AppTestCase {
    private func tokens(_ text: String, _ language: Language) -> [(String, Token)] {
        Lexer.tokenize(text, language: language).map { ((text as NSString).substring(with: NSRange(location: $0.location, length: $0.length)), $0.token) }
    }

    private func token(_ word: String, in text: String, _ language: Language) -> Token? {
        tokens(text, language).first { $0.0 == word }?.1
    }

    func testSwift() {
        let text = "let name: String = \"hi // not a comment\" // real\nfunc greet() { return 42 }"
        XCTAssertEqual(token("let", in: text, .swift), .keyword)
        XCTAssertEqual(token("String", in: text, .swift), .type)
        XCTAssertEqual(token("\"hi // not a comment\"", in: text, .swift), .string)
        XCTAssertEqual(token("// real", in: text, .swift), .comment)
        XCTAssertEqual(token("greet", in: text, .swift), .function)
        XCTAssertEqual(token("42", in: text, .swift), .number)
    }

    func testPythonTripleQuotesSpanLines() {
        let text = "x = \"\"\"one\ntwo\"\"\"\n# note\ndef f(): pass"
        XCTAssertEqual(token("\"\"\"one\ntwo\"\"\"", in: text, .python), .string)
        XCTAssertEqual(token("# note", in: text, .python), .comment)
        XCTAssertEqual(token("def", in: text, .python), .keyword)
    }

    func testJSONKeysAndValues() {
        let text = "{ \"name\": \"lean\", \"count\": 3, \"ok\": true }"
        XCTAssertEqual(token("\"name\"", in: text, .json), .attribute)
        XCTAssertEqual(token("\"lean\"", in: text, .json), .string)
        XCTAssertEqual(token("3", in: text, .json), .number)
        XCTAssertEqual(token("true", in: text, .json), .constant)
    }

    func testRustLifetimeIsNotAString() {
        let text = "fn f<'a>(x: &'a str) -> char { 'x' }"
        XCTAssertEqual(tokens(text, .rust).filter { $0.1 == .string }.map(\.0), ["'x'"])
    }

    func testMarkdown() {
        let text = "# Title\n\nSome `code` and **bold** and [a link](http://x.y).\n\n```sh\nls # not a heading\n```\n- item"
        XCTAssertEqual(token("# Title", in: text, .markdown), .heading)
        XCTAssertEqual(token("`code`", in: text, .markdown), .constant)
        XCTAssertEqual(token("**bold**", in: text, .markdown), .emphasis)
        XCTAssertEqual(token("[a link]", in: text, .markdown), .link)
        XCTAssertEqual(token("ls # not a heading", in: text, .markdown), .string)
        XCTAssertEqual(token("-", in: text, .markdown), .keyword)
    }

    func testTeX() {
        let text = "\\begin{document} % comment\n\\textbf{Hi} $x^2$ 50\\% off"
        XCTAssertEqual(token("\\begin", in: text, .tex), .keyword)
        XCTAssertEqual(token("document", in: text, .tex), .type)
        XCTAssertEqual(token("% comment", in: text, .tex), .comment)
        XCTAssertEqual(token("$x^2$", in: text, .tex), .string)
        XCTAssertEqual(tokens(text, .tex).filter { $0.1 == .comment }.count, 1, "an escaped percent sign is not a comment")
    }

    func testHTML() {
        let text = "<!-- c --><a href=\"x\">t</a>"
        XCTAssertEqual(token("<!-- c -->", in: text, .markup), .comment)
        XCTAssertEqual(token("<a", in: text, .markup), .tag)
        XCTAssertEqual(token("href", in: text, .markup), .attribute)
        XCTAssertEqual(token("\"x\"", in: text, .markup), .string)
    }

    func testSpansAreOrderedAndInsideTheText() {
        let samples: [(String, Language)] = [
            ("let s = \"unterminated", .swift), ("/* never closed", .javascript), ("```\nopen fence", .markdown),
            ("$ math without end\n\n\\", .tex), ("<a href='x", .markup), ("'", .rust), ("x = '''", .python), ("", .swift),
        ]
        for (text, language) in samples {
            var position = 0
            for span in Lexer.tokenize(text, language: language) {
                XCTAssertGreaterThanOrEqual(span.location, position, "\(language.name): \(text)")
                XCTAssertGreaterThan(span.length, 0)
                position = span.location + span.length
            }
            XCTAssertLessThanOrEqual(position, (text as NSString).length, "\(language.name): \(text)")
        }
    }

    func testLanguageForFile() {
        XCTAssertEqual(Language.forFile(URL(fileURLWithPath: "/a/App.swift")).name, "Swift")
        XCTAssertEqual(Language.forFile(URL(fileURLWithPath: "/a/resume.tex")).name, "LaTeX")
        XCTAssertEqual(Language.forFile(URL(fileURLWithPath: "/a/README.md")).name, "Markdown")
        XCTAssertEqual(Language.forFile(URL(fileURLWithPath: "/a/Makefile")).name, "Shell")
        XCTAssertEqual(Language.forFile(URL(fileURLWithPath: "/a/unknown.xyz")).name, "Plain Text")
    }
}

final class MarkdownTests: AppTestCase {
    func testRendersGitHubFlavour() {
        let html = Markdown.html("# Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n~~gone~~ <img src=\"logo.png\">")
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("type=\"checkbox\""))
        XCTAssertTrue(html.contains("<del>gone</del>"))
        XCTAssertTrue(html.contains("<img src=\"logo.png\">"), "raw HTML is kept, as on GitHub")
    }

    func testColoursFencedCode() {
        let html = Markdown.html("```swift\nlet x = \"<a>\"\n```")
        XCTAssertTrue(html.contains("<span class=\"t-keyword\">let</span>"))
        XCTAssertTrue(html.contains("<span class=\"t-string\">&quot;&lt;a&gt;&quot;</span>"), html)
    }
}

final class LatexTests: AppTestCase {
    func testReadsLatexWorkshopRecipe() throws {
        let settings = """
        {
          // comments and a trailing comma, as VS Code allows
          "latex-workshop.latex.recipes": [{ "name": "build.sh", "tools": ["build-sh"] }],
          "latex-workshop.latex.tools": [
            { "name": "build-sh", "command": "bash", "args": ["-c", "cd \\"%WORKSPACE_FOLDER%\\" && ./build.sh \\"$(basename \\"%DIR%\\")\\""] },
          ],
          "latex-workshop.latex.recipe.default": "first",
        }
        """
        let commands = try XCTUnwrap(Latex.recipe(inSettings: Data(settings.utf8), tex: URL(fileURLWithPath: "/r/bases/pm/resume.tex"),
                                                  root: URL(fileURLWithPath: "/r")))
        XCTAssertEqual(commands, [Latex.Command(executable: "bash", arguments: ["-c", "cd \"/r\" && ./build.sh \"$(basename \"/r/bases/pm\")\""])])
    }

    func testNoRecipeMeansLatexmk() {
        XCTAssertNil(Latex.recipe(inSettings: Data("{ \"editor.fontSize\": 12 }".utf8), tex: URL(fileURLWithPath: "/r/a.tex"), root: URL(fileURLWithPath: "/r")))
        XCTAssertEqual(Latex.engineFlag(for: "\\usepackage{fontspec}"), "-xelatex")
        XCTAssertEqual(Latex.engineFlag(for: "% !TEX program = lualatex"), "-lualatex")
        XCTAssertEqual(Latex.engineFlag(for: "\\documentclass{article}"), "-pdf")
    }

    func testFindsThePDFThatBelongsToTheSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["cover-letter.pdf", "jane-resume.pdf"] { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        XCTAssertEqual(Latex.existingPDF(for: folder.appendingPathComponent("resume.tex"))?.lastPathComponent, "jane-resume.pdf")
        XCTAssertEqual(Latex.existingPDF(for: folder.appendingPathComponent("cover-letter.tex"))?.lastPathComponent, "cover-letter.pdf")
    }

    func testSummaryPrefersErrorLines() {
        let log = "This is XeTeX\n./resume.tex:12: Undefined control sequence.\nl.12 \\oops\n\nmore\nOutput written"
        XCTAssertTrue(Latex.summary(of: log).hasPrefix("./resume.tex:12: Undefined control sequence."))
    }
}

final class TerminalTests: AppTestCase {
    func testShellEscaping() {
        XCTAssertEqual(LeanTerminalView.shellEscaped("/a/b-c_d.png"), "/a/b-c_d.png")
        XCTAssertEqual(LeanTerminalView.shellEscaped("/a/Screen Shot.png"), "'/a/Screen Shot.png'")
        XCTAssertEqual(LeanTerminalView.shellEscaped("/a/it's.png"), "'/a/it'\\''s.png'")
    }

    /// A terminal with a test home starts as a new user's would, and a missing agent is found missing there.
    func testAMissingAgentIsFoundTheWayItsTerminalLooks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ProcessCodeTests-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            TerminalSession.homeOverride = nil
            try? FileManager.default.removeItem(at: home)
        }
        TerminalSession.homeOverride = home.path
        let env = TerminalSession.variables(["HOME": "/Users/x", "PATH": "/Users/x/.nvm/bin:/usr/bin", "ZDOTDIR": "/Users/x/.zsh",
                                             "NVM_DIR": "/Users/x/.nvm"], shell: "/bin/zsh")
        XCTAssertEqual(env["HOME"], home.path)
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin", "nothing found through someone's own PATH")
        XCTAssertNil(env["ZDOTDIR"])
        XCTAssertNil(env["NVM_DIR"])

        XCTAssertEqual(TerminalSession.isInstalled("ls", shell: "/bin/zsh", directory: home, environment: env), true)
        XCTAssertEqual(TerminalSession.isInstalled("no-such-agent-\(UUID().uuidString.prefix(8))", shell: "/bin/zsh",
                                                   directory: home, environment: env), false)
    }

    func testEveryPresetHasAnInstallCommandTheShellCanRead() {
        for agent in Agent.presets {
            guard let command = agent.installCommand else { return XCTFail("\(agent.name) has no install command") }
            XCTAssertTrue(command.hasSuffix(agent.command), "\(agent.name) starts once it's installed")
            XCTAssertEqual(Shell.run("/bin/zsh", ["-n", "-c", command]).status, 0, command)
        }
        XCTAssertEqual(Agent(id: "custom", name: "Mine", command: "aider --model x").program, "aider")
    }

    func testAgentStartsInALoginShellAndLeavesAShellBehind() {
        XCTAssertEqual(TerminalSession.arguments(shell: "/bin/zsh", agent: nil), ["-l"])
        XCTAssertEqual(TerminalSession.arguments(shell: "/bin/zsh", agent: Agent.presets[0]), ["-l", "-i", "-c", "claude; exec /bin/zsh -l"])
    }

    func testRunningProgramsAreNamedShortly() {
        XCTAssertEqual(TerminalSession.describe(["/opt/homebrew/bin/node", "/opt/homebrew/bin/npm", "run", "dev"]), "npm run dev")
        XCTAssertEqual(TerminalSession.describe(["python3", "server.py", "--port", "8000"]), "python3 server.py --port 8000")
        XCTAssertEqual(TerminalSession.describe(["/Users/x/.local/bin/claude", "--continue"]), "claude --continue")
        XCTAssertEqual(TerminalSession.describe(["cargo", "build", String(repeating: "x", count: 80)]).count, 60)
        let claude = Agent.presets[0]
        XCTAssertEqual(TerminalSession.summary(arguments: ["claude"], agent: claude, title: "✳ Claude Code", shell: "zsh"), "Claude Code")
        XCTAssertEqual(TerminalSession.summary(arguments: ["claude", "--continue"], agent: claude, title: "✳ Fix the login", shell: "zsh"),
                       "Claude Code (“✳ Fix the login”)")
        XCTAssertEqual(TerminalSession.summary(arguments: ["npm", "run", "dev"], agent: claude, title: "zsh", shell: "zsh"), "npm run dev",
                       "something else run in the agent's tab, once the agent has exited, goes by its command")
        XCTAssertEqual(TerminalSession.summary(arguments: nil, agent: nil, title: "", shell: "zsh"), "a program")
        let me = TerminalSession.commandLine(of: getpid())
        XCTAssertEqual(me?.first.map { ($0 as NSString).lastPathComponent }, (CommandLine.arguments[0] as NSString).lastPathComponent)
        XCTAssertEqual(Workspace.runningWarning(["npm run dev"], closing: "the window"),
                       "This is still running, and closing the window will end it:\n\n• npm run dev")
        XCTAssertTrue(Workspace.runningWarning(["npm run dev", "claude"], closing: "the window").hasPrefix("These are still running"))
    }

    func testClaudeCodeAtItsPromptIsNothingToWarnAbout() {
        XCTAssertTrue(TerminalSession.isClaudeCode(["/Users/x/.local/bin/claude", "--continue"]))
        XCTAssertTrue(TerminalSession.isClaudeCode(["claude"]))
        XCTAssertFalse(TerminalSession.isClaudeCode(["codex"]))
        XCTAssertFalse(TerminalSession.isClaudeCode(["claude-monitor"]))
        XCTAssertFalse(TerminalSession.isClaudeCode(nil))

        typealias Child = TerminalSession.Child
        let mcp = [Child(group: 500, program: "ResolvePython"), Child(group: 500, program: "Python")]
        XCTAssertEqual(TerminalSession.ClaudeActivity(children: [], group: 500), .waiting)
        XCTAssertEqual(TerminalSession.ClaudeActivity(children: mcp, group: 500), .waiting, "MCP servers stay in its group")
        XCTAssertEqual(TerminalSession.ClaudeActivity(children: mcp + [Child(group: 500, program: "caffeinate")], group: 500), .replying)
        XCTAssertEqual(TerminalSession.ClaudeActivity(children: mcp + [Child(group: 501, program: "zsh"), Child(group: 500, program: "caffeinate")],
                                                      group: 500), .commands(1))
        XCTAssertEqual(TerminalSession.ClaudeActivity(children: mcp + [Child(group: 501, program: "zsh"), Child(group: 502, program: "zsh")],
                                                      group: 500), .commands(2), "a background command left running after the reply")
        XCTAssertEqual(TerminalSession.ClaudeActivity(children: nil, group: 500), .unknown)

        let claude = Agent.presets[0], codex = Agent.presets[1]
        XCTAssertTrue(TerminalSession.carriesOn(tabAgent: claude, startedWithFolder: true, folderAgent: claude, remembers: true, startsAgent: true, continues: true))
        XCTAssertFalse(TerminalSession.carriesOn(tabAgent: nil, startedWithFolder: true, folderAgent: claude, remembers: true, startsAgent: true, continues: true),
                       "claude typed into a shell tab")
        XCTAssertFalse(TerminalSession.carriesOn(tabAgent: claude, startedWithFolder: false, folderAgent: claude, remembers: true, startsAgent: true, continues: true),
                       "an agent tab opened later starts fresh, so its conversation isn't the one that carries on")
        XCTAssertFalse(TerminalSession.carriesOn(tabAgent: claude, startedWithFolder: true, folderAgent: codex, remembers: true, startsAgent: true, continues: true),
                       "the folder now starts another agent")
        XCTAssertFalse(TerminalSession.carriesOn(tabAgent: claude, startedWithFolder: true, folderAgent: claude, remembers: true, startsAgent: true, continues: false))
        XCTAssertFalse(TerminalSession.carriesOn(tabAgent: claude, startedWithFolder: true, folderAgent: claude, remembers: true, startsAgent: false, continues: true))
        XCTAssertFalse(TerminalSession.carriesOn(tabAgent: claude, startedWithFolder: true, folderAgent: claude, remembers: false, startsAgent: true, continues: true))
        XCTAssertFalse(TerminalSession.carriesOn(tabAgent: claude, startedWithFolder: true, othersWorked: true, folderAgent: claude,
                                                 remembers: true, startsAgent: true, continues: true),
                       "another Claude Code's conversation may be the folder's latest, the one that carries on")

        let quiet = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(TerminalSession.writtenElsewhere(latest: nil, lastOutput: quiet))
        XCTAssertFalse(TerminalSession.writtenElsewhere(latest: quiet.addingTimeInterval(5), lastOutput: quiet),
                       "written as the tab finished its reply, or named a moment after: its own")
        XCTAssertTrue(TerminalSession.writtenElsewhere(latest: quiet.addingTimeInterval(60), lastOutput: quiet),
                      "written a minute after the tab went quiet: another Claude Code's")

        // With the tab's own session, its output doesn't matter: a redraw after the other wrote
        // can't hide that the latest is another's.
        let mine = Agent.Conversation(session: "mine", written: quiet)
        let theirs = Agent.Conversation(session: "theirs", written: quiet.addingTimeInterval(60))
        let redrawn = quiet.addingTimeInterval(120)
        XCTAssertFalse(TerminalSession.anotherIsLatest(conversations: [], ownSession: "mine", lastOutput: quiet))
        XCTAssertTrue(TerminalSession.anotherIsLatest(conversations: [mine, theirs], ownSession: "mine", lastOutput: redrawn),
                      "the shell tab's Claude Code wrote last, though this tab printed since")
        XCTAssertFalse(TerminalSession.anotherIsLatest(conversations: [theirs, Agent.Conversation(session: "mine", written: redrawn)],
                                                       ownSession: "mine", lastOutput: quiet),
                       "its own is the latest, though it's been quiet")
        XCTAssertFalse(TerminalSession.anotherIsLatest(conversations: [theirs], ownSession: "mine", lastOutput: quiet),
                       "it hasn't written a conversation yet, so closing it loses nothing")
        XCTAssertFalse(TerminalSession.anotherIsLatest(conversations: [mine, theirs], ownSession: nil, lastOutput: redrawn),
                       "without its session, it falls back to when it last printed")
        XCTAssertTrue(TerminalSession.anotherIsLatest(conversations: [mine, theirs], ownSession: nil, lastOutput: quiet))
    }

    /// A running Claude Code's session is read from the note it keeps on itself, by its process.
    func testClaudeCodesSessionIsReadFromItsNote() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"pid":4242,"sessionId":"48a76296-c4a6","cwd":"/a","status":"idle"}"#.utf8).write(to: sessions.appendingPathComponent("4242.json"))
        try Data(#"{"pid":7,"sessionId":"left-behind"}"#.utf8).write(to: sessions.appendingPathComponent("4343.json"))
        try Data("not json".utf8).write(to: sessions.appendingPathComponent("4444.json"))
        XCTAssertEqual(Agent.claudeSession(pid: 4242, home: home.path), "48a76296-c4a6")
        XCTAssertNil(Agent.claudeSession(pid: 4343, home: home.path), "a note about another process")
        XCTAssertNil(Agent.claudeSession(pid: 4444, home: home.path))
        XCTAssertNil(Agent.claudeSession(pid: 4545, home: home.path), "no note")
    }

    /// The folder's first agent tab stops counting on carrying on once another tab with the same
    /// agent opens; a shell tab or another agent doesn't change that.
    @MainActor
    func testALaterAgentTabMeansTheFirstOneMayNotCarryOn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        let fake = Agent(id: "fake", name: "Fake", command: "true"), other = Agent(id: "other", name: "Other", command: "true")
        let first = workspace.newTerminal(agent: fake, startedWithFolder: true)
        workspace.newTerminal()
        workspace.newTerminal(agent: other)
        XCTAssertFalse(first.laterAgentOpened)
        workspace.newTerminal(agent: fake)
        XCTAssertTrue(first.laterAgentOpened)
    }

    /// A tab notes when it last printed, so a conversation written after it went quiet can be told
    /// from its own.
    @MainActor
    func testATabNotesWhenItLastPrinted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        let session = workspace.newTerminal(agent: Agent(id: "late", name: "Late", command: "sleep 1; echo printed; sleep 30"))
        let started = session.lastOutput.date
        let deadline = Date().addingTimeInterval(10)
        while session.lastOutput.date.timeIntervalSince(started) < 0.9, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(session.lastOutput.date.timeIntervalSince(started), 0.9, "the line printed a second in")
    }

    func testChildrenAreReadWithTheirGroups() throws {
        // A sleep in the shell's group, as an MCP server is in Claude Code's, and one in a group of
        // its own, as each of its commands is.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 5 & perl -e 'setpgrp(0, 0); sleep 5' & wait"]
        try shell.run()
        defer { shell.terminate() }
        let group = getpgid(shell.processIdentifier)
        var children: [TerminalSession.Child] = []
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            children = TerminalSession.children(of: shell.processIdentifier) ?? []
            if children.count == 2, children.contains(where: { $0.group != group }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(children.map(\.program).sorted(), ["perl", "sleep"])
        XCTAssertEqual(TerminalSession.ClaudeActivity(children: children, group: group), .commands(1))
        for child in children where child.group != group { kill(-child.group, SIGTERM) }
    }

    @MainActor
    func testALiveTerminalNamesWhatsRunningInIt() {
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory,
                                      agent: Agent(id: "test", name: "Sleeper", command: "sleep 30"))
        defer { session.terminate() }
        let deadline = Date().addingTimeInterval(15)
        while session.running == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(session.running, "Sleeper", "the agent goes by its name")
    }

    @MainActor
    func testTheInstallOfferStaysWhileSomethingRuns() {
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory,
                                      agent: Agent(id: "test", name: "Sleeper", command: "sleep 30", installCommand: "echo installed"))
        defer { session.terminate() }
        let deadline = Date().addingTimeInterval(15)
        while !session.isBusy, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(session.isBusy)
        session.agentMissing = true
        session.installAgent()
        XCTAssertTrue(session.agentMissing, "nothing was typed, so the offer stays")
    }

    func testEnvironmentDropsTheLaunchersVariables() {
        let env = TerminalSession.environment(["CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "TERM_PROGRAM": "vscode", "HOME": "/Users/x"], shell: "/bin/zsh")
        XCTAssertFalse(env.contains { $0.hasPrefix("CLAUDE") })
        XCTAssertTrue(env.contains("TERM_PROGRAM=ProcessCode"))
        XCTAssertTrue(env.contains("TERM=xterm-256color"))
        XCTAssertTrue(env.contains("COLORTERM=truecolor"))
        XCTAssertTrue(env.contains("HOME=/Users/x"))
        XCTAssertTrue(env.contains("LANG=en_US.UTF-8"))
    }
}

final class WorkspaceTests: AppTestCase {
    @MainActor
    func testDraggingTheSplitHandleReportsHowFarItMoved() throws {
        let view = SplitHandle.HandleView(frame: NSRect(x: 0, y: 0, width: 400, height: SplitHandle.thickness))
        var drags: [String] = []
        view.resize = { phase in
            switch phase {
            case .began: drags.append("began")
            case .moved(let down): drags.append("moved \(Int(down))")
            case .ended: drags.append("ended")
            }
        }
        func event(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: y), modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, y: 300))
        view.mouseDragged(with: try event(.leftMouseDragged, y: 340))   // window y grows upwards: 40 up
        view.mouseDragged(with: try event(.leftMouseDragged, y: 250))   // 50 down
        view.mouseUp(with: try event(.leftMouseUp, y: 250))
        XCTAssertEqual(drags, ["began", "moved -40", "moved 50", "ended"])
        XCTAssertTrue(view.acceptsFirstMouse(for: nil), "the first click into the window grabs it too")

        var doubleClicks = 0
        view.doubleClick = { doubleClicks += 1 }
        drags = []
        func doubleClick(y: CGFloat) throws {
            view.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: y), modifierFlags: [],
                                                                  timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                                  clickCount: 2, pressure: 1)))
            view.mouseUp(with: try event(.leftMouseUp, y: y))
        }
        try doubleClick(y: 2)   // the lower half, over the terminal's bar
        XCTAssertEqual(doubleClicks, 1, "a double-click on the bar under the handle still maximizes the terminal")
        XCTAssertEqual(drags, [], "and isn't a drag")
        try doubleClick(y: 8)   // the upper half, over the editor
        XCTAssertEqual(doubleClicks, 1, "the editor's side doesn't maximize the terminal")

        // The sidebar's line is vertical and reports how far right it moved.
        let side = SplitHandle.HandleView(frame: NSRect(x: 0, y: 0, width: SplitHandle.thickness, height: 400))
        side.axis = .vertical
        var widths: [String] = []
        side.resize = { if case .moved(let right) = $0 { widths.append("moved \(Int(right))") } }
        func at(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 100), modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        side.mouseDown(with: try at(.leftMouseDown, x: 250))
        side.mouseDragged(with: try at(.leftMouseDragged, x: 280))
        side.mouseDragged(with: try at(.leftMouseDragged, x: 230))
        side.mouseUp(with: try at(.leftMouseUp, x: 230))
        XCTAssertEqual(widths, ["moved 30", "moved -20"])
    }

    func testGoToFileRanksNameMatchesFirst() {
        let files = ["Sources/ProcessCode/Git.swift", "docs/git-notes/intro.md", "Sources/ProcessCode/Settings.swift", "README.md"]
        XCTAssertEqual(Workspace.match("git", in: files).first, "Sources/ProcessCode/Git.swift")
        XCTAssertEqual(Workspace.match("stgs", in: files), ["Sources/ProcessCode/Settings.swift"], "letters in order still match")
        XCTAssertEqual(Workspace.match("zzz", in: files), [])
    }

    func testVideosThePlayerOpensAreShownOthersAreNot() {
        XCTAssertEqual(Document.mediaKind(of: URL(fileURLWithPath: "/x/clip.mp4")), .video)
        XCTAssertEqual(Document.mediaKind(of: URL(fileURLWithPath: "/x/clip.MOV")), .video)
        XCTAssertEqual(Document.mediaKind(of: URL(fileURLWithPath: "/x/still.png")), .image)
        XCTAssertEqual(Document.mediaKind(of: URL(fileURLWithPath: "/x/paper.pdf")), .pdf)
        XCTAssertNil(Document.mediaKind(of: URL(fileURLWithPath: "/x/clip.webm")), "not a format the system plays")
        XCTAssertNil(Document.mediaKind(of: URL(fileURLWithPath: "/x/icon.svg")), "edited as text")
        XCTAssertNil(Document.mediaKind(of: URL(fileURLWithPath: "/x/main.swift")))
    }

    func testAFileIsInOnePaneAtMost() {
        let ids = ["a", "b", "c"]
        var panes = Panes(active: "a", side: nil)
        panes.show("b", toSide: true, among: ids)
        XCTAssertEqual(panes, Panes(active: "a", side: "b"), "beside the file that's showing")
        panes.show("c", toSide: false, among: ids)
        XCTAssertEqual(panes, Panes(active: "c", side: "b"), "the side stays while the main pane changes")
        panes.show("b", toSide: false, among: ids)
        XCTAssertEqual(panes, Panes(active: "c", side: "b"), "a file at the side stays there")
        panes.show("c", toSide: true, among: ids)
        XCTAssertEqual(panes, Panes(active: "b", side: "c"), "the two change places")

        panes = Panes(active: "b", side: nil)
        panes.show("b", toSide: true, among: ids)
        XCTAssertEqual(panes, Panes(active: "c", side: "b"), "the next tab takes the main pane")
        panes = Panes(active: "a", side: nil)
        panes.show("a", toSide: true, among: ["a"])
        XCTAssertEqual(panes, Panes(active: "a", side: nil), "nothing to put beside it")
        panes = Panes(active: nil, side: nil)
        panes.show("a", toSide: true, among: ["a"])
        XCTAssertEqual(panes, Panes(active: "a", side: nil), "the first file takes the main pane")
    }

    func testClosingAFileLeavesThePanesFilled() {
        var panes = Panes(active: "a", side: "b")
        panes.remove("b", from: ["a", "b", "c"])
        XCTAssertEqual(panes, Panes(active: "a", side: nil))
        panes = Panes(active: "a", side: "b")
        panes.remove("a", from: ["a", "b", "c"])
        XCTAssertEqual(panes, Panes(active: "c", side: "b"), "the next tab that isn't at the side")
        panes = Panes(active: "a", side: "b")
        panes.remove("a", from: ["a", "b"])
        XCTAssertEqual(panes, Panes(active: "b", side: nil), "the file at the side is then alone")
        panes = Panes(active: "a", side: nil)
        panes.remove("a", from: ["a"])
        XCTAssertEqual(panes, Panes(active: nil, side: nil))
    }

    func testIndentIsReadFromTheFile() {
        XCTAssertEqual(EditorController.indentUnit(of: "a {\n  b\n}", language: .swift), "  ")
        XCTAssertEqual(EditorController.indentUnit(of: "a {\n\tb\n}", language: .swift), "\t")
        XCTAssertEqual(EditorController.indentUnit(of: "a", language: .swift), "    ")
    }

    func testMarginsOnlyWhereThePaneIsWiderThanTheColumn() {
        XCTAssertEqual(Settings.sideMargin(available: 1288, readable: 862), 213)
        XCTAssertEqual(Settings.sideMargin(available: 862, readable: 862), 0)
        XCTAssertEqual(Settings.sideMargin(available: 600, readable: 862), 0, "a narrow pane is filled")
    }

    func testFocusModeOnlyWithTheTerminalAlone() {
        XCTAssertTrue(Workspace.focusMode(sidebarVisible: false, editorShown: false))
        XCTAssertFalse(Workspace.focusMode(sidebarVisible: true, editorShown: false), "not with the sidebar")
        XCTAssertFalse(Workspace.focusMode(sidebarVisible: false, editorShown: true), "not with a file open above")
        XCTAssertFalse(Workspace.focusMode(sidebarVisible: false, editorShown: false, spotlight: false), "not with spotlight off")
    }

    func testMarginsSetting() {
        let defaults = UserDefaults(suiteName: "ProcessCodeTests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.margins, "margins are on until turned off")
        settings.margins = false
        XCTAssertFalse(Settings(defaults: defaults).margins)
        XCTAssertTrue(settings.spotlight, "spotlight is on until turned off")
        settings.spotlight = false
        XCTAssertFalse(Settings(defaults: defaults).spotlight)
        settings.fontSize = 13
        let width = settings.readableWidth
        settings.fontSize = 16
        XCTAssertGreaterThan(settings.readableWidth, width, "the column holds the same text at a bigger size")
    }

    func testAgentSetting() {
        let defaults = UserDefaults(suiteName: "ProcessCodeTests.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.agent?.command, "claude")
        XCTAssertTrue(settings.startAgentOnOpen)
        XCTAssertTrue(settings.continueConversation, "carrying on the last conversation is the default")
        settings.continueConversation = false
        XCTAssertFalse(Settings(defaults: defaults).continueConversation, "and turning it off is remembered")
        settings.agentID = Agent.customID
        XCTAssertNil(settings.agent, "a custom agent with no command is no agent")
        settings.customAgentCommand = "/opt/bin/hermes --fast"
        XCTAssertEqual(settings.agent?.name, "hermes")
        XCTAssertEqual(settings.agent?.command, "/opt/bin/hermes --fast")
    }
}

final class ProjectTests: AppTestCase {
    func testReadsStatus() {
        var project = Project(path: "/r/app")
        project.read(status: "# branch.oid abc\n# branch.head feature/x\n# branch.upstream origin/feature/x\n# branch.ab +2 -1\n1 .M N... 100644 100644 100644 a b file.swift\n? new.txt\n")
        XCTAssertEqual(project.branch, "feature/x")
        XCTAssertEqual(project.ahead, 2)
        XCTAssertEqual(project.behind, 1)
        XCTAssertEqual(project.changes, 2)
        XCTAssertTrue(project.hasCommits)
        project.read(status: "# branch.oid (initial)\n# branch.head (detached)\n")
        XCTAssertEqual(project.branch, "detached")
        XCTAssertEqual(project.changes, 0)
        XCTAssertFalse(project.hasCommits)
    }

    func testGitHubNames() {
        XCTAssertEqual(ProjectStore.githubName(for: "my project"), "my-project")
        XCTAssertEqual(ProjectStore.githubName(for: " Café  & co. "), "Caf-co.")
        XCTAssertEqual(ProjectStore.githubName(for: "already_fine-1.0"), "already_fine-1.0")
        XCTAssertEqual(ProjectStore.githubName(for: "-test"), "test", "never read as an option")
        XCTAssertEqual(ProjectStore.githubName(for: " & "), "")
    }

    func testAPushThatFailsAfterTheRepositoryIsMadeSaysToPush() {
        let halfway = ProjectStore.publishFailure("rejected", remoteAdded: true, branch: "trunk")
        XCTAssertTrue(halfway.contains("git push -u origin trunk"))
        XCTAssertFalse(halfway.contains("right-click"), "publishing again would be refused")
        let detached = ProjectStore.publishFailure("rejected", remoteAdded: true, branch: "detached")
        XCTAssertFalse(detached.contains("origin detached"))
        XCTAssertTrue(detached.contains("git switch -c <new-branch>"), "not main, which usually exists already")
        let unlinked = ProjectStore.publishFailure("network", remoteAdded: false, madeAt: "https://github.com/o/app", branch: "main")
        XCTAssertTrue(unlinked.contains("git remote add origin https://github.com/o/app && git push -u origin main"))
        XCTAssertFalse(unlinked.contains("right-click"), "publishing again would collide with the repository it made")
        let nothing = ProjectStore.publishFailure("not signed in", remoteAdded: false, branch: "main")
        XCTAssertTrue(nothing.contains("right-click menu"))
    }

    func testPublishArguments() {
        XCTAssertEqual(ProjectStore.publishArguments(path: "/r/app", name: "app", description: " ", isPrivate: true, hasCommits: true),
                       ["gh", "repo", "create", "app", "--private", "--source", "/r/app", "--remote", "origin", "--push"])
        XCTAssertEqual(ProjectStore.publishArguments(path: "/r/app", name: "app", description: "A thing", isPrivate: false, hasCommits: false),
                       ["gh", "repo", "create", "app", "--public", "--source", "/r/app", "--remote", "origin", "--description", "A thing"],
                       "nothing to push without a commit")
    }

    func testTrashWarningNamesWhatWouldBeLost() {
        let local = Project(path: "/r/local")
        XCTAssertTrue(ProjectStore.trashWarning(for: local).hasPrefix("It isn't on GitHub"))
        XCTAssertFalse(ProjectStore.trashWarning(for: local).contains("GitHub isn't touched"))

        let safe = Project(path: "/r/safe", remote: "git@github.com:o/safe.git")
        XCTAssertEqual(ProjectStore.trashWarning(for: safe),
                       "The folder moves to the Trash, where you can put it back. The repository on GitHub isn't touched.")

        var risky = safe
        risky.changes = 3
        risky.unpushed = 1
        risky.stashes = 2
        let warning = ProjectStore.trashWarning(for: risky)
        XCTAssertTrue(warning.contains("3 uncommitted changes"))
        XCTAssertTrue(warning.contains("1 commit that isn't on GitHub"))
        XCTAssertTrue(warning.contains("2 stashes"))

        let plainFolder = Project(path: "/r/notes", isRepository: false)
        XCTAssertEqual(ProjectStore.trashWarning(for: plainFolder), "The folder moves to the Trash, where you can put it back.")

        // Unsaved text in a window still open, on a folder above, is named apart from kept drafts.
        let both = ProjectStore.trashWarning(for: safe, drafts: 1, unsavedOpen: 2)
        XCTAssertTrue(both.hasPrefix("2 files in it have unsaved changes in an open window. Their tabs will close, and the changes will be lost."))
        XCTAssertTrue(both.contains("1 file in it has unsaved changes, kept from when its window closed."))
        XCTAssertTrue(ProjectStore.trashWarning(for: safe, unsavedOpen: 1).hasPrefix("1 file in it has unsaved changes in an open window. Its tab will close"))
    }

    func testAHungToolIsStopped() {
        let start = Date()
        let result = Shell.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertEqual(result.status, 124)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(Shell.run("/bin/echo", ["hi"], timeout: 5).output, "hi\n", "a quick tool is untouched")
        XCTAssertNotEqual(Shell.run("/bin/sh", ["-c", "kill -TERM $$"], timeout: 30).status, 124,
                          "a tool that dies of a signal by itself isn't reported as too slow")
    }

    func testAHungToolIsStoppedEvenIfItsChildHoldsTheOutput() {
        // As git does with ssh: a child that inherits the tool's output and outlives it.
        for merging in [true, false] {
            let start = Date()
            let result = Shell.run("/bin/sh", ["-c", "sleep 20 & sleep 20"], mergingErrors: merging, timeout: 0.5)
            XCTAssertEqual(result.status, 124)
            XCTAssertLessThan(Date().timeIntervalSince(start), 5, "merging errors: \(merging)")
        }
    }

    func testOnlyARepositoryHoldingNoOtherProjectGoesToTheTrash() {
        let listed = ["/r/app", "/r/app/inner", "/r/other", "/elsewhere/notes"]
        XCTAssertNil(ProjectStore.trashRefusal(for: Project(path: "/r/other"), root: "/r", listed: listed))
        XCTAssertNotNil(ProjectStore.trashRefusal(for: Project(path: "/elsewhere/notes", isRepository: false), root: "/r", listed: listed),
                        "a plain folder opened from elsewhere is only removed from the list")
        XCTAssertNotNil(ProjectStore.trashRefusal(for: Project(path: "/r/app"), root: "/r", listed: listed), "it holds another project")
        XCTAssertNotNil(ProjectStore.trashRefusal(for: Project(path: "/r/"), root: "/r", listed: listed), "the projects folder itself")
        XCTAssertNil(ProjectStore.trashRefusal(for: Project(path: "/r/app-2"), root: "/r", listed: listed + ["/r/app-2x"]),
                     "a sibling whose name starts the same isn't inside it")
        XCTAssertNotNil(ProjectStore.trashRefusal(for: Project(path: "/Users/me/Documents"), root: "/Users/me/Documents/GitHub", listed: []),
                        "a folder above the projects folder, even with nothing listed inside it")
        XCTAssertNotNil(ProjectStore.trashRefusal(for: Project(path: NSHomeDirectory()), root: "/r", listed: []))
        XCTAssertNotNil(ProjectStore.trashRefusal(for: Project(path: "/"), root: "/r", listed: []))
        XCTAssertEqual(ProjectStore.trashRefusal(for: Project(path: "/r/other"), root: "/r", listed: listed, open: ["/r/other"]),
                       "It's open in a window. Close the window first.")
        XCTAssertEqual(ProjectStore.trashRefusal(for: Project(path: "/r/other"), root: "/r", listed: listed, open: ["/r/other/web"]),
                       "“web” in it is open in a window. Close the window first.", "a window on a folder inside it")
        XCTAssertNil(ProjectStore.trashRefusal(for: Project(path: "/r/other"), root: "/r", listed: listed, open: ["/r", "/r/other-2"]),
                     "a window above it, or on a sibling, doesn't stop it")
    }

    /// Work that only exists in the folder: a branch never pushed, a branch whose upstream was
    /// deleted (from here, and on the remote alone), and a stash, all while the current branch is in
    /// step with its remote.
    func testTrashCountsWorkOnEveryBranchAndStash() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let remote = base.appendingPathComponent("remote.git"), repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        func git(_ args: String..., in dir: URL) {
            let result = Shell.run("/usr/bin/env", ["git", "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args, in: dir)
            XCTAssertEqual(result.status, 0, "git \(args.joined(separator: " ")): \(result.output)")
        }
        git("init", "--bare", "-b", "main", in: remote)
        _ = try ProjectStore.create(name: "repo", readme: true, in: base.path).get()
        git("remote", "add", "origin", remote.path, in: repo)
        git("push", "-u", "origin", "main", in: repo)
        XCTAssertEqual(Project(path: repo.path).inspectedForTrash().unpushed, 0, "everything is on the remote")

        git("switch", "-c", "gone", in: repo)
        git("commit", "--allow-empty", "-m", "pushed, then deleted on the remote", in: repo)
        git("push", "-u", "origin", "gone", in: repo)
        git("push", "origin", "--delete", "gone", in: repo)
        git("switch", "-c", "local", in: repo)
        git("commit", "--allow-empty", "-m", "never pushed", in: repo)
        git("switch", "main", in: repo)
        // Deleted on the remote but still fetched here, like a PR branch GitHub removed after merging.
        git("switch", "-c", "feature/stale", in: repo)
        git("commit", "--allow-empty", "-m", "pushed, then deleted on the remote alone", in: repo)
        git("push", "-u", "origin", "feature/stale", in: repo)
        git("branch", "-D", "feature/stale", in: remote)
        git("switch", "main", in: repo)
        XCTAssertEqual(Shell.run("/usr/bin/env", ["git", "rev-parse", "--verify", "-q", "origin/feature/stale"], in: repo).status, 0,
                       "this Mac still has the remote branch")
        try "edit".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        git("stash", in: repo)

        let project = Project(path: repo.path).inspectedForTrash()
        XCTAssertEqual(project.ahead, 0, "the current branch alone looks safe")
        XCTAssertEqual(project.unpushed, 3)
        XCTAssertEqual(project.stashes, 1)
        XCTAssertFalse(project.remoteUnchecked)
        XCTAssertTrue(ProjectStore.trashWarning(for: project).contains("3 commits that aren't on GitHub"))

        git("checkout", "--detach", in: repo)
        git("commit", "--allow-empty", "-m", "on no branch", in: repo)
        XCTAssertEqual(Project(path: repo.path).inspectedForTrash().unpushed, 4, "a commit on a detached HEAD counts too")

        // A remote that can't be reached: the count goes by what was last fetched, and says so.
        git("remote", "add", "away", base.appendingPathComponent("missing.git").path, in: repo)
        let away = Project(path: repo.path).inspectedForTrash()
        XCTAssertTrue(away.remoteUnchecked)
        XCTAssertEqual(away.unpushed, 4)
        XCTAssertTrue(ProjectStore.trashWarning(for: away).contains("couldn't be reached"))
        git("remote", "remove", "away", in: repo)

        // A ref to a missing object: git status still works, but the count fails.
        try "0123456789abcdef0123456789abcdef01234567\n".write(to: repo.appendingPathComponent(".git/refs/heads/broken"),
                                                               atomically: true, encoding: .utf8)
        let broken = Project(path: repo.path).inspectedForTrash()
        XCTAssertTrue(broken.isRead)
        XCTAssertTrue(broken.uncounted)
        XCTAssertTrue(ProjectStore.trashWarning(for: broken).contains("couldn't count"))

        let empty = Project(path: try ProjectStore.create(name: "empty", readme: false, in: base.path).get().path).inspectedForTrash()
        XCTAssertFalse(empty.hasCommits)
        XCTAssertFalse(empty.uncounted, "no commits yet is nothing to count, not a failure")
        XCTAssertEqual(empty.unpushed, 0)
    }

    @MainActor
    func testANewRepositoryCanBePublishedAndRefusalsLeaveItAlone() throws {
        let suite = "ProcessCodeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        defaults.set(root, forKey: "projectsFolder")

        let made = try ProjectStore.create(name: "fresh", readme: true, in: root).get()
        let fresh = Project(path: made.path).inspected()
        XCTAssertTrue(fresh.canPublish, "read, a repository, and no remote")
        XCTAssertFalse(Project(path: made.path).canPublish, "not before git has been read")

        let store = ProjectStore(defaults: defaults)
        let inner = Project(path: made.path + "/inner", isRepository: false, isExternal: true)
        store.projects = [fresh, inner]
        XCTAssertNotNil(store.moveToTrash(fresh), "it holds another listed project")
        XCTAssertNotNil(store.moveToTrash(inner), "not a repository")
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path))
        XCTAssertEqual(store.projects.count, 2, "a refusal changes nothing")

        var reports: [String] = []
        store.trash(inner, confirm: { _ in false }, report: { reports.append($0) })
        XCTAssertEqual(reports, [], "cancelled: nothing moves and nothing is reported")
        var asked = false
        store.trash(inner, confirm: { _ in
            asked = true
            XCTAssertEqual(reports, [], "the error doesn't come while the question is up")
            return true
        }, report: { reports.append($0) })
        XCTAssertTrue(asked)
        XCTAssertEqual(reports.count, 1, "the refusal is reported after the question")
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path))
    }

    /// Remotes that are slow to answer are asked side by side, so the question waits for the slowest
    /// one, not for all of them in turn.
    func testSlowRemotesAreAskedSideBySide() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try ProjectStore.create(name: "repo", readme: true, in: base.path).get()
        for name in ["one", "two"] {
            XCTAssertEqual(Shell.run("/usr/bin/env", ["git", "remote", "add", name, "ssh://example.invalid/\(name).git"], in: repo).status, 0)
        }
        // Each remote is slow to fail, as an unreachable host is. Git tries it twice, so 4 s each.
        let saved = ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"]
        setenv("GIT_SSH_COMMAND", "sleep 2; false", 1)
        defer { if let saved { setenv("GIT_SSH_COMMAND", saved, 1) } else { unsetenv("GIT_SSH_COMMAND") } }
        let start = Date()
        let project = Project(path: repo.path).inspectedForTrash()
        XCTAssertTrue(project.remoteUnchecked)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6.5, "about 4 s, not 8")
    }

    func testGoneBranchesAreReadFromPrune() {
        let output = "Pruning origin\nURL: git@github.com:o/r.git\n * [would prune] origin/feature/x\n * [would prune] origin/old\n"
        XCTAssertEqual(Project.goneBranches(inPruneOutput: output), ["origin/feature/x", "origin/old"])
        XCTAssertEqual(Project.goneBranches(inPruneOutput: "Pruning origin\nURL: ../r.git\n"), [])
    }

    func testRemoteFormsBecomeWebURLs() {
        let cases = [
            "https://github.com/owner/name.git": "https://github.com/owner/name",
            "git@github.com:owner/name.git": "https://github.com/owner/name",
            "ssh://git@github.com/owner/name": "https://github.com/owner/name",
            "https://user:token@github.com/owner/name.git": "https://github.com/owner/name",
        ]
        for (remote, web) in cases {
            let project = Project(path: "/tmp/x", remote: remote)
            XCTAssertEqual(project.webURL?.absoluteString, web, remote)
            XCTAssertEqual(project.slug, "owner/name", remote)
        }
        XCTAssertNil(Project(path: "/tmp/x").webURL)
        XCTAssertEqual(Project.remote(in: "upstream\thttps://a/b (fetch)\norigin\tgit@github.com:o/n.git (fetch)\n"), "git@github.com:o/n.git")
    }

    func testAges() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func age(_ seconds: Double) -> String { Project.age(of: now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(age(5), "now")
        XCTAssertEqual(age(300), "5m")
        XCTAssertEqual(age(3 * 3600), "3h")
        XCTAssertEqual(age(2 * 86_400), "2d")
        XCTAssertEqual(age(21 * 86_400), "3w")
        XCTAssertEqual(age(120 * 86_400), "3mo")
        XCTAssertEqual(age(800 * 86_400), "2y")
    }

    func testMostRecentlyWorkedOnComesFirst() {
        let old = Project(path: "/r/old", lastCommit: Date(timeIntervalSince1970: 100))
        let committed = Project(path: "/r/committed", lastCommit: Date(timeIntervalSince1970: 500))
        let opened = Project(path: "/r/opened", lastCommit: Date(timeIntervalSince1970: 50), lastOpened: Date(timeIntervalSince1970: 900))
        let untouched = Project(path: "/r/aaa")
        XCTAssertEqual(ProjectStore.filter([old, untouched, committed, opened], by: "").map(\.name), ["opened", "committed", "old", "aaa"])
        XCTAssertEqual(ProjectStore.filter([old, committed, opened], by: " OLD ").map(\.name), ["old"])
        let remote = Project(path: "/r/local-name", remote: "git@github.com:someone/upstream-name.git")
        XCTAssertEqual(ProjectStore.filter([old, remote], by: "upstream").map(\.name), ["local-name"], "the GitHub name matches too")
    }

    func testCloneNames() {
        XCTAssertEqual(ProjectStore.cloneName(for: "owner/name"), "name")
        XCTAssertEqual(ProjectStore.cloneName(for: "https://github.com/owner/name.git"), "name")
        XCTAssertEqual(ProjectStore.cloneName(for: "git@github.com:owner/name.git"), "name")
        XCTAssertEqual(ProjectStore.cloneName(for: " https://github.com/owner/my%20repo "), "my repo")
    }

    func testScanCreateAndRefuseDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString).path
        let elsewhere = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root + "/plain-folder", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: elsewhere) }

        let created = try ProjectStore.create(name: "demo", readme: true, in: root).get()
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path + "/README.md"))
        XCTAssertThrowsError(try ProjectStore.create(name: "demo", readme: false, in: root).get())
        XCTAssertThrowsError(try ProjectStore.create(name: "a/b", readme: false, in: root).get())
        XCTAssertThrowsError(try ProjectStore.clone("owner/demo", into: root).get(), "an existing folder is never cloned over")

        let found = ProjectStore.scan(root: root, opened: [elsewhere: 123, "/no/such/folder": 5])
        XCTAssertEqual(Set(found.map(\.name)), ["demo", (elsewhere as NSString).lastPathComponent], "only repositories, plus folders opened from elsewhere")
        let outside = try XCTUnwrap(found.first { $0.path == elsewhere })
        XCTAssertTrue(outside.isExternal)
        XCTAssertFalse(outside.isRepository)
        XCTAssertEqual(outside.lastOpened, Date(timeIntervalSince1970: 123))

        let inspected = try XCTUnwrap(found.first { $0.name == "demo" }).inspected()
        XCTAssertEqual(inspected.branch, "main")
        XCTAssertEqual(inspected.changes, 0)
        XCTAssertTrue(inspected.hasCommits)
        XCTAssertFalse(inspected.isPublished)

        let empty = try ProjectStore.create(name: "empty", readme: false, in: root).get()
        XCTAssertFalse(Project(path: empty.path).inspected().hasCommits)
        XCTAssertThrowsError(try ProjectStore.publish(Project(path: created.path, remote: "x"), name: " ", description: "", isPrivate: true).get(),
                             "a name is needed before anything runs")
        XCTAssertThrowsError(try ProjectStore.publish(Project(path: created.path), name: "--", description: "", isPrivate: true).get(),
                             "a name that cleans to nothing is refused before gh runs")
    }
}

final class ServiceTests: AppTestCase {
    private var folder: URL!
    private var savedDrafts: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedDrafts = Drafts.folder
        Drafts.folder = folder.appendingPathComponent("drafts")
    }

    override func tearDown() {
        Drafts.flush()
        Drafts.folder = savedDrafts
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Drafts

    func testDraftsAreKeptPerFolderAndRemoved() {
        let a = Draft(root: "/p/one", path: "/p/one/a.txt", text: "hello", diskDate: Date(timeIntervalSince1970: 100))
        let b = Draft(root: "/p/two", path: "/p/two/b.txt", text: "other", diskDate: nil)
        Drafts.write(a)
        Drafts.write(b)
        XCTAssertEqual(Drafts.all(root: URL(fileURLWithPath: "/p/one")), [a])
        Drafts.write(Draft(root: "/p/one", path: "/p/one/a.txt", text: "newer", diskDate: nil))
        XCTAssertEqual(Drafts.all(root: URL(fileURLWithPath: "/p/one")).map(\.text), ["newer"], "a newer draft replaces the older")
        Drafts.remove(for: URL(fileURLWithPath: "/p/one/a.txt"))
        XCTAssertEqual(Drafts.all(root: URL(fileURLWithPath: "/p/one")), [])
        XCTAssertEqual(Drafts.all(root: URL(fileURLWithPath: "/p/two")), [b])
    }

    @MainActor
    func testRestoredDraftIsUnsavedAndSavingForgetsIt() throws {
        let file = folder.appendingPathComponent("a.txt")
        try "on disk".write(to: file, atomically: true, encoding: .utf8)
        let date = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let document = Document(url: file)
        document.draftRoot = folder
        document.restore(Draft(root: folder.path, path: file.path, text: "typed", diskDate: date))
        XCTAssertEqual(document.text, "typed")
        XCTAssertTrue(document.isDirty)
        XCTAssertFalse(document.changedOnDisk, "the file hasn't changed since the draft was kept")
        document.keepDraft()
        XCTAssertEqual(Drafts.all(root: folder).map(\.text), ["typed"])
        try document.save()
        XCTAssertEqual(Drafts.all(root: folder), [])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "typed")
    }

    @MainActor
    func testDraftOfAFileChangedSinceSaysSo() throws {
        let file = folder.appendingPathComponent("a.txt")
        try "changed by the agent".write(to: file, atomically: true, encoding: .utf8)
        let document = Document(url: file)
        document.restore(Draft(root: folder.path, path: file.path, text: "typed", diskDate: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(document.changedOnDisk, "Keep Mine or Reload decides")
    }

    @MainActor
    func testDraftThatMatchesTheFileIsDropped() throws {
        let file = folder.appendingPathComponent("a.txt")
        try "same".write(to: file, atomically: true, encoding: .utf8)
        let document = Document(url: file)
        document.restore(Draft(root: folder.path, path: file.path, text: "same", diskDate: nil))
        XCTAssertFalse(document.isDirty)
    }

    @MainActor
    func testDraftOfADeletedFileComesBackAndSavingPutsItBack() throws {
        let file = folder.appendingPathComponent("gone.txt")
        let draft = Draft(root: folder.path, path: file.path, text: "still here", diskDate: nil)
        let document = Document(url: file, draft: draft.text)
        document.restore(draft)
        XCTAssertEqual(document.kind, .text)
        XCTAssertTrue(document.isDirty)
        XCTAssertFalse(document.changedOnDisk)
        try document.save()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "still here")
    }

    // MARK: A whole window

    @MainActor
    func testReopeningAFolderBringsBackUnsavedTextAndTrashCanBeUndone() throws {
        // A git step that fails would leave a file Trash asks about, in a dialog nobody can answer.
        continueAfterFailure = false
        let root = folder.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.txt")
        try "committed".write(to: file, atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "first"]] {
            XCTAssertEqual(Shell.run("/usr/bin/env", ["git"] + arguments, in: root).status, 0)
        }
        let date = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        Drafts.write(Draft(root: root.path, path: file.path, text: "typed", diskDate: date))
        Drafts.write(Draft(root: root.path, path: root.appendingPathComponent("gone.txt").path, text: "kept", diskDate: nil))

        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        XCTAssertEqual(workspace.documents.map(\.name).sorted(), ["a.txt", "gone.txt"])
        XCTAssertTrue(workspace.documents.allSatisfy(\.isDirty))
        XCTAssertEqual(workspace.documents.first { $0.name == "a.txt" }?.text, "typed")

        // A committed file goes without a question, and Undo puts it back.
        let other = root.appendingPathComponent("b.txt")
        try "b".write(to: other, atomically: true, encoding: .utf8)
        _ = Shell.run("/usr/bin/env", ["git", "add", "b.txt"], in: root)
        XCTAssertEqual(Shell.run("/usr/bin/env", ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "b"], in: root).status, 0)
        workspace.trash(other)
        // Git is asked off the main thread, so the move comes a moment later.
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: other.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(workspace.fileUndo.undoActionName, "Move to Trash")
        workspace.fileUndo.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "b")
    }

    // MARK: Trash

    func testTrashAsksOnlyWhenSomethingWouldBeLost() {
        let status = GitStatus.parse(["## main", " M src/edited.swift", "?? notes/", "A  added.txt", "!! .env", "!! src/build/"]
            .joined(separator: "\0") + "\0")
        XCTAssertNil(Workspace.trashWarning(path: "src/clean.swift", isDirectory: false, status: status, unsaved: []))
        XCTAssertNil(Workspace.trashWarning(path: "docs", isDirectory: true, status: status, unsaved: []))
        XCTAssertEqual(Workspace.trashWarning(path: "src/edited.swift", isDirectory: false, status: status, unsaved: [])?
            .components(separatedBy: "\n\n").first, "It has changes that aren't committed.")
        XCTAssertTrue(Workspace.trashWarning(path: "notes/todo.md", isDirectory: false, status: status, unsaved: [])!.hasPrefix("It isn't committed"))
        XCTAssertTrue(Workspace.trashWarning(path: "added.txt", isDirectory: false, status: status, unsaved: [])!.hasPrefix("It isn't committed"))
        XCTAssertTrue(Workspace.trashWarning(path: ".env", isDirectory: false, status: status, unsaved: [])!.hasPrefix("Git ignores it"))
        let folder = Workspace.trashWarning(path: "src", isDirectory: true, status: status, unsaved: [])!
        XCTAssertTrue(folder.contains("1 file in it has changes that aren't committed."))
        XCTAssertTrue(folder.contains("Git ignores some of what's in it (build/)"))
        XCTAssertTrue(Workspace.trashWarning(path: "src/clean.swift", isDirectory: false, status: status, unsaved: ["clean.swift"])!
            .hasPrefix("“clean.swift” has unsaved changes"))
        XCTAssertTrue(Workspace.trashWarning(path: "a.txt", isDirectory: false, status: GitStatus(), unsaved: [])!.hasPrefix("This folder isn't a git repository"))
        XCTAssertEqual(Workspace.trashWarning(path: "a.txt", isDirectory: false, status: nil, unsaved: ["a.txt"]),
                       "Git didn't answer in time, so it can't say whether all of it is committed.\n\n“a.txt” has unsaved changes, which will be lost.\n\n"
                       + "It moves to the Trash, where you can put it back. Edit ▸ Undo puts it back at once.")

        let more = GitStatus.parse(["## main", " M vendor/lib", "?? app/new.swift", " M app/old.swift"].joined(separator: "\0") + "\0")
        XCTAssertEqual(Workspace.trashWarning(path: "vendor/lib", isDirectory: true, status: more, unsaved: [])?
            .components(separatedBy: "\n\n").first, "It has changes that aren't committed.", "a submodule with changes in it")
        let app = Workspace.trashWarning(path: "app", isDirectory: true, status: more, unsaved: [])!
        XCTAssertTrue(app.contains("Some of what's in it isn't committed (new.swift), so the Trash will hold the only copy of that."))
        XCTAssertTrue(app.contains("1 file in it has changes that aren't committed."))
    }

    /// A folder opened inside an untracked folder of a bigger repository: git names only the
    /// untracked folder above, and nothing in the opened one is committed.
    func testTrashAsksInsideAnUntrackedFolderOfAParentRepository() throws {
        let repo = folder.appendingPathComponent("parent")
        let opened = repo.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: opened.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "t".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "work".write(to: opened.appendingPathComponent("src/f.swift"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "tracked.txt"], ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "first"]] {
            XCTAssertEqual(Shell.run("/usr/bin/env", ["git"] + arguments, in: repo).status, 0)
        }
        let status = try XCTUnwrap(Git.status(root: opened, timeout: 30))
        XCTAssertEqual(status.state(of: "src", isDirectory: true), .untracked)
        XCTAssertEqual(status.changeCount, 0, "the folder above isn't listed as a change here")
        XCTAssertTrue(try XCTUnwrap(Workspace.trashWarning(path: "src", isDirectory: true, status: status, unsaved: [])).hasPrefix("It isn't committed"))

        try "a/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let ignored = try XCTUnwrap(Git.status(root: opened, timeout: 30))
        XCTAssertEqual(ignored.state(of: "src/f.swift", isDirectory: false), .ignored)
        XCTAssertTrue(try XCTUnwrap(Workspace.trashWarning(path: "src/f.swift", isDirectory: false, status: ignored, unsaved: [])).hasPrefix("Git ignores it"))
    }

    /// The two git calls behind the Trash question share one time limit, so a slow repository
    /// is named within it rather than within twice it.
    func testGitStatusKeepsBothCallsWithinOneTimeLimit() throws {
        let bin = folder.appendingPathComponent("slow-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let git = bin.appendingPathComponent("git")
        try "#!/bin/sh\nsleep 1\n".write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", bin.path + ":" + path, 1)
        defer { setenv("PATH", path, 1) }

        let start = Date()
        XCTAssertNil(Git.status(root: folder, timeout: 1.5), "each call alone is within the limit, but not both")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.9)
    }

    @MainActor
    func testATrashedProjectTakesItsDraftsWithIt() throws {
        let suite = "ProcessCodeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(folder.path, forKey: "projectsFolder")
        let made = try ProjectStore.create(name: "doomed", readme: true, in: folder.path).get()
        let other = folder.appendingPathComponent("kept/a.txt").path
        Drafts.write(Draft(root: made.path, path: made.path + "/README.md", text: "typed", diskDate: nil))
        Drafts.write(Draft(root: made.path + "/sub", path: made.path + "/sub/b.txt", text: "from a window on a subfolder", diskDate: nil))
        Drafts.write(Draft(root: folder.path + "/kept", path: other, text: "elsewhere", diskDate: nil))
        // A window still open on the folder above holds its own, and writes it again as it's typed.
        let held = made.path + "/c.txt"
        Drafts.write(Draft(root: folder.path, path: held, text: "in an open window", diskDate: nil))
        XCTAssertEqual(Drafts.all(under: made).count, 3)

        let store = ProjectStore(defaults: defaults)
        store.openFolders = { [self.folder.path] }
        let project = Project(path: made.path).inspected()
        store.projects = [project]
        XCTAssertEqual(store.keptDrafts(in: project), 2, "the warning counts drafts from a closed window on a subfolder too, not an open one's")
        XCTAssertNil(store.moveToTrash(project))
        XCTAssertEqual(Drafts.all(under: made).map(\.path), [held], "nothing comes back if the folder is put back, but the open window keeps its own")
        Drafts.remove(for: URL(fileURLWithPath: held))
        XCTAssertEqual(Drafts.all(under: folder).map(\.path), [other])
    }

    /// A window open on a folder above a trashed project closes the project's tabs, unsaved ones
    /// included, and lets their drafts go, as the warning said. Its other tabs stay.
    @MainActor
    func testAWindowAboveATrashedProjectClosesItsTabs() throws {
        let suite = "ProcessCodeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = folder.appendingPathComponent("above-trash")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(root.path, forKey: "projectsFolder")
        let made = try ProjectStore.create(name: "doomed", readme: true, in: root.path).get()
        let outside = root.appendingPathComponent("notes.txt")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        let readme = made.appendingPathComponent("README.md")
        workspace.open(readme)
        workspace.open(outside)
        let document = try XCTUnwrap(workspace.documents.first)
        try XCTUnwrap(document.editor).textView.insertText("typed", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(document.keepDraft(now: true))
        XCTAssertEqual(Drafts.all(under: made).count, 1)

        let store = ProjectStore(defaults: defaults)
        store.openFolders = { [root.path] }
        store.unsavedInWindows = { Workspace.unsavedCount(under: $0, in: [workspace]) }
        store.closeInWindows = { workspace.closeTrashed($0) }
        let project = Project(path: made.path).inspected()
        store.projects = [project]
        XCTAssertEqual(store.unsavedInWindows(project.url), 1)
        XCTAssertNil(store.moveToTrash(project))
        XCTAssertEqual(workspace.documents.map(\.url.path), [outside.path], "the project's tab closed; the one outside stayed")
        XCTAssertEqual(Drafts.all(under: made).count, 0, "and its draft went with it")
    }

    /// A window open on a folder above a project counts the unsaved files inside it, for the
    /// Trash warning; saved ones and those elsewhere don't count.
    @MainActor
    func testAWindowCountsItsUnsavedFilesInsideAFolder() throws {
        let root = folder.appendingPathComponent("above")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
        let files = ["app/a.txt", "app/b.txt", "c.txt"].map { root.appendingPathComponent($0) }
        for file in files { try "x".write(to: file, atomically: true, encoding: .utf8) }
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        files.forEach { workspace.open($0) }
        for index in [0, 2] {
            let editor = try XCTUnwrap(workspace.documents[index].editor)
            editor.textView.insertText("!", replacementRange: NSRange(location: 1, length: 0))
        }
        let app = root.appendingPathComponent("app")
        XCTAssertEqual(workspace.unsavedPaths(under: app), [files[0].path], "a.txt; b.txt is saved and c.txt is outside")
        XCTAssertEqual(workspace.unsavedPaths(under: root.appendingPathComponent("app/")), [files[0].path])
        XCTAssertEqual(workspace.unsavedPaths(under: root.appendingPathComponent("ap")), [], "a name that starts the same isn't inside")

        // A second window, on the folder itself, with the same file unsaved there too: still one file.
        let inner = Workspace(root: app, launchAgent: false)
        defer { inner.close() }
        inner.open(files[0])
        try XCTUnwrap(inner.documents.first?.editor).textView.insertText("?", replacementRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(Workspace.unsavedCount(under: app, in: [workspace, inner]), 1, "a file open in two windows counts once")
        XCTAssertEqual(Workspace.unsavedCount(under: root, in: [workspace, inner]), 2, "a.txt and c.txt")
        for document in workspace.documents + inner.documents where document.isDirty { document.reload() }
    }

    /// In tests nobody can answer a question on screen, so each one gets an answer that changes
    /// nothing (AppTestCase), instead of waiting there and hanging the run.
    @MainActor
    func testQuestionsAnswerThemselvesUnderTests() throws {
        XCTAssertNil(Workspace.ask("Rename", detail: "", value: "a", action: "Rename"), "a name asked for is cancelled")
        XCTAssertEqual(NSOpenPanel().choose(), .cancel)

        let root = folder.appendingPathComponent("questions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        workspace.open(file)
        let document = try XCTUnwrap(workspace.documents.first)
        try XCTUnwrap(document.editor).textView.insertText("!", replacementRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(document.isDirty)

        // Not a git repository and unsaved: the Trash asks, and Cancel keeps the file.
        workspace.trash(file)
        let deadline = Date().addingTimeInterval(10)
        while !workspace.trashing.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(workspace.trashing.isEmpty)
        XCTAssertTrue(Workspace.exists(file), "the Trash question is cancelled")

        // Closing asks about the unsaved change, and Don't Save leaves the file as it was.
        XCTAssertTrue(workspace.close(document))
        XCTAssertTrue(workspace.documents.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "x")
    }

    /// A folder and then a file inside it, both sent to the Trash before git answers: if the
    /// folder goes first, the file went with it, so its own move neither asks nor fails.
    @MainActor
    func testTrashingAFileAfterItsFolderLeavesNothingToReport() throws {
        let root = folder.appendingPathComponent("overlap")
        let dir = root.appendingPathComponent("dir"), file = dir.appendingPathComponent("a.txt")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "a".write(to: file, atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "first"]] {
            XCTAssertEqual(Shell.run("/usr/bin/env", ["git"] + arguments, in: root).status, 0)
        }
        var told: [String] = []
        Workspace.toldInstead = { title, _ in told.append(title) }
        defer { Workspace.toldInstead = nil }
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }

        workspace.trash(dir)
        workspace.trash(file)
        let deadline = Date().addingTimeInterval(10)
        while !workspace.trashing.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(workspace.trashing.isEmpty)
        XCTAssertFalse(Workspace.exists(dir))
        XCTAssertEqual(told, [], "nothing to say: the file is in the Trash with its folder")
        // Git may answer for the file first, which then goes on its own: undo all there is.
        while workspace.fileUndo.canUndo { workspace.fileUndo.undo() }
        XCTAssertTrue(Workspace.exists(file), "undo puts it all back")
    }

    /// ⌘Z in an editor undoes whichever came last, the typing there or a file moved to the Trash,
    /// wherever the keyboard is after the Trash.
    @MainActor
    func testUndoInAnEditorPutsBackAFileTrashedSinceTheTyping() throws {
        let root = folder.appendingPathComponent("undo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let open = root.appendingPathComponent("a.txt"), trashed = root.appendingPathComponent("b.txt")
        try "a".write(to: open, atomically: true, encoding: .utf8)
        try "b".write(to: trashed, atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "first"]] {
            XCTAssertEqual(Shell.run("/usr/bin/env", ["git"] + arguments, in: root).status, 0)
        }
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        workspace.open(open)
        let editor = try XCTUnwrap(workspace.documents.first?.editor)
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.textView.insertText("!", replacementRange: editor.textView.selectedRange())
        editor.textView.breakUndoCoalescing()
        XCTAssertEqual(editor.text, "a!")

        workspace.trash(trashed)
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: trashed.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))

        editor.textView.undo(nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path), "the Trash came after the typing, so it's undone first")
        XCTAssertEqual(editor.text, "a!")
        editor.textView.undo(nil)
        XCTAssertEqual(editor.text, "a", "then the typing")

    }

    /// A step AppKit removes by its target (a text field's, when its editing ends) takes its time
    /// with it, so it can't make an older step look newer; a step that acts on more than that
    /// target keeps its time.
    @MainActor
    func testAnUndoStepRemovedByItsTargetTakesItsTimeWithIt() {
        final class Target: NSObject {}
        let history = ClockedUndoManager(), mine = Target(), field = Target()
        // Each action registers its counterpart, as a real one does, so undo leaves something to redo.
        func register(_ target: Target) { history.registerUndo(withTarget: target) { _ in register(target) } }
        func step(_ targets: Target...) {
            targets.forEach(register)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        step(mine)
        let first = history.time(redo: false)
        XCTAssertNotNil(first)
        step(field)
        XCTAssertNotEqual(history.time(redo: false), first)
        history.removeAllActions(withTarget: field)
        XCTAssertEqual(history.time(redo: false), first, "the field's step went, and its time with it")

        step(mine, field)
        let both = history.time(redo: false)
        history.removeAllActions(withTarget: field)
        XCTAssertEqual(history.time(redo: false), both, "a step that also acts on something else stays")

        history.undo()
        history.undo()
        XCTAssertNil(history.time(redo: false))
        XCTAssertEqual(history.time(redo: true), first, "undone last, so redone first")

        // An undo that fails registers nothing to redo, and takes no time onto the redo stack.
        history.registerUndo(withTarget: mine) { _ in }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        step(mine)
        let top = history.time(redo: false)
        history.undo()
        XCTAssertEqual(history.time(redo: true), top)
        history.undo()
        XCTAssertEqual(history.time(redo: true), top, "the failed one left nothing to redo")
    }

    /// Undo and redo go back and forth through typing and the Trash in the order they happened,
    /// however they're interleaved: each step is ordered by when it was made, not by when its
    /// history last changed.
    @MainActor
    func testUndoAndRedoKeepTheOrderOfTypingAndTheTrash() throws {
        let root = folder.appendingPathComponent("undo-order")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let open = root.appendingPathComponent("a.txt")
        let first = root.appendingPathComponent("b.txt"), second = root.appendingPathComponent("c.txt")
        for file in [open, first, second] { try "x".write(to: file, atomically: true, encoding: .utf8) }
        for arguments in [["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "first"]] {
            XCTAssertEqual(Shell.run("/usr/bin/env", ["git"] + arguments, in: root).status, 0)
        }
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        workspace.open(open)
        let editor = try XCTUnwrap(workspace.documents.first?.editor)
        let text = editor.textView
        func type(_ string: String) {
            text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
            text.insertText(string, replacementRange: text.selectedRange())
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        func trash(_ url: URL) {
            workspace.trash(url)
            let deadline = Date().addingTimeInterval(10)
            while FileManager.default.fileExists(atPath: url.path), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        // A Trash, typing, another Trash: putting the newer file back doesn't make the older one newer than the typing.
        trash(first)
        type("1")
        trash(second)
        text.undo(nil)
        XCTAssertTrue(exists(second))
        text.undo(nil)
        XCTAssertEqual(editor.text, "x", "the typing came between the two")
        XCTAssertFalse(exists(first))
        text.undo(nil)
        XCTAssertTrue(exists(first))
        text.redo(nil)
        XCTAssertFalse(exists(first), "redo goes forward in the same order")
        XCTAssertEqual(editor.text, "x")
        text.redo(nil)
        XCTAssertEqual(editor.text, "x1")
        XCTAssertTrue(exists(second))
        text.redo(nil)
        XCTAssertFalse(exists(second))

        // Typing, a Trash, typing: undoing the newer typing doesn't make the older typing newer than the Trash.
        try "x".write(to: first, atomically: true, encoding: .utf8)
        type("2")
        trash(first)
        type("3")
        text.undo(nil)
        XCTAssertEqual(editor.text, "x12", "the typing after the Trash, apart from the typing before it")
        text.undo(nil)
        XCTAssertTrue(exists(first), "then the Trash")
        XCTAssertEqual(editor.text, "x12")
        text.undo(nil)
        XCTAssertEqual(editor.text, "x1")

        XCTAssertTrue(CodeTextView.undoesFiles(files: 5, text: 3, redo: false))
        XCTAssertFalse(CodeTextView.undoesFiles(files: 3, text: 5, redo: false), "typing after the Trash is undone first")
        XCTAssertTrue(CodeTextView.undoesFiles(files: 3, text: nil, redo: false), "with no typing left, the files")
        XCTAssertFalse(CodeTextView.undoesFiles(files: nil, text: 3, redo: false))
        XCTAssertTrue(CodeTextView.undoesFiles(files: 3, text: 5, redo: true), "the older step, undone last, is redone first")
    }

    @MainActor
    func testClosingOtherTabsAndAllTabs() throws {
        let root = folder.appendingPathComponent("tabs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = ["a.txt", "b.txt", "c.txt"].map { root.appendingPathComponent($0) }
        for file in files { try "x".write(to: file, atomically: true, encoding: .utf8) }
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        files.forEach { workspace.open($0) }
        workspace.open(files[2], toSide: true)
        let b = try XCTUnwrap(workspace.documents.first { $0.name == "b.txt" })

        XCTAssertTrue(workspace.closeTabs(keeping: b))
        XCTAssertEqual(workspace.documents.map(\.name), ["b.txt"])
        XCTAssertEqual(workspace.activeDocumentID, b.id)
        XCTAssertNil(workspace.sideDocumentID, "the side pane's file went with the others")

        workspace.open(files[0])
        XCTAssertTrue(workspace.closeTabs())
        XCTAssertEqual(workspace.documents.count, 0)
        XCTAssertTrue(workspace.terminalVisible, "with no files left, the terminal shows")
    }

    @MainActor
    func testRenamingMovesTheOpenFilesWithIt() throws {
        let root = folder.appendingPathComponent("renamed")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("src/a.txt")
        try "a".write(to: file, atomically: true, encoding: .utf8)
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        workspace.open(file)

        workspace.rename(root.appendingPathComponent("src"), to: "lib")
        XCTAssertEqual(workspace.documents.map { workspace.relativePath(of: $0.url) }, ["lib/a.txt"], "a renamed folder's open files follow it")
        workspace.rename(root.appendingPathComponent("lib/a.txt"), to: "b.txt")
        XCTAssertEqual(workspace.documents.map { workspace.relativePath(of: $0.url) }, ["lib/b.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("lib").path), ["b.txt"],
                       "nothing is left under the old name")
    }

    /// A rename keeps each open file's tab in its place, with its text's undo history and the side
    /// pane; one whose new name makes it another kind of file opens afresh in the same place.
    @MainActor
    func testARenameKeepsTheTabsInTheirPlaces() throws {
        let root = folder.appendingPathComponent("rename-keeps")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let files = ["src/a.txt", "other.txt", "src/b.txt"].map { root.appendingPathComponent($0) }
        for file in files { try "x".write(to: file, atomically: true, encoding: .utf8) }
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        files.forEach { workspace.open($0) }
        workspace.open(files[2], toSide: true)
        let before = workspace.documents, side = workspace.sideDocumentID
        let editor = try XCTUnwrap(before[0].editor)
        editor.textView.insertText("!", replacementRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(workspace.save(before[0]))

        workspace.rename(root.appendingPathComponent("src"), to: "lib")
        XCTAssertTrue(workspace.documents.elementsEqual(before, by: ===), "the same tabs, in the same order")
        XCTAssertEqual(workspace.documents.map { workspace.relativePath(of: $0.url) }, ["lib/a.txt", "other.txt", "lib/b.txt"])
        XCTAssertEqual(workspace.sideDocumentID, side)
        editor.textView.undo(nil)
        XCTAssertEqual(editor.text, "x", "the typing before the rename can still be undone")
        // Saved again, so the next rename has no unsaved changes to ask about: a test can't answer
        // the question, and it would wait on screen until closed by hand.
        XCTAssertTrue(workspace.save(before[0]))

        workspace.rename(root.appendingPathComponent("lib/a.txt"), to: "a.md")
        XCTAssertFalse(workspace.documents[0] === before[0], "Markdown is another kind of file, with a preview")
        XCTAssertEqual(workspace.documents.map { workspace.relativePath(of: $0.url) }, ["lib/a.md", "other.txt", "lib/b.txt"])
        XCTAssertEqual(workspace.sideDocumentID, side)
    }

    /// A LaTeX build that was running when its file was renamed doesn't leave the old name's
    /// result on the tab: it builds again at the new name.
    @MainActor
    func testABuildRunningThroughARenameBuildsAtTheNewName() throws {
        let root = folder.appendingPathComponent("rename-build")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".vscode"), withIntermediateDirectories: true)
        // A stand-in for latexmk: a moment's work, then a PDF beside the file, if the file is still there.
        let settings = """
        {
          "latex-workshop.latex.recipes": [{ "name": "fake", "tools": ["fake"] }],
          "latex-workshop.latex.tools": [
            { "name": "fake", "command": "bash", "args": ["-c", "sleep 0.5; test -f \\"%DOC_EXT%\\" && printf x > \\"%DOC%.pdf\\""] }
          ]
        }
        """
        try settings.write(to: root.appendingPathComponent(".vscode/settings.json"), atomically: true, encoding: .utf8)
        let paper = root.appendingPathComponent("paper.tex")
        try "\\documentclass{article}".write(to: paper, atomically: true, encoding: .utf8)
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        workspace.open(paper)
        let document = try XCTUnwrap(workspace.documents.first)
        workspace.build(document)
        XCTAssertEqual(document.build, .running)

        workspace.rename(paper, to: "essay.tex")
        XCTAssertTrue(workspace.documents.first === document, "the tab followed the file")
        let deadline = Date().addingTimeInterval(15)
        while document.build == .running || document.build == .idle, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(document.build, .succeeded, "built again at the new name, not failed at the old one")
        XCTAssertEqual(document.pdfURL?.lastPathComponent, "essay.pdf")
    }

    /// A LaTeX file saved for a rename that then can't be done is built where it still is, so its
    /// PDF matches the text on disk.
    @MainActor
    func testALatexFileSavedForARenameThatFailsIsStillBuilt() throws {
        let root = folder.appendingPathComponent("rename-build-fails")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".vscode"), withIntermediateDirectories: true)
        let settings = """
        {
          "latex-workshop.latex.recipes": [{ "name": "fake", "tools": ["fake"] }],
          "latex-workshop.latex.tools": [{ "name": "fake", "command": "bash", "args": ["-c", "printf x > \\"%DOC%.pdf\\""] }]
        }
        """
        try settings.write(to: root.appendingPathComponent(".vscode/settings.json"), atomically: true, encoding: .utf8)
        let paper = root.appendingPathComponent("paper.tex"), taken = root.appendingPathComponent("essay.tex")
        for file in [paper, taken] { try "\\documentclass{article}".write(to: file, atomically: true, encoding: .utf8) }
        Workspace.toldInstead = { _, _ in }
        NSAlert.answering = { AppTestCase.press(["Save"], in: $0) }
        defer { Workspace.toldInstead = nil }
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        workspace.open(paper)
        let document = try XCTUnwrap(workspace.documents.first)
        try XCTUnwrap(document.editor).textView.insertText("%", replacementRange: NSRange(location: 0, length: 0))

        workspace.rename(paper, to: "essay.tex")   // the name is taken, so the move fails
        XCTAssertFalse(document.isDirty, "saved before the move was tried")
        XCTAssertEqual(document.url, paper)
        let deadline = Date().addingTimeInterval(15)
        while document.build == .running || document.build == .idle, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(document.build, .succeeded, "built at the name it kept")
        XCTAssertEqual(document.pdfURL?.lastPathComponent, "paper.pdf")
    }

    /// A rename that can't be done leaves the tabs as they were: the same documents, in the same
    /// order, with the side pane and each one's undo history.
    @MainActor
    func testARenameThatFailsLeavesTheTabsAlone() throws {
        let root = folder.appendingPathComponent("rename-fails")
        for folder in ["src", "lib"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let files = ["src/a.txt", "other.txt", "src/b.txt"].map { root.appendingPathComponent($0) }
        for file in files { try "x".write(to: file, atomically: true, encoding: .utf8) }
        var told: [String] = []
        Workspace.toldInstead = { title, _ in told.append(title) }
        defer { Workspace.toldInstead = nil }
        let workspace = Workspace(root: root, launchAgent: false)
        defer { workspace.close() }
        files.forEach { workspace.open($0) }
        workspace.open(files[2], toSide: true)
        let before = workspace.documents, side = workspace.sideDocumentID

        workspace.rename(root.appendingPathComponent("src"), to: "lib")
        XCTAssertEqual(told, ["Couldn't rename “src”"], "lib is taken")
        XCTAssertTrue(workspace.documents.elementsEqual(before, by: ===), "the same tabs, in the same order")
        XCTAssertEqual(workspace.sideDocumentID, side)
    }

    func testADraftThatCantBeWrittenIsReported() throws {
        let blocked = folder.appendingPathComponent("blocked")
        try "a file where the folder would go".write(to: blocked, atomically: true, encoding: .utf8)
        Drafts.folder = blocked.appendingPathComponent("drafts")
        XCTAssertFalse(Drafts.writeNow(Draft(root: "/p", path: "/p/a.txt", text: "x", diskDate: nil)))
        Drafts.folder = folder.appendingPathComponent("drafts")
        XCTAssertTrue(Drafts.writeNow(Draft(root: "/p", path: "/p/a.txt", text: "x", diskDate: nil)))
    }

    @MainActor
    func testClosingAWindowKeepsUnsavedTextOrSaysItCant() throws {
        let file = folder.appendingPathComponent("a.txt")
        try "on disk".write(to: file, atomically: true, encoding: .utf8)
        let document = Document(url: file)
        document.restore(Draft(root: folder.path, path: file.path, text: "typed", diskDate: nil))
        XCTAssertFalse(document.keepDraft(now: true), "with nowhere to keep it, the window asks about it")
        document.draftRoot = folder
        XCTAssertTrue(document.keepDraft(now: true))
        XCTAssertEqual(Drafts.all(root: folder).map(\.text), ["typed"])
    }

    /// A stand-in for gh, first on the PATH: signing in prints a code and waits a moment, then
    /// succeeds or fails; everything else succeeds.
    private func fakeGitHubCLI(signInSucceeds: Bool) throws -> String {
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1 $2" = "auth login" ]; then
          echo "! One-time code (AB12-CD34) copied to clipboard"
          sleep 1
          \(signInSucceeds ? "exit 0" : "echo 'error: the code expired'; exit 1")
        fi
        [ "$1 $2" = "repo list" ] && echo "[]"
        exit 0
        """
        let gh = bin.appendingPathComponent("gh")
        try script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", bin.path + ":" + path, 1)
        return path
    }

    @MainActor
    private func signIn(succeeds: Bool) throws -> (store: ProjectStore, opened: [URL], copied: [String]) {
        let oldPath = try fakeGitHubCLI(signInSucceeds: succeeds)
        defer { setenv("PATH", oldPath, 1) }
        let store = ProjectStore(defaults: UserDefaults(suiteName: "ProcessCodeTests.\(UUID().uuidString)")!)
        store.githubSetup = .signedOut
        var opened: [URL] = [], copied: [String] = []
        store.openPage = { opened.append($0) }
        store.copyText = { copied.append($0) }
        store.signInToGitHub()
        var sawCode = false
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if store.setupStep == .signingIn(code: "AB12-CD34") { sawCode = true }
            if case .failed = store.setupStep { break }
            if store.setupStep == .idle, store.githubSetup == nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(sawCode, "the code is shown while GitHub waits for it")
        return (store, opened, copied)
    }

    @MainActor
    func testSigningInShowsTheCodeOpensGitHubAndClearsTheNote() throws {
        let result = try signIn(succeeds: true)
        XCTAssertEqual(result.opened, [ProjectStore.deviceLoginPage])
        XCTAssertEqual(result.copied, ["AB12-CD34"])
        XCTAssertEqual(result.store.setupStep, .idle)
        XCTAssertNil(result.store.githubSetup, "signed in, the note goes")
    }

    @MainActor
    func testAFailedSignInSaysWhy() throws {
        let result = try signIn(succeeds: false)
        guard case .failed(let message) = result.store.setupStep else { return XCTFail("\(result.store.setupStep)") }
        XCTAssertTrue(message.contains("the code expired"))
        XCTAssertEqual(result.store.githubSetup, .signedOut)
    }

    func testACheckThatCantReachGitHubChangesOnlyWhatItMust() {
        let slow = Shell.Result(status: 124, output: "gh didn't answer within 30 seconds and was stopped.")
        let offline = Shell.Result(status: 1, output: "error connecting to api.github.com")
        let signedOut = Shell.Result(status: 1, output: "You are not logged into any GitHub hosts. To log in, run: gh auth login")
        XCTAssertNil(ProjectStore.githubSetup(after: slow, was: .signedOut, signedIn: true), "a sign-in that just succeeded counts")
        XCTAssertNil(ProjectStore.githubSetup(after: offline, was: .signedOut, signedIn: true))
        XCTAssertEqual(ProjectStore.githubSetup(after: slow, was: .signedOut, signedIn: false), .signedOut, "Check Again, still unknown")
        XCTAssertNil(ProjectStore.githubSetup(after: offline, was: nil, signedIn: false), "a working setup isn't undone by a slow network")
        XCTAssertEqual(ProjectStore.githubSetup(after: slow, was: .notInstalled, signedIn: false), .signedOut, "gh answered, so it's installed")
        XCTAssertEqual(ProjectStore.githubSetup(after: signedOut, was: nil, signedIn: false), .signedOut)
        XCTAssertNil(ProjectStore.githubSetup(after: Shell.Result(status: 0, output: ""), was: .signedOut, signedIn: false))
    }

    func testSignInReadsTheOneTimeCode() {
        XCTAssertEqual(ProjectStore.deviceCode(in: "! One-time code (AB12-CD34) copied to clipboard\nOpen this URL…"), "AB12-CD34")
        XCTAssertEqual(ProjectStore.deviceCode(in: "! First copy your one-time code: 9F3E-1A2B\n"), "9F3E-1A2B", "as older versions say it")
        XCTAssertNil(ProjectStore.deviceCode(in: "Open this URL to continue in your web browser: https://github.com/login/device"))
        XCTAssertEqual(ProjectStore.lastLines(of: "a\nb\nc\nd\n", count: 2), "c\nd")
    }

    /// A clone or publish that fails for want of a sign-in says so, so its sheet can offer the button.
    func testCloneAndPublishFailuresSayWhenGitHubNeedsSigningIn() throws {
        let bin = folder.appendingPathComponent("signed-out-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let gh = bin.appendingPathComponent("gh")
        try "#!/bin/sh\necho 'To get started with GitHub CLI, please run:  gh auth login' >&2\nexit 4\n"
            .write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", bin.path + ":" + oldPath, 1)
        defer { setenv("PATH", oldPath, 1) }

        let root = folder.appendingPathComponent("projects").path
        guard case .failure(let clone) = ProjectStore.clone("owner/app", into: root) else { return XCTFail("the clone should fail") }
        XCTAssertEqual(clone.setup, .signedOut)

        let local = folder.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        Shell.run("/usr/bin/env", ["git", "init", "-q"], in: local)
        guard case .failure(let publish) = ProjectStore.publish(Project(path: local.path), name: "local", description: "", isPrivate: true)
        else { return XCTFail("the publish should fail") }
        XCTAssertEqual(publish.setup, .signedOut)

        guard case .failure(let byURL) = ProjectStore.clone("file:///nowhere/at/all.git", into: root) else { return XCTFail() }
        XCTAssertNil(byURL.setup, "a clone by URL uses git, not GitHub's sign-in")
    }

    func testProjectTrashCountsUnsavedDrafts() {
        let project = Project(path: "/p/app")
        XCTAssertTrue(ProjectStore.trashWarning(for: project, drafts: 2).hasPrefix("2 files in it have unsaved changes"))
    }

    // MARK: Errors

    func testFileErrorsSayWhatToDo() {
        XCTAssertTrue(Workspace.explain(CocoaError(.fileWriteOutOfSpace)).hasPrefix("The disk is full."))
        XCTAssertTrue(Workspace.explain(CocoaError(.fileWriteFileExists)).contains("Choose another name"))
        XCTAssertTrue(Workspace.explain(CocoaError(.fileWriteNoPermission)).contains("Privacy & Security"))
    }

    func testGitHubFailuresKeepWhatTheToolSaidAndAddTheWayOut() {
        let signedOut = Shell.Result(status: 4, output: "You are not logged into any GitHub hosts. To log in, run: gh auth login\n")
        XCTAssertEqual(ProjectStore.githubSetup(from: signedOut), .signedOut)
        let message = ProjectStore.explain(signedOut, tool: "gh")
        XCTAssertTrue(message.hasPrefix("You are not logged into any GitHub hosts."), "what gh said comes first")
        XCTAssertTrue(message.hasSuffix("Run gh auth login in a terminal, then try again."))
        XCTAssertEqual(ProjectStore.githubSetup(from: Shell.Result(status: 127, output: "env: gh: No such file or directory")), .notInstalled)
        XCTAssertNil(ProjectStore.githubSetup(from: Shell.Result(status: 1, output: "error connecting to api.github.com")),
                     "a network failure isn't a setup problem")
        XCTAssertTrue(ProjectStore.explain(Shell.Result(status: 1, output: "GraphQL: Name already exists on this account (createRepository)"), tool: "gh")
            .contains("Choose another name"))
        XCTAssertEqual(ProjectStore.explain(Shell.Result(status: 1, output: "something new"), tool: "gh"), "something new")
        XCTAssertEqual(ProjectStore.explain(Shell.Result(status: 1, output: ""), tool: "git"), "git stopped without saying why.")
    }

    // MARK: Agent

    func testClaudeCarriesOnOnlyWhenThereIsAConversation() throws {
        let home = folder.appendingPathComponent("home")
        let project = URL(fileURLWithPath: "/Users/x/My Projects/app.v2")
        XCTAssertEqual(Agent.claudeFolderName(for: project.path), "-Users-x-My-Projects-app-v2")
        let claude = Agent.presets[0]
        XCTAssertFalse(claude.hasConversation(in: project, home: home.path))
        let store = home.appendingPathComponent(".claude/projects/-Users-x-My-Projects-app-v2")
        try FileManager.default.createDirectory(at: store.appendingPathComponent("memory"), withIntermediateDirectories: true)
        XCTAssertFalse(claude.hasConversation(in: project, home: home.path), "a folder of memories isn't a conversation")
        try Data().write(to: store.appendingPathComponent("1234.jsonl"))
        XCTAssertTrue(claude.hasConversation(in: project, home: home.path))
        XCTAssertFalse(Agent.presets[1].hasConversation(in: project, home: home.path), "Codex starts fresh")
        XCTAssertEqual(TerminalSession.arguments(shell: "/bin/zsh", agent: claude, resume: true),
                       ["-l", "-i", "-c", "__pc_started=$(date +%s); claude --continue || { [ $? -eq 1 ] && [ $(($(date +%s) - __pc_started)) -lt 10 ] && claude; }; exec /bin/zsh -l"])
        XCTAssertEqual(TerminalSession.arguments(shell: "/opt/homebrew/bin/fish", agent: claude, resume: true),
                       ["-l", "-i", "-c", "claude --continue; exec /opt/homebrew/bin/fish -l"], "fish keeps the plain resume")
        XCTAssertEqual(TerminalSession.arguments(shell: "/bin/zsh", agent: Agent.presets[1], resume: true),
                       ["-l", "-i", "-c", "codex; exec /bin/zsh -l"])
    }

    func testClaudesLongAndNonASCIIFolderNamesAreFound() throws {
        let projects = folder.appendingPathComponent("home/.claude/projects")
        XCTAssertEqual(Agent.claudeFolderName(for: "/a/caf\u{e9}/\u{1F680}"), "-a-caf----", "é and / are a dash each, and the emoji is two UTF-16 units, so two")
        // A long name is cut to 200 and given Claude Code's hash of the whole path. These are the
        // names Claude Code's own code gives (run in node).
        let long = "/Users/x/" + String(repeating: "a-very-long-folder-name/", count: 10) + "app"
        XCTAssertEqual(Agent.claudeFolderName(for: long), "-Users-x-" + String(repeating: "a-very-long-folder-name-", count: 8).dropLast() + "-wtgfru")
        let emoji = "/Users/x/\u{1F389} " + String(repeating: "deep/", count: 45) + "\u{e9}"
        XCTAssertEqual(Agent.claudeFolderName(for: emoji), "-Users-x----" + String(repeating: "deep-", count: 37) + "dee-dxcj84")
        XCTAssertEqual(Agent.claudeHash("a"), 97)
        XCTAssertEqual(Agent.claudeHash("/Users/x"), 1825244930)

        let home = folder.appendingPathComponent("home").path
        let sibling = String(long.dropLast(3)) + "web"
        XCTAssertEqual(Agent.claudeFolderName(for: sibling).prefix(Agent.claudeNameLimit), Agent.claudeFolderName(for: long).prefix(Agent.claudeNameLimit))
        let store = projects.appendingPathComponent(Agent.claudeFolderName(for: sibling))
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data().write(to: store.appendingPathComponent("1.jsonl"))
        XCTAssertTrue(Agent.presets[0].hasConversation(in: URL(fileURLWithPath: sibling), home: home))
        XCTAssertFalse(Agent.presets[0].hasConversation(in: URL(fileURLWithPath: long), home: home),
                       "a folder whose name starts the same isn't this one")
    }

    /// A folder's conversations are its sessions' files, each with when it was written last. A
    /// subagent's transcript isn't one.
    func testTheConversationsAreTheSessionsFiles() throws {
        let home = folder.appendingPathComponent("home-latest")
        let project = folder.appendingPathComponent("latest-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let claude = Agent.presets[0]
        XCTAssertEqual(claude.conversations(in: project, home: home.path), [])
        let store = Agent.claudeFolder(for: project.resolvingSymlinksInPath().path, in: home.appendingPathComponent(".claude/projects"))
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let older = Date(timeIntervalSince1970: 1_000_000), newer = Date(timeIntervalSince1970: 2_000_000)
        for (name, date) in [("a.jsonl", older), ("b.jsonl", newer), ("notes.txt", Date()), ("agent-1f2e.jsonl", Date())] {
            let file = store.appendingPathComponent(name)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        let found = claude.conversations(in: project, home: home.path).sorted { $0.written < $1.written }
        XCTAssertEqual(found, [Agent.Conversation(session: "a", written: older), Agent.Conversation(session: "b", written: newer)],
                       "only conversations count, not notes or a subagent's transcript")
        XCTAssertEqual(Agent.presets[1].conversations(in: project, home: home.path), [], "Codex keeps none here")
    }

    /// Claude Code names a folder's conversations by its real path: /private/tmp for /tmp. The
    /// folder is found under that name whichever spelling the window was opened with.
    func testConversationsAreFoundUnderTheFoldersRealPath() throws {
        let home = folder.appendingPathComponent("home-real")
        let project = URL(fileURLWithPath: "/tmp").appendingPathComponent("pc-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let real = try XCTUnwrap(Agent.realPath(project.path))
        XCTAssertTrue(real.hasPrefix("/private/tmp/"), real)
        XCTAssertEqual(project.resolvingSymlinksInPath().path, project.path, "Foundation spells it /tmp")
        let store = Agent.claudeFolder(for: real, in: home.appendingPathComponent(".claude/projects"))
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data().write(to: store.appendingPathComponent("s.jsonl"))
        for spelling in [project, URL(fileURLWithPath: real)] {
            XCTAssertEqual(Agent.presets[0].conversations(in: spelling, home: home.path).map(\.session), ["s"], spelling.path)
        }
        XCTAssertNil(Agent.realPath("/no/such/folder/\(UUID().uuidString)"))
    }

    /// The resume, run for real in each shell, against a stand-in for claude.
    func testAResumeWithNothingToContinueStartsFresh() throws {
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try """
        #!/bin/sh
        if [ "$1" = "--continue" ]; then
          [ "$MODE" = ended ] && sleep 3
          [ "$MODE" = continued ] && { echo continued; exit 0; }
          [ "$MODE" = interrupted ] && { echo interrupted; exit 130; }
          echo "No conversation found to continue"; exit 1
        fi
        echo fresh
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        // The clock counts whole seconds, so the quick cases take 0 or 1 of them and the slow one 3.
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh", "/bin/ksh", "/bin/dash"] {
            let command = TerminalSession.startCommand(agent: Agent.presets[0], resume: true, shell: shell, grace: 2)
            func run(_ mode: String) -> String {
                var environment = Shell.environment
                environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "")
                environment["MODE"] = mode
                return Shell.run(shell, ["-c", command], timeout: 20, environment: environment).output
            }
            XCTAssertEqual(run("none"), "No conversation found to continue\nfresh\n", shell)
            XCTAssertEqual(run("continued"), "continued\n", shell)
            XCTAssertEqual(run("ended"), "No conversation found to continue\n", "\(shell): a conversation that ended later isn't followed by a new one")
            XCTAssertEqual(run("interrupted"), "interrupted\n", "\(shell): only exit status 1 says there was nothing to continue")
        }
    }
}
