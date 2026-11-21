import AppKit
import SwiftUI

/// The window: sidebar, and beside it the open file above the terminal.
struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        GeometryReader { window in
            HStack(spacing: 0) {
                if workspace.sidebarVisible {
                    SidebarView(workspace: workspace)
                        .frame(width: workspace.sidebarWidth)
                    Divider1(axis: .vertical, onDrag: { x in
                        workspace.sidebarWidth = min(max(x - window.frame(in: .global).minX, 200), min(480, window.size.width - 320))
                    }, onEnd: workspace.saveState)
                }
                VStack(spacing: 0) {
                    // In full screen the top bar is in the window's title bar strip instead.
                    if !workspace.isFullScreen {
                        TopBar(workspace: workspace)
                        Divider1(axis: .horizontal)
                    }
                    panes
                }
            }
        }
        .overlay(alignment: .top) { if workspace.isFullScreen { Divider1(axis: .horizontal) } }
        // The content runs under the title bar, except in full screen, where the title bar is a
        // strip of its own, holding the top bar, and the content starts below it.
        .ignoresSafeArea(edges: workspace.isFullScreen ? [.horizontal, .bottom] : .all)
        .background(Theme.background.ignoresSafeArea())
    }

    /// The editor above the terminal, or either one alone.
    private var panes: some View {
        GeometryReader { area in
            VStack(spacing: 0) {
                if workspace.editorShown, let document = workspace.activeDocument {
                    DocumentView(document: document, workspace: workspace)
                        .id(document.id)
                        .frame(height: workspace.terminalVisible ? max(area.size.height * (1 - workspace.terminalFraction), 80) : nil)
                    if workspace.terminalVisible {
                        Divider1(axis: .horizontal, onDrag: { y in
                            let fraction = 1 - (y - area.frame(in: .global).minY) / max(area.size.height, 1)
                            workspace.terminalFraction = min(max(fraction, 0.12), 0.88)
                        }, onEnd: workspace.saveState)
                    }
                }
                if workspace.terminalVisible || !workspace.editorShown {
                    TerminalPanel(workspace: workspace)
                }
            }
        }
    }
}

// MARK: Top bar

/// Across the top of the content: the open files as tabs, then how the active one is viewed,
/// the agent launcher and the terminal switch.
struct TopBar: View {
    @ObservedObject var workspace: Workspace
    /// In full screen the bar sits in the window's title bar strip, after the window's buttons,
    /// and holds the sidebar's button whether the sidebar is shown or not.
    var inTitleBar = false
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        HStack(spacing: 8) {
            if inTitleBar {
                // Laid out as the sidebar's own bar is in a window: the window's buttons at the
                // left, the sidebar's button at the sidebar's right edge, and the tabs starting
                // where the content does.
                HStack(spacing: 8) {
                    WindowButtons(workspace: workspace)
                        .frame(width: 54, height: 16)
                    if workspace.sidebarVisible { Spacer(minLength: 0) }
                    Button { workspace.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(IconButtonStyle())
                        .help(workspace.sidebarVisible ? "Hide Sidebar (⌘B)" : "Show Sidebar (⌘B)")
                }
                .frame(width: workspace.sidebarVisible ? workspace.sidebarWidth - 12 - 19 : nil)
                .padding(.trailing, workspace.sidebarVisible ? 17 : 0)
            } else if !workspace.sidebarVisible {
                // Room for the window's buttons, which the sidebar otherwise holds.
                Color.clear.frame(width: 64)
                Button { workspace.sidebarVisible = true } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(IconButtonStyle())
                    .help("Show Sidebar (⌘B)")
            }
            if workspace.documents.isEmpty {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .allowsHitTesting(false)
                Spacer(minLength: 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(workspace.documents) { document in
                                Tab(title: document.name, selected: document.id == workspace.activeDocumentID && workspace.editorShown,
                                    dirty: document.isDirty, help: workspace.relativePath(of: document.url),
                                    select: { workspace.activate(document) }, close: { workspace.close(document) })
                                    .id(document.id)
                            }
                        }
                    }
                    .onChange(of: workspace.activeDocumentID) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if workspace.editorShown, let document = workspace.activeDocument, document.hasPreview {
                DocumentControls(document: document, workspace: workspace)
            }
            AgentButton(workspace: workspace)
            Button { workspace.toggleTerminal() } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }
                .buttonStyle(IconButtonStyle(active: workspace.terminalVisible))
                .disabled(workspace.documents.isEmpty)
                .help(workspace.terminalVisible ? "Hide Terminal (⇧⌘J)" : "Show Terminal (⇧⌘J)")
        }
        .padding(.leading, inTitleBar ? 19 : 12)
        .padding(.trailing, 12)
        .frame(height: Theme.barHeight)
        .background { if !inTitleBar { WindowDragArea() } }
    }
}

/// The window's close, minimise and zoom buttons, for the top bar in full screen: there the
/// system shows its own only while the menu bar is down, and these are always on screen.
private struct WindowButtons: NSViewRepresentable {
    let workspace: Workspace

    final class Group: NSView {
        weak var workspace: Workspace?
        private var hovering = false

        private var workspaceWindow: NSWindow? {
            NSApp.windows.first { ($0.windowController as? WorkspaceWindowController)?.workspace === workspace }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            let kinds: [(NSWindow.ButtonType, Selector)] = [(.closeButton, #selector(close)), (.miniaturizeButton, #selector(close)), (.zoomButton, #selector(leaveFullScreen))]
            for (index, kind) in kinds.enumerated() {
                guard let button = NSWindow.standardWindowButton(kind.0, for: style) else { continue }
                button.target = self
                button.action = kind.1
                // A full screen window can't be minimised.
                if kind.0 == .miniaturizeButton { button.isEnabled = false }
                button.setFrameOrigin(NSPoint(x: CGFloat(index) * 20, y: 0))
                addSubview(button)
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func close() { workspaceWindow?.performClose(nil) }
        @objc private func leaveFullScreen() { workspaceWindow?.toggleFullScreen(nil) }

        // The buttons ask the view around them whether the pointer is over the group, to show
        // their symbols on all three at once.
        @objc func _mouseInGroup(_ button: NSButton) -> Bool { hovering }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { setHovering(true) }
        override func mouseExited(with event: NSEvent) { setHovering(false) }

        private func setHovering(_ value: Bool) {
            hovering = value
            subviews.forEach { $0.needsDisplay = true }
        }
    }

    func makeNSView(context: Context) -> Group {
        let group = Group(frame: NSRect(x: 0, y: 0, width: 54, height: 16))
        group.workspace = workspace
        return group
    }

    func updateNSView(_ group: Group, context: Context) {}
}

/// A tab in either bar: a rounded plate when selected, a close button on hover.
struct Tab: View {
    let title: String
    let selected: Bool
    var dirty = false
    var help = ""
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.text : Theme.secondary)
                .lineLimit(1)
                .frame(maxWidth: 200)
                .fixedSize()
            Button(action: close) {
                ZStack {
                    // An unsaved file shows a dot where its close button is, until pointed at.
                    Circle().fill(Theme.text).frame(width: 7, height: 7).opacity(dirty && !hovering ? 1 : 0)
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .opacity(hovering || (selected && !dirty) ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(Color.primary.opacity(selected ? 0.1 : (hovering ? 0.05 : 0)), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .help(help)
    }
}

/// Code / side by side / result, and for LaTeX the build.
private struct DocumentControls: View {
    @ObservedObject var document: Document
    let workspace: Workspace
    @State private var showingLog = false

    var body: some View {
        HStack(spacing: 8) {
            if document.isTeX {
                switch document.build {
                case .running:
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                case .failed(let log):
                    Button { showingLog = true } label: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.deleted)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("The build failed. Click for details.")
                    .popover(isPresented: $showingLog, arrowEdge: .bottom) {
                        ScrollView {
                            Text(log.isEmpty ? "The build failed." : log)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                        .frame(width: 560, height: 320)
                    }
                default:
                    EmptyView()
                }
                Button { if workspace.save(document) == false { } } label: { Image(systemName: "hammer") }
                    .buttonStyle(IconButtonStyle())
                    .disabled(document.build == .running)
                    .help("Save and Build PDF (⌘S)")
            }
            HStack(spacing: 0) {
                mode(.code, icon: "chevron.left.forwardslash.chevron.right", help: "Source")
                mode(.split, icon: "rectangle.split.2x1", help: "Side by Side")
                mode(.preview, icon: document.isTeX ? "doc.richtext" : "eye", help: document.isTeX ? "PDF" : "Preview")
            }
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        }
    }

    private func mode(_ mode: Document.Mode, icon: String, help: String) -> some View {
        Button { document.mode = mode } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(document.mode == mode ? Theme.text : Theme.secondary)
                .frame(width: 32, height: 24)
                .background(Color.primary.opacity(document.mode == mode ? 0.1 : 0), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help + " (⇧⌘V cycles)")
    }
}

/// Starts the coding agent in a new terminal tab; the arrow picks which agent that is.
private struct AgentButton: View {
    let workspace: Workspace
    @ObservedObject private var settings = Settings.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button { workspace.startAgent() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 10))
                    Text(settings.agent?.name ?? "Choose Agent").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.text)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start \(settings.agent?.name ?? "an agent") in a new terminal tab (⇧⌘A)")

            Rectangle().fill(Theme.border).frame(width: 1, height: 16)

            Menu {
                ForEach(Agent.presets) { agent in
                    Toggle(agent.name, isOn: Binding(get: { settings.agentID == agent.id }, set: { _ in settings.agentID = agent.id }))
                }
                if !settings.customAgentCommand.trimmingCharacters(in: .whitespaces).isEmpty {
                    Toggle(settings.customAgentCommand, isOn: Binding(get: { settings.agentID == Agent.customID },
                                                                    set: { _ in settings.agentID = Agent.customID }))
                }
                Divider()
                Button("Other…") { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(Theme.secondary)
            .frame(width: 28, height: 28)
            .help("Choose which agent starts")
        }
        .background(Color.primary.opacity(hovering ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        .onHover { hovering = $0 }
    }
}

// MARK: The open file

/// The active file: its text, its rendered result, or both.
private struct DocumentView: View {
    @ObservedObject var document: Document
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if document.changedOnDisk {
                HStack(spacing: 12) {
                    Text("This file changed on disk while you were editing it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Button("Keep Mine") { document.changedOnDisk = false }
                    Button("Reload") { document.reload() }
                }
                .controlSize(.small)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(Theme.modified.opacity(0.14))
            }
            content
        }
        .background(Theme.background)
    }

    @ViewBuilder private var content: some View {
        switch document.kind {
        case .text:
            if let editor = document.editor {
                if !document.hasPreview || document.mode == .code {
                    EditorHost(controller: editor)
                } else if document.mode == .preview {
                    preview
                } else {
                    HStack(spacing: 0) {
                        EditorHost(controller: editor)
                        Divider1(axis: .vertical)
                        preview
                    }
                }
            }
        case .pdf:
            PDFPreview(url: document.url, revision: document.revision)
        case .image:
            ImagePreview(url: document.url, revision: document.revision)
        case .unsupported(let message):
            MessageView(icon: "doc", title: message) {
                Button("Open in Default App") { NSWorkspace.shared.open(document.url) }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if document.isMarkdown {
            MarkdownPreview(document: document) { workspace.open($0) }
        } else if let pdf = document.pdfURL {
            PDFPreview(url: pdf, revision: document.revision)
        } else {
            MessageView(icon: "doc.richtext", title: "No PDF yet", detail: "Saving the file builds it.") {
                Button("Build") { workspace.save(document) }
            }
        }
    }
}

// MARK: Terminal

/// The terminal with its tabs. One button, a double click on its bar or ⌘J gives it the whole
/// window and brings the editor back.
private struct TerminalPanel: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(workspace.terminals) { session in
                            TerminalTab(session: session, selected: session.id == workspace.activeTerminalID,
                                        select: { workspace.select(session) }, close: { workspace.close(session) })
                        }
                        Button { workspace.newTerminal() } label: { Image(systemName: "plus") }
                            .buttonStyle(IconButtonStyle())
                            .help("New Terminal Tab (⌘T)")
                    }
                }
                Spacer(minLength: 8)
                if !workspace.documents.isEmpty {
                    let maximized = workspace.terminalMaximized
                    Button { workspace.toggleTerminalMaximized() } label: {
                        Image(systemName: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(maximized ? "Bring Back the Editor (⌘J)" : "Fill the Window with the Terminal (⌘J)")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(BarDoubleClick { if !workspace.documents.isEmpty { workspace.toggleTerminalMaximized() } })

            if let session = workspace.activeTerminal {
                TerminalHost(session: session, focusToken: workspace.terminalFocusToken)
                    .padding(.leading, 12)
                    .padding(.bottom, 8)
            } else {
                MessageView(icon: "terminal", title: "No terminal open") {
                    Button("New Terminal") { workspace.newTerminal() }
                }
            }
        }
        .background(Theme.background)
    }
}

private struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        Tab(title: session.title, selected: selected, select: select, close: close)
    }
}

/// Catches a double click on the empty part of the terminal's bar.
private struct BarDoubleClick: NSViewRepresentable {
    let action: () -> Void

    final class ClickView: NSView {
        var action: () -> Void = {}
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { action() }
        }
    }

    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) { view.action = action }
}
