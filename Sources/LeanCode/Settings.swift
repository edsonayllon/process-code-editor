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

    static func font(named name: String, size: Double) -> NSFont {
        if !name.isEmpty {
            if let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) { return font }
            if let font = NSFont(name: name, size: size) { return font }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
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
