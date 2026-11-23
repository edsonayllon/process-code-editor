import AppKit
import SwiftUI

/// The left column: go-to-file, the file tree or the list of changes, and the branch.
struct SidebarView: View {
    @ObservedObject var workspace: Workspace
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // The window's close, minimise and zoom buttons sit at the left of this bar. In full
            // screen they and the sidebar's button are in the title bar strip above.
            if workspace.isFullScreen {
                Color.clear.frame(height: 12)
            } else {
                HStack(spacing: 4) {
                    Spacer()
                    Button { workspace.sidebarVisible = false } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(IconButtonStyle(glass: true))
                        .help("Hide Sidebar (⌘B)")
                }
                .padding(.horizontal, 12)
                .frame(height: Theme.barHeight)
                .background(WindowDragArea())
            }

            filterField
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            if workspace.filter.trimmingCharacters(in: .whitespaces).isEmpty {
                header
                switch workspace.sidebarMode {
                case .files: tree
                case .changes: changes
                }
            } else {
                results
            }

            footer
        }
        .background(Theme.sidebar)
        .onChange(of: workspace.filterFocusToken) { filterFocused = true }
    }

    // MARK: Go to file

    private var filterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
            TextField("Go to file", text: $workspace.filter)
                .tint(Theme.accent)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($filterFocused)
                .onSubmit {
                    if let first = workspace.filterResults.first { openResult(first) }
                }
                .onExitCommand {
                    workspace.filter = ""
                    filterFocused = false
                }
            if !workspace.filter.isEmpty {
                Button { workspace.filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .glassEffect(.regular, in: Capsule())
    }

    private func openResult(_ path: String) {
        let url = workspace.root.appendingPathComponent(path)
        workspace.filter = ""
        workspace.reveal(url)
        workspace.open(url)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(workspace.filterResults.enumerated()), id: \.element) { index, path in
                    PathRow(path: path, url: workspace.root.appendingPathComponent(path),
                            state: workspace.git.state(of: path, isDirectory: false), selected: index == 0) { openResult(path) }
                }
                if workspace.filterResults.isEmpty {
                    Text("No files match")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: Files and changes

    private var header: some View {
        HStack(spacing: 4) {
            ModeTab(title: "Files", selected: workspace.sidebarMode == .files) { workspace.sidebarMode = .files }
            ModeTab(title: "Changes", count: workspace.git.changeCount, selected: workspace.sidebarMode == .changes) {
                workspace.sidebarMode = .changes
            }
            Spacer()
            Menu {
                Button("New File…") { workspace.newItem(directory: false) }
                Button("New Folder…") { workspace.newItem(directory: true) }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.secondary)
            .help("New File or Folder")
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.bottom, 8)
    }

    private var tree: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(workspace.rows) { row in
                    TreeRowView(row: row, workspace: workspace)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .contextMenu {
            Button("New File…") { workspace.newItem(directory: false, in: workspace.root) }
            Button("New Folder…") { workspace.newItem(directory: true, in: workspace.root) }
        }
    }

    private var changes: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let changes = workspace.git.changes
                ForEach(changes, id: \.path) { change in
                    let url = workspace.root.appendingPathComponent(change.path)
                    PathRow(path: change.path, url: url, state: change.state, selected: workspace.selectedPath == url.path) {
                        workspace.selectedPath = url.path
                        workspace.open(url)
                    }
                }
                if changes.isEmpty {
                    Text(workspace.git.isRepository ? "No changes" : "Not a git repository")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    // MARK: Branch

    private var footer: some View {
        HStack(spacing: 8) {
            if let branch = workspace.git.branch {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Text(branch)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if workspace.git.ahead > 0 { Text("↑\(workspace.git.ahead)").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                if workspace.git.behind > 0 { Text("↓\(workspace.git.behind)").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
            } else {
                Text(workspace.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) } label: { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle())
                .help("Settings (⌘,)")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 44)
    }
}

/// "Files" / "Changes 3": a text tab in the sidebar's header.
private struct ModeTab: View {
    let title: String
    var count = 0
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(selected ? Theme.secondary : Theme.tertiary)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(selected ? Theme.text : (hovering ? Theme.text : Theme.secondary))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.primary.opacity(selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A file or folder in the tree. Dragging it onto the terminal types its path, as from Finder.
private struct TreeRowView: View {
    let row: TreeRow
    @ObservedObject var workspace: Workspace
    @State private var hovering = false

    var body: some View {
        let state = workspace.git.state(of: row.relativePath, isDirectory: row.isDirectory)
        let selected = workspace.selectedPath == row.url.path
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
                .rotationEffect(.degrees(workspace.isExpanded(row) ? 90 : 0))
                .opacity(row.isDirectory ? 1 : 0)
                .frame(width: 10)
            Text(row.name)
                .font(.system(size: 13))
                .foregroundStyle(nameColor(state))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let state, state != .ignored {
                if row.isDirectory {
                    Circle().fill(state.color).frame(width: 6, height: 6).padding(.trailing, 3)
                } else {
                    Text(state.letter)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state.color)
                }
            }
        }
        .padding(.leading, 8 + CGFloat(row.depth) * 12)
        .padding(.trailing, 8)
        .frame(height: Theme.rowHeight)
        .background(Color.primary.opacity(selected ? 0.1 : (hovering ? 0.05 : 0)), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: row.url as NSURL) }
        .onTapGesture {
            workspace.selectedPath = row.url.path
            // With Option held, a file opens beside the one that's showing.
            if row.isDirectory { workspace.toggle(row) } else { workspace.open(row.url, toSide: NSEvent.modifierFlags.contains(.option)) }
        }
        .contextMenu {
            let folder = row.isDirectory ? row.url : row.url.deletingLastPathComponent()
            if !row.isDirectory {
                Button("Open to the Side") { workspace.open(row.url, toSide: true) }
                Divider()
            }
            Button("New File…") { workspace.newItem(directory: false, in: folder) }
            Button("New Folder…") { workspace.newItem(directory: true, in: folder) }
            Divider()
            Button("Rename…") { workspace.rename(row.url) }
            Button("Move to Trash") { workspace.trash(row.url) }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
            Button("Copy Path") { copy(row.url.path) }
            Button("Copy Relative Path") { copy(row.relativePath) }
        }
    }

    private func nameColor(_ state: GitState?) -> Color {
        guard let state else { return Theme.text }
        if state == .ignored { return Theme.tertiary }
        return row.isDirectory ? Theme.text : state.color
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A file shown by its path: the name, then its folder, quieter. Used for changes and search results.
private struct PathRow: View {
    let path: String
    let url: URL
    let state: GitState?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let directory = (path as NSString).deletingLastPathComponent
        HStack(spacing: 8) {
            Text(path.lastComponent + (path.hasSuffix("/") ? "/" : ""))
                .font(.system(size: 13))
                .foregroundStyle(state.map { $0 == .ignored ? Theme.tertiary : $0.color } ?? Theme.text)
                .strikethrough(state == .deleted)
                .lineLimit(1)
                .layoutPriority(1)
            Text(directory)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if let state, state != .ignored {
                Text(state.letter)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state.color)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.rowHeight)
        .background(Color.primary.opacity(selected ? 0.1 : (hovering ? 0.05 : 0)), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .onTapGesture(perform: action)
    }
}

private extension String {
    var lastComponent: String { (self as NSString).lastPathComponent }
}

/// An empty stretch of a bar that moves the window when dragged, and zooms it on a double click.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
