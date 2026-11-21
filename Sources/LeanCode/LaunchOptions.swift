import AppKit

/// Command-line options. A folder or file to open is the everyday one:
///
///     LeanCode ~/Documents/GitHub/resume
///
/// The rest set up a window and save a picture of it, which is how the app's design is checked
/// without anyone clicking through it:
///
///     LeanCode <folder> --shell --open README.md --mode split --layout split \
///         --appearance dark --snapshot /tmp/shot.png --delay 3
struct LaunchOptions {
    var folders: [URL] = []
    var files: [String] = []
    var appearance: Appearance?
    var mode: Document.Mode?
    /// "terminal" (terminal fills the window), "split" or "editor".
    var layout: String?
    var sidebar: String?
    var filter: String?
    var type: String?
    /// Start a plain shell even if an agent is set to start.
    var plainShell = false
    var snapshot: String?
    var delay = 2.5
    var size: NSSize?
    /// Checks: paste into the terminal, press Shift-Return in it, report what a click at a point would hit.
    var paste = false
    var save = false
    var settings = false
    /// For a picture of the projects window: a filter to type, a sheet to show ("clone" or "new").
    var projectsFilter: String?
    var sheet: String?
    var pressReturn = false
    var switchTo: Appearance?
    var shiftReturn = false
    var hit: NSPoint?
    /// Starts the window in full screen and prints which windows the app has on screen then.
    var fullScreen = false

    init() {}

    init(arguments: [String]) {
        var index = 0
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--open": if let v = value() { files.append(v) }
            case "--appearance": appearance = value().flatMap(Appearance.init(rawValue:))
            case "--mode": mode = value().flatMap(Document.Mode.init(rawValue:))
            case "--layout": layout = value()
            case "--sidebar": sidebar = value()
            case "--filter": filter = value()
            case "--type": type = value()
            case "--shell": plainShell = true
            case "--paste": paste = true
            case "--save": save = true
            case "--settings": settings = true
            case "--projects-filter": projectsFilter = value()
            case "--sheet": sheet = value()
            case "--return": pressReturn = true
            case "--switch-to": switchTo = value().flatMap(Appearance.init(rawValue:))
            case "--shift-return": shiftReturn = true
            case "--fullscreen": fullScreen = true
            case "--hit":
                let parts = (value() ?? "").split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 { hit = NSPoint(x: parts[0], y: parts[1]) }
            case "--snapshot": snapshot = value()
            case "--delay": delay = value().flatMap(Double.init) ?? delay
            case "--size":
                let parts = (value() ?? "").split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
            default:
                // AppKit's own "-Key value" pairs are skipped; anything else is a path.
                if argument.hasPrefix("-") { index += 1 } else {
                    folders.append(URL(fileURLWithPath: (argument as NSString).expandingTildeInPath))
                }
            }
            index += 1
        }
    }

    /// Applies the window options, then saves the picture and quits if one was asked for.
    @MainActor
    func run(with controller: WorkspaceWindowController?) {
        if settings {
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
            if snapshot != nil { capture(NSApp.keyWindow) }
            return
        }
        guard let controller, let window = controller.window else {
            if let size, let projects = NSApp.windows.first(where: { $0.isVisible }) { projects.setContentSize(size); projects.center() }
            if let projectsFilter { ProjectStore.shared.search = projectsFilter }
            if let sheet { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ProjectsView.requestedSheet.send(sheet) } }
            if pressReturn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if let window = NSApp.keyWindow { LaunchOptions.press("\r", code: 36, [], in: window) }
                }
            }
            if snapshot != nil { capture(nil) }
            return
        }
        let workspace = controller.workspace
        if let size { window.setContentSize(size); window.center() }
        for file in files { workspace.open(workspace.root.appendingPathComponent(file)) }
        if let mode { workspace.activeDocument?.mode = mode }
        switch layout {
        case "terminal": workspace.terminalVisible = true; workspace.terminalMaximized = true
        case "split": workspace.terminalVisible = true; workspace.terminalMaximized = false
        case "editor": workspace.terminalVisible = false; workspace.terminalMaximized = false
        default: break
        }
        if sidebar == "changes" { workspace.sidebarMode = .changes }
        if sidebar == "hidden" { workspace.sidebarVisible = false }
        if let filter { workspace.filter = filter }
        if fullScreen {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { window.toggleFullScreen(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(delay - 0.5, 1)) {
                print("fullscreen:", window.styleMask.contains(.fullScreen), "toolbar visible:", window.toolbar?.isVisible ?? false)
                for w in NSApp.windows where w.isVisible {
                    // The title bar's own window should stay clear (alpha 0) until it's called down.
                    print("window:", String(describing: Swift.type(of: w)), w.frame, "alpha:", w.alphaValue)
                }
            }
        }
        if let type {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                workspace.activeTerminal?.view.send(txt: type.replacingOccurrences(of: "\\n", with: "\r"))
            }
        }
        if paste || shiftReturn {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(delay - 3, 1)) {
                guard let terminal = workspace.activeTerminal?.view else { return }
                window.makeFirstResponder(terminal)
                // The real keystroke, through the Edit menu, as when typed.
                if paste { LaunchOptions.press("v", code: 9, [.command], in: window) }
                if shiftReturn {
                    terminal.send(txt: "first line")
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                        NSApp.postEvent(event, atStart: false)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { terminal.send(txt: "second line") }
                }
            }
        }
        if save {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let editor = workspace.activeDocument?.editor else { return }
                editor.focus()
                editor.textView.insertText("% edited\n", replacementRange: NSRange(location: 0, length: 0))
                LaunchOptions.press("s", code: 1, [.command], in: window)
            }
        }
        if let switchTo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.appearance = switchTo == .system ? nil : NSAppearance(named: switchTo == .dark ? .darkAqua : .aqua)
            }
        }
        if let hit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // The point is measured from the window's top left, as on screen.
                guard let frame = window.contentView?.superview else { return }
                var view = frame.hitTest(NSPoint(x: hit.x, y: frame.bounds.height - hit.y))
                var chain: [String] = []
                while let current = view { chain.append(String(describing: Swift.type(of: current))); view = current.superview }
                print("hit:", chain.joined(separator: " < "))
            }
        }
        if snapshot != nil { capture(window) }
    }

    @MainActor
    static func press(_ key: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: key,
                                        charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) {
            NSApp.postEvent(event, atStart: false)
        }
    }

    @MainActor
    private func capture(_ window: NSWindow?) {
        guard let snapshot else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // The system's own capture of the window, which sees what the screen shows (the
            // terminal draws in a layer that a view snapshot misses). Falls back to the views.
            let url = URL(fileURLWithPath: snapshot)
            // Whichever window is in front by now.
            let window = window ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
            if let window {
                Shell.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(window.windowNumber), snapshot])
            }
            if !FileManager.default.fileExists(atPath: snapshot),
               let view = window?.contentView?.superview ?? window?.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
            exit(0)
        }
    }
}
