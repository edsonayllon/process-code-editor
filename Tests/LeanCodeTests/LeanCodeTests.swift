import XCTest
@testable import LeanCode

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
        for name in ["cover-letter.pdf", "edson-resume.pdf"] { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        XCTAssertEqual(Latex.existingPDF(for: folder.appendingPathComponent("resume.tex"))?.lastPathComponent, "edson-resume.pdf")
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
        XCTAssertTrue(env.contains("TERM_PROGRAM=LeanCode"))
        XCTAssertTrue(env.contains("TERM=xterm-256color"))
        XCTAssertTrue(env.contains("COLORTERM=truecolor"))
        XCTAssertTrue(env.contains("HOME=/Users/x"))
        XCTAssertTrue(env.contains("LANG=en_US.UTF-8"))
    }
}

final class WorkspaceTests: XCTestCase {
    func testGoToFileRanksNameMatchesFirst() {
        let files = ["Sources/LeanCode/Git.swift", "docs/git-notes/intro.md", "Sources/LeanCode/Settings.swift", "README.md"]
        XCTAssertEqual(Workspace.match("git", in: files).first, "Sources/LeanCode/Git.swift")
        XCTAssertEqual(Workspace.match("stgs", in: files), ["Sources/LeanCode/Settings.swift"], "letters in order still match")
        XCTAssertEqual(Workspace.match("zzz", in: files), [])
    }

    func testIndentIsReadFromTheFile() {
        XCTAssertEqual(EditorController.indentUnit(of: "a {\n  b\n}", language: .swift), "  ")
        XCTAssertEqual(EditorController.indentUnit(of: "a {\n\tb\n}", language: .swift), "\t")
        XCTAssertEqual(EditorController.indentUnit(of: "a", language: .swift), "    ")
    }

    func testAgentSetting() {
        let defaults = UserDefaults(suiteName: "LeanCodeTests.\(UUID().uuidString)")!
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
        project.read(status: "# branch.oid (initial)\n# branch.head (detached)\n")
        XCTAssertEqual(project.branch, "detached")
        XCTAssertEqual(project.changes, 0)
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
    }
}
