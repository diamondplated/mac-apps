import SwiftUI

/// The enhancement inspector: one grouped section per stage with its on/off
/// switch in the section header, then the comparison picker, Export and a
/// status line pinned to the bottom.
@MainActor
struct EnhancementPanel: View {
    @Bindable var state: EnhancementState

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if state.isLoadingRecipe {
                    Section {
                        LabeledContent("Loading saved settings…") {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else if state.currentURL != nil && !state.canEnhanceCurrentMedia {
                    Section {
                        Text("Still images only")
                            .foregroundStyle(.secondary)
                    }
                }

                Group {
                    // Sharpen first — it's the one stage that always works
                    // without any models installed.
                    stageSection(
                        "Sharpen",
                        isOn: $state.sharpenEnabled,
                        status: StageStatusResolver.sharpen()
                    ) {
                        SharpenControls(state: state)
                    }
                    stageSection(
                        "Upscale",
                        isOn: $state.upscaleEnabled,
                        status: StageStatusResolver.upscale()
                    ) {
                        UpscaleControls(state: state)
                    }
                    stageSection(
                        "Denoise",
                        isOn: $state.denoiseEnabled,
                        status: StageStatusResolver.denoise()
                    ) {
                        DenoiseControls(state: state)
                    }
                    stageSection(
                        "Artifact Removal",
                        isOn: $state.artifactRemovalEnabled,
                        status: StageStatusResolver.artifactRemoval()
                    ) {
                        ArtifactRemovalControls(state: state)
                    }
                }
                .disabled(!state.canEnhanceCurrentMedia || state.isExporting)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            footer
        }
        .background(.background)
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
    }

    // MARK: - Pieces

    /// One stage: a header carrying the stage name and its switch, the
    /// stage's parameter rows, and a one-line status footer when the stage
    /// depends on a model.
    private func stageSection<Content: View>(
        _ title: String,
        isOn: Binding<Bool>,
        status: StageStatus,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
                .disabled(!status.isOperational)
        } header: {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Toggle(title, isOn: Binding(
                    get: { isOn.wrappedValue && status.isOperational },
                    set: { isOn.wrappedValue = $0; state.runPipeline() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!status.isOperational)
            }
        } footer: {
            if let summary = status.summary {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(summary)
                    if status.offersInstallHelp {
                        Button {
                            ModelInstallHelp.open()
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("How to Install Models")
                        .accessibilityLabel("How to install models")
                    }
                    Spacer(minLength: 0)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            // Enhanced / original / side-by-side. Hold B at any time to
            // flash the original on top of any of these. Switching away from
            // .original starts the full decode and pipeline run if needed.
            Picker("Compare", selection: $state.compareMode) {
                ForEach(CompareMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!state.canEnhanceCurrentMedia || state.isExporting)
            .onChange(of: state.compareMode) { _, newMode in
                if newMode != .original {
                    state.ensureEnhancedAvailable()
                }
            }

            HStack(spacing: Theme.Spacing.small) {
                Button("Reset") {
                    state.resetEnhancements()
                }
                .help("Reset Enhancements for This Photo")
                .disabled(!state.canResetRecipe || state.isExporting)

                Button {
                    Task { await state.saveEnhanced() }
                } label: {
                    Text("Export Copy")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                // Enabled as soon as a supported still is selected — the
                // export path loads the full buffer itself if browsing never
                // did.
                .disabled(!state.canEnhanceCurrentMedia || state.isExporting)
            }
            .controlSize(.large)

            statusRow
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
        }
        .padding(Theme.Spacing.regular)
    }

    /// One line. A single small spinner while working; otherwise the latest
    /// outcome or the file name.
    @ViewBuilder
    private var statusRow: some View {
        Group {
            if let err = state.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if state.isExporting || state.isProcessing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(state.isExporting ? "Exporting…" : "Processing…")
                        .foregroundStyle(.secondary)
                }
            } else if let url = state.lastExportedURL {
                Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            } else if let warning = state.recipeWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if let url = state.currentURL {
                Text(url.lastPathComponent)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(state.lastError ?? state.recipeWarning ?? "")
    }
}
