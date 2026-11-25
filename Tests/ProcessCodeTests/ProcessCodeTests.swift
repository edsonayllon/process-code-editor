import XCTest
@testable import ProcessCode

final class GitStatusTests: XCTestCase {
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

final class LexerTests: XCTestCase {
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

final class MarkdownTests: XCTestCase {
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

final class LatexTests: XCTestCase {
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

final class TerminalTests: XCTestCase {
    func testShellEscaping() {
        XCTAssertEqual(LeanTerminalView.shellEscaped("/a/b-c_d.png"), "/a/b-c_d.png")
        XCTAssertEqual(LeanTerminalView.shellEscaped("/a/Screen Shot.png"), "'/a/Screen Shot.png'")
        XCTAssertEqual(LeanTerminalView.shellEscaped("/a/it's.png"), "'/a/it'\\''s.png'")
    }

    func testAgentStartsInALoginShellAndLeavesAShellBehind() {
        XCTAssertEqual(TerminalSession.arguments(shell: "/bin/zsh", agent: nil), ["-l"])
        XCTAssertEqual(TerminalSession.arguments(shell: "/bin/zsh", agent: Agent.presets[0]), ["-l", "-i", "-c", "claude; exec /bin/zsh -l"])
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

final class WorkspaceTests: XCTestCase {
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
        settings.agentID = Agent.customID
        XCTAssertNil(settings.agent, "a custom agent with no command is no agent")
        settings.customAgentCommand = "/opt/bin/hermes --fast"
        XCTAssertEqual(settings.agent?.name, "hermes")
        XCTAssertEqual(settings.agent?.command, "/opt/bin/hermes --fast")
    }
}

final class ProjectTests: XCTestCase {
    func testReadsStatus() {
        var project = Project(path: "/r/app")
        project.read(status: "# branch.oid abc\n# branch.head feature/x\n# branch.upstream origin/feature/x\n# branch.ab +2 -1\n1 .M N... 100644 100644 100644 a b file.swift\n? new.txt\n")
        XCTAssertEqual(project.branch, "feature/x")
        XCTAssertEqual(project.ahead, 2)
        XCTAssertEqual(project.behind, 1)
        XCTAssertEqual(project.changes, 2)
        XCTAssertTrue(project.hasUpstream)
        XCTAssertTrue(project.hasCommits)
        project.read(status: "# branch.oid (initial)\n# branch.head (detached)\n")
        XCTAssertEqual(project.branch, "detached")
        XCTAssertEqual(project.changes, 0)
        XCTAssertFalse(project.hasUpstream)
        XCTAssertFalse(project.hasCommits)
    }

    func testGitHubNames() {
        XCTAssertEqual(ProjectStore.githubName(for: "my project"), "my-project")
        XCTAssertEqual(ProjectStore.githubName(for: " Café  & co. "), "Caf-co.")
        XCTAssertEqual(ProjectStore.githubName(for: "already_fine-1.0"), "already_fine-1.0")
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

        var safe = Project(path: "/r/safe", remote: "git@github.com:o/safe.git")
        safe.hasUpstream = true
        XCTAssertEqual(ProjectStore.trashWarning(for: safe),
                       "The folder moves to the Trash, where you can put it back. The repository on GitHub isn't touched.")

        var risky = safe
        risky.changes = 3
        risky.ahead = 1
        risky.hasUpstream = false
        let warning = ProjectStore.trashWarning(for: risky)
        XCTAssertTrue(warning.contains("3 uncommitted changes"))
        XCTAssertTrue(warning.contains("1 commit that isn't pushed"))
        XCTAssertTrue(warning.contains("branch isn't on GitHub"))

        let plainFolder = Project(path: "/r/notes", isRepository: false)
        XCTAssertEqual(ProjectStore.trashWarning(for: plainFolder), "The folder moves to the Trash, where you can put it back.")
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
    }
}
