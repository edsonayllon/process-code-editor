import Foundation

/// Builds a LaTeX file to PDF. A project that already has LaTeX Workshop settings in
/// `.vscode/settings.json` builds the way they say; anything else builds with latexmk.
enum Latex {
    struct Command: Equatable {
        var executable: String
        var arguments: [String]
    }

    struct Result {
        var succeeded: Bool
        var log: String
        var pdf: URL?
    }

    /// The commands that build `tex`, in order.
    static func commands(for tex: URL, root: URL) -> [Command] {
        let settings = root.appendingPathComponent(".vscode/settings.json")
        if let data = try? Data(contentsOf: settings), let commands = recipe(inSettings: data, tex: tex, root: root) {
            return commands
        }
        let source = (try? String(contentsOf: tex, encoding: .utf8)) ?? ""
        return [Command(executable: "latexmk", arguments: [engineFlag(for: source), "-interaction=nonstopmode", "-file-line-error",
                                                           "-halt-on-error", tex.lastPathComponent])]
    }

    /// XeLaTeX or LuaLaTeX when the source asks for it, pdfLaTeX otherwise.
    static func engineFlag(for source: String) -> String {
        let head = String(source.prefix(6000)).lowercased()
        if head.contains("lualatex") || head.contains("luacode") || head.contains("luatex") { return "-lualatex" }
        if head.contains("xelatex") || head.contains("fontspec") || head.contains("xecjk") || head.contains("polyglossia") { return "-xelatex" }
        return "-pdf"
    }

    /// Reads the default LaTeX Workshop recipe from a VS Code settings file (JSON with comments).
    static func recipe(inSettings data: Data, tex: URL, root: URL) -> [Command]? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
              let recipes = json["latex-workshop.latex.recipes"] as? [[String: Any]], !recipes.isEmpty,
              let tools = json["latex-workshop.latex.tools"] as? [[String: Any]] else { return nil }
        let wanted = json["latex-workshop.latex.recipe.default"] as? String
        let recipe = recipes.first { $0["name"] as? String == wanted } ?? recipes[0]
        guard let names = recipe["tools"] as? [String] else { return nil }

        let directory = tex.deletingLastPathComponent().path
        let file = tex.deletingPathExtension().lastPathComponent
        let placeholders: [(String, String)] = [
            ("%DOC_EXT%", tex.path), ("%DOCFILE_EXT%", tex.lastPathComponent),
            ("%DOC%", tex.deletingPathExtension().path), ("%DOCFILE%", file),
            ("%DIR%", directory), ("%OUTDIR%", directory), ("%WORKSPACE_FOLDER%", root.path),
            ("%TMPDIR%", NSTemporaryDirectory()),
        ]
        func fill(_ text: String) -> String {
            placeholders.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        }
        var commands: [Command] = []
        for name in names {
            guard let tool = tools.first(where: { $0["name"] as? String == name }), let command = tool["command"] as? String else { return nil }
            commands.append(Command(executable: fill(command), arguments: (tool["args"] as? [String] ?? []).map(fill)))
        }
        return commands.isEmpty ? nil : commands
    }

    /// Runs the build and finds the PDF it wrote.
    static func build(tex: URL, root: URL) -> Result {
        let started = Date().addingTimeInterval(-1)
        let directory = tex.deletingLastPathComponent()
        var log = ""
        for command in commands(for: tex, root: root) {
            let result = Shell.run("/usr/bin/env", [command.executable] + command.arguments, in: directory)
            log += result.output
            if result.status != 0 {
                return Result(succeeded: false, log: summary(of: log), pdf: nil)
            }
        }
        let pdf = existingPDF(for: tex, modifiedAfter: started) ?? existingPDF(for: tex)
        return Result(succeeded: pdf != nil, log: pdf == nil ? "The build finished without writing a PDF.\n\n" + summary(of: log) : "", pdf: pdf)
    }

    /// The PDF that belongs to a LaTeX file: `name.pdf` beside it, else one whose name contains
    /// the file's (resume.tex → jane-resume.pdf), else the newest PDF in the folder.
    static func existingPDF(for tex: URL, modifiedAfter date: Date? = nil) -> URL? {
        let directory = tex.deletingLastPathComponent()
        let name = tex.deletingPathExtension().lastPathComponent.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var candidates: [(url: URL, modified: Date)] = []
        for file in files where file.pathExtension.lowercased() == "pdf" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let date, modified < date { continue }
            candidates.append((file, modified))
        }
        func stem(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        if let exact = candidates.first(where: { stem($0.url) == name }) { return exact.url }
        let newestFirst = candidates.sorted { $0.modified > $1.modified }
        return (newestFirst.first { stem($0.url).contains(name) } ?? newestFirst.first)?.url
    }

    /// The error lines of a log if it has any, otherwise its last lines.
    static func summary(of log: String) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        var errors: [String] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("!") || line.range(of: #"^[^\s:]+:\d+: "#, options: .regularExpression) != nil {
            errors.append(contentsOf: lines[index..<min(index + 3, lines.count)].map(String.init))
        }
        let chosen = errors.isEmpty ? lines.suffix(40).map(String.init) : Array(errors.prefix(60))
        return chosen.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
