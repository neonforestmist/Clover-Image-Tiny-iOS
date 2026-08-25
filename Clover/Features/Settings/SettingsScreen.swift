import SwiftUI
import UIKit

struct SettingsScreen: View {
    let modelManager: ModelManager
    let inpaintingModelManager: InpaintingModelManager

    @Environment(\.dismiss) private var dismiss

    private let guard_ = ResourceGuard()

    var body: some View {
        NavigationStack {
            List {
                storageSection
                deviceSection
                aboutSection
                licensesSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Free space") {
                Text(guard_.availableBytes(), format: .byteCount(style: .memory))
                    .monospacedDigit()
            }
            LabeledContent("Clover models") {
                Text(modelManager.isBaseInstalled ? "Installed" : "Not installed")
                    .foregroundStyle(
                        modelManager.isBaseInstalled
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.orange)
                    )
            }
            LabeledContent("Inpainting") {
                Text(inpaintingModelManager.isInstalled ? "Installed" : "Not installed")
                    .foregroundStyle(.secondary)
            }
            Button {
                revealDocuments()
            } label: {
                Label("Reveal in Files", systemImage: "folder")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Models live in On My iPhone › Clover › Models. Imported LoRAs go in Imported Styles.")
        }
    }

    private var deviceSection: some View {
        Section("This Device") {
            LabeledContent("Thermal state", value: thermalTitle)
            LabeledContent(
                "Low Power Mode",
                value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off"
            )
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: "Clover Image Tiny")
            LabeledContent("Output", value: "512 × 512")
            LabeledContent("Pipeline", value: "On-device Core ML")
            Link(
                "Clover Image Tiny on Hugging Face",
                destination: modelManager.catalog.hubURL
            )
        }
    }

    private var licensesSection: some View {
        Section {
            Text("Clover is Apache-2.0. Converted weights and derived styles use CreativeML Open RAIL-M. The pipeline includes Apple’s ml-stable-diffusion. Interface icons are Phosphor via Iconify (MIT).")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link(
                "CreativeML Open RAIL-M",
                destination: URL(string: "https://huggingface.co/spaces/CompVis/stable-diffusion-license")!
            )
            Link(
                "ml-stable-diffusion",
                destination: URL(string: "https://github.com/apple/ml-stable-diffusion")!
            )
        } header: {
            Text("Licenses")
        } footer: {
            Text("Weight terms are also shown before the first model download.")
        }
    }

    private var thermalTitle: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    private func revealDocuments() {
        let url = ModelStorage.rootURL
        UIApplication.shared.open(url)
    }
}

#Preview {
    SettingsScreen(
        modelManager: ModelManager(previewInstalled: true),
        inpaintingModelManager: InpaintingModelManager()
    )
}
