import SwiftUI

/// Placeholder for the gap between selection and the preview landing on
/// screen. Usually that gap is tens of milliseconds, so the spinner waits a
/// moment before fading in: fast navigation shows nothing at all, and a slow
/// drive or an iCloud download shows one quiet indicator.
struct PhotoSkeleton: View {
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .colorScheme(.dark) // always over the black photo backdrop
            .opacity(visible ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                if reduceMotion {
                    visible = true
                } else {
                    withAnimation(.easeIn(duration: Theme.Motion.standard)) { visible = true }
                }
            }
            .accessibilityLabel("Loading photo")
    }
}
