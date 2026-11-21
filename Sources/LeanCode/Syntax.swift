import Foundation

enum Token: UInt8 {
    case plain, comment, string, number, keyword, type, function, constant, tag, attribute, heading, emphasis, link

    var cssClass: String { "t-\(self)" }
}

/// A coloured run of text, in UTF-16 offsets.
struct Span: Equatable {
    var location: Int
    var length: Int
    var token: Token
}

struct StringRule {
    var open: String
    var close: String
    var multiline = false
    var escapes = true
}

/// How to colour one language. Most are the same scanner with different word lists.
struct Language {
    enum Kind { case code, markup, markdown, tex, plain }

    var name: String
    var kind: Kind = .code
    var lineComments: [String] = []
    var blockComments: [(String, String)] = []
    var strings: [StringRule] = [StringRule(open: "\"", close: "\""), StringRule(open: "'", close: "'")]
    var keywords: Set<String> = []
    var constants: Set<String> = ["true", "false", "null"]
    var types: Set<String> = []
    /// Words starting with a capital are types.
    var capitalizedTypes = true
    /// A word or string followed by ":" is a key (JSON, YAML, CSS).
    var colonKeys = false
    /// "@name" is an attribute or decorator.
    var decorators = false
    /// A single quote only opens a one-character literal ('a', '\n'), as in Rust and C.
    var characterLiterals = false
    /// Characters that count as part of a word besides letters, digits and "_".
    var wordExtras = ""
    var indent = 4
    /// Prose: lines wrap to the window.
    var wraps = false

    static let plain = Language(name: "Plain Text", kind: .plain, wraps: true)
}

extension Language {
    private static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }

    private static let cStrings = [StringRule(open: "\"", close: "\"")]
    private static let jsStrings = [StringRule(open: "\"", close: "\""), StringRule(open: "'", close: "'"),
                                    StringRule(open: "`", close: "`", multiline: true)]

    static let swift = Language(
        name: "Swift", lineComments: ["//"], blockComments: [("/*", "*/")],
        strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true), StringRule(open: "\"", close: "\"")],
        keywords: words("actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is lazy let mutating nonisolated nonmutating open operator override postfix prefix private protocol public repeat required rethrows return set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet didSet convenience dynamic optional consuming borrowing macro"),
        constants: words("true false nil self Self"), decorators: true)

    static let python = Language(
        name: "Python", lineComments: ["#"],
        strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true), StringRule(open: "'''", close: "'''", multiline: true),
                  StringRule(open: "\"", close: "\""), StringRule(open: "'", close: "'")],
        keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"),
        constants: words("True False None self cls"),
        types: words("int float str bool list dict set tuple bytes object"), decorators: true)

    static let javascript = Language(
        name: "JavaScript", lineComments: ["//"], blockComments: [("/*", "*/")], strings: jsStrings,
        keywords: words("async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch throw try typeof var void while with yield"),
        constants: words("true false null undefined NaN Infinity this"), decorators: true, wordExtras: "$", indent: 2)

    static let typescript: Language = {
        var language = javascript
        language.name = "TypeScript"
        language.keywords.formUnion(words("abstract as asserts declare enum implements interface is keyof namespace module private protected public readonly satisfies type unique override infer"))
        language.types = words("string number boolean any unknown never void object symbol bigint")
        return language
    }()

    static let json = Language(name: "JSON", lineComments: ["//"], blockComments: [("/*", "*/")], strings: cStrings,
                               capitalizedTypes: false, colonKeys: true, indent: 2)

    static let rust = Language(
        name: "Rust", lineComments: ["//"], blockComments: [("/*", "*/")],
        strings: [StringRule(open: "\"", close: "\"", multiline: true)],
        keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type unsafe use where while"),
        constants: words("true false self Self None Some Ok Err"),
        types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"), characterLiterals: true)

    static let cFamily = Language(
        name: "C", lineComments: ["//"], blockComments: [("/*", "*/")], strings: cStrings,
        keywords: words("auto break case catch class const constexpr continue default delete do else enum explicit extern for friend goto if inline namespace new noexcept operator private protected public register return sizeof static struct switch template this throw try typedef typename union using virtual volatile while #include #define #if #ifdef #ifndef #else #elif #endif #pragma #import @interface @implementation @end @property @protocol"),
        constants: words("true false NULL nullptr nil YES NO self"),
        types: words("void int char short long float double signed unsigned bool size_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t id"),
        characterLiterals: true, wordExtras: "#@")

    static let go = Language(
        name: "Go", lineComments: ["//"], blockComments: [("/*", "*/")],
        strings: [StringRule(open: "\"", close: "\""), StringRule(open: "`", close: "`", multiline: true, escapes: false)],
        keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
        constants: words("true false nil iota"),
        types: words("string int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float32 float64 bool byte rune error any"),
        characterLiterals: true)

    static let java = Language(
        name: "Java", lineComments: ["//"], blockComments: [("/*", "*/")],
        strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true), StringRule(open: "\"", close: "\"")],
        keywords: words("abstract as break case catch class companion const continue data default do else enum extends final finally for fun if implements import in instanceof interface internal is lateinit new object open override package private protected public return sealed static super suspend switch synchronized throw throws try val var void volatile when while"),
        constants: words("true false null this"),
        types: words("int long short byte char float double boolean"), decorators: true, characterLiterals: true)

    static let gdscript = Language(
        name: "GDScript", lineComments: ["#"],
        strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true), StringRule(open: "\"", close: "\""), StringRule(open: "'", close: "'")],
        keywords: words("and as assert await break breakpoint class class_name const continue elif else enum extends for func if in is match not or pass return signal static super var while preload"),
        constants: words("true false null self PI TAU INF NAN"),
        types: words("int float bool void"), decorators: true)

    static let solidity = Language(
        name: "Solidity", lineComments: ["//"], blockComments: [("/*", "*/")],
        keywords: words("abstract as assembly break calldata catch constant constructor continue contract delete do else emit enum error event external fallback for function if immutable import indexed interface internal is library mapping memory modifier new override payable pragma private public pure receive return returns revert storage struct try unchecked using view virtual while"),
        constants: words("true false this msg block tx"),
        types: words("address bool string bytes uint int uint8 uint256 int256 bytes32"))

    static let shell = Language(
        name: "Shell", lineComments: ["#"],
        strings: [StringRule(open: "\"", close: "\"", multiline: true), StringRule(open: "'", close: "'", multiline: true, escapes: false)],
        keywords: words("if then else elif fi for in do done while until case esac function return exit local export readonly set unset shift source alias echo cd eval exec trap"),
        constants: words("true false"), capitalizedTypes: false, indent: 2)

    static let yaml = Language(name: "YAML", lineComments: ["#"], constants: words("true false null yes no on off"),
                               capitalizedTypes: false, colonKeys: true, wordExtras: "-.", indent: 2)

    static let toml = Language(
        name: "TOML", lineComments: ["#"],
        strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true), StringRule(open: "\"", close: "\""), StringRule(open: "'", close: "'", escapes: false)],
        constants: words("true false"), capitalizedTypes: false, wordExtras: "-")

    static let css = Language(
        name: "CSS", lineComments: [], blockComments: [("/*", "*/")],
        keywords: words("@media @import @font-face @keyframes @supports @use @mixin @include !important"),
        constants: words("inherit initial unset none auto"), capitalizedTypes: false, colonKeys: true, wordExtras: "-@!", indent: 2)

    static let sql = Language(
        name: "SQL", lineComments: ["--"], blockComments: [("/*", "*/")],
        strings: [StringRule(open: "'", close: "'", multiline: true)],
        keywords: words("select from where and or not insert into values update set delete create table index view drop alter add column primary key foreign references join left right inner outer on group by order having limit offset as distinct union all null is in like between case when then else end begin commit rollback SELECT FROM WHERE AND OR NOT INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE INDEX VIEW DROP ALTER ADD COLUMN PRIMARY KEY FOREIGN REFERENCES JOIN LEFT RIGHT INNER OUTER ON GROUP BY ORDER HAVING LIMIT OFFSET AS DISTINCT UNION ALL NULL IS IN LIKE BETWEEN CASE WHEN THEN ELSE END BEGIN COMMIT ROLLBACK"),
        capitalizedTypes: false)

    static let ruby = Language(
        name: "Ruby", lineComments: ["#"],
        keywords: words("alias and begin break case class def defined do else elsif end ensure for if in module next not or redo rescue retry return super then undef unless until when while yield require include attr_accessor attr_reader"),
        constants: words("true false nil self"))

    static let fortran = Language(
        name: "Fortran", lineComments: ["!"],
        keywords: words("program end subroutine function module use implicit none integer real double precision complex logical character dimension allocatable intent in out inout parameter if then else elseif endif do enddo while call return contains type interface select case stop allocate deallocate print write read"),
        capitalizedTypes: false)

    static let lua = Language(
        name: "Lua", lineComments: ["--"], blockComments: [("--[[", "]]")],
        keywords: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
        constants: words("true false nil self"), capitalizedTypes: false, indent: 2)

    static let markup = Language(name: "HTML", kind: .markup, indent: 2)
    static let markdown = Language(name: "Markdown", kind: .markdown, indent: 2, wraps: true)
    static let tex = Language(name: "LaTeX", kind: .tex, indent: 2, wraps: true)

    private static let byExtension: [String: Language] = {
        var map: [String: Language] = [:]
        func add(_ language: Language, _ extensions: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = language }
        }
        add(.swift, "swift")
        add(.python, "py pyi pyw")
        add(.javascript, "js jsx mjs cjs")
        add(.typescript, "ts tsx mts cts")
        add(.json, "json jsonc json5 resolved webmanifest ipynb")
        add(.rust, "rs")
        add(.cFamily, "c h cpp hpp cc cxx hh m mm cuh cu glsl metal gdshader")
        add(.go, "go")
        add(.java, "java kt kts")
        add(.gdscript, "gd")
        add(.solidity, "sol")
        add(.shell, "sh bash zsh fish command env")
        add(.yaml, "yaml yml")
        add(.toml, "toml lock cfg ini tscn tres godot import")
        add(.css, "css scss less")
        add(.sql, "sql")
        add(.ruby, "rb podspec")
        add(.fortran, "f90 f95 f")
        add(.lua, "lua")
        add(.markup, "html htm xml svg plist xib storyboard entitlements storekit xcscheme vue")
        add(.markdown, "md markdown mdx")
        add(.tex, "tex cls sty bib ltx")
        add(.plain, "txt log csv tsv usfm")
        return map
    }()

    private static let byName: [String: Language] = [
        "makefile": .shell, "dockerfile": .shell, "gemfile": .ruby, "podfile": .ruby, "fastfile": .ruby,
        ".gitignore": .shell, ".gitattributes": .shell, ".zshrc": .shell, ".bashrc": .shell, ".env": .shell,
        ".firebaserc": .json, ".prettierrc": .json, ".eslintrc": .json, "license": .plain,
    ]

    static func forFile(_ url: URL) -> Language {
        let name = url.lastPathComponent.lowercased()
        return byName[name] ?? byExtension[url.pathExtension.lowercased()] ?? .plain
    }

    /// The language of a fenced code block's info string ("swift", "js", "bash").
    static func forFence(_ info: String) -> Language? {
        let name = info.lowercased()
        let aliases: [String: Language] = [
            "javascript": .javascript, "typescript": .typescript, "python": .python, "shell": .shell, "console": .shell,
            "rust": .rust, "golang": .go, "kotlin": .java, "objc": .cFamily, "c++": .cFamily, "latex": .tex,
            "gdscript": .gdscript, "solidity": .solidity, "ruby": .ruby,
        ]
        return aliases[name] ?? byExtension[name]
    }
}

// MARK: Scanner

enum Lexer {
    static func tokenize(_ text: String, language: Language) -> [Span] {
        let units = Array(text.utf16)
        switch language.kind {
        case .plain: return []
        case .code: return code(units, language)
        case .markup: return markup(units)
        case .markdown: return markdown(units)
        case .tex: return tex(units)
        }
    }

    // Character classes, on UTF-16 units.
    private static let newline: UInt16 = 10
    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
    private static func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
    private static func ch(_ s: String) -> UInt16 { s.utf16.first! }

    private static func matches(_ units: [UInt16], _ pattern: [UInt16], at i: Int) -> Bool {
        guard i + pattern.count <= units.count else { return false }
        for k in 0..<pattern.count where units[i + k] != pattern[k] { return false }
        return true
    }

    private static func find(_ units: [UInt16], _ pattern: [UInt16], from start: Int) -> Int? {
        guard !pattern.isEmpty, start <= units.count - pattern.count else { return nil }
        var i = start
        let last = units.count - pattern.count
        while i <= last {
            if units[i] == pattern[0], matches(units, pattern, at: i) { return i }
            i += 1
        }
        return nil
    }

    private static func lineEnd(_ units: [UInt16], from start: Int) -> Int {
        var i = start
        while i < units.count, units[i] != newline { i += 1 }
        return i
    }

    /// The end of a string that opened before `start`, just past its closing delimiter.
    private static func stringEnd(_ units: [UInt16], from start: Int, close: [UInt16], multiline: Bool, escapes: Bool) -> Int {
        var i = start
        while i < units.count {
            let c = units[i]
            if escapes, c == 92 { i += 2; continue }
            if !multiline, c == newline { return i }
            if c == close[0], matches(units, close, at: i) { return i + close.count }
            i += 1
        }
        return units.count
    }

    private static func code(_ units: [UInt16], _ language: Language) -> [Span] {
        var spans: [Span] = []
        let n = units.count
        let lineComments = language.lineComments.map { Array($0.utf16) }
        let blockComments = language.blockComments.map { (Array($0.0.utf16), Array($0.1.utf16)) }
        let strings = language.strings.map { (Array($0.open.utf16), Array($0.close.utf16), $0.multiline, $0.escapes) }
        let extras = Set(language.wordExtras.utf16)
        let quote = ch("'"), colon = ch(":"), paren = ch("("), at = ch("@"), dot = ch(".")

        func isWordStart(_ c: UInt16) -> Bool { isLetter(c) || extras.contains(c) }
        func isWord(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) || extras.contains(c) }
        func nextNonSpace(_ from: Int) -> UInt16? {
            var j = from
            while j < n, units[j] == 32 || units[j] == 9 { j += 1 }
            return j < n ? units[j] : nil
        }

        var i = 0
        scan: while i < n {
            let c = units[i]
            if isSpace(c) { i += 1; continue }

            for (open, close) in blockComments where c == open[0] && matches(units, open, at: i) {
                let end = find(units, close, from: i + open.count).map { $0 + close.count } ?? n
                spans.append(Span(location: i, length: end - i, token: .comment))
                i = end
                continue scan
            }
            for comment in lineComments where c == comment[0] && matches(units, comment, at: i) {
                let end = lineEnd(units, from: i)
                spans.append(Span(location: i, length: end - i, token: .comment))
                i = end
                continue scan
            }
            for (open, close, multiline, escapes) in strings where c == open[0] && matches(units, open, at: i) {
                let end = stringEnd(units, from: i + open.count, close: close, multiline: multiline, escapes: escapes)
                let isKey = language.colonKeys && nextNonSpace(end) == colon
                spans.append(Span(location: i, length: end - i, token: isKey ? .attribute : .string))
                i = end
                continue scan
            }
            if language.characterLiterals, c == quote {
                // 'a' or '\n'; anything else (a Rust lifetime) is left alone.
                if i + 2 < n, units[i + 1] != 92, units[i + 2] == quote {
                    spans.append(Span(location: i, length: 3, token: .string)); i += 3
                } else if i + 3 < n, units[i + 1] == 92, let end = find(units, [quote], from: i + 2), end - i <= 8 {
                    spans.append(Span(location: i, length: end + 1 - i, token: .string)); i = end + 1
                } else {
                    i += 1
                }
                continue
            }
            if isDigit(c) || (c == dot && i + 1 < n && isDigit(units[i + 1])) {
                var j = i + 1
                while j < n, isDigit(units[j]) || isLetter(units[j]) || (units[j] == dot && j + 1 < n && isDigit(units[j + 1])) { j += 1 }
                spans.append(Span(location: i, length: j - i, token: .number))
                i = j
                continue
            }
            if language.decorators, c == at, i + 1 < n, isLetter(units[i + 1]) {
                var j = i + 1
                while j < n, isLetter(units[j]) || isDigit(units[j]) || units[j] == dot { j += 1 }
                spans.append(Span(location: i, length: j - i, token: .attribute))
                i = j
                continue
            }
            if isWordStart(c) {
                var j = i + 1
                while j < n, isWord(units[j]) { j += 1 }
                let word = String(utf16CodeUnits: Array(units[i..<j]), count: j - i)
                var token: Token?
                if language.keywords.contains(word) { token = .keyword }
                else if language.constants.contains(word) { token = .constant }
                else if language.types.contains(word) { token = .type }
                else if language.colonKeys, j < n, units[j] == colon, j + 1 >= n || isSpace(units[j + 1]) { token = .attribute }
                else if j < n, units[j] == paren { token = .function }
                else if language.capitalizedTypes, isUpper(c) { token = .type }
                if let token { spans.append(Span(location: i, length: j - i, token: token)) }
                i = j
                continue
            }
            i += 1
        }
        return spans
    }

    private static func markup(_ units: [UInt16]) -> [Span] {
        var spans: [Span] = []
        let n = units.count
        let lt = ch("<"), gt = ch(">"), slash = ch("/"), bang = ch("!"), question = ch("?"), dash = ch("-")
        let commentOpen = Array("<!--".utf16), commentClose = Array("-->".utf16)
        func isName(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) || c == dash || c == 58 || c == 46 }

        var i = 0
        while i < n {
            guard units[i] == lt else { i += 1; continue }
            if matches(units, commentOpen, at: i) {
                let end = find(units, commentClose, from: i + 4).map { $0 + 3 } ?? n
                spans.append(Span(location: i, length: end - i, token: .comment))
                i = end
                continue
            }
            var j = i + 1
            if j < n, units[j] == slash || units[j] == bang || units[j] == question { j += 1 }
            guard j < n, isLetter(units[j]) else { i += 1; continue }
            while j < n, isName(units[j]) { j += 1 }
            spans.append(Span(location: i, length: j - i, token: .tag))
            // Attributes, up to the closing bracket.
            while j < n, units[j] != gt {
                let c = units[j]
                if c == 34 || c == 39 {
                    let end = stringEnd(units, from: j + 1, close: [c], multiline: true, escapes: false)
                    spans.append(Span(location: j, length: end - j, token: .string))
                    j = end
                } else if isLetter(c) {
                    var k = j + 1
                    while k < n, isName(units[k]) { k += 1 }
                    spans.append(Span(location: j, length: k - j, token: .attribute))
                    j = k
                } else {
                    j += 1
                }
            }
            if j < n {
                let start = j > 0 && (units[j - 1] == slash || units[j - 1] == question) ? j - 1 : j
                spans.append(Span(location: start, length: j + 1 - start, token: .tag))
                j += 1
            }
            i = j
        }
        return spans
    }

    private static func markdown(_ units: [UInt16]) -> [Span] {
        var spans: [Span] = []
        let n = units.count
        let hash = ch("#"), tick = ch("`"), tilde = ch("~"), star = ch("*"), under = ch("_"), gt = ch(">")
        let dash = ch("-"), plus = ch("+"), open = ch("["), close = ch("]"), paren = ch("("), closeParen = ch(")")
        var fence: UInt16?

        var lineStart = 0
        while lineStart < n {
            let end = lineEnd(units, from: lineStart)
            defer { lineStart = end + 1 }
            var i = lineStart
            while i < end, units[i] == 32 || units[i] == 9 { i += 1 }
            guard i < end else { continue }
            let c = units[i]

            let isFence = (c == tick || c == tilde) && i + 2 < end && units[i + 1] == c && units[i + 2] == c
            if let marker = fence {
                spans.append(Span(location: lineStart, length: end - lineStart, token: .string))
                if isFence, c == marker { fence = nil }
                continue
            }
            if isFence {
                fence = c
                spans.append(Span(location: lineStart, length: end - lineStart, token: .string))
                continue
            }
            if c == hash {
                var j = i
                while j < end, units[j] == hash { j += 1 }
                if j - i <= 6, j == end || units[j] == 32 {
                    spans.append(Span(location: i, length: end - i, token: .heading))
                    continue
                }
            }
            if c == gt {
                spans.append(Span(location: i, length: end - i, token: .comment))
                continue
            }
            // List markers: "- ", "* ", "+ ", "1. "
            if (c == dash || c == star || c == plus), i + 1 < end, units[i + 1] == 32 {
                spans.append(Span(location: i, length: 1, token: .keyword))
                i += 2
            } else if isDigit(c) {
                var j = i
                while j < end, isDigit(units[j]) { j += 1 }
                if j + 1 < end, units[j] == 46, units[j + 1] == 32 {
                    spans.append(Span(location: i, length: j + 1 - i, token: .keyword))
                    i = j + 2
                }
            }
            // Inline: `code`, **bold**, [text](url)
            while i < end {
                let c = units[i]
                if c == tick, let j = find(units, [tick], from: i + 1), j < end {
                    spans.append(Span(location: i, length: j + 1 - i, token: .constant))
                    i = j + 1
                } else if (c == star || c == under), i + 1 < end, units[i + 1] == c,
                          let j = find(units, [c, c], from: i + 2), j < end, j > i + 2 {
                    spans.append(Span(location: i, length: j + 2 - i, token: .emphasis))
                    i = j + 2
                } else if c == open, let j = find(units, [close, paren], from: i + 1), j < end,
                          let k = find(units, [closeParen], from: j + 2), k < end {
                    spans.append(Span(location: i, length: j + 1 - i, token: .link))
                    spans.append(Span(location: j + 1, length: k + 1 - (j + 1), token: .comment))
                    i = k + 1
                } else {
                    i += 1
                }
            }
        }
        return spans
    }

    private static func tex(_ units: [UInt16]) -> [Span] {
        var spans: [Span] = []
        let n = units.count
        let percent = ch("%"), backslash: UInt16 = 92, dollar = ch("$"), brace = ch("{"), closeBrace = ch("}")
        func isAlpha(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 64 }

        var i = 0
        while i < n {
            let c = units[i]
            if c == percent {
                let end = lineEnd(units, from: i)
                spans.append(Span(location: i, length: end - i, token: .comment))
                i = end
            } else if c == backslash {
                var j = i + 1
                if j < n, isAlpha(units[j]) {
                    while j < n, isAlpha(units[j]) { j += 1 }
                } else {
                    j = min(j + 1, n)
                }
                spans.append(Span(location: i, length: j - i, token: .keyword))
                let name = String(utf16CodeUnits: Array(units[(i + 1)..<j]), count: j - i - 1)
                // The environment or class named by \begin{...}, \end{...}, \documentclass{...}.
                if ["begin", "end", "documentclass", "usepackage"].contains(name) {
                    var k = j
                    if k < n, units[k] == 91, let close = find(units, [93], from: k), close < lineEnd(units, from: k) { k = close + 1 }
                    if k < n, units[k] == brace, let close = find(units, [closeBrace], from: k), close < lineEnd(units, from: k) {
                        spans.append(Span(location: k + 1, length: close - k - 1, token: .type))
                        j = close + 1
                    }
                }
                i = j
            } else if c == dollar {
                // Math, to the next unescaped "$" in the same paragraph.
                var j = i + 1
                if j < n, units[j] == dollar { j += 1 }
                var end: Int?
                while j < n {
                    if units[j] == backslash { j += 2; continue }
                    if units[j] == newline, j + 1 < n, units[j + 1] == newline { break }
                    if units[j] == dollar { end = (j + 1 < n && units[j + 1] == dollar) ? j + 2 : j + 1; break }
                    j += 1
                }
                if let end {
                    spans.append(Span(location: i, length: end - i, token: .string))
                    i = end
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return spans
    }
}
