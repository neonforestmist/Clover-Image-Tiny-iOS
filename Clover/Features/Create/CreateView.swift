import SwiftUI

struct CreateView: View {
    @State private var store: GenerationStore
    @FocusState private var focusedField: Field?
    private let library: ArtworkLibrary
    private let modelManager: ModelManager

    private enum Field {
        case prompt
        case negativePrompt
    }

    init(
        generator: any ImageGenerating,
        library: ArtworkLibrary,
        modelManager: ModelManager
    ) {
        self.library = library
        self.modelManager = modelManager
        _store = State(
            initialValue: GenerationStore(
                generator: generator,
                library: library
            )
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                OutputCanvas(
                    artworks: store.latest,
                    phase: store.phase,
                    outputAspectRatio: store.settings.outputWidthOverHeight
                )

                modelButton
                promptSection
            }
            .padding()
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(library)
        .navigationTitle("Create")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    focusedField = nil
                    store.presentedSheet = .parameters
                } label: {
                    Label("Parameters", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("parameters-button")
                .disabled(store.phase.isWorking)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            generationAction
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .sheet(item: $store.presentedSheet) { destination in
            switch destination {
            case .parameters:
                GenerationSettingsSheet(settings: $store.settings)
            case .models:
                ModelPickerView(
                    settings: $store.settings,
                    manager: modelManager
                )
            }
        }
        .task {
            await modelManager.refreshCatalog()
        }
        .alert(
            "Couldn’t Generate",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var modelButton: some View {
        Button {
            focusedField = nil
            store.presentedSheet = .models
        } label: {
            HStack(spacing: 12) {
                modelIcon
                    .foregroundStyle(.cloverGreen)
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: .circle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(modelManager.displayName(for: store.settings.modelID) ?? "Clover")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(modelStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                Color(.secondarySystemBackground),
                in: .rect(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.phase.isWorking)
        .accessibilityIdentifier("model-picker-button")
    }

    @ViewBuilder
    private var modelIcon: some View {
        if let variant = selectedVariant {
            Image(variant.iconAssetName)
                .resizable()
                .scaledToFit()
                .padding(7)
        } else {
            Image(systemName: "paintpalette.fill")
                .font(.title3)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt")
                .font(.headline)

            TextField(
                "Describe the image you want",
                text: $store.settings.prompt,
                axis: .vertical
            )
            .lineLimit(3...7)
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .prompt)
            .padding(14)
            .background(
                Color(.secondarySystemBackground),
                in: .rect(cornerRadius: 14)
            )
            .accessibilityIdentifier("prompt-field")

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("Negative Prompt", systemImage: "eye.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("Optional")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField(
                    "What should Clover avoid?",
                    text: $store.settings.negativePrompt,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .negativePrompt)

                Text("Describe details you don’t want in the generated image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(
                Color(.secondarySystemBackground),
                in: .rect(cornerRadius: 14)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("negative-prompt-field")

            parameterSummary
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var parameterSummary: some View {
        HStack(spacing: 8) {
            ParameterPill(
                title: "\(store.settings.stepCount) steps",
                systemImage: "arrow.triangle.2.circlepath"
            )
            ParameterPill(
                title: String(format: "%.1f CFG", store.settings.guidanceScale),
                systemImage: "scope"
            )
            ParameterPill(
                title: "#\(store.settings.seed)",
                systemImage: "dice"
            )
        }
        .font(.caption)
        .lineLimit(1)
    }

    @ViewBuilder
    private var generationAction: some View {
        VStack(spacing: 8) {
            if case let .generating(progress) = store.phase {
                ProgressView(value: progress)
                    .tint(.cloverGreen)
                    .accessibilityLabel("Generation progress")
            }

            if store.phase.isWorking {
                Button(role: .cancel) {
                    store.cancel()
                } label: {
                    Label(statusTitle, systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                if modelManager.isInstalled(store.settings.modelID) {
                    Button {
                        focusedField = nil
                        store.generate()
                    } label: {
                        Label("Generate", systemImage: "wand.and.stars")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.settings.trimmedPrompt.isEmpty)
                    .accessibilityIdentifier("generate-button")
                } else {
                    Button {} label: {
                        Label("Generate", systemImage: "wand.and.stars")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(true)
                    .accessibilityIdentifier("generate-button")
                }
            }
        }
        .padding(.top, 4)
    }

    private var statusTitle: String {
        switch store.phase {
        case .preparing:
            "Preparing model…"
        case let .generating(progress):
            "Generating \(Int(progress * 100))% · Cancel"
        case .idle, .finished:
            "Cancel"
        }
    }

    private var selectedVariant: ModelCatalog.Variant? {
        modelManager.variant(id: store.settings.modelID)
    }

    private var modelStatus: String {
        switch modelManager.state(for: store.settings.modelID) {
        case .installed:
            if let trigger = selectedVariant?.trigger {
                "Installed · Trigger: \(trigger)"
            } else {
                "Installed · Runs on device"
            }
        case let .downloading(progress):
            "Downloading \(progress.formatted(.percent))"
        case .notInstalled:
            if store.settings.modelID == "base" {
                "Tap to download Clover"
            } else if !modelManager.isBaseInstalled {
                "Install Clover first to unlock this style"
            } else {
                "Tap to add this style"
            }
        case .failed:
            "Download needs attention"
        }
    }
}

private struct ParameterPill: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: .capsule)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    NavigationStack {
        CreateView(
            generator: PreviewGenerationService(),
            library: .preview,
            modelManager: ModelManager(previewInstalled: true)
        )
    }
}
