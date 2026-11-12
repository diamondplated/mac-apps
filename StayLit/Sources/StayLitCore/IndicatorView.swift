import SwiftUI

public struct IndicatorModel: Equatable {
    public enum Kind: Equatable { case brightness, volume, muted }
    public var kind: Kind
    /// 0–1.
    public var level: Double
    public var displayName: String
    public init(kind: Kind, level: Double, displayName: String) {
        self.kind = kind; self.level = min(max(level, 0), 1); self.displayName = displayName
    }

    var symbol: String {
        switch kind {
        case .brightness: return "sun.max.fill"
        case .muted: return "speaker.slash.fill"
        case .volume:
            if level <= 0 { return "speaker.fill" }
            return level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }

    var accessibilityLabel: String {
        let name = kind == .brightness ? "Brightness" : "Volume"
        return kind == .muted ? "\(displayName) muted" : "\(displayName) \(name) \(Int((level * 100).rounded())) percent"
    }
}

/// The on-screen indicator shown on the display whose brightness or volume changed.
public struct IndicatorView: View {
    public static let size = CGSize(width: 260, height: 64)
    let model: IndicatorModel
    public init(model: IndicatorModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                LevelBar(fraction: model.kind == .muted ? 0 : model.level)
                    .frame(height: 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: Self.size.width)
        .frame(minHeight: Self.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
    }
}

private struct LevelBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule().fill(Color.primary.opacity(0.85))
                    .frame(width: max(fraction > 0 ? proxy.size.height : 0, proxy.size.width * fraction))
            }
        }
    }
}
