import AppKit
import SwiftUI

extension NSColor {
    /// A colour that follows the app's appearance.
    convenience init(light: UInt32, dark: UInt32) {
        self.init(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }

    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }

    /// "#rrggbb", resolved for the given appearance.
    func hexString(for appearance: NSAppearance) -> String {
        var result = "#000000"
        appearance.performAsCurrentDrawingAppearance {
            guard let c = usingColorSpace(.sRGB) else { return }
            result = String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)),
                            Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
        }
        return result
    }
}

/// One palette, one radius family and one spacing scale (multiples of 4) for the whole app.
/// The colours are dark-grey neutrals (not near-black, which glares against light text) with a single
/// accent, the periwinkle of the app's icon. The syntax colours are GitHub's, which is what the code is read against everywhere else;
/// the dark git colours are softer tints of GitHub's hues.
enum Theme {
    // Surfaces
    static let backgroundNS = NSColor(light: 0xffffff, dark: 0x171918)
    static let sidebarNS = NSColor(light: 0xf5f6f5, dark: 0x1d1f1e)
    static let borderNS = NSColor(light: 0xdcdfdd, dark: 0x303432)
    /// The accent, washed into the surface.
    static let selectionNS = NSColor(light: 0xdfe2fd, dark: 0x343a66)

    // Text
    static let textNS = NSColor(light: 0x1f2328, dark: 0xdcdfdd)
    static let secondaryNS = NSColor(light: 0x59636e, dark: 0x9a9f9c)
    static let tertiaryNS = NSColor(light: 0x8a929b, dark: 0x808582)

    // The accent is the icon's periwinkle (scripts/make-icon.swift), darkened in light mode to stay legible.
    // It marks where you are: the caret, the selection, the project that's open.
    static let accentNS = NSColor(light: 0x4f5bd5, dark: 0xb1b9f9)

    // Git states. In dark mode green and yellow are lifted to one lightness (OKLCH L 0.82),
    // between secondary and primary text, so a changed file never reads dimmer than an unchanged one.
    static let addedNS = NSColor(light: 0x1a7f37, dark: 0x75df8f)
    static let modifiedNS = NSColor(light: 0x9a6700, dark: 0xe8be62)
    static let deletedNS = NSColor(light: 0xcf222e, dark: 0xff7b72)

    static let background = Color(nsColor: backgroundNS)
    static let sidebar = Color(nsColor: sidebarNS)
    static let border = Color(nsColor: borderNS)
    static let text = Color(nsColor: textNS)
    static let secondary = Color(nsColor: secondaryNS)
    static let tertiary = Color(nsColor: tertiaryNS)
    static let accent = Color(nsColor: accentNS)
    /// The accent as a fill behind white, for the system's switches and pickers.
    static let accentFill = Color(nsColor: NSColor(light: 0x4f5bd5, dark: 0x6f7ae8))
    static let added = Color(nsColor: addedNS)
    static let modified = Color(nsColor: modifiedNS)
    static let deleted = Color(nsColor: deletedNS)

    static let radius: CGFloat = 8
    static let smallRadius: CGFloat = 6
    /// The height of the bar at the top of the sidebar and of the content, and of the terminal's bar.
    static let barHeight: CGFloat = 52
    static let rowHeight: CGFloat = 28

    // Syntax colours (GitHub light and dark).
    static func syntaxColor(_ token: Token) -> NSColor {
        switch token {
        case .plain: return textNS
        case .comment: return syntaxComment
        case .string: return syntaxString
        case .number, .constant: return syntaxConstant
        case .keyword: return syntaxKeyword
        case .type: return syntaxType
        case .function: return syntaxFunction
        case .tag: return syntaxTag
        case .attribute: return syntaxConstant
        case .heading: return syntaxConstant
        case .emphasis: return syntaxType
        case .link: return syntaxString
        }
    }

    static let syntaxComment = NSColor(light: 0x59636e, dark: 0x8b949e)
    static let syntaxString = NSColor(light: 0x0a3069, dark: 0xa5d6ff)
    static let syntaxConstant = NSColor(light: 0x0550ae, dark: 0x79c0ff)
    static let syntaxKeyword = NSColor(light: 0xcf222e, dark: 0xff7b72)
    static let syntaxType = NSColor(light: 0x953800, dark: 0xffa657)
    static let syntaxFunction = NSColor(light: 0x8250df, dark: 0xd2a8ff)
    static let syntaxTag = NSColor(light: 0x116329, dark: 0x7ee787)

    /// The sixteen ANSI colours for the terminal, normal then bright. The greys that agents write their
    /// secondary text in (bright black in dark, the whites in light) keep 4.5:1 against the background.
    /// Black in dark stays dark, since it's mostly used as a background.
    static func ansiColors(dark: Bool) -> [UInt32] {
        dark
            ? [0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
               0x8b949e, 0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xffffff]
            : [0x24292f, 0xcf222e, 0x116329, 0x7d4e00, 0x0969da, 0x8250df, 0x1b7c83, 0x656d76,
               0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x6e7781]
    }
}

extension GitState {
    var color: Color {
        switch self {
        case .modified, .renamed: return Theme.modified
        case .added, .untracked: return Theme.added
        case .deleted, .conflicted: return Theme.deleted
        case .ignored: return Theme.tertiary
        }
    }
}

// MARK: Controls

/// A borderless icon button that shows a soft plate on hover, as in the bars.
struct IconButtonStyle: ButtonStyle {
    var active = false
    /// A round glass button, for the bar across the top of the window, as the system's own
    /// toolbar buttons are. Buttons in the content stay flat.
    var glass = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, active: active, glass: glass)
    }

    struct Styled: View {
        let configuration: Configuration
        let active: Bool
        let glass: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let label = configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active || hovering ? Theme.text : Theme.secondary)
                .frame(width: 28, height: 28)
            Group {
                if glass {
                    label.glassEffect(.regular.tint(active ? Color.primary.opacity(0.12) : nil).interactive(enabled), in: Circle())
                } else {
                    label.background(Color.primary.opacity(configuration.isPressed ? 0.14 : (active ? 0.1 : (hovering ? 0.07 : 0))),
                                     in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                }
            }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }
        }
    }
}

/// A draggable hairline between two panes.
struct Divider1: View {
    enum Axis { case horizontal, vertical }
    /// `.vertical` is a vertical line (between side-by-side panes).
    /// A line that resizes the panes beside it gets a `SplitHandle` laid over it.
    let axis: Axis

    var body: some View {
        let line = Rectangle().fill(Theme.border)
        if axis == .vertical { line.frame(width: 1) } else { line.frame(height: 1) }
    }
}
