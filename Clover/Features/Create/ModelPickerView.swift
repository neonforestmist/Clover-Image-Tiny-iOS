import SwiftUI

struct ModelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: GenerationSettings
    let manager: ModelManager

    @State private var confirmingBaseRemoval = false

    var body: some View {
        NavigationStack {
            List {
                cloverSection
                stylesSection
                importedSection
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
                    isSelected: settings.modelID == base.id,
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
                    if settings.modelID != base.id {
                        settings.modelID = base.id
                        settings.persist()
                    }
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
                        isSelected: settings.modelID == style.id,
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
                        ? "Each style is a named 6.9 MB LoRA file that reuses the one-time Clover download. Include the trigger shown under the style in your prompt."
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
                        isSelected: settings.modelID == style.id,
                        isLocked: style.requiresClover
                            && !manager.isBaseInstalled,
                        select: { select(style.id) }
                    )
                }
            }

            Button {
                manager.refreshImported()
                HapticManager.selection()
            } label: {
                Label("Rescan Files", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("Imported Styles")
        } footer: {
            Text(
                "Drop a Clover-compatible .safetensors file into On My iPhone › Clover › Imported Styles. The app detects the file and loads it into the installed Clover model. Legacy full Core ML folders still work."
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

    // MARK: - Actions

    private func select(_ id: String) {
        let previousTrigger = manager.variant(
            id: settings.modelID
        )?.trigger
        let trigger = manager.variant(id: id)?.trigger

        settings.applyStyleTrigger(
            trigger,
            replacing: previousTrigger
        )
        settings.modelID = id
        settings.persist()
        HapticManager.selection()
    }

    private func removeStyle(_ style: ModelCatalog.Variant) {
        if settings.modelID == style.id {
            settings.modelID = ModelManager.baseID
            settings.persist()
        }
        manager.remove(style)
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
            if state == .installed, !isSelected { select() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-\(variant.id)")
        .contextMenu {
            if state == .installed {
                Button("Remove Download", role: .destructive, action: remove)
            }
        }
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
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.cloverGreen)
                    .accessibilityLabel("\(variant.name), selected")
            } else {
                Button("Use", action: select)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Use \(variant.name)")
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
                Button("Use", action: select)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Use \(style.name)")
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture {
            if !isSelected, !isLocked { select() }
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
