import SwiftUI

/// The one type scale and the one radius scale. Every view takes its fonts and corner radii from
/// here; nothing under 11 pt, no half points. The numbers match the Mac Tools manager: 6 for
/// controls, 10 for cards, 14 for panels, always continuous corners.
enum Theme {
    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 10
        static let panel: CGFloat = 14
    }

    /// Short and eased, for anything that appears or disappears. Reduce Motion is honoured by
    /// `siftAnimation(value:)` rather than at each call site.
    static let transition = Animation.easeInOut(duration: 0.18)
}

extension Font {
    static let siftCaption = Font.system(size: 11)
    static let siftCaptionStrong = Font.system(size: 11, weight: .semibold)
    static let siftMono = Font.system(size: 11, design: .monospaced)
    static let siftLabel = Font.system(size: 12)
    static let siftLabelStrong = Font.system(size: 12, weight: .semibold)
    static let siftLabelMono = Font.system(size: 12, design: .monospaced)
    static let siftBody = Font.system(size: 13)
    static let siftBodyStrong = Font.system(size: 13, weight: .semibold)
    static let siftTitle = Font.system(size: 15, weight: .semibold)
}

extension RoundedRectangle {
    /// A rounded rectangle with a radius from `Theme.Radius`, always continuous.
    static func sift(_ radius: CGFloat = Theme.Radius.control) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

extension View {
    /// An eased transition for `value` changes that honours Reduce Motion.
    func siftAnimation<V: Equatable>(value: V) -> some View {
        modifier(SiftAnimation(value: value))
    }
}

private struct SiftAnimation<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : Theme.transition, value: value)
    }
}
