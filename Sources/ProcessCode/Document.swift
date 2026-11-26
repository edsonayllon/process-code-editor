import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

/// One open file: its tab, its editor (for text) and how it's being viewed.
final class Document: ObservableObject, Identifiable {
    enum Kind: Equatable {
        case text, pdf, image, video
        /// Shown as a message instead of content (binary or too large).
        case unsupported(String)
    }

    /// Source, rendered result, or both side by side. Only Markdown and LaTeX have a result.
    enum Mode: String, CaseIterable {
        case code, split, preview
    }

    enum Build: Equatable {
        case idle, running, succeeded
        case failed(String)
    }

    static let maximumTextSize = 8_000_000

    let url: URL
    let kind: Kind
    let language: Language
    var id: String { url.path }
    var name: String { url.lastPathComponent }

    @Published var isDirty = false
    @Published var changedOnDisk = false
    @Published var mode: Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: modeKey) } }
    /// Goes up whenever a preview of this document should refresh.
    @Published var revision = 0
    @Published var build = Build.idle
    /// The PDF a LaTeX file builds to, once known.
    @Published var pdfURL: URL?

    private(set) var editor: EditorController?
    /// The player, for a video.
    private(set) var video: VideoController?
    private var loadedDate: Date?
    private var previewTimer: Timer?
    private var draftTimer: Timer?
    /// The folder whose window this file is open in, while its unsaved text is kept as a draft.
    /// Nil while the app is only being photographed, which leaves no trace.
    var draftRoot: URL?

    var isMarkdown: Bool { language.kind == .markdown }
    var isTeX: Bool { language.kind == .tex && ["tex", "ltx"].contains(url.pathExtension.lowercased()) }
    var hasPreview: Bool { kind == .text && (isMarkdown || isTeX) }
    var text: String { editor?.text ?? "" }
    private var modeKey: String { isTeX ? "mode.tex" : "mode.markdown" }

    /// `draft` is unsaved text kept from before, for a file that's no longer on disk: the tab
    /// opens with it, and saving puts the file back.
    init(url: URL, draft: String? = nil) {
        self.url = url
        language = Language.forFile(url)
        var text: String?
        if let draft, !FileManager.default.fileExists(atPath: url.path) {
            kind = .text
            text = draft
        } else if let media = Document.mediaKind(of: url) {
            kind = media
        } else if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            if data.count > Document.maximumTextSize {
                kind = .unsupported("This file is too large to edit here (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))).")
            } else if data.prefix(8000).contains(0) {
                kind = .unsupported("This is a binary file.")
            } else {
                kind = .text
                text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            }
        } else {
            kind = .unsupported("This file couldn't be read.")
        }
        mode = .code
        if hasPreview {
            mode = Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .split
        }
        loadedDate = Document.modificationDate(url)

        if let text {
            let editor = EditorController(text: text, language: language)
            editor.onEdit = { [weak self] in self?.edited() }
            self.editor = editor
        }
        if isTeX { pdfURL = Latex.existingPDF(for: url) }
        if kind == .video { video = VideoController(url: url) }
    }

    /// The kind of a file that's shown rather than edited, going by its name: a PDF, an image, or
    /// a video in a format the system plays. Nil for everything else, which is read to find out.
    static func mediaKind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image), !type.conforms(to: .svg) { return .image }
        if type.conforms(to: .movie), playableTypes.contains(where: type.conforms(to:)) { return .video }
        return nil
    }

    /// The containers AVFoundation opens (MP4, QuickTime and the like; not WebM or Matroska).
    private static let playableTypes = AVURLAsset.audiovisualContentTypes

    /// Whether two modification dates are the same, allowing for the rounding of a round trip through JSON.
    static func sameDate(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) < 0.001
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func edited() {
        if !isDirty { isDirty = true }
        // The preview follows typing, a beat behind.
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in self?.revision += 1 }
        // The draft is kept a beat after typing stops.
        if draftRoot != nil {
            draftTimer?.invalidate()
            draftTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.keepDraft() }
        }
    }

    /// Keeps the unsaved text as a draft, if there is any. `now` writes it before returning, and
    /// says whether it was kept; false means the text would be lost without asking about it.
    @discardableResult
    func keepDraft(now: Bool = false) -> Bool {
        draftTimer?.invalidate()
        draftTimer = nil
        guard isDirty, let editor else { return true }
        guard let draftRoot else { return false }
        let draft = Draft(root: draftRoot.standardizedFileURL.path, path: url.standardizedFileURL.path, text: editor.text, diskDate: loadedDate)
        if now { return Drafts.writeNow(draft) }
        Drafts.write(draft)
        return true
    }

    /// Forgets the draft: the text was saved, reloaded or let go.
    func discardDraft() {
        draftTimer?.invalidate()
        draftTimer = nil
        if draftRoot != nil { Drafts.remove(for: url) }
    }

    /// Puts back unsaved text kept from before. If the file on disk has changed since, the tab
    /// says so, and Keep Mine or Reload decides. A draft that matches the file is just dropped.
    func restore(_ draft: Draft) {
        guard let editor else { return }
        let onDisk = FileManager.default.fileExists(atPath: url.path)
        if onDisk, editor.text == draft.text {
            discardDraft()
            return
        }
        if editor.text != draft.text { editor.setText(draft.text) }
        isDirty = true
        if onDisk, !Document.sameDate(loadedDate, draft.diskDate) { changedOnDisk = true }
        revision += 1
    }

    /// Writes the text in place, keeping the file's permissions.
    func save() throws {
        guard let editor else { return }
        try Data(editor.text.utf8).write(to: url)
        loadedDate = Document.modificationDate(url)
        isDirty = false
        changedOnDisk = false
        discardDraft()
    }

    /// Something under the workspace changed on disk; `paths` are the files involved.
    func filesChanged(_ paths: Set<String>) {
        if let pdfURL, paths.contains(pdfURL.path) { revision += 1 }
        guard paths.contains(url.path) else { return }
        switch kind {
        case .pdf, .image:
            revision += 1
        case .video:
            video?.reload()
        case .text:
            guard let date = Document.modificationDate(url), date != loadedDate else { return }
            if isDirty { changedOnDisk = true } else { reload() }
        case .unsupported:
            break
        }
    }

    /// Takes the file's contents from disk, discarding any edits here.
    func reload() {
        guard let editor, let data = try? Data(contentsOf: url) else { return }
        editor.setText(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
        loadedDate = Document.modificationDate(url)
        isDirty = false
        changedOnDisk = false
        discardDraft()
        revision += 1
    }
}
