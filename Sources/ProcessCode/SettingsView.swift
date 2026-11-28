import AppKit
import SwiftUI

/// The whole of Settings: light or dark, the code font, which agent starts, and the check for a new version.
struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var projects = ProjectStore.shared
    @ObservedObject private var updater = AppUpdater.shared

    private func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: projects.rootPath)
        if panel.choose() == .OK, let url = panel.url { projects.rootPath = url.standardizedFileURL.path }
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .tint(Theme.accentFill)
                Picker("Font", selection: $settings.fontName) {
                    ForEach(settings.availableFonts, id: \.self) { name in
                        Text(Settings.fontTitle(name)).tag(name)
                    }
                }
                Stepper(value: $settings.fontSize, in: Settings.fontSizes, step: 1) {
                    LabeledContent("Size", value: "\(Int(settings.fontSize)) pt")
                }
                Toggle("Margins beside the terminal in a wide window", isOn: $settings.margins)
                    .tint(Theme.accentFill)
                Toggle("Spotlight: fade the bars away while the terminal is alone", isOn: $settings.spotlight)
                    .tint(Theme.accentFill)
                Text("func greet(name: String) -> String { \"Hello, \\(name)\" }")
                    .font(Font(settings.codeFont))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text((projects.rootPath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseProjectsFolder() }
                    }
                }
            } header: {
                Text("Projects")
            } footer: {
                Text("The git repositories in this folder are listed when you open a new window. Clones and new repositories go here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Agent", selection: $settings.agentID) {
                    ForEach(Agent.presets) { Text($0.name).tag($0.id) }
                    Text("Other").tag(Agent.customID)
                }
                if settings.agentID == Agent.customID {
                    TextField("Command", text: $settings.customAgentCommand, prompt: Text("hermes, aider, ollama run …"))
                        .font(.system(size: 13, design: .monospaced))
                }
                Toggle("Start it when a folder opens", isOn: $settings.startAgentOnOpen)
                    .tint(Theme.accentFill)
                if settings.agent?.resumeCommand != nil {
                    Toggle("Continue the folder's last conversation", isOn: $settings.continueConversation)
                        .tint(Theme.accentFill)
                        .disabled(!settings.startAgentOnOpen)
                }
            } header: {
                Text("Coding Agent")
            } footer: {
                Text("The agent runs in a terminal tab in the folder you opened. When it exits, the tab stays open as a shell. "
                     + "A new agent tab always starts a new conversation.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent(AppUpdater.version.map { "Version \($0)" } ?? "Development build") {
                    Button("Check for Updates…") { updater.check() }
                        .disabled(!updater.canCheck)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(AppUpdater.hasFeed
                     ? "Process Code also checks each time it opens. A new version downloads quietly and is installed when you quit."
                     : "This copy was built from source, so it doesn't update itself. Rebuild it to get a new version.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
