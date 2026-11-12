import AppKit
import SwiftUI

/// What the hold-to-quit panel shows. The app fills the ring by animating `progress`.
public final class HoldToQuitModel: ObservableObject {
    @Published public var icon: NSImage
    @Published public var appName: String
    @Published public var progress: Double
    public init(icon: NSImage, appName: String, progress: Double = 0) {
        self.icon = icon; self.appName = appName; self.progress = progress
    }
}

/// The frontmost app's icon inside a ring that fills while ⌘Q is held.
public struct HoldToQuitView: View {
    @ObservedObject var model: HoldToQuitModel
    public init(model: HoldToQuitModel) { self.model = model }

    public static let ringSize: CGFloat = 76
    public static let ringWidth: CGFloat = 5

    public var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: Self.ringWidth)
                Circle()
                    .trim(from: 0, to: model.progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(nsImage: model.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
            }
            .frame(width: Self.ringSize, height: Self.ringSize)
            Text("Hold ⌘Q to Quit \(model.appName)")
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(minWidth: 240, maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hold Command Q to quit \(model.appName)")
    }
}
