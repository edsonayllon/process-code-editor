import AppKit
import Combine
import SwiftUI

/// What a new window shows: the projects on this Mac, most recently worked on first. Type to
/// filter, Return to open. Cloning and starting a repository are one button away; publishing one
/// to GitHub and moving one to the Trash are on its right-click menu.
struct ProjectsView: View {
    @ObservedObject var store = ProjectStore.shared
    /// Whether a folder already has a window.
    let isOpen: (String) -> Bool
    let open: (URL) -> Void
    let chooseFolder: () -> Void

    enum Sheet: Identifiable {
        case clone, new
        case publish(Project)
        var id: String {
            switch self {
            case .clone: return "clone"
            case .new: return "new"
            case .publish(let project): return "publish:" + project.path
            }
        }
    }

    @State private var sheet: Sheet?
    /// The project waiting on the "Move to Trash?" confirmation, freshly read.
    @State private var pendingTrash: Project?
    @State private var trashError: String?
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
        .onReceive(ProjectsView.requestedSheet, perform: showRequested)
        .sheet(item: $sheet) { kind in
            switch kind {
            case .clone: CloneSheet(store: store, finished: finished)
            case .new: NewRepositorySheet(store: store, finished: finished)
            case .publish(let project): PublishSheet(project: project, finished: published, failed: { store.refresh() })
            }
        }
        .alert(
            "Move “\(pendingTrash?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { project in
            Button("Move to Trash", role: .destructive) {
                // A second alert put up while this one is still going away can be dropped, so the
                // error waits until it has gone.
                if let error = store.moveToTrash(project) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { trashError = error }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text(ProjectStore.trashWarning(for: project))
        }
        .alert("Couldn't move it to the Trash",
               isPresented: Binding(get: { trashError != nil }, set: { if !$0 { trashError = nil } }),
               presenting: trashError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    /// A sheet asked for by a launch option, for a picture of it. Publish waits until git has read
    /// the list (up to 10 seconds), so it picks a repository that really isn't on GitHub if there is one.
    private func showRequested(_ name: String) {
        showRequested(name, tries: 20)
    }

    private func showRequested(_ name: String, tries: Int) {
        switch name {
        case "clone": sheet = .clone
        case "new": sheet = .new
        case "publish":
            if (store.isLoading || !store.projects.contains(where: \.isRead)) && tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showRequested(name, tries: tries - 1) }
                return
            }
            let list = store.visible
            if let project = list.first(where: \.canPublish) ?? list.first { sheet = .publish(project) }
        default: break
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.visible) { project in
                        ProjectRow(project: project, isPrivate: store.isPrivate(project), selected: project.path == store.selection,
                                   isOpen: isOpen(project.path)) {
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
                            if project.canPublish {
                                Button("Publish to GitHub…") { sheet = .publish(project) }
                            }
                            Divider()
                            if project.isExternal {
                                Button("Remove from List") { store.forget(project) }
                            }
                            // Only repositories, and not one with a window: close the window first.
                            if project.isRepository {
                                Button("Move to Trash…") { confirmTrash(project) }
                                    .disabled(isOpen(project.path) || store.trashRefusal(for: project) != nil)
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
        store.refresh(askGitHub: true)
        open(url)
    }

    /// A published repository stays in the list, now with its remote and lock.
    private func published(_ url: URL) {
        sheet = nil
        store.refresh(askGitHub: true)
    }

    /// Reads the repository again before warning, so the warning counts what's there now.
    private func confirmTrash(_ project: Project) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = project.inspectedForTrash()
            DispatchQueue.main.async { pendingTrash = fresh }
        }
    }
}

/// One project: its name, then branch, what's uncommitted or unpushed, and how long ago it was touched.
private struct ProjectRow: View {
    let project: Project
    /// nil when it isn't on GitHub, or GitHub hasn't said.
    let isPrivate: Bool?
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
            if isPrivate == true {
                Image(systemName: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .help("Private on GitHub")
            }
            if isOpen {
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    .help("Open in a window")
            }
            if !project.isRepository {
                Text("no git")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            } else if project.canPublish {
                Text("not on GitHub")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .help("Publish it from the right-click menu")
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
    /// After a failure, which may still have changed something on disk.
    var failed: () -> Void = {}
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
                case .failure(let failure):
                    error = failure.message
                    failed()
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
    @State private var publish = false
    @State private var isPrivate = true
    @FocusState private var focused: Bool

    var body: some View {
        let root = store.rootPath
        let name = self.name, readme = self.readme, publish = self.publish, isPrivate = self.isPrivate
        SheetFrame(title: "New repository", confirm: publish ? "Create and Publish" : "Create",
                   busyText: publish ? "Creating and publishing…" : "Creating…",
                   canConfirm: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                   action: { ProjectStore.create(name: name, readme: readme, publish: publish, isPrivate: isPrivate, in: root) },
                   finished: finished,
                   // If it was made but not published, it's on the list to publish or push from.
                   failed: { store.refresh() }) {
            TextField("", text: $name, prompt: Text("Name")).field().focused($focused)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Start with a README and a first commit", isOn: $readme)
                Toggle("Publish to GitHub now", isOn: $publish)
                if publish {
                    Toggle("Keep it private", isOn: $isPrivate)
                        .padding(.leading, 20)
                }
            }
            .font(.system(size: 13))
            Text(publish
                 ? "Created in \((root as NSString).abbreviatingWithTildeInPath), then published to your GitHub account as \(isPrivate ? "private" : "public")."
                 : "Created in \((root as NSString).abbreviatingWithTildeInPath).")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 420)
        .onAppear { focused = true }
    }
}

/// Make a GitHub repository for a local one and push it, with the GitHub CLI's sign-in.
private struct PublishSheet: View {
    let project: Project
    let finished: (URL) -> Void
    let failed: () -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var isPrivate = true
    @FocusState private var focused: Bool

    var body: some View {
        let project = self.project
        let githubName = name, about = description, makePrivate = isPrivate
        SheetFrame(title: "Publish “\(project.name)” to GitHub", confirm: "Publish", busyText: "Publishing…",
                   canConfirm: !ProjectStore.githubName(for: githubName).isEmpty,
                   action: { ProjectStore.publish(project, name: githubName, description: about, isPrivate: makePrivate) },
                   finished: finished, failed: failed) {
            TextField("", text: $name, prompt: Text("Name on GitHub")).field().focused($focused)
            TextField("", text: $description, prompt: Text("Description (optional)")).field()
            Toggle("Keep it private", isOn: $isPrivate)
                .font(.system(size: 13))
            let cleaned = ProjectStore.githubName(for: githubName)
            Text((project.hasCommits
                  ? "Makes the repository on your GitHub account, sets it as origin and pushes."
                  : "Makes the repository on your GitHub account and sets it as origin. There are no commits to push yet.")
                 + (cleaned.isEmpty || cleaned == githubName.trimmingCharacters(in: .whitespaces) ? "" : " It will be named “\(cleaned)”."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 420)
        .onAppear {
            if name.isEmpty { name = ProjectStore.githubName(for: project.name) }
            focused = true
        }
    }
}
