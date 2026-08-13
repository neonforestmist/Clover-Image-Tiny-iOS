import SwiftUI

struct ModelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: GenerationSettings
    let manager: ModelManager

    @State private var confirmingBaseRemoval = false
    @State private var styleLimitMessage: String?

    var body: some View {
        NavigationStack {
            List {
                cloverSection
                stylesSection
                importedSection
                styleMixSection
                catalogSection
            }
            .navigationTitle("Models & Styles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await manager.refreshCatalog() }
                        manager.refreshImported()
                    } label: {
                        if manager.isRefreshing {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(manager.isRefreshing)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task {
                await manager.refreshCatalog()
                manager.refreshImported()
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
                "Style Limit",
                isPresented: Binding(
                    get: { styleLimitMessage != nil },
                    set: { if !$0 { styleLimitMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(styleLimitMessage ?? "")
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Clover base model

    @ViewBuilder
    private var cloverSection: some View {
        if let base = manager.catalog.baseVariant {
            Section {
                ModelVariantRow(
                    variant: base,
                    state: manager.state(for: base.id),
                    isSelected: settings.styleIDs.isEmpty,
                    isLocked: false,
                    downloadSize: manager.requiredDownloadSize(for: base),
                    canDownload: manager.canDownload(base),
                    select: { select(base.id) },
                    download: { manager.download(base) },
                    cancel: { manager.cancelDownload(base.id) },
                    remove: { confirmingBaseRemoval = true }
                )
            } header: {
                Text("Clover Model")
            } footer: {
                Text(
                    "Download Clover first — it’s a one-time \(formattedCloverSize) model that runs entirely on your iPhone. Files are verified with SHA-256 and stored in On My iPhone › Clover › Models."
                )
            }
            .confirmationDialog(
                "Remove Clover and all styles?",
                isPresented: $confirmingBaseRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Downloads", role: .destructive) {
                    select(base.id)
                    manager.remove(base)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Styles reuse Clover’s weights, so they’ll be removed too. You can download them again anytime.")
            }
        }
    }

    // MARK: - Styles

    @ViewBuilder
    private var stylesSection: some View {
        let styles = manager.catalog.styleVariants
        if !styles.isEmpty {
            Section {
                ForEach(styles) { style in
                    ModelVariantRow(
                        variant: style,
                        state: manager.state(for: style.id),
                        isSelected: settings.styleIDs.contains(style.id),
                        isLocked: manager.isLocked(style),
                        downloadSize: manager.requiredDownloadSize(for: style),
                        canDownload: manager.canDownload(style),
                        select: { select(style.id) },
                        download: { manager.download(style) },
                        cancel: { manager.cancelDownload(style.id) },
                        remove: { removeStyle(style) }
                    )
                }
            } header: {
                Text("Styles")
            } footer: {
                Text(
                    manager.isBaseInstalled
                        ? "Mix up to \(GenerationSettings.maximumStyleCount) downloaded LoRAs. Clover adds their trigger phrases and lets you tune each strength below."
                        : "Install Clover above to unlock these styles."
                )
            }
        }
    }

    // MARK: - Imported styles

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
                        isSelected: settings.styleIDs.contains(style.id),
                        isLocked: style.requiresClover
                            && !manager.isBaseInstalled,
                        select: { select(style.id) }
                    )
                }
            }

            Button {
                manager.refreshImported()
            } label: {
                Label("Rescan Files", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("Imported Styles")
        } footer: {
            Text(
                "Drop a Clover-compatible .safetensors file into On My iPhone › Clover › Imported Styles. The app detects it and loads the style into your installed Clover model."
            )
        }
    }

    @ViewBuilder
    private var styleMixSection: some View {
        if !settings.styleIDs.isEmpty {
            Section {
                ForEach(settings.styleIDs, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(manager.displayName(for: id) ?? "Imported Style")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(settings.styleStrength(for: id), format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { settings.styleStrength(for: id) },
                                set: {
                                    settings.setStyleStrength($0, for: id)
                                    settings.persist()
                                }
                            ),
                            in: 0...1.5,
                            step: 0.05
                        )
                        .accessibilityLabel("\(manager.displayName(for: id) ?? "Style") strength")
                    }
                }
            } header: {
                Text("Style Mix")
            } footer: {
                Text("Strength 1.00 uses the LoRA as trained. Lower values soften it; values above 1.00 make it more pronounced.")
            }
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

    // MARK: - Actions

    private func select(_ id: String) {
        let previousIDs = settings.styleIDs
        var nextIDs = previousIDs
        if id == ModelManager.baseID {
            nextIDs.removeAll()
        } else if let index = nextIDs.firstIndex(of: id) {
            nextIDs.remove(at: index)
            settings.styleStrengths[id] = nil
        } else {
            guard nextIDs.count < GenerationSettings.maximumStyleCount else {
                styleLimitMessage = "Remove a selected style before adding another. This Core ML model can mix up to \(GenerationSettings.maximumStyleCount) LoRAs at once."
                return
            }
            nextIDs.append(id)
            settings.styleStrengths[id] = 1
        }
        settings.applyStyleTriggers(
            triggers(for: nextIDs),
            replacing: triggers(for: previousIDs)
        )
        settings.styleIDs = nextIDs
        settings.modelID = ModelManager.baseID
        settings.persist()
    }

    private func removeStyle(_ style: ModelCatalog.Variant) {
        if settings.styleIDs.contains(style.id) {
            select(style.id)
        }
        manager.remove(style)
    }

    private func triggers(for ids: [String]) -> [String] {
        ids.compactMap { manager.variant(id: $0)?.trigger }
    }

    private var formattedCloverSize: String {
        // The full Clover install is the shared components plus the base U-Net.
        let bytes = manager.catalog.baseVariant
            .map { manager.requiredDownloadSize(for: $0) }
            ?? manager.catalog.common.downloadSize
        guard bytes > 0 else { return "≈1.5 GB" }
        return "≈\(bytes.formatted(.byteCount(style: .memory)))"
    }
}

// MARK: - Catalog variant row

private struct ModelVariantRow: View {
    let variant: ModelCatalog.Variant
    let state: ModelManager.InstallState
    let isSelected: Bool
    let isLocked: Bool
    let downloadSize: Int64
    let canDownload: Bool
    let select: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                icon

                VStack(alignment: .leading, spacing: 3) {
                    Text(variant.name)
                        .font(.headline)
                        .foregroundStyle(isLocked ? .secondary : .primary)
                    Text(variant.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let trigger = variant.trigger {
                        Text("Trigger: \(trigger)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let filename = variant.publicWeightsFilename {
                        Text(filename)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 8)
                action
            }

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
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture {
            if state == .installed { select() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-\(variant.id)")
    }

    private var icon: some View {
        Image(variant.iconAssetName)
            .resizable()
            .scaledToFit()
            .padding(6)
            .foregroundStyle(isLocked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.cloverGreen))
            .frame(width: 30, height: 30)
            .background(.quaternary, in: .circle)
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .installed:
            HStack(spacing: 12) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.cloverGreen)
                        .accessibilityLabel("\(variant.name), selected. Tap row to remove")
                } else {
                    Button("Add", action: select)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Add \(variant.name)")
                }

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
            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(.borderless)

        case .notInstalled, .failed:
            if isLocked {
                Label("Locked", systemImage: "lock.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("\(variant.name) is locked until Clover is installed")
            } else {
                Button(action: download) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: state.isFailed
                            ? "arrow.clockwise.circle"
                            : "arrow.down.circle")
                            .font(.title3)
                        Text(downloadSize > 0 ? formattedDownloadSize : "Included")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!canDownload)
                .accessibilityLabel(
                    state.isFailed
                        ? "Retry download of \(variant.name)"
                        : "Download \(variant.name)"
                )
            }
        }
    }

    private var formattedDownloadSize: String {
        downloadSize.formatted(.byteCount(style: .file))
    }
}

// MARK: - Imported style row

private struct ImportedStyleRow: View {
    let style: ModelStorage.ImportedStyle
    let isSelected: Bool
    let isLocked: Bool
    let select: () -> Void

    var body: some View {
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
                .frame(width: 30, height: 30)
                .background(.quaternary, in: .circle)

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
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.cloverGreen)
                    .accessibilityLabel("\(style.name), selected")
            } else {
                Button("Add", action: select)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add \(style.name)")
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture {
            if !isLocked { select() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("imported-\(style.name)")
    }
}

private extension ModelManager.InstallState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

#Preview {
    ModelPickerView(
        settings: .constant(GenerationSettings()),
        manager: ModelManager(previewInstalled: true)
    )
}
