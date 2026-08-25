import SwiftUI
import UIKit

struct CreateView: View {
    @Bindable var store: GenerationStore
    private let library: ArtworkLibrary
    private let modelManager: ModelManager
    @State private var showsNegative = false
    @State private var timelineSelection = 0
    @State private var promptIsFocused = false
    @State private var negativePromptIsFocused = false

    private enum ScrollTarget: Hashable {
        case prompt
        case negativePrompt
    }

    init(
        store: GenerationStore,
        library: ArtworkLibrary,
        modelManager: ModelManager
    ) {
        self.store = store
        self.library = library
        self.modelManager = modelManager
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    OutputCanvas(
                        artworks: store.latest,
                        phase: store.phase,
                        preview: store.preview,
                        activity: store.activity,
                        frameSelection: $timelineSelection
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 720)

                    if let advisory = store.advisory {
                        ResourceAdvisoryBanner(verdict: advisory)
                    }

                    if !store.phase.isWorking, let artwork = store.latest.first {
                        ArtworkTimelineControls(
                            artwork: artwork,
                            selection: $timelineSelection,
                            showsExportAction: true
                        )
                    }

                    promptSection
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .environment(library)
            .scrollDismissesKeyboard(.immediately)
            .scrollIndicators(.automatic)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Create")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    parametersButton
                }
            }
            .sheet(item: $store.presentedSheet) { destination in
                switch destination {
                case .parameters:
                    GenerationSettingsSheet(
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
            .keyboardShortcut(.return, modifiers: .command)
            .onKeyPress(.escape) {
                if store.phase.isWorking {
                    store.cancel()
                    return .handled
                }
                return .ignored
            }
            .onChange(of: negativePromptIsFocused) { _, isFocused in
                if isFocused {
                    reveal(.negativePrompt, using: proxy)
                }
            }
            .onChange(of: promptIsFocused) { _, isFocused in
                if isFocused {
                    reveal(.prompt, using: proxy)
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillChangeFrameNotification
                )
            ) { _ in
                if promptIsFocused {
                    reveal(.prompt, using: proxy)
                } else if negativePromptIsFocused {
                    reveal(.negativePrompt, using: proxy)
                }
            }
        }
    }

    private func reveal(
        _ target: ScrollTarget,
        using proxy: ScrollViewProxy
    ) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private var parametersButton: some View {
        Button("Parameters", systemImage: "slider.horizontal.3") {
            store.presentedSheet = .parameters
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("parameters-button")
        .disabled(store.phase.isWorking)
        .keyboardShortcut("0", modifiers: .command)
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Prompt", systemImage: "text.bubble")
                .font(.headline)

            PromptTokenEditor(
                text: promptBody,
                tokens: styleTriggerTokens,
                placeholder: "Describe the image you want to create",
                accessibilityLabel: "Prompt",
                accessibilityIdentifier: "prompt-field",
                minimumHeight: 120,
                removeToken: removeStyle,
                onFocusChange: { isFocused in
                    promptIsFocused = isFocused
                }
            )
            .id(ScrollTarget.prompt)

                Toggle(isOn: $showsNegative) {
                    Label("Show Negative Prompt", systemImage: "eye.slash")
                }
            .accessibilityIdentifier("negative-prompt-toggle")

            if showsNegative {
                PromptTokenEditor(
                    text: $store.settings.negativePrompt,
                    tokens: [],
                    placeholder: "Describe what Clover should avoid",
                    accessibilityLabel: "Negative prompt",
                    accessibilityIdentifier: "negative-prompt-field",
                    minimumHeight: 88,
                    removeToken: { _ in },
                    onFocusChange: { isFocused in
                        negativePromptIsFocused = isFocused
                    }
                )
                .id(ScrollTarget.negativePrompt)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if store.phase.isWorking {
                GenerationProgressStatus(
                    progress: generationProgress,
                    activity: store.activity
                )
            } else if !modelManager.isBaseInstalled {
                Label(
                    "Download Clover from Models before generating.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("model-not-loaded-label")
            }

            generationAction
        }
        .animation(.default, value: showsNegative)
    }

    private var promptBody: Binding<String> {
        Binding(
            get: {
                store.settings.promptBody(
                    removingStyleTriggers: styleTriggerTokens.map(\.title)
                )
            },
            set: { body in
                store.settings.setPromptBody(
                    body,
                    styleTriggers: styleTriggerTokens.map(\.title)
                )
            }
        )
    }

    private var styleTriggerTokens: [PromptToken] {
        store.settings.styleIDs.compactMap { id in
            let trigger = modelManager.variant(id: id)?.trigger
                ?? modelManager.importedStyle(id: id)?.trigger
            return trigger.map { PromptToken(id: id, title: $0) }
        }
    }

    private func removeStyle(_ id: String) {
        let previousTokens = styleTriggerTokens
        store.settings.styleIDs.removeAll { $0 == id }
        store.settings.styleStrengths[id] = nil
        let nextTokens = styleTriggerTokens
        store.settings.applyStyleTriggers(
            nextTokens.map(\.title),
            replacing: previousTokens.map(\.title)
        )
        store.settings.persist()
    }

    @ViewBuilder
    private var generationAction: some View {
        if store.phase.isWorking {
            Button(role: .cancel) {
                store.cancel()
            } label: {
                Label("Cancel Generation", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else {
            Button {
                store.generate()
            } label: {
                Label("Generate", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canGenerate)
            .accessibilityIdentifier("generate-button")
        }
    }

    private var generationProgress: Double {
        if case let .generating(value) = store.phase { return value }
        return store.phase == .preparing ? 0.04 : 0.98
    }

    private var canGenerate: Bool {
        selectedModelsAreInstalled && !store.settings.trimmedPrompt.isEmpty
    }

    private var selectedModelsAreInstalled: Bool {
        modelManager.isBaseInstalled
            && store.settings.styleIDs.allSatisfy(modelManager.isInstalled)
    }
}

struct PromptToken: Identifiable, Equatable {
    let id: String
    let title: String
}

struct PromptTokenEditor: View {
    @Binding var text: String
    let tokens: [PromptToken]
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let minimumHeight: CGFloat
    let removeToken: (String) -> Void
    var onFocusChange: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !tokens.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tokens) { token in
                            Button {
                                removeToken(token.id)
                            } label: {
                                HStack(spacing: 5) {
                                    Text(token.title)
                                        .lineLimit(1)
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Color.accentColor.opacity(0.14),
                                    in: .rect(cornerRadius: 8)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(token.title) trigger")
                            .accessibilityHint("Removes this trigger and LoRA")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                }
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }

                BackspaceAwareTextView(
                    text: $text,
                    accessibilityLabel: accessibilityLabel,
                    accessibilityIdentifier: accessibilityIdentifier,
                    onDeleteAtBeginning: {
                        if let token = tokens.last {
                            removeToken(token.id)
                        }
                    },
                    onFocusChange: onFocusChange
                )
            }
            .frame(minHeight: minimumHeight)
        }
        .background(
            Color(.secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35))
        }
    }
}

private struct BackspaceAwareTextView: UIViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let onDeleteAtBeginning: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> DeletionAwareTextView {
        let textView = DeletionAwareTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.autocapitalizationType = .sentences
        textView.keyboardDismissMode = .onDrag
        textView.returnKeyType = .done
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(
            top: 10,
            left: 12,
            bottom: 10,
            right: 12
        )
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityIdentifier = accessibilityIdentifier
        return textView
    }

    func updateUIView(
        _ textView: DeletionAwareTextView,
        context: Context
    ) {
        context.coordinator.parent = self
        if textView.text != text {
            textView.text = text
        }
        textView.onDeleteAtBeginning = onDeleteAtBeginning
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityIdentifier = accessibilityIdentifier
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BackspaceAwareTextView

        init(parent: BackspaceAwareTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange(false)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard text == "\n" else { return true }
            textView.resignFirstResponder()
            return false
        }
    }
}

private final class DeletionAwareTextView: UITextView {
    var onDeleteAtBeginning: (() -> Void)?

    override func deleteBackward() {
        if selectedRange.location == 0,
           selectedRange.length == 0,
           let onDeleteAtBeginning {
            onDeleteAtBeginning()
            return
        }
        super.deleteBackward()
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
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!isEnabled)
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
                .tint(.accentColor)
                .accessibilityLabel("Generation progress")
                .accessibilityValue("\(Int(progress * 100)) percent")
        }
    }
}

#Preview {
    NavigationStack {
        CreateView(
            store: GenerationStore(
                generator: PreviewGenerationService(),
                library: .preview
            ),
            library: .preview,
            modelManager: ModelManager(previewInstalled: true)
        )
        .environment(Route())
    }
}
