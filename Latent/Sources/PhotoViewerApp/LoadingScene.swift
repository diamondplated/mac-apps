import SwiftUI

/// Shown in place of the grid while a folder is scanned or an archive is
/// extracted. One indeterminate indicator, what is happening, which folder,
/// a live count, and Stop for scans.
struct LoadingScene: View {
    let phase: AppState.LoadPhase
    let lastError: String?
    /// Stop callback. Shown only while scanning: interrupting an archive
    /// extract mid-stream would leave a half-written temporary folder.
    var onStop: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.regular) {
            ProgressView()
                .controlSize(.large)
                .padding(.bottom, Theme.Spacing.tight)

            VStack(spacing: Theme.Spacing.tight) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260)
                Text(status)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let onStop, case .scanning = phase {
                Button("Stop", action: onStop)
                    .controlSize(.regular)
                    .padding(.top, Theme.Spacing.tight)
            }

            if let lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 260)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch phase {
        case .extracting: "Extracting Archive"
        case .scanning: "Scanning Folder"
        }
    }

    private var subtitle: String {
        switch phase {
        case .extracting(let name): name
        case .scanning(let name, _): name
        }
    }

    /// Snaps to each new value rather than rolling the digits: the scan
    /// reports in batches, and overlapping numeric transitions used to render
    /// as scrambled glyphs.
    private var status: String {
        switch phase {
        case .extracting:
            "Decompressing…"
        case .scanning(_, let n):
            n == 0 ? "Looking for photos…" : "\(n.formatted()) found"
        }
    }
}
