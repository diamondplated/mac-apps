import SwiftUI

/// The containing app's one small window.
public struct StatusView: View {
    public static let size = CGSize(width: 380, height: 252)
    public let isEnabled: Bool
    public var openSettings: () -> Void

    public init(isEnabled: Bool, openSettings: @escaping () -> Void = {}) {
        self.isEnabled = isEnabled
        self.openSettings = openSettings
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "contextualmenu.and.cursorarrow")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("RightHere").font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                Circle().fill(isEnabled ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text(isEnabled ? "Finder Extension Is On" : "Finder Extension Is Off").font(.headline)
            }
            .accessibilityElement(children: .combine)
            Text("Adds New File, Open Terminal Here and Copy Path to Finder's right-click menu.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2)
            Button(isEnabled ? "Open Extension Settings" : "Turn On in System Settings") { openSettings() }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.background)
    }
}
