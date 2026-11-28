import AppKit
import Combine
import SwiftUI

// MARK: Text view

/// Orders the changes in a window, so ⌘Z can undo whichever came last: typing in a file, or a
/// file moved to the Trash.
enum UndoClock {
    nonisolated(unsafe) private static var count = 0
    static func tick() -> Int {
        count += 1
        return count
    }
}

/// The code text view: plain text, no substitutions, indentation that follows the line above.
final class CodeTextView: NSTextView {
    var language = Language.plain
    var indentUnit = "    "
    /// The window's undo for files (putting back what went to the Trash), and when it last changed.
    var fileUndo: (() -> (manager: UndoManager, changed: Int)?)?
    /// When this file's text last changed, on the same clock.
    var edited = 0

    /// Whether ⌘Z (or ⇧⌘Z with `redo`) goes to the files rather than this file's text: when a file
    /// change is newer than the last edit here, or there's nothing here to undo.
    nonisolated static func undoesFiles(fileCan: Bool, fileChanged: Int, textCan: Bool, edited: Int) -> Bool {
        fileCan && (!textCan || fileChanged > edited)
    }

    /// The undo history ⌘Z or ⇧⌘Z works on now.
    private func history(redo: Bool) -> UndoManager? {
        let own = undoManager
        guard let files = fileUndo?() else { return own }
        let fileCan = redo ? files.manager.canRedo : files.manager.canUndo
        let textCan = redo ? own?.canRedo ?? false : own?.canUndo ?? false
        return CodeTextView.undoesFiles(fileCan: fileCan, fileChanged: files.changed, textCan: textCan, edited: edited) ? files.manager : own
    }

    @objc func undo(_ sender: Any?) { history(redo: false)?.undo() }
    @objc func redo(_ sender: Any?) { history(redo: true)?.redo() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            let manager = history(redo: false)
            item.title = manager?.undoMenuItemTitle ?? "Undo"
            return manager?.canUndo ?? false
        case #selector(redo(_:)):
            let manager = history(redo: true)
            item.title = manager?.redoMenuItemTitle ?? "Redo"
            return manager?.canRedo ?? false
        default:
            return super.validateMenuItem(item)
        }
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let selection = selectedRange()
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        var indent = String(before.prefix { $0 == " " || $0 == "\t" })
        if language.kind == .code, let last = before.trimmingCharacters(in: .whitespaces).last, "{[(:".contains(last) {
            indent += indentUnit
        }
        insertText("\n" + indent, replacementRange: selection)
    }

    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, (string as NSString).substring(with: selection).contains("\n") {
            changeLines { self.indentUnit + $0 }
        } else if indentUnit == "\t" {
            insertText("\t", replacementRange: selection)
        } else {
            // Up to the next indent stop.
            let text = string as NSString
            let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let column = selection.location - line.location
            let width = indentUnit.count - column % indentUnit.count
            insertText(String(repeating: " ", count: width), replacementRange: selection)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        changeLines { line in
            if line.hasPrefix(self.indentUnit) { return String(line.dropFirst(self.indentUnit.count)) }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.drop { $0 == " " })
        }
    }

    /// Comments or uncomments the selected lines.
    @objc func toggleComment(_ sender: Any?) {
        guard let marker = language.lineComments.first ?? (language.kind == .tex ? "%" : nil) else { NSSound.beep(); return }
        let text = string as NSString
        let lines = text.substring(with: text.lineRange(for: selectedRange())).split(separator: "\n", omittingEmptySubsequences: false)
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !content.isEmpty && content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(marker) }
        changeLines { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let rest = line.dropFirst(indent.count)
            if allCommented {
                let stripped = rest.dropFirst(marker.count)
                return String(indent) + String(stripped.hasPrefix(" ") ? stripped.dropFirst() : stripped)
            }
            return String(indent) + marker + " " + String(rest)
        }
    }

    /// Rewrites every line the selection touches, as one undoable edit, and keeps them selected.
    private func changeLines(_ transform: (String) -> String) {
        let text = string as NSString
        let range = text.lineRange(for: selectedRange())
        var block = text.substring(with: range)
        let endsWithNewline = block.hasSuffix("\n")
        if endsWithNewline { block.removeLast() }
        var result = block.split(separator: "\n", omittingEmptySubsequences: false).map { transform(String($0)) }.joined(separator: "\n")
        if endsWithNewline { result += "\n" }
        guard shouldChangeText(in: range, replacementString: result) else { return }
        textStorage?.replaceCharacters(in: range, with: result)
        didChangeText()
        let length = (result as NSString).length - (endsWithNewline ? 1 : 0)
        setSelectedRange(NSRange(location: range.location, length: max(length, 0)))
    }

    // Paste and drop as plain text only.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

// MARK: Line numbers

/// The line-number column beside the text.
final class GutterView: NSView {
    weak var textView: CodeTextView?
    var lineStarts: [Int] = [0] { didSet { needsDisplay = true } }
    var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }

    /// Room for four digits whatever the file's length, so the code starts at the same place in
    /// every file up to 9,999 lines, and the terminal's text can start there too.
    static let minimumDigits = 4
    /// How far the code's first character is from the gutter's right edge: the text view's inset
    /// and its container's padding.
    static let textInset: CGFloat = 9

    /// Wide enough for the largest line number, with room either side.
    var preferredWidth: CGFloat { GutterView.width(lines: lineStarts.count, font: font) }

    static func width(lines: Int, font: NSFont) -> CGFloat {
        let digits = max(String(lines).count, minimumDigits)
        return ceil(CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width) + 28
    }

    func lineNumber(at location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fill only this column: since macOS 14 a view isn't clipped to its bounds, and the dirty
        // rectangle can reach across the text beside it.
        Theme.backgroundNS.setFill()
        bounds.fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = textView.visibleRect
        let inset = textView.textContainerInset.height
        let text = textView.string as NSString
        let current = lineNumber(at: textView.selectedRange().location)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.tertiaryNS]
        let currentAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.textNS]

        func draw(_ number: Int, lineRect: NSRect) {
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            let y = lineRect.minY + inset - visible.minY + (lineRect.height - size.height) / 2
            label.draw(at: NSPoint(x: bounds.width - 12 - size.width, y: y),
                       withAttributes: number == current ? currentAttributes : attributes)
        }

        let glyphs = layoutManager.glyphRange(forBoundingRect: visible.offsetBy(dx: 0, dy: -inset), in: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let location = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            // Only the first fragment of a wrapped line is numbered.
            if location == 0 || text.character(at: location - 1) == 10 {
                draw(self.lineNumber(at: location), lineRect: rect)
            }
        }
        if layoutManager.extraLineFragmentTextContainer != nil {
            draw(lineStarts.count, lineRect: layoutManager.extraLineFragmentRect)
        }
    }
}

/// The gutter and the scrolling text, side by side.
final class EditorContainerView: NSView {
    let gutter = GutterView()
    let scrollView = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(scrollView)
        addSubview(gutter)
        gutter.clipsToBounds = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private var placed = false
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func layout() {
        super.layout()
        defer {
            // The first time it has a size, start at the top of the file.
            if !placed, bounds.height > 0 {
                placed = true
                scrollView.documentView?.setFrameOrigin(.zero)
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        let width = gutter.preferredWidth
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(bounds.width - width, 0), height: bounds.height)
    }
}

// MARK: Controller

/// Owns one document's text view, so its undo history, scroll position and selection survive
/// switching tabs. The text in the view is the document's text.
final class EditorController: NSObject, NSTextViewDelegate {
    let container = EditorContainerView()
    let textView: CodeTextView
    private let language: Language
    private var spans: [Span] = []
    private var highlighted = NSRange(location: 0, length: 0)
    private var tokenizeGeneration = 0
    private var observers: Set<AnyCancellable> = []
    private var loading = false

    /// Called after every edit by the user.
    var onEdit: (() -> Void)?
    /// This file's undo history, apart from the other files' and from the window's.
    private let history = UndoManager()

    var text: String { textView.string }

    init(text: String, language: Language) {
        self.language = language
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: 1e7))
        layoutManager.addTextContainer(textContainer)
        textView = CodeTextView(frame: .zero, textContainer: textContainer)
        super.init()

        textView.language = language
        textView.indentUnit = EditorController.indentUnit(of: text, language: language)
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 12)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: 1e7, height: 1e7)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        if language.wraps {
            textContainer.widthTracksTextView = true
        } else {
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(width: 1e7, height: 1e7)
            textView.isHorizontallyResizable = true
        }

        let scrollView = container.scrollView
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !language.wraps
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        // Otherwise the window's tall title bar pushes the text down, though this view isn't under it.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        container.gutter.textView = textView
        container.onAppearanceChange = { [weak self] in self?.rehighlight(); self?.container.gutter.needsDisplay = true }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.frameDidChangeNotification,
                                               object: textView)
        textView.postsFrameChangedNotifications = true

        applyStyle()
        setText(text)
        Settings.shared.$fontName.merge(with: Settings.shared.$fontSize.map { _ in "" }).dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyStyle(); self?.rehighlight() }
            .store(in: &observers)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Tabs if the file uses them, otherwise the width of its smallest indent.
    static func indentUnit(of text: String, language: Language) -> String {
        var smallest = Int.max
        for line in text.split(separator: "\n").prefix(400) {
            if line.hasPrefix("\t") { return "\t" }
            let spaces = line.prefix { $0 == " " }.count
            if spaces >= 2, spaces < line.count { smallest = min(smallest, spaces) }
        }
        return String(repeating: " ", count: smallest == 2 || smallest == 4 ? smallest : language.indent)
    }

    /// Replaces the whole text (on load and when the file changes on disk), keeping the view where it was.
    func setText(_ text: String) {
        loading = true
        let selection = textView.selectedRange()
        let origin = container.scrollView.contentView.bounds.origin
        textView.string = text
        applyParagraphStyle()
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        if origin != .zero {
            container.scrollView.contentView.scroll(to: origin)
            container.scrollView.reflectScrolledClipView(container.scrollView.contentView)
        }
        textView.undoManager?.removeAllActions()
        loading = false
        textChanged()
    }

    func focus() { textView.window?.makeFirstResponder(textView) }

    func undoManager(for view: NSTextView) -> UndoManager? { history }

    /// Scrolls to a 1-based line and puts the insertion point there.
    func reveal(line: Int) {
        let starts = container.gutter.lineStarts
        let location = starts[min(max(line - 1, 0), starts.count - 1)]
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    private var paragraphStyle: NSParagraphStyle {
        let font = Settings.shared.codeFont
        let style = NSMutableParagraphStyle()
        style.lineSpacing = round(font.pointSize * 0.3)
        style.tabStops = []
        style.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: font]).width
        return style
    }

    private func applyParagraphStyle() {
        guard let storage = textView.textStorage else { return }
        storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: storage.length))
    }

    private func applyStyle() {
        let font = Settings.shared.codeFont
        textView.font = font
        textView.textColor = Theme.textNS
        textView.backgroundColor = Theme.backgroundNS
        textView.insertionPointColor = Theme.accentNS
        textView.selectedTextAttributes = [.backgroundColor: Theme.selectionNS]
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [.font: font, .foregroundColor: Theme.textNS, .paragraphStyle: paragraphStyle]
        applyParagraphStyle()
        container.scrollView.backgroundColor = Theme.backgroundNS
        container.gutter.font = Settings.shared.gutterFont
        container.needsLayout = true
        container.gutter.needsDisplay = true
    }

    // MARK: Changes

    func textDidChange(_ notification: Notification) {
        guard !loading else { return }
        textView.edited = UndoClock.tick()
        textChanged()
        onEdit?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        container.gutter.needsDisplay = true
    }

    private func textChanged() {
        let text = textView.string
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        let widthBefore = container.gutter.preferredWidth
        container.gutter.lineStarts = starts
        if container.gutter.preferredWidth != widthBefore { container.needsLayout = true }

        // Small files are coloured as you type; large ones off the main thread.
        tokenizeGeneration += 1
        let generation = tokenizeGeneration
        let language = self.language
        if offset < 200_000 {
            spans = Lexer.tokenize(text, language: language)
            rehighlight()
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let spans = Lexer.tokenize(text, language: language)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.tokenizeGeneration == generation else { return }
                    self.spans = spans
                    self.rehighlight()
                }
            }
        }
    }

    @objc private func scrolled() {
        container.gutter.needsDisplay = true
        highlightVisible()
    }

    func rehighlight() {
        highlighted = NSRange(location: 0, length: 0)
        highlightVisible()
    }

    /// Colours the text on screen, plus a margin. Colours are temporary attributes, so they never
    /// touch the text, its layout or the undo history.
    private func highlightVisible() {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let length = (textView.string as NSString).length
        guard length > 0 else { return }
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        if highlighted.length > 0, visible.location >= highlighted.location, NSMaxRange(visible) <= NSMaxRange(highlighted) { return }

        let start = max(visible.location - 4000, 0)
        let end = min(NSMaxRange(visible) + 4000, length)
        let range = NSRange(location: start, length: end - start)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)

        // The first span that ends after the start of the range.
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].location + spans[mid].length <= start { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < spans.count, spans[index].location < end {
            let span = spans[index]
            let clipped = NSIntersectionRange(NSRange(location: span.location, length: span.length), range)
            if clipped.length > 0, NSMaxRange(clipped) <= length {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.syntaxColor(span.token), forCharacterRange: clipped)
            }
            index += 1
        }
        highlighted = range
    }
}

/// A plain view that keeps one AppKit view filling it. SwiftUI hosts are created with no size,
/// so the child is laid out here rather than by autoresizing from zero.
final class FillingHostView: NSView {
    private(set) weak var content: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Returns true if the content changed.
    @discardableResult
    func show(_ view: NSView) -> Bool {
        guard view.superview !== self else { return false }
        subviews.forEach { $0.removeFromSuperview() }
        view.autoresizingMask = []
        view.frame = bounds
        addSubview(view)
        content = view
        return true
    }

    override func layout() {
        super.layout()
        if let content, content.frame != bounds { content.frame = bounds }
    }
}

/// Shows the editor of whichever document is active.
struct EditorHost: NSViewRepresentable {
    let controller: EditorController

    func makeNSView(context: Context) -> FillingHostView { FillingHostView() }

    func updateNSView(_ host: FillingHostView, context: Context) {
        host.show(controller.container)
    }
}
