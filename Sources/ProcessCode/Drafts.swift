import CryptoKit
import Foundation

/// Unsaved text, kept on disk while it's being typed, so quitting, closing a window or a crash
/// loses none of it. Reopening the folder brings each file back with its changes still unsaved.
struct Draft: Codable, Equatable {
    /// The folder whose window the file was open in.
    var root: String
    /// The file.
    var path: String
    var text: String
    /// When the file on disk was last changed as the text was loaded or saved. If the file has
    /// changed since, the restored tab says so, as it does when a file changes while it's open.
    var diskDate: Date?
}

enum Drafts {
    /// Where drafts are kept. Tests point it somewhere of their own.
    nonisolated(unsafe) static var folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Process Code/Drafts", isDirectory: true)

    /// Every write and removal goes through one queue, in order, off the main thread.
    private static let queue = DispatchQueue(label: "Process Code drafts")

    /// One file per open file, named after its path, so a newer draft replaces the older.
    static func url(for file: URL) -> URL {
        let digest = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8))
        return folder.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    /// Keeps a draft in the background, while typing.
    static func write(_ draft: Draft) {
        let destination = url(for: URL(fileURLWithPath: draft.path))
        let folder = self.folder
        queue.async { _ = store(draft, at: destination, in: folder) }
    }

    /// Keeps a draft now, and says whether it was kept: before a window closes, when a draft that
    /// couldn't be written (a full disk, say) means asking about the file instead.
    static func writeNow(_ draft: Draft) -> Bool {
        let destination = url(for: URL(fileURLWithPath: draft.path))
        let folder = self.folder
        return queue.sync { store(draft, at: destination, in: folder) }
    }

    private static func store(_ draft: Draft, at destination: URL, in folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(draft).write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func remove(for file: URL) {
        let target = url(for: file)
        queue.async { try? FileManager.default.removeItem(at: target) }
    }

    /// Waits for the writes and removals already asked for, before the app quits.
    static func flush() {
        queue.sync {}
    }

    /// The drafts of files that were open in the window for `root`.
    static func all(root: URL) -> [Draft] {
        flush()
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let rootPath = root.standardizedFileURL.path
        return names.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Draft.self, from: Data(contentsOf: $0)) }
            .filter { $0.root == rootPath }
            .sorted { $0.path < $1.path }
    }
}
