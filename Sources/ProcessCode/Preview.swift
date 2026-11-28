import AppKit
import AVKit
import cmark_gfm
import cmark_gfm_extensions
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: Markdown

enum Markdown {
    /// GitHub-flavoured Markdown to HTML: tables, task lists, strikethrough, autolinks, footnotes
    /// and raw HTML (READMEs use it for images and centring), with fenced code coloured.
    static func html(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let rendered = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(rendered) }
        return highlightCode(in: String(cString: rendered))
    }

    private static let codeBlock = try! NSRegularExpression(pattern: #"<pre><code class="language-([^"]+)">([\s\S]*?)</code></pre>"#)

    /// Colours the fenced code blocks whose language is known.
    static func highlightCode(in html: String) -> String {
        let source = html as NSString
        let result = NSMutableString(string: html)
        for match in codeBlock.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let language = Language.forFence(source.substring(with: match.range(at: 1))) else { continue }
            let code = unescape(source.substring(with: match.range(at: 2)))
            result.replaceCharacters(in: match.range(at: 2), with: colored(code, language: language))
        }
        return result as String
    }

    static func colored(_ code: String, language: Language) -> String {
        let text = code as NSString
        var html = ""
        var position = 0
        for span in Lexer.tokenize(code, language: language) where span.location >= position && span.location + span.length <= text.length {
            html += escape(text.substring(with: NSRange(location: position, length: span.location - position)))
            html += "<span class=\"\(span.token.cssClass)\">" + escape(text.substring(with: NSRange(location: span.location, length: span.length))) + "</span>"
            position = span.location + span.length
        }
        return html + escape(text.substring(from: position))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The page the preview loads once; its content is replaced in place as the text changes, so
    /// the scroll position holds.
    static var page: String {
        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        func variables(_ appearance: NSAppearance) -> String {
            let colors: [(String, NSColor)] = [
                ("bg", Theme.backgroundNS), ("text", Theme.textNS), ("muted", Theme.secondaryNS), ("border", Theme.borderNS),
                ("panel", Theme.sidebarNS), ("link", NSColor(light: 0x0969da, dark: 0x4493f8)),
                ("comment", Theme.syntaxComment), ("string", Theme.syntaxString), ("constant", Theme.syntaxConstant),
                ("keyword", Theme.syntaxKeyword), ("type", Theme.syntaxType), ("function", Theme.syntaxFunction), ("tag", Theme.syntaxTag),
            ]
            return colors.map { "--\($0.0): \($0.1.hexString(for: appearance));" }.joined(separator: " ")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        :root { \(variables(light)) color-scheme: light dark; }
        @media (prefers-color-scheme: dark) { :root { \(variables(dark)) } }
        html { background: var(--bg); }
        body { margin: 0; padding: 32px 40px 64px; color: var(--text); background: var(--bg);
               font: 15px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; word-wrap: break-word; }
        #content { max-width: 820px; margin: 0 auto; }
        #content > :first-child { margin-top: 0; }
        h1, h2, h3, h4, h5, h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
        h1 { font-size: 2em; padding-bottom: 8px; border-bottom: 1px solid var(--border); }
        h2 { font-size: 1.5em; padding-bottom: 8px; border-bottom: 1px solid var(--border); }
        h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: var(--muted); }
        p, ul, ol, pre, table, blockquote, dl { margin: 0 0 16px; }
        ul, ol { padding-left: 2em; } li + li { margin-top: 4px; } li > ul, li > ol { margin: 4px 0 0; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        img { max-width: 100%; }
        hr { height: 1px; margin: 24px 0; border: 0; background: var(--border); }
        blockquote { padding: 0 16px; color: var(--muted); border-left: 4px solid var(--border); }
        code { font: 85%/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; padding: 2px 6px; border-radius: 6px; background: var(--panel); }
        pre { padding: 16px; overflow: auto; border-radius: 8px; background: var(--panel); border: 1px solid var(--border); }
        pre code { padding: 0; background: none; font-size: 13px; }
        table { border-collapse: collapse; display: block; overflow: auto; width: max-content; max-width: 100%; }
        th, td { padding: 6px 12px; border: 1px solid var(--border); } th { font-weight: 600; background: var(--panel); }
        li:has(> input[type=checkbox]) { list-style: none; margin-left: -1.4em; }
        input[type=checkbox] { margin-right: 6px; }
        .footnotes { font-size: 13px; color: var(--muted); border-top: 1px solid var(--border); margin-top: 32px; padding-top: 16px; }
        .t-comment { color: var(--comment); } .t-string, .t-link { color: var(--string); }
        .t-number, .t-constant, .t-attribute, .t-heading { color: var(--constant); } .t-keyword { color: var(--keyword); }
        .t-type, .t-emphasis { color: var(--type); } .t-function { color: var(--function); } .t-tag { color: var(--tag); }
        </style></head><body><div id="content"></div>
        <script>function setContent(html) { document.getElementById('content').innerHTML = html; }</script>
        </body></html>
        """
    }
}

/// Serves files from disk to the preview, so a README's relative images load.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "leanfile"

    static func url(forDirectory directory: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "local"
        components.path = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return components.url
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let data = try? Data(contentsOf: URL(fileURLWithPath: url.path)) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: (url.path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct MarkdownPreview: NSViewRepresentable {
    @ObservedObject var document: Document
    /// Opens another file of the workspace that the page links to.
    let openFile: (URL) -> Void

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = false
        var pending: String?
        var revision = -1
        var openFile: (URL) -> Void = { _ in }
        /// The folder the page's relative images and links are read from: the file's.
        var base: URL?
        /// The page's load under way, so a finish from one it replaced isn't taken for it.
        var navigation: WKNavigation?

        /// Loads the page, reading relative images and links from `folder`. Its content is set again
        /// once it has loaded.
        func load(in webView: WKWebView, folder: URL) {
            base = folder
            loaded = false
            revision = -1
            navigation = webView.loadHTMLString(Markdown.page, baseURL: LocalFileSchemeHandler.url(forDirectory: folder))
        }

        func show(_ html: String, in webView: WKWebView) {
            guard loaded else { pending = html; return }
            guard let json = try? JSONSerialization.data(withJSONObject: [html]), let array = String(data: json, encoding: .utf8) else { return }
            webView.evaluateJavaScript("setContent(\(array)[0])")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard self.navigation == nil || navigation === self.navigation else { return }
            loaded = true
            if let pending { show(pending, in: webView) }
            pending = nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return decisionHandler(.allow) }
            if url.scheme == LocalFileSchemeHandler.scheme {
                // A link within the page scrolls; a link to another file opens it.
                if url.fragment != nil, url.path == webView.url?.path { return decisionHandler(.allow) }
                openFile(URL(fileURLWithPath: url.path))
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(in: webView, folder: document.url.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.openFile = openFile
        // A rename moved the file to another folder, and the tab followed it: read from there.
        let folder = document.url.deletingLastPathComponent()
        if context.coordinator.base != folder { context.coordinator.load(in: webView, folder: folder) }
        guard context.coordinator.revision != document.revision else { return }
        context.coordinator.revision = document.revision
        context.coordinator.show(Markdown.html(document.text), in: webView)
    }
}

// MARK: PDF

struct PDFPreview: NSViewRepresentable {
    let url: URL
    /// Changes when the file was rewritten and should be read again.
    let revision: Int

    final class Coordinator {
        var url: URL?
        var revision = -1
        var attempt = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = Theme.sidebarNS
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.url != url || coordinator.revision != revision else { return }
        let sameFile = coordinator.url == url
        coordinator.url = url
        coordinator.revision = revision
        coordinator.attempt += 1
        load(into: view, coordinator: coordinator, keepPosition: sameFile, attempt: coordinator.attempt, triesLeft: 8)
    }

    /// Reads the file, keeping the page and zoom. A PDF that is still being written doesn't
    /// parse yet, so a failed read is tried again shortly.
    private func load(into view: PDFView, coordinator: Coordinator, keepPosition: Bool, attempt: Int, triesLeft: Int) {
        guard coordinator.attempt == attempt else { return }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            if triesLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    load(into: view, coordinator: coordinator, keepPosition: keepPosition, attempt: attempt, triesLeft: triesLeft - 1)
                }
            }
            return
        }
        var pageIndex: Int?
        var point: NSPoint?
        let scale = view.scaleFactor
        let autoScales = view.autoScales
        if keepPosition, let destination = view.currentDestination, let page = destination.page, let old = view.document {
            pageIndex = old.index(for: page)
            point = destination.point
        }
        view.document = document
        if let pageIndex, let point, pageIndex < document.pageCount, let page = document.page(at: pageIndex) {
            if !autoScales { view.scaleFactor = scale }
            view.go(to: PDFDestination(page: page, at: point))
        }
    }
}

// MARK: Images and other files

struct ImagePreview: View {
    let url: URL
    let revision: Int

    var body: some View {
        let image = NSImage(contentsOf: url)
        VStack(spacing: 16) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                if let rep = image.representations.first {
                    Text("\(rep.pixelsWide) × \(rep.pixelsHigh)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
            } else {
                MessageView(icon: "photo", title: "This image couldn't be shown.")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(revision)
    }
}

/// A quiet, centred message for an empty or unsupported pane.
struct MessageView<Actions: View>: View {
    let icon: String
    let title: String
    var detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
            }
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension MessageView where Actions == EmptyView {
    init(icon: String, title: String, detail: String? = nil) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}

// MARK: Video

/// Plays one video file. The document owns it, so the place and the playing carry on when its
/// pane is rebuilt, and two of them can be played together.
final class VideoController: ObservableObject {
    let url: URL
    let player = AVPlayer()
    /// The file couldn't be played, and nothing from before is showing in its place.
    @Published private(set) var failed = false
    @Published private(set) var isPlaying = false
    /// The picture's width over its height, once known. The player is given that shape, so the
    /// space around it is the window's colour rather than black bars.
    @Published private(set) var aspect: CGFloat?

    private var attempt = 0
    private var observer: NSKeyValueObservation?
    private var ended: NSObjectProtocol?
    private var sizeObserver: NSKeyValueObservation?

    init(url: URL) {
        self.url = url
        observer = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            DispatchQueue.main.async { if self?.isPlaying != playing { self?.isPlaying = playing } }
        }
        sizeObserver = player.observe(\.currentItem?.presentationSize) { [weak self] player, _ in
            guard let size = player.currentItem?.presentationSize, size.width > 0, size.height > 0 else { return }
            let aspect = size.width / size.height
            DispatchQueue.main.async { if self?.aspect != aspect { self?.aspect = aspect } }
        }
        // A video goes round again when it runs out: the clips compared here last a second or two.
        player.actionAtItemEnd = .none
        ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
            self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }
        load(keepPosition: false, triesLeft: 8)
    }

    deinit {
        if let ended { NotificationCenter.default.removeObserver(ended) }
    }

    /// The file was rewritten: shows the new one, at the same place and still playing if it was.
    func reload() {
        load(keepPosition: true, triesLeft: 8)
    }

    /// A video that is still being written doesn't play yet, so a failed read is tried again
    /// shortly, and what was showing stays until the new file is ready.
    private func load(keepPosition: Bool, triesLeft: Int) {
        attempt += 1
        let attempt = attempt
        let asset = AVURLAsset(url: url)
        Task { @MainActor [weak self] in
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard let self, self.attempt == attempt else { return }
            guard playable else {
                if triesLeft > 0 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if self.attempt == attempt { self.load(keepPosition: keepPosition, triesLeft: triesLeft - 1) }
                } else if self.player.currentItem == nil {
                    self.failed = true
                }
                return
            }
            let time = self.player.currentTime()
            let wasPlaying = self.player.rate != 0
            let hadItem = self.player.currentItem != nil
            self.player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            self.failed = false
            if keepPosition, hadItem {
                _ = await self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying, self.attempt == attempt { self.player.play() }
            }
        }
    }

    func pause() { player.pause() }

    private var atEnd: Bool {
        guard let duration = player.currentItem?.duration, duration.isNumeric else { return false }
        return player.currentTime() >= duration
    }

    /// Plays two videos from the same moment (the first one's), or stops both. From the start
    /// again if the first has run out.
    static func togglePlaying(_ first: VideoController, _ second: VideoController) {
        if first.isPlaying || second.isPlaying {
            first.pause()
            second.pause()
            return
        }
        let time = first.atEnd ? CMTime.zero : first.player.currentTime()
        seek(first, second, to: time) {
            first.player.play()
            second.player.play()
        }
    }

    /// Takes both back to the start, playing or not.
    static func restart(_ first: VideoController, _ second: VideoController) {
        seek(first, second, to: .zero) {}
    }

    private static func seek(_ first: VideoController, _ second: VideoController, to time: CMTime, then: @escaping () -> Void) {
        let group = DispatchGroup()
        for controller in [first, second] {
            group.enter()
            controller.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in group.leave() }
        }
        group.notify(queue: .main, execute: then)
    }
}

struct VideoPreview: View {
    @ObservedObject var controller: VideoController

    var body: some View {
        if controller.failed {
            MessageView(icon: "film", title: "This video couldn't be played.") {
                Button("Open in Default App") { NSWorkspace.shared.open(controller.url) }
            }
        } else {
            VideoPlayerHost(controller: controller)
                .aspectRatio(controller.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct VideoPlayerHost: NSViewRepresentable {
    let controller: VideoController

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = controller.player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== controller.player { view.player = controller.player }
    }

    /// A video that's no longer on screen (its tab was left or closed) stops, sound and all.
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
