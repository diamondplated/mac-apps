import SwiftUI
import EnhancementStages

// The rows inside each enhancement inspector section. The section header
// owns the stage's on/off switch (see `EnhancementPanel`); these views hold
// only the stage's parameters, as label / slider / value rows.
//
// Each slider calls `state.runPipeline()` when the user releases it, so a
// drag doesn't start a pipeline run for every tick.

@MainActor
struct ArtifactRemovalControls: View {
    @Bindable var state: EnhancementState

    var body: some View {
        ParameterSlider(
            label: "Strength",
            value: $state.artifactRemovalParams.strength,
            range: 0...1,
            format: "%.2f",
            onCommit: { state.runPipeline() }
        )
        .disabled(!state.artifactRemovalEnabled)
    }
}

@MainActor
struct DenoiseControls: View {
    @Bindable var state: EnhancementState

    var body: some View {
        Group {
            ParameterSlider(
                label: "Strength",
                value: $state.denoiseParams.strength,
                range: 0...1,
                format: "%.2f",
                onCommit: { state.runPipeline() }
            )
            ParameterSlider(
                label: "Keep Detail",
                value: $state.denoiseParams.preserveDetailBias,
                range: 0...1,
                format: "%.2f",
                onCommit: { state.runPipeline() }
            )
        }
        .disabled(!state.denoiseEnabled)
    }
}

/// Upscale has no parameters: it is always 2×, through Real-ESRGAN when the
/// model is installed and Lanczos otherwise. One read-only row says so.
@MainActor
struct UpscaleControls: View {
    @Bindable var state: EnhancementState

    var body: some View {
        LabeledContent("Scale") {
            Text("\(Upscale.Params.supportedScale)×")
                .monospacedDigit()
        }
        .foregroundStyle(state.upscaleEnabled ? .primary : .secondary)
    }
}

@MainActor
struct SharpenControls: View {
    @Bindable var state: EnhancementState

    var body: some View {
        Group {
            ParameterSlider(
                label: "Amount",
                value: $state.sharpenParams.amount,
                range: 0...2,
                format: "%.2f",
                onCommit: { state.runPipeline() }
            )
            ParameterSlider(
                label: "Radius",
                value: $state.sharpenParams.radius,
                range: 0.1...10,
                format: "%.1f",
                onCommit: { state.runPipeline() }
            )
            ParameterSlider(
                label: "Threshold",
                value: $state.sharpenParams.threshold,
                range: 0...0.5,
                format: "%.2f",
                onCommit: { state.runPipeline() }
            )
        }
        .disabled(!state.sharpenEnabled)
    }
}

// MARK: - Slider row

/// Label, slider and numeric value in fixed columns, so every row in every
/// section lines up. `onCommit` fires when the user releases the slider.
@MainActor
struct ParameterSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    let onCommit: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: Theme.Spacing.small) {
                Slider(value: $value, in: range) { editing in
                    if !editing { onCommit() }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(String(format: format, value)))
                Text(String(format: format, value))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            Text(label)
        }
    }
}
