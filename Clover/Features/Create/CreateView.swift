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
            VStack(spacing: 20) {
                OutputCanvas(
                    artworks: store.latest,
                    phase: store.phase,
                    preview: store.preview,
                    activity: store.activity
                )

                modelButton
                promptSection
            }
            .padding()
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.immediately)
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

            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedField = nil
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("dismiss-keyboard-button")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if focusedField == nil {
                generationAction
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
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
                    Text(styleDisplayName)
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

            ZStack(alignment: .topLeading) {
                if store.settings.prompt.isEmpty {
                    Text("Describe the image you want")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $store.settings.prompt)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .prompt)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityLabel("Prompt")
                    .accessibilityIdentifier("prompt-field")
            }
            .frame(height: 112)
            .padding(10)
            .background(
                Color(.secondarySystemBackground),
                in: .rect(cornerRadius: 14)
            )

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

                ZStack(alignment: .topLeading) {
                    if store.settings.negativePrompt.isEmpty {
                        Text("What should Clover avoid?")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $store.settings.negativePrompt)
                        .scrollContentBackground(.hidden)
                        .focused(
                            $focusedField,
                            equals: .negativePrompt
                        )
                        .textInputAutocapitalization(.sentences)
                        .accessibilityLabel("Negative Prompt")
                }
                .frame(height: 72)

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
                GenerationProgressStatus(
                    progress: progress,
                    activity: store.activity
                )
                .accessibilityIdentifier("generation-stage")
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
                if selectedModelsAreInstalled {
                    PrimaryGenerationButton(
                        title: "Generate",
                        systemImage: "wand.and.stars",
                        isEnabled: !store.settings.trimmedPrompt.isEmpty
                    ) {
                        focusedField = nil
                        store.generate()
                    }
                    .accessibilityIdentifier("generate-button")
                } else {
                    PrimaryGenerationButton(
                        title: "Generate",
                        systemImage: "wand.and.stars",
                        isEnabled: false,
                        action: {}
                    )
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
        case .generating:
            "Cancel"
        case .idle, .finished:
            "Cancel"
        }
    }

    private var selectedVariant: ModelCatalog.Variant? {
        store.settings.styleIDs.first.flatMap {
            modelManager.variant(id: $0)
        } ?? modelManager.variant(id: ModelManager.baseID)
    }

    private var modelStatus: String {
        guard modelManager.isBaseInstalled else {
            return "Tap to download Clover"
        }
        let unavailable = store.settings.styleIDs.filter {
            !modelManager.isInstalled($0)
        }
        if !unavailable.isEmpty {
            return "A selected style needs to be downloaded again"
        }
        if store.settings.styleIDs.isEmpty {
            return "Installed · Runs on device"
        }
        return "\(store.settings.styleIDs.count) \(store.settings.styleIDs.count == 1 ? "style" : "styles") mixed on device"
    }

    private var styleDisplayName: String {
        let names = store.settings.styleIDs.compactMap {
            modelManager.displayName(for: $0)
        }
        return names.isEmpty ? "Clover" : names.joined(separator: " + ")
    }

    private var selectedModelsAreInstalled: Bool {
        modelManager.isBaseInstalled
            && store.settings.styleIDs.allSatisfy(modelManager.isInstalled)
    }
}

struct PrimaryGenerationButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(CloverPrimaryActionButtonStyle())
        .disabled(!isEnabled)
    }
}

private struct CloverPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .padding(.vertical, 13)
            .background {
                Capsule()
                    .fill(
                        isEnabled
                            ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1)
                            : Color.secondary.opacity(0.18)
                    )
            }
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GenerationProgressStatus: View {
    let progress: Double
    let activity: GenerationActivity

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(activity.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ProgressView(value: progress)
                .tint(.cloverGreen)
                .accessibilityLabel("Generation progress")
                .accessibilityValue("\(Int(progress * 100)) percent")
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
