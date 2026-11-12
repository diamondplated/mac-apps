import SwiftUI
import AppKit

/// The few design constants Latent's views share. Matches the Mac Tools
/// suite: one corner-radius scale, a small spacing scale, and the colour
/// label palette that thumbnails, the filter bar and the menus all use.
enum Theme {
    /// Corner radii, always drawn with continuous corners.
    enum Radius {
        /// Buttons, fields, thumbnails, small badges.
        static let control: CGFloat = 6
        /// Rows, tiles and other card-like groups.
        static let card: CGFloat = 10
        /// Floating panels: the loader, the shortcut sheet.
        static let panel: CGFloat = 14
    }

    enum Spacing {
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let regular: CGFloat = 12
        static let large: CGFloat = 20
        static let section: CGFloat = 32
    }

    /// Shared timing for things that appear or disappear.
    enum Motion {
        static let quick: Double = 0.15
        static let standard: Double = 0.2
    }

    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// The nine colour labels, keyed 1-9 like the number keys that set them.
/// The first five follow the familiar photo-workflow palette; 6-9 stay
/// visually distinct so every label is recognisable at thumbnail size.
enum ColorLabel {
    static let all = Array(1...9)

    static func color(_ label: Int) -> Color {
        switch label {
        case 1: .red
        case 2: .yellow
        case 3: .green
        case 4: .blue
        case 5: .purple
        case 6: .orange
        case 7: .cyan
        case 8: .mint
        case 9: .pink
        default: .gray
        }
    }

    static func name(_ label: Int) -> String {
        switch label {
        case 1: "Red"
        case 2: "Yellow"
        case 3: "Green"
        case 4: "Blue"
        case 5: "Purple"
        case 6: "Orange"
        case 7: "Cyan"
        case 8: "Mint"
        case 9: "Pink"
        default: "None"
        }
    }

    /// A filled dot for menu items. Menus draw SF Symbols as monochrome
    /// templates, so the dot is a small non-template bitmap instead.
    static func menuIcon(_ label: Int) -> Image {
        let size = NSSize(width: 12, height: 12)
        let fill = NSColor(color(label))
        let image = NSImage(size: size, flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}

extension View {
    /// An eased transition duration that collapses to an instant change
    /// when the user has turned on Reduce Motion.
    func latentAnimation<V: Equatable>(_ value: V, reduceMotion: Bool, duration: Double = Theme.Motion.standard) -> some View {
        animation(reduceMotion ? nil : .easeInOut(duration: duration), value: value)
    }
}
