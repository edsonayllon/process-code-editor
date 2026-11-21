import AppKit
import Combine
import SwiftUI

/// What a new window shows: the projects on this Mac, most recently worked on first. Type to
/// filter, Return to open. Cloning and starting a repository are one button away.
struct ProjectsView: View {
    @ObservedObject var store = ProjectStore.shared
    /// Whether a folder already has a window.
    let isOpen: (String) -> Bool
    let open: (URL) -> Void
    let chooseFolder: () -> Void

    enum Sheet: String, Identifiable {
        case clone, new
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?
    @FocusState private var filterFocused: Bool
    /// Lets a launch option put a sheet up, for a picture of it.
    static let requestedSheet = PassthroughSubject<String, Never>()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Projects")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Clone…") { sheet = .clone }
                    .buttonStyle(PlateButtonStyle(glass: true))
                    .help("Clone a repository from GitHub or a URL")
                Button("New…") { sheet = .new }
                    .buttonStyle(PlateButtonStyle(glass: true))
                    .help("Start a new repository")
                Button("Open Folder…", action: chooseFolder)
                    .buttonStyle(PlateButtonStyle(glass: true))
                    .help("Open any folder (⌘O)")
            }
            .padding(.horizontal, 24)
            .padding(.top, 44)
            .padding(.bottom, 16)
            .background(WindowDragArea())

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                TextField("Filter projects", text: $store.search)
                    .tint(Theme.accent)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($filterFocused)
                    .onSubmit(openSelection)
                    .onKeyPress(.downArrow) { store.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { store.moveSelection(-1); return .handled }
                    .onExitCommand { store.search = "" }
                if store.isLoading { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16) }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            list

            HStack(spacing: 8) {
                Text((store.rootPath as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(store.projects.count == 1 ? "1 project" : "\(store.projects.count) projects")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 24)
            .frame(height: 40)
        }
        .frame(minWidth: 560, minHeight: 360)
        .background(Theme.background)
        .ignoresSafeArea()
        .onAppear {
            filterFocused = true
            store.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refresh() }
        .onReceive(ProjectsView.requestedSheet) { sheet = Sheet(rawValue: $0) }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .clone: CloneSheet(store: store, finished: finished)
            case .new: NewRepositorySheet(store: store, finished: finished)
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.visible) { project in
                        ProjectRow(project: project, selected: project.path == store.selection, isOpen: isOpen(project.path)) {
                            open(project.url)
                        }
                        .id(project.path)
                        .contextMenu {
                            Button("Open") { open(project.url) }
                            Divider()
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                            if let web = project.webURL { Button("View on \(web.host == "github.com" ? "GitHub" : "the Web")") { NSWorkspace.shared.open(web) } }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(project.path, forType: .string)
                            }
                            if project.isExternal {
                                Divider()
                                Button("Remove from List") { store.forget(project) }
                            }
                        }
                    }
                    if store.visible.isEmpty {
                        MessageView(icon: "folder", title: store.projects.isEmpty ? "No repositories here yet" : "No projects match",
                                    detail: store.projects.isEmpty ? "Clone one, start one, or open any folder." : nil)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .onChange(of: store.selection) { _, path in
                if let path { proxy.scrollTo(path) }
            }
        }
    }

    private func openSelection() {
        if let project = store.visible.first(where: { $0.path == store.selection }) ?? store.visible.first { open(project.url) }
    }

    /// A clone or a new repository is opened as soon as it exists.
    private func finished(_ url: URL) {
        sheet = nil
        store.refresh()
        open(url)
    }
}

/// One project: its name, then branch, what's uncommitted or unpushed, and how long ago it was touched.
private struct ProjectRow: View {
    let project: Project
    let selected: Bool
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(project.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if isOpen {
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    .help("Open in a window")
            }
            if !project.isRepository {
                Text("no git")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
            if project.isExternal {
                Text((((project.path as NSString).deletingLastPathComponent) as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if project.changes > 0 {
                    Text("\(project.changes)")
                        .foregroundStyle(Theme.modified)
                        .help(project.changes == 1 ? "1 uncommitted change" : "\(project.changes) uncommitted changes")
                }
                if project.ahead > 0 { Text("↑\(project.ahead)").foregroundStyle(Theme.secondary).help("Commits to push") }
                if project.behind > 0 { Text("↓\(project.behind)").foregroundStyle(Theme.secondary).help("Commits to pull") }
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            // The usual branch goes without saying; any other is worth seeing.
            if let branch = project.branch, !Project.usualBranches.contains(branch) {
                Text(branch)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .trailing)
                    .fixedSize()
            }
            Text(project.activity == .distantPast ? "" : Project.age(of: project.activity))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.primary.opacity(selected ? 0.1 : (hovering ? 0.05 : 0)), in: RoundedRectangle(cornerRadius: Theme.radius))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

// MARK: Sheets

/// The bordered plate used for the window's secondary actions.
struct PlateButtonStyle: ButtonStyle {
    var prominent = false
    /// A glass capsule, for the buttons across the top of the window, as in the workspace's bar.
    /// Buttons in a sheet stay flat plates.
    var glass = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, prominent: prominent, glass: glass)
    }

    struct Styled: View {
        let configuration: Configuration
        let prominent: Bool
        let glass: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let label = configuration.label
                .font(.system(size: 13, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? Theme.background : Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
            Group {
                if glass {
                    label
                        .glassEffect(.regular.interactive(enabled), in: Capsule())
                        .opacity(enabled ? 1 : 0.4)
                        .contentShape(Capsule())
                } else {
                    label
                        .background(prominent ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.1 : 0.06)),
                                    in: RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(prominent ? Color.clear : Theme.border))
                        .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                        .contentShape(Rectangle())
                }
            }
            .onHover { hovering = $0 }
        }
    }
}

/// The frame every sheet shares: a title, the content, any error, then Cancel and the action.
private struct SheetFrame<Content: View>: View {
    let title: String
    let confirm: String
    let busyText: String
    let canConfirm: Bool
    /// Runs off the main thread; returns the folder to open.
    let action: () -> Result<URL, ProjectError>
    let finished: (URL) -> Void
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            content
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.deleted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(busyText).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PlateButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: run)
                    .buttonStyle(PlateButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm || busy)
            }
        }
        .padding(24)
        .background(Theme.background)
    }

    private func run() {
        busy = true
        error = nil
        let action = self.action
        DispatchQueue.global(qos: .userInitiated).async {
            let result = action()
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let url): finished(url)
                case .failure(let failure): error = failure.message
                }
            }
        }
    }
}

private extension View {
    /// A text field drawn in the app's own style.
    func field() -> some View {
        textFieldStyle(.plain)
            .tint(Theme.accent)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.radius))
    }
}

/// Clone one of your GitHub repositories, or anything by URL, into the projects folder.
private struct CloneSheet: View {
    enum Source: String, CaseIterable, Identifiable {
        case github = "Your GitHub"
        case url = "URL"
        var id: String { rawValue }
    }

    @ObservedObject var store: ProjectStore
    let finished: (URL) -> Void

    @State private var source = Source.github
    @State private var remotes: [RemoteRepository] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var filter = ""
    @State private var picked: String?
    @State private var url = ""

    private var shown: [RemoteRepository] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? remotes : remotes.filter { $0.nameWithOwner.lowercased().contains(query) }
    }

    private var target: String {
        source == .github ? (picked ?? "") : url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let root = store.rootPath
        let target = self.target
        SheetFrame(title: "Clone a repository", confirm: "Clone", busyText: "Cloning…", canConfirm: !target.isEmpty,
                   action: { ProjectStore.clone(target, into: root) }, finished: finished) {
            HStack(spacing: 4) {
                ForEach(Source.allCases) { tab in
                    Button { source = tab } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(source == tab ? Theme.text : Theme.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Color.primary.opacity(source == tab ? 0.1 : 0), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if source == .github {
                TextField("", text: $filter, prompt: Text("Filter your repositories")).field()
                remoteList
            } else {
                TextField("", text: $url, prompt: Text("https://github.com/owner/name or owner/name")).field()
                Spacer(minLength: 0)
            }
            Text("Clones into \((root as NSString).abbreviatingWithTildeInPath)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(width: 480, height: 500)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = ProjectStore.remoteRepositories()
                DispatchQueue.main.async {
                    switch result {
                    case .success(let list): remotes = list
                    case .failure(let failure): loadError = failure.message
                    }
                    loading = false
                }
            }
        }
    }

    private var remoteList: some View {
        let cloned = Set(store.projects.compactMap { $0.slug?.lowercased() })
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(shown) { remote in
                    let isCloned = cloned.contains(remote.nameWithOwner.lowercased())
                    HStack(spacing: 12) {
                        Image(systemName: remote.isPrivate ? "lock" : "book.closed")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 16)
                        Text(remote.nameWithOwner)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if isCloned { Text("On this Mac").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: Theme.rowHeight)
                    .background(Color.primary.opacity(picked == remote.nameWithOwner ? 0.1 : 0), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    .contentShape(Rectangle())
                    .opacity(isCloned ? 0.5 : 1)
                    .onTapGesture { if !isCloned { picked = remote.nameWithOwner } }
                }
                if loading {
                    ProgressView().controlSize(.small).padding(.top, 24)
                } else if let loadError {
                    Text(loadError)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                } else if shown.isEmpty {
                    Text("No repositories match").font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.top, 24)
                }
            }
            .padding(4)
        }
        .frame(maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}

/// Start a repository in the projects folder.
private struct NewRepositorySheet: View {
    @ObservedObject var store: ProjectStore
    let finished: (URL) -> Void
    @State private var name = ""
    @State private var readme = true
    @FocusState private var focused: Bool

    var body: some View {
        let root = store.rootPath
        let name = self.name, readme = self.readme
        SheetFrame(title: "New repository", confirm: "Create", busyText: "Creating…",
                   canConfirm: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                   action: { ProjectStore.create(name: name, readme: readme, in: root) }, finished: finished) {
            TextField("", text: $name, prompt: Text("Name")).field().focused($focused)
            Toggle("Start with a README and a first commit", isOn: $readme)
                .font(.system(size: 13))
            Text("Created in \((root as NSString).abbreviatingWithTildeInPath). Publish it to GitHub from Lean GitHub or with gh.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 420)
        .onAppear { focused = true }
    }
}
