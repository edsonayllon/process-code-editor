import AppKit
import Combine

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// A command-line coding agent that can be started in a terminal tab.
struct Agent: Identifiable, Equatable {
    let id: String
    let name: String
    let command: String

    static let presets = [
        Agent(id: "claude", name: "Claude Code", command: "claude"),
        Agent(id: "codex", name: "Codex", command: "codex"),
        Agent(id: "gemini", name: "Gemini", command: "gemini"),
    ]
    static let customID = "custom"
}

/// The few things that can be customized: appearance, the code font, and which agent starts.
final class Settings: ObservableObject {
    static let shared = Settings()

    static let fontSizes: ClosedRange<Double> = 10...20
    /// Monospaced families offered when installed. The empty name is the system's own (SF Mono).
    static let offeredFonts = ["", "Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Source Code Pro", "IBM Plex Mono"]

    @Published var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance"); applyAppearance() } }
    @Published var fontName: String { didSet { defaults.set(fontName, forKey: "fontName") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    /// The terminal's text is kept to a centred column, with margins either side, instead of
    /// running the width of a wide window.
    @Published var margins: Bool { didSet { defaults.set(margins, forKey: "margins") } }
    /// Spotlight: in full screen, with the terminal alone, the bars fade away until the pointer
    /// goes to them.
    @Published var spotlight: Bool { didSet { defaults.set(spotlight, forKey: "spotlight") } }
    @Published var agentID: String { didSet { defaults.set(agentID, forKey: "agentID") } }
    @Published var customAgentCommand: String { didSet { defaults.set(customAgentCommand, forKey: "customAgentCommand") } }
    @Published var startAgentOnOpen: Bool { didSet { defaults.set(startAgentOnOpen, forKey: "startAgentOnOpen") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        fontName = defaults.string(forKey: "fontName") ?? ""
        let size = defaults.double(forKey: "fontSize")
        fontSize = Settings.fontSizes.contains(size) ? size : 13
        margins = defaults.object(forKey: "margins") == nil ? true : defaults.bool(forKey: "margins")
        spotlight = defaults.object(forKey: "spotlight") as? Bool ?? true
        agentID = defaults.string(forKey: "agentID") ?? "claude"
        customAgentCommand = defaults.string(forKey: "customAgentCommand") ?? ""
        startAgentOnOpen = defaults.object(forKey: "startAgentOnOpen") as? Bool ?? true
    }

    /// The font families that can be picked on this Mac.
    var availableFonts: [String] {
        Settings.offeredFonts.filter { $0.isEmpty || NSFont(name: $0, size: 12) != nil || NSFontManager.shared.availableMembers(ofFontFamily: $0) != nil }
    }

    static func fontTitle(_ name: String) -> String { name.isEmpty ? "SF Mono" : name }

    var codeFont: NSFont { Settings.font(named: fontName, size: fontSize) }
    /// The line numbers are two points smaller than the code.
    var gutterFont: NSFont { Settings.font(named: fontName, size: max(fontSize - 2, 9)) }

    /// How far from the editor's left edge the code starts, in a file of ordinary length. The
    /// terminal's text starts here too while the editor is above it, so the two share an edge.
    var codeLeading: CGFloat { GutterView.width(lines: 1, font: gutterFont) + GutterView.textInset }

    static func font(named name: String, size: Double) -> NSFont {
        if !name.isEmpty {
            if let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) { return font }
            if let font = NSFont(name: name, size: size) { return font }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// How many characters wide the column of text is when it has margins: as wide as code and
    /// hard-wrapped text usually run, so neither is cut short.
    static let readableColumns = 120

    /// The width of that column in the code font, so it holds the same text at any font size.
    var readableWidth: CGFloat {
        let cell = ("W" as NSString).size(withAttributes: [.font: codeFont]).width
        return (CGFloat(Settings.readableColumns) * cell).rounded(.up)
    }

    /// The margin either side of a column `readable` wide in a pane `available` wide. None when
    /// the pane is no wider than the column, so a narrow window loses nothing.
    static func sideMargin(available: CGFloat, readable: CGFloat) -> CGFloat {
        max(0, ((available - readable) / 2).rounded(.down))
    }

    /// The agent the launch button starts, or nil when a custom one has no command yet.
    var agent: Agent? {
        if agentID == Agent.customID {
            let command = customAgentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return nil }
            let name = command.split(separator: " ").first.map(String.init) ?? command
            return Agent(id: Agent.customID, name: (name as NSString).lastPathComponent, command: command)
        }
        return Agent.presets.first { $0.id == agentID } ?? Agent.presets[0]
    }

    func changeFontSize(by delta: Double) {
        fontSize = min(max(fontSize + delta, Settings.fontSizes.lowerBound), Settings.fontSizes.upperBound)
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
