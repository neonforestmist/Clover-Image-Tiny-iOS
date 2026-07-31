import SwiftUI

struct ModelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: GenerationSettings
    let manager: ModelManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(manager.catalog.variants) { variant in
                        ModelVariantRow(
                            variant: variant,
                            state: manager.state(for: variant.id),
                            isSelected: settings.modelID == variant.id,
                            downloadSize: manager.requiredDownloadSize(
                                for: variant
                            ),
                            isBundledStyle: manager.catalog.schemaVersion >= 2
                                && variant.id != "base",
                            canDownload: !manager.catalog.common.files.isEmpty
                                && (
                                    manager.catalog.schemaVersion >= 2
                                    || !variant.files.isEmpty
                                ),
                            select: {
                                settings.modelID = variant.id
                                settings.persist()
                                HapticManager.selection()
                            },
                            download: {
                                manager.download(variant)
                            },
                            cancel: {
                                manager.cancelDownload(variant.id)
                            },
                            remove: {
                                if settings.modelID == variant.id {
                                    settings.modelID = "base"
                                    settings.persist()
                                }
                                manager.remove(variant)
                            }
                        )
                    }
                } header: {
                    Text("On-device models")
                } footer: {
                    Text(
                        "One shared Clover download includes the base model and all three lightweight style adapters. Files are verified with SHA-256 and visible in On My iPhone › Clover › Models."
                    )
                }

                Section {
                    Link(destination: manager.catalog.hubURL) {
                        Label(
                            "View Core ML catalog",
                            systemImage: "safari"
                        )
                    }
                } footer: {
                    Text(
                        "Generation stays on this iPhone after the selected model is installed."
                    )
                }
            }
            .navigationTitle("Models & Styles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await manager.refreshCatalog() }
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
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task {
                await manager.refreshCatalog()
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
        .presentationDetents([.medium, .large])
    }
}

private struct ModelVariantRow: View {
    let variant: ModelCatalog.Variant
    let state: ModelManager.InstallState
    let isSelected: Bool
    let downloadSize: Int64
    let isBundledStyle: Bool
    let canDownload: Bool
    let select: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: variant.id == "base"
                    ? "leaf.fill"
                    : "paintpalette.fill")
                    .font(.title3)
                    .foregroundStyle(.cloverGreen)
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: .circle)

                VStack(alignment: .leading, spacing: 3) {
                    Text(variant.name)
                        .font(.headline)
                    Text(variant.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let trigger = variant.trigger {
                        Text("Prompt trigger: \(trigger)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-\(variant.id)")
        .contextMenu {
            if state == .installed, !isBundledStyle {
                Button("Remove Download", role: .destructive) {
                    remove()
                }
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .installed:
            Button {
                select()
            } label: {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.cloverGreen)
                } else {
                    Text("Use")
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                isSelected
                    ? "\(variant.name), selected"
                    : "Use \(variant.name)"
            )
        case .downloading:
            Button("Cancel", role: .cancel) {
                cancel()
            }
            .buttonStyle(.borderless)
        case .notInstalled, .failed:
            if isBundledStyle {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Included")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("with Clover")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("\(variant.name) is included with Clover")
            } else {
                Button {
                    download()
                } label: {
                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                        Text(downloadSize, format: .byteCount(style: .file))
                            .font(.caption2)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!canDownload)
                .accessibilityLabel("Download \(variant.name)")
            }
        }
    }
}

#Preview {
    ModelPickerView(
        settings: .constant(GenerationSettings()),
        manager: ModelManager(previewInstalled: true)
    )
}
