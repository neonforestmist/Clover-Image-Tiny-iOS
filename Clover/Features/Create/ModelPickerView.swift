import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ModelPickerView: View {
    enum Presentation {
        case sheet
        case page
    }

    @Environment(\.dismiss) private var dismiss
    @Binding var settings: GenerationSettings
    let manager: ModelManager
    var inpaintingManager: InpaintingModelManager?
    var presentation: Presentation = .sheet

    @State private var confirmingBaseRemoval = false
    @State private var confirmingInpaintingRemoval = false
    @State private var importerPresented = false
    @State private var storageWarning: String?

    var body: some View {
        content
            .modifier(OptionalNavigationStack(enabled: presentation == .sheet))
    }

    @ViewBuilder
    private var content: some View {
        List {
            cloverSection
            if let inpaintingManager {
                inpaintingSection(inpaintingManager)
            }
            stylesSection
            importedSection
            catalogSection
            licenseSection
        }
        .navigationTitle(presentation == .page ? "Models" : "Models & LoRA Styles")
        .navigationBarTitleDisplayMode(presentation == .page ? .large : .inline)
        .toolbar {
            if presentation == .sheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .refreshable {
            await refreshAll()
        }
        .task {
            await manager.refreshCatalog()
            manager.refreshImported()
            if let inpaintingManager {
                await inpaintingManager.refresh()
            }
        }
        .alert(
            "Couldn’t Refresh Models",
            isPresented: Binding(
                get: { manager.errorMessage != nil },
                set: { if !$0 { manager.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manager.errorMessage ?? "")
        }
        .alert(
            "Not Enough Storage",
            isPresented: Binding(
                get: { storageWarning != nil },
                set: { if !$0 { storageWarning = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storageWarning ?? "")
        }
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: [.safetensorsFile]
        ) { result in
            handleImport(result)
        }
        .modifier(SheetDetents(enabled: presentation == .sheet))
    }

    @MainActor
    private func refreshAll() async {
        await manager.refreshCatalog()
        manager.refreshImported()
        if let inpaintingManager {
            await inpaintingManager.refresh()
        }
    }

    // MARK: - Clover base model

    @ViewBuilder
    private var cloverSection: some View {
        if let base = manager.catalog.baseVariant {
            Section {
                ModelVariantRow(
                    variant: base,
                    state: manager.state(for: base.id),
                    isLocked: false,
                    downloadSize: manager.requiredDownloadSize(for: base),
                    canDownload: manager.canDownload(base),
                    download: { requestDownload(base) },
                    cancel: { manager.cancelDownload(base.id) },
                    remove: { confirmingBaseRemoval = true }
                )
            } header: {
                Text("Clover Image")
            } footer: {
                Text(
                    "One-time \(formattedCloverSize) runtime download. The full 1.6 GB repository also includes an unused 608 MB safety-checker model. Stored in On My iPhone › Clover › Models."
                )
            }
            .confirmationDialog(
                "Remove Clover and all styles?",
                isPresented: $confirmingBaseRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Downloads", role: .destructive) {
                    clearStyleMix()
                    manager.remove(base)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Styles reuse Clover’s weights, so they’ll be removed too. You can download them again anytime.")
            }
        }
    }

    @ViewBuilder
    private func inpaintingSection(_ inpaintingManager: InpaintingModelManager) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(
                            inpaintingManager.isInstalled
                                ? AnyShapeStyle(.cloverGreen)
                                : AnyShapeStyle(.secondary)
                        )
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inpainting U-Net")
                            .font(.headline)
                        Text("Optional 9-channel model for replacing masked areas.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    if !manager.isBaseInstalled {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 28, minHeight: 28)
                            .accessibilityLabel("Install Clover first")
                    }
                }

                if inpaintingManager.isInstalled {
                    HStack(spacing: 10) {
                        Label("Installed", systemImage: "checkmark")
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Menu {
                            Button(role: .destructive) {
                                confirmingInpaintingRemoval = true
                            } label: {
                                Label("Remove Download", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 28, minHeight: 28)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Manage Inpainting download")
                        .accessibilityIdentifier("manage-download-inpainting")
                    }
                } else if manager.isBaseInstalled,
                   case .downloading = inpaintingManager.state {
                    Button("Cancel Download", role: .cancel) {
                        inpaintingManager.cancel()
                    }
                    .buttonStyle(.bordered)
                } else if manager.isBaseInstalled,
                          !inpaintingManager.isInstalled {
                    ModelDownloadButton(
                        size: inpaintingManager.manifest?.totalSize ?? 0,
                        action: requestInpaintingDownload
                    )
                    .accessibilityLabel("Download Inpainting model")
                }

                if case let .downloading(progress) = inpaintingManager.state {
                    ProgressView(value: progress) {
                        Text("Downloading \(progress, format: .percent)")
                            .font(.caption)
                    }
                    .tint(.cloverGreen)
                } else if case let .failed(message) = inpaintingManager.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Inpainting")
        } footer: {
                Text(
                    manager.isBaseInstalled
                        ? "Optional. Downloaded only when you enable Inpainting."
                        : "Requires Clover."
                )
        }
        .confirmationDialog(
            "Remove Inpainting download?",
            isPresented: $confirmingInpaintingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) {
                inpaintingManager.removeDownload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can download the Inpainting model again at any time.")
        }
    }

    // MARK: - LoRA styles

    @ViewBuilder
    private var stylesSection: some View {
        let styles = manager.catalog.styleVariants
        if !styles.isEmpty {
            Section {
                ForEach(styles) { style in
                    ModelVariantRow(
                        variant: style,
                        state: manager.state(for: style.id),
                        isLocked: manager.isLocked(style),
                        downloadSize: manager.requiredDownloadSize(for: style),
                        canDownload: manager.canDownload(style),
                        download: { requestDownload(style) },
                        cancel: { manager.cancelDownload(style.id) },
                        remove: { removeStyle(style) }
                    )
                }
            } header: {
                Text("LoRA Styles")
            } footer: {
                Text(
                    manager.isBaseInstalled
                        ? "Downloaded LoRAs appear in Create › Parameters, where you can enable up to \(GenerationSettings.maximumStyleCount) styles and tune their weights."
                        : "Install Clover above to unlock these styles."
                )
            }
        }
    }

    // MARK: - Imported LoRA styles

    @ViewBuilder
    private var importedSection: some View {
        Section {
            if manager.imported.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No imported styles yet")
                            .font(.subheadline)
                        Text("Add a .safetensors file in Files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                ForEach(manager.imported) { style in
                    ImportedStyleRow(
                        style: style,
                        isLocked: style.requiresClover
                            && !manager.isBaseInstalled,
                        saveTrigger: { trigger in
                            saveImportedTrigger(trigger, for: style)
                        }
                    )
                }
            }

            Button {
                importerPresented = true
            } label: {
                Label("Import File…", systemImage: "square.and.arrow.down")
            }

            Button {
                manager.refreshImported()
            } label: {
                Label("Rescan Files", systemImage: "arrow.clockwise")
            }

            Button {
                UIApplication.shared.open(ModelStorage.importedRootURL)
            } label: {
                Label("Reveal in Files", systemImage: "folder")
            }
        } header: {
            Text("Imported LoRA Styles")
        } footer: {
            Text(
                "Drop a Clover-compatible .safetensors file into On My iPhone › Clover › Imported Styles. The app detects it and makes it available in the LoRA Style Mix."
            )
        }
    }

    private var catalogSection: some View {
        Section {
            Link(destination: manager.catalog.hubURL) {
                Label("View Core ML Catalog", systemImage: "safari")
            }
        } footer: {
            Text("Generation stays on this iPhone once a model is installed.")
        }
    }

    private var licenseSection: some View {
        Section {
            Link(
                "CreativeML Open RAIL-M",
                destination: URL(
                    string: "https://huggingface.co/neonforestmist/Clover-Image-Tiny/blob/main/LICENSE"
                )!
            )
            .accessibilityIdentifier("model-license-link")
        } header: {
            Text("Model License")
        } footer: {
            Text(
                "Clover’s converted weights and derived LoRA styles are licensed under CreativeML Open RAIL-M."
            )
        }
    }

    // MARK: - Actions

    private func requestDownload(_ variant: ModelCatalog.Variant) {
        let needed = manager.requiredDownloadSize(for: variant)
        let verdict = ResourceGuard().check(requiredBytes: needed)
        if verdict.blocksDownload {
            storageWarning = verdict.advisoryText
            return
        }
        manager.download(variant)
    }

    private func requestInpaintingDownload() {
        let needed = inpaintingManager?.manifest?.totalSize ?? 1_800_000_000
        let verdict = ResourceGuard().check(requiredBytes: needed)
        if verdict.blocksDownload {
            storageWarning = verdict.advisoryText
            return
        }
        inpaintingManager?.download()
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let destination = ModelStorage.importedRootURL.appending(
            path: url.lastPathComponent
        )
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            manager.refreshImported()
        } catch {
            manager.errorMessage = error.localizedDescription
        }
    }

    private func clearStyleMix() {
        let previousIDs = settings.styleIDs
        settings.applyStyleTriggers(
            [],
            replacing: triggers(for: previousIDs)
        )
        settings.styleIDs.removeAll()
        settings.styleStrengths.removeAll()
        settings.modelID = ModelManager.baseID
        settings.persist()
    }

    private func removeStyle(_ style: ModelCatalog.Variant) {
        if settings.styleIDs.contains(style.id) {
            let previousIDs = settings.styleIDs
            settings.styleIDs.removeAll { $0 == style.id }
            settings.styleStrengths[style.id] = nil
            settings.applyStyleTriggers(
                triggers(for: settings.styleIDs),
                replacing: triggers(for: previousIDs)
            )
            settings.persist()
        }
        manager.remove(style)
    }

    private func triggers(for ids: [String]) -> [String] {
        ids.compactMap { id in
            manager.variant(id: id)?.trigger
                ?? manager.importedStyle(id: id)?.trigger
        }
    }

    private func saveImportedTrigger(
        _ trigger: String,
        for style: ModelStorage.ImportedStyle
    ) {
        let previousTriggers = triggers(for: settings.styleIDs)
        do {
            try ModelStorage.setImportedTrigger(
                trigger,
                for: style.weightsURL
            )
            manager.refreshImported()
            settings.applyStyleTriggers(
                triggers(for: settings.styleIDs),
                replacing: previousTriggers
            )
            settings.persist()
        } catch {
            manager.errorMessage = error.localizedDescription
        }
    }

    private var formattedCloverSize: String {
        // The full Clover install is the shared components plus the base U-Net.
        let bytes = manager.catalog.baseVariant
            .map { manager.requiredDownloadSize(for: $0) }
            ?? manager.catalog.common.downloadSize
        guard bytes > 0 else { return "994.9 MB" }
        return bytes.formatted(.byteCount(style: .file))
    }
}

// MARK: - Catalog variant row

private struct ModelVariantRow: View {
    let variant: ModelCatalog.Variant
    let state: ModelManager.InstallState
    let isLocked: Bool
    let downloadSize: Int64
    let canDownload: Bool
    let download: () -> Void
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                icon

                VStack(alignment: .leading, spacing: 4) {
                    Text(variant.name)
                        .font(.headline)
                        .foregroundStyle(isLocked ? .secondary : .primary)
                    Text(variant.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let trigger = variant.trigger {
                        Text(trigger)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Color.accentColor.opacity(0.14),
                                in: .rect(cornerRadius: 6)
                            )
                    }
                }

                Spacer(minLength: 8)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 28, minHeight: 28)
                        .accessibilityLabel("\(variant.name) requires Clover")
                }
            }

            action

            if case let .downloading(progress) = state {
                ProgressView(value: progress) {
                    Text("Downloading \(progress, format: .percent)")
                        .font(.caption)
                }
                .tint(.cloverGreen)
            }

            if case let .failed(message) = state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-\(variant.id)")
    }

    @ViewBuilder
    private var icon: some View {
        if variant.id == ModelManager.baseID {
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(
                    isLocked
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.cloverGreen)
                )
                .frame(width: 52, height: 52)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(StudioPalette.hairline.opacity(0.5))
                }
                .accessibilityHidden(true)
        } else {
            Image(variant.iconAssetName)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .cloverContinuousClip(12)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(StudioPalette.hairline.opacity(0.5))
                }
                .saturation(isLocked ? 0 : 1)
                .opacity(isLocked ? 0.45 : 1)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .installed:
            HStack(spacing: 10) {
                Label("Installed", systemImage: "checkmark")
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Menu {
                    Button(role: .destructive, action: remove) {
                        Label("Remove Download", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Manage \(variant.name) download")
                .accessibilityIdentifier("manage-download-\(variant.id)")
            }

        case .downloading:
            Button("Cancel Download", role: .cancel, action: cancel)
                .buttonStyle(.bordered)

        case .notInstalled, .failed:
            if isLocked {
                Text("Install Clover to download this LoRA.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ModelDownloadButton(
                    size: downloadSize,
                    isRetry: state.isFailed,
                    action: download
                )
                .disabled(!canDownload)
                .accessibilityLabel(
                    state.isFailed
                        ? "Retry download of \(variant.name)"
                        : "Download \(variant.name)"
                )
            }
        }
    }
}

// MARK: - Native download action

private struct ModelDownloadButton: View {
    let size: Int64
    var isRetry = false
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: action) {
                Label(
                    buttonTitle,
                    systemImage: isRetry
                        ? "arrow.clockwise.circle"
                        : "arrow.down.circle"
                )
            }
            .buttonStyle(.bordered)
        }
        .frame(minHeight: 44)
    }

    private var buttonTitle: String {
        let sizeText = size > 0
            ? size.formatted(.byteCount(style: .file))
            : nil
        if isRetry {
            return sizeText.map { "Retry Download \($0)" }
                ?? "Retry Download"
        }
        return sizeText.map { "Download \($0)" } ?? "Download"
    }
}

// MARK: - Imported style row

private struct ImportedStyleRow: View {
    let style: ModelStorage.ImportedStyle
    let isLocked: Bool
    let saveTrigger: (String) -> Void

    @State private var triggerDraft: String
    @FocusState private var triggerIsFocused: Bool

    init(
        style: ModelStorage.ImportedStyle,
        isLocked: Bool,
        saveTrigger: @escaping (String) -> Void
    ) {
        self.style = style
        self.isLocked = isLocked
        self.saveTrigger = saveTrigger
        _triggerDraft = State(initialValue: style.trigger ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: style.requiresClover
                    ? "paintbrush.pointed.fill"
                    : "square.and.arrow.down.on.square.fill")
                    .font(.title3)
                    .foregroundStyle(
                        isLocked
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.cloverGreen)
                    )
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(style.name)
                        .font(.headline)
                        .foregroundStyle(isLocked ? .secondary : .primary)
                    Text(style.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(
                            "\(style.name) requires Clover"
                        )
                }
            }

            Label("Installed", systemImage: "checkmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trigger word")
                    Text("Optional")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                TextField("None", text: $triggerDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 110, idealWidth: 150, maxWidth: 190)
                    .focused($triggerIsFocused)
                    .submitLabel(.done)
                    .onSubmit(commitTrigger)
                    .accessibilityLabel("Trigger word for \(style.name), optional")
                    .accessibilityIdentifier("imported-trigger-\(style.name)")
            }
            .disabled(isLocked)
        }
        .padding(.vertical, 6)
        .onChange(of: triggerIsFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                commitTrigger()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("imported-\(style.name)")
    }

    private func commitTrigger() {
        let cleaned = triggerDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard cleaned != (style.trigger ?? "") else { return }
        triggerDraft = cleaned
        saveTrigger(cleaned)
    }
}

private extension ModelManager.InstallState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

private extension UTType {
    static var safetensorsFile: UTType {
        UTType(filenameExtension: "safetensors") ?? .data
    }
}

private struct OptionalNavigationStack: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            NavigationStack { content }
        } else {
            content
        }
    }
}

private struct SheetDetents: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.presentationDetents([.large])
        } else {
            content
        }
    }
}

#Preview {
    ModelPickerView(
        settings: .constant(GenerationSettings()),
        manager: ModelManager(previewInstalled: true)
    )
}
