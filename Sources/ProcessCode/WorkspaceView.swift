import AppKit
import SwiftUI

/// The window: sidebar, and beside it the open file above the terminal.
struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var settings = Settings.shared
    /// The terminal's share of the height when a drag on its bar began.
    @State private var dragStartFraction: CGFloat = 0

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
                        Divider1(axis: .horizontal).fadesInFocusMode(workspace)
                    }
                    panes
                }
            }
        }
        .overlay(alignment: .top) { if workspace.isFullScreen { Divider1(axis: .horizontal).fadesInFocusMode(workspace) } }
        // The content runs under the title bar, except in full screen, where the title bar is a
        // strip of its own, holding the top bar, and the content starts below it.
        .ignoresSafeArea(edges: workspace.isFullScreen ? [.horizontal, .bottom] : .all)
        .background(Theme.background.ignoresSafeArea())
        // In a window the system's buttons sit over the top bar, and fade with it.
        .background(SystemButtonsFade(hidden: workspace.barsHidden && !workspace.isFullScreen))
    }

    /// The editor above the terminal, or either one alone.
    private var panes: some View {
        GeometryReader { area in
            VStack(spacing: 0) {
                if workspace.editorShown, let document = workspace.activeDocument {
                    HStack(spacing: 0) {
                        if let side = workspace.sideDocument {
                            // Two files, half the width each, with their names above them.
                            let width = max((area.size.width - 1) / 2, 0)
                            DocumentPane(document: document, workspace: workspace, atSide: false)
                                .id(document.id)
                                .frame(width: width)
                            Divider1(axis: .vertical)
                            DocumentPane(document: side, workspace: workspace, atSide: true)
                                .id(side.id)
                                .frame(width: width)
                        } else {
                            DocumentView(document: document, workspace: workspace)
                                .id(document.id)
                        }
                    }
                        .frame(height: workspace.terminalVisible ? max(area.size.height * (1 - workspace.terminalFraction), 80) : nil)
                    // The handle for this line is laid over it by the terminal panel (SplitHandle).
                    if workspace.terminalVisible { Divider1(axis: .horizontal) }
                }
                if workspace.terminalVisible || !workspace.editorShown {
                    // The editor and terminal on each side of the line take the pointer, so the
                    // handle is an AppKit strip laid over the line, above both of them.
                    let split = workspace.editorShown && workspace.activeDocument != nil
                    TerminalPanel(workspace: workspace, width: area.size.width, resize: split ? { phase in
                        switch phase {
                        case .began: dragStartFraction = workspace.terminalFraction
                        case .moved(let down):
                            workspace.terminalFraction = min(max(dragStartFraction - down / max(area.size.height, 1), 0.12), 0.88)
                        case .ended: workspace.saveState()
                        }
                    } : nil)
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
                        .buttonStyle(IconButtonStyle(glass: true))
                        .help(workspace.sidebarVisible ? "Hide Sidebar (⌘B)" : "Show Sidebar (⌘B)")
                }
                .frame(width: workspace.sidebarVisible ? workspace.sidebarWidth - 12 - 19 : nil)
                .padding(.trailing, workspace.sidebarVisible ? 17 : 0)
            } else if !workspace.sidebarVisible {
                // Room for the window's buttons, which the sidebar otherwise holds.
                Color.clear.frame(width: 64)
                Button { workspace.sidebarVisible = true } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(IconButtonStyle(glass: true))
                    .help("Show Sidebar (⌘B)")
            }
            // The folder's name stays at the start of the bar, ahead of any open files, so it's
            // always clear which folder the window is.
            Text(workspace.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                // As wide as the name, up to a limit past which it's cut short in the middle.
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 8)
                .allowsHitTesting(false)
            if workspace.documents.isEmpty {
                Spacer(minLength: 8)
            } else {
                Rectangle().fill(Theme.border).frame(width: 1, height: 16)
                    .padding(.horizontal, 2)
                    .allowsHitTesting(false)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(workspace.documents) { document in
                                let atSide = document.id == workspace.sideDocumentID
                                Tab(title: document.name, selected: (document.id == workspace.activeDocumentID || atSide) && workspace.editorShown,
                                    dirty: document.isDirty, help: workspace.relativePath(of: document.url),
                                    select: { workspace.activate(document) }, close: { workspace.close(document) })
                                    .id(document.id)
                                    .contextMenu {
                                        if atSide {
                                            Button("Close Side Pane") { workspace.closeSide() }
                                        } else {
                                            Button("Move to the Side") { workspace.open(document.url, toSide: true) }
                                                .disabled(workspace.documents.count < 2)
                                        }
                                        Divider()
                                        Button("Close Tab") { workspace.close(document) }
                                    }
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
            if workspace.editorShown, let first = workspace.activeDocument?.video, let second = workspace.sideDocument?.video {
                CompareControls(first: first, second: second)
            }
            AgentButton(workspace: workspace)
            Button { workspace.toggleTerminal() } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }
                .buttonStyle(IconButtonStyle(active: workspace.terminalVisible, glass: true))
                .disabled(workspace.documents.isEmpty)
                .help(workspace.terminalVisible ? "Hide Terminal (⇧⌘J)" : "Show Terminal (⇧⌘J)")
        }
        .padding(.leading, inTitleBar ? 19 : 12)
        .padding(.trailing, 12)
        .frame(height: Theme.barHeight)
        // The sidebar's edge runs on up through the strip, so its button sits in the sidebar's
        // column rather than floating over the bar.
        .overlay(alignment: .leading) {
            if inTitleBar && workspace.sidebarVisible {
                Theme.border.frame(width: 1).offset(x: workspace.sidebarWidth)
            }
        }
        .fadesInFocusMode(workspace)
        .background {
            if inTitleBar {
                BarHover(workspace: workspace, reachesUp: true)
            } else {
                WindowDragArea()
                BarHover(workspace: workspace)
            }
        }
        // The strip has a grey backdrop of its own; over it the bar is on the content's colour, as
        // in a window, so in focus mode the screen is one colour to the top. Above the sidebar it's
        // the sidebar's colour, so the sidebar's column is one colour to the top as well.
        .background {
            if inTitleBar {
                Theme.background.allowsHitTesting(false)
                if workspace.sidebarVisible {
                    Theme.sidebar.frame(width: workspace.sidebarWidth)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                }
            }
        }
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
                .font(.system(size: 13, weight: selected ? .medium : .regular))
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
                    .buttonStyle(IconButtonStyle(glass: true))
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
                    .buttonStyle(IconButtonStyle(glass: true))
                    .disabled(document.build == .running)
                    .help("Save and Build PDF (⌘S)")
            }
            HStack(spacing: 0) {
                mode(.code, icon: "chevron.left.forwardslash.chevron.right", help: "Source")
                mode(.split, icon: "rectangle.split.2x1", help: "Side by Side")
                mode(.preview, icon: document.isTeX ? "doc.richtext" : "eye", help: document.isTeX ? "PDF" : "Preview")
            }
            .padding(2)
            .glassEffect(.regular, in: Capsule())
        }
    }

    private func mode(_ mode: Document.Mode, icon: String, help: String) -> some View {
        Button { document.mode = mode } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(document.mode == mode ? Theme.text : Theme.secondary)
                .frame(width: 32, height: 24)
                .background(Color.primary.opacity(document.mode == mode ? 0.12 : 0), in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help + " (⇧⌘V cycles)")
    }
}

/// For two videos side by side: plays and stops them as one, and takes both back to the start.
private struct CompareControls: View {
    @ObservedObject var first: VideoController
    @ObservedObject var second: VideoController

    var body: some View {
        let playing = first.isPlaying || second.isPlaying
        HStack(spacing: 0) {
            button("backward.end.fill", help: "Both Back to the Start") { VideoController.restart(first, second) }
            button(playing ? "pause.fill" : "play.fill", help: playing ? "Pause Both" : "Play Both from the Same Moment") {
                VideoController.togglePlaying(first, second)
            }
        }
        .padding(2)
        .glassEffect(.regular, in: Capsule())
        .disabled(first.failed || second.failed)
    }

    private func button(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 32, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Starts the coding agent in a new terminal tab; the arrow picks which agent that is.
private struct AgentButton: View {
    let workspace: Workspace
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        HStack(spacing: 0) {
            Button { workspace.startAgent() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 10))
                    Text(settings.agent?.name ?? "Choose Agent").font(.system(size: 13, weight: .medium))
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
        .padding(.leading, 2)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

// MARK: The open file

/// One of two files side by side, under its name. The one at the side has a button to put it away.
private struct DocumentPane: View {
    @ObservedObject var document: Document
    let workspace: Workspace
    let atSide: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(document.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(workspace.relativePath(of: document.url))
                Spacer(minLength: 0)
                if atSide {
                    Button { workspace.closeSide() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle())
                        .help("Close Side Pane")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 32)
            DocumentView(document: document, workspace: workspace)
        }
        .background(Theme.background)
    }
}

/// The active file: its text, its rendered result, or both.
private struct DocumentView: View {
    @ObservedObject var document: Document
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if document.changedOnDisk {
                HStack(spacing: 12) {
                    Text("This file changed on disk while you were editing it.")
                        .font(.system(size: 13))
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
        case .video:
            if let video = document.video { VideoPreview(controller: video) }
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
    /// How wide the panel is, to know whether there's room for margins.
    let width: CGFloat
    /// Dragging the line above the panel resizes the split, when there's an editor above it.
    var resize: ((SplitHandle.Drag) -> Void)?
    @ObservedObject private var settings = Settings.shared

    /// The editor is showing above the terminal.
    private var underEditor: Bool { workspace.editorShown && workspace.activeDocument != nil }

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
                // Only where there's room for margins is there anything to switch.
                if Settings.sideMargin(available: width - 12, readable: settings.readableWidth) > 0 {
                    Button { settings.margins.toggle() } label: {
                        Image(systemName: settings.margins ? "arrow.left.and.right" : "arrow.right.and.arrow.left")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(settings.margins ? "Use the Full Width (⇧⌘M)" : "Show Margins (⇧⌘M)")
                }
                // Only with the terminal alone do the bars fade.
                if workspace.focusModePossible {
                    Button { settings.spotlight.toggle() } label: {
                        Image(systemName: settings.spotlight ? "lightbulb.fill" : "lightbulb")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(settings.spotlight ? "Turn Off Spotlight: Keep the Bars Shown" : "Turn On Spotlight: Fade the Bars Away")
                }
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
            .fadesInFocusMode(workspace)
            // With the bars faded, the folder's name stays, over the terminal's text and starting
            // where it starts, so one focused window can be told from another.
            .overlay(alignment: .leading) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .padding(.leading, 12 + (settings.margins ? Settings.sideMargin(available: width - 12, readable: settings.readableWidth) : 0))
                    .opacity(workspace.barsHidden ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: workspace.barsHidden)
                    .allowsHitTesting(false)
            }
            .background(BarDoubleClick { if !workspace.documents.isEmpty { workspace.toggleTerminalMaximized() } })
            .background(BarHover(workspace: workspace))

            if let session = workspace.activeTerminal {
                // Under the editor the text starts where the code does; alone, the column is centred.
                ReadableColumn(leading: underEditor ? settings.codeLeading : 12, centred: !underEditor, onMarginClick: session.focus) {
                    TerminalHost(session: session, focusToken: workspace.terminalFocusToken)
                }
                .padding(.bottom, 8)
            } else {
                MessageView(icon: "terminal", title: "No terminal open") {
                    Button("New Terminal") { workspace.newTerminal() }
                }
            }
        }
        .background(Theme.background)
        .overlay(alignment: .top) {
            if let resize {
                SplitHandle(resize: resize)
                    .frame(height: SplitHandle.height)
                    .offset(y: -SplitHandle.height / 2)
            }
        }
    }
}

/// Keeps the terminal's wide text readable: in a pane wider than a line reads well at, the
/// content is held to a centred column with empty margins either side. A narrower pane is filled
/// as before. The editor has no margins. The width changes in one step, because every width in
/// between would resize the terminal. Not `centred`, the column starts at `leading` and all the
/// spare room is at the right.
private struct ReadableColumn<Content: View>: View {
    /// Space always kept at the left, margins or not.
    var leading: CGFloat = 0
    var centred = true
    /// A click in a margin goes to the content, as it would if the text reached that far.
    var onMarginClick: () -> Void = {}
    @ViewBuilder let content: Content
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        GeometryReader { area in
            let spare = settings.margins ? max(0, area.size.width - leading - settings.readableWidth).rounded(.down) : 0
            let margin = settings.margins ? Settings.sideMargin(available: area.size.width - leading, readable: settings.readableWidth) : 0
            HStack(spacing: 0) {
                edge(width: leading + (centred ? margin : 0))
                content
                edge(width: centred ? margin : spare)
            }
        }
    }

    private func edge(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .onTapGesture(perform: onMarginClick)
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

/// Fades the window's close, minimise and zoom buttons with the top bar, in a window. They're
/// faded rather than hidden, so they stay where they are and still take a click.
private struct SystemButtonsFade: NSViewRepresentable {
    let hidden: Bool

    final class FadeView: NSView {
        var faded = false {
            didSet { if faded != oldValue { apply(animated: true) } }
        }

        // The first update comes before the view is in its window; it catches up here.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply(animated: false)
        }

        private func apply(animated: Bool) {
            guard let window else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.25 : 0
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(kind)?.animator().alphaValue = faded ? 0 : 1
                }
            }
        }
    }

    func makeNSView(context: Context) -> FadeView { FadeView() }

    func updateNSView(_ view: FadeView, context: Context) { view.faded = hidden }
}

/// Tells the workspace when the pointer is on a bar, which shows the bars in focus mode. It sits
/// behind the bar rather than in it, so the bar can fade out and still be found, and it lets
/// clicks through.
struct BarHover: NSViewRepresentable {
    let workspace: Workspace
    /// The bar is at the top of the screen, so the menu bar above it counts as on it: the bars
    /// stay while the menu bar is down.
    var reachesUp = false

    func makeNSView(context: Context) -> BarHoverView {
        let view = BarHoverView()
        view.workspace = workspace
        view.reachesUp = reachesUp
        return view
    }

    func updateNSView(_ view: BarHoverView, context: Context) {}
}

final class BarHoverView: NSView {
    weak var workspace: Workspace?
    var reachesUp = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { workspace?.registerBarArea(self) }
    }

    override func mouseEntered(with event: NSEvent) { workspace?.pointerEnteredBar() }

    var containsPointer: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        var area = window.convertToScreen(convert(bounds, to: nil))
        if reachesUp, let screen = window.screen { area.size.height = screen.frame.maxY - area.minY }
        return area.contains(NSEvent.mouseLocation)
    }
}

extension View {
    /// Fades a bar out in focus mode, in place, so nothing around it moves.
    func fadesInFocusMode(_ workspace: Workspace) -> some View {
        opacity(workspace.barsHidden ? 0 : 1)
            .animation(.easeInOut(duration: 0.25), value: workspace.barsHidden)
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

/// The grab area for the line between editor and terminal: a strip laid over the line, half over
/// the editor and half over the terminal's bar. It's an AppKit view so that it, and not the text
/// and scroll views on either side, gets the pointer.
struct SplitHandle: NSViewRepresentable {
    enum Drag {
        case began
        /// How far the pointer has moved down since the drag began, in points.
        case moved(CGFloat)
        case ended
    }

    /// How tall the grab area is.
    static let height: CGFloat = 10

    let resize: (Drag) -> Void

    final class HandleView: NSView {
        var resize: (Drag) -> Void = { _ in }
        private var startY: CGFloat?

        /// The first click into an inactive window grabs the line too.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            startY = event.locationInWindow.y
            resize(.began)
        }

        override func mouseDragged(with event: NSEvent) {
            // Window coordinates grow upwards.
            guard let startY else { return }
            resize(.moved(startY - event.locationInWindow.y))
        }

        override func mouseUp(with event: NSEvent) {
            guard startY != nil else { return }
            startY = nil
            resize(.ended)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
    }

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) { view.resize = resize }
}
