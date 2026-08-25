import SwiftUI

struct ParameterForm: View {
    @Binding var settings: GenerationSettings
    var mode: StudioMode = .create
    var manager: ModelManager?
    @State private var styleLimitMessage: String?

    private var isInpainting: Bool { mode == .inpaint }

    var body: some View {
        Form {
            samplingSection
            seedSection
            if !isInpainting {
                outputSection
            }
            if !isInpainting {
                styleSection
            }
            previewSection
            computeSection
            factsSection
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier(
            isInpainting ? "inpainting-settings-form" : "parameters-form"
        )
        .onAppear {
            if isInpainting {
                settings.scheduler = .dpmSolver
                settings.styleIDs = []
                settings.styleStrengths = [:]
                settings.stepCount = InpaintingGenerationLimits.clampedStepCount(
                    settings.stepCount
                )
            }
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

    private var samplingSection: some View {
        Section {
            Stepper(
                "\(stepCount.wrappedValue) steps",
                value: stepCount,
                in: stepRange
            )
            .accessibilityIdentifier(
                isInpainting ? "inpainting-steps-stepper" : "steps-stepper"
            )

            HapticlessIntegerSlider(
                value: stepCount,
                in: stepRange,
                accessibilityLabel: isInpainting
                    ? "Inpainting steps"
                    : "Inference steps",
                accessibilityValue: "\(stepCount.wrappedValue)",
                accessibilityIdentifier: isInpainting
                    ? "inpainting-steps-slider"
                    : "steps-slider"
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Guidance", systemImage: "scope")
                    Spacer()
                    Text(
                        settings.guidanceScale,
                        format: .number.precision(.fractionLength(1))
                    )
                    .foregroundStyle(.secondary)
                }
                Slider(
                    value: $settings.guidanceScale,
                    in: 1...20,
                    step: 0.5
                )
                .accessibilityLabel("Guidance scale")
                .accessibilityIdentifier(
                    isInpainting ? "inpainting-guidance-slider" : "guidance-slider"
                )
            }

            if isInpainting {
                LabeledContent("Scheduler", value: "DPM-Solver++")
            } else {
                Picker("Scheduler", selection: $settings.scheduler) {
                    ForEach(GenerationSettings.Scheduler.allCases) { scheduler in
                        Text(scheduler.title).tag(scheduler)
                    }
                }
                .accessibilityIdentifier("scheduler-picker")
            }
        } header: {
            Text("Sampling")
        } footer: {
            Text(
                isInpainting
                    ? "20 steps is recommended for inpainting; 50 is the on-device maximum."
                    : "Clover generates natively at 512 × 512."
            )
        }
    }

    private var seedSection: some View {
        Section("Seed") {
            TextField(
                "Seed",
                value: $settings.seed,
                format: .number.grouping(.never)
            )
            .keyboardType(.numberPad)
            .accessibilityIdentifier(
                isInpainting ? "inpainting-seed-field" : "seed-field"
            )

            Button {
                settings.seed = .random(in: .min ... .max)
                HapticManager.selection()
            } label: {
                Label("Randomize Seed", systemImage: "dice")
            }

            Picker("Noise generator", selection: $settings.randomGenerator) {
                ForEach(GenerationSettings.RandomGenerator.allCases) { generator in
                    Text(generator.title).tag(generator)
                }
            }
            .accessibilityIdentifier(
                isInpainting ? "inpainting-rng-picker" : "rng-picker"
            )
        }
    }

    private var outputSection: some View {
        Section("Output") {
            Stepper(
                "\(settings.imageCount) \(settings.imageCount == 1 ? "image" : "images")",
                value: $settings.imageCount,
                in: 1...4
            )
            .accessibilityIdentifier("image-count-stepper")
        }
    }

    @ViewBuilder
    private var styleSection: some View {
        if !installedStyleIDs.isEmpty {
            Section {
                ForEach(installedStyleIDs, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            styleIcon(for: id)

                            Text(manager?.displayName(for: id) ?? "Imported Style")
                                .font(.body)

                            Spacer()

                            Toggle("", isOn: styleEnabledBinding(for: id))
                                .labelsHidden()
                                .accessibilityLabel(
                                    "Use \(manager?.displayName(for: id) ?? "style")"
                                )
                                .accessibilityIdentifier("style-mix-enabled-\(id)")
                        }

                        if settings.styleIDs.contains(id) {
                            HStack {
                                Text("Weight")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(
                                    settings.styleStrength(for: id),
                                    format: .number.precision(.fractionLength(2))
                                )
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            }

                            Slider(
                                value: Binding(
                                    get: { settings.styleStrength(for: id) },
                                    set: { settings.setStyleStrength($0, for: id) }
                                ),
                                in: 0...1.5,
                                step: 0.05
                            )
                            .accessibilityLabel(
                                "\(manager?.displayName(for: id) ?? "Style") weight"
                            )
                            .accessibilityIdentifier("style-weight-\(id)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("style-mix-\(id)")
                }
            } header: {
                Text("LoRA")
            } footer: {
                Text("Styles are off by default. A weight of 1.00 uses a LoRA as trained; up to three can be enabled together.")
            }
        }
    }

    private var installedStyleIDs: [String] {
        guard let manager else { return settings.styleIDs }
        let catalogIDs = manager.catalog.styleVariants
            .filter { manager.isInstalled($0.id) }
            .map(\.id)
        let importedIDs = manager.imported.map(\.id)
        return catalogIDs + importedIDs
    }

    private func styleEnabledBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { settings.styleIDs.contains(id) },
            set: { enabled in setStyle(id, enabled: enabled) }
        )
    }

    private func setStyle(_ id: String, enabled: Bool) {
        let previousIDs = settings.styleIDs
        if enabled {
            guard !settings.styleIDs.contains(id) else { return }
            guard settings.styleIDs.count < GenerationSettings.maximumStyleCount else {
                styleLimitMessage = "Disable another LoRA before enabling this one. Clover can mix up to \(GenerationSettings.maximumStyleCount) LoRAs at once."
                return
            }
            settings.styleIDs.append(id)
            settings.styleStrengths[id] = settings.styleStrengths[id] ?? 1
        } else {
            settings.styleIDs.removeAll { $0 == id }
            settings.styleStrengths[id] = nil
        }
        settings.applyStyleTriggers(
            triggers(for: settings.styleIDs),
            replacing: triggers(for: previousIDs)
        )
        settings.modelID = ModelManager.baseID
        settings.persist()
    }

    private func triggers(for ids: [String]) -> [String] {
        ids.compactMap { id in
            manager?.variant(id: id)?.trigger
                ?? manager?.importedStyle(id: id)?.trigger
        }
    }

    private var previewSection: some View {
        Section {
            Toggle(isOn: $settings.livePreviewEnabled) {
                Label(
                    "Live Step Previews",
                    systemImage: "photo.on.rectangle.angled"
                )
            }
            .accessibilityIdentifier(
                isInpainting
                    ? "inpainting-live-preview-toggle"
                    : "live-preview-toggle"
            )

            Stepper(
                previewIntervalTitle,
                value: previewIntervalBinding,
                in: 1...previewIntervalLimit
            )
            .disabled(!settings.livePreviewEnabled)
            .accessibilityIdentifier(
                isInpainting
                    ? "inpainting-preview-interval-stepper"
                    : "preview-interval-stepper"
            )

            HapticlessIntegerSlider(
                value: previewIntervalBinding,
                in: 1...previewIntervalLimit,
                accessibilityLabel: isInpainting
                    ? "Inpainting preview interval"
                    : "Preview interval",
                accessibilityValue: previewIntervalTitle,
                accessibilityIdentifier: isInpainting
                    ? "inpainting-preview-interval-slider"
                    : "preview-interval-slider"
            )
            .disabled(!settings.livePreviewEnabled)
        } header: {
            Text("Live Step Previews")
        } footer: {
            Text(
                settings.livePreviewEnabled
                    ? "Frames are approximated from the latent, saved as JPEGs beside the artwork, and scrubbable in the Library. More frequent previews cost time, storage and battery."
                    : "Off: no latent rendering and no timeline frames — the fastest, smallest run."
            )
        }
    }

    private var computeSection: some View {
        Section {
            Picker("Preference", selection: $settings.computeTarget) {
                ForEach(GenerationSettings.ComputeTarget.allCases) { target in
                    Label(target.title, systemImage: target.systemImage)
                        .tag(target)
                }
            }
            .accessibilityIdentifier(
                isInpainting ? "inpainting-compute-picker" : "compute-picker"
            )

            LabeledContent(
                "U-Net",
                value: isInpainting ? "Neural Engine" : "CPU + GPU"
            )
        } header: {
            Text("Compute")
        } footer: {
            Text(
                isInpainting
                    ? "The chunked inpainting U-Net runs on the Neural Engine to keep peak memory low and preserve numerical accuracy."
                    : "The stateful U-Net uses CPU + GPU because its mutable style buffers aren't planned reliably on the Neural Engine. Your preference applies to text encoding and VAE processing."
            )
        }
    }

    private var factsSection: some View {
        Section("Details") {
            LabeledContent("Output", value: "512 × 512")
            if isInpainting {
                LabeledContent("Composite", value: "Exact mask")
                LabeledContent("Unmasked pixels", value: "Preserved")
                LabeledContent("Automatic reseeds", value: "3")
            } else {
                LabeledContent(
                    "Styles",
                    value: settings.styleIDs.isEmpty
                        ? "None"
                        : "\(settings.styleIDs.count) active"
                )
                LabeledContent("Runs", value: "On device")
            }
        }
    }

    private func styleIcon(for id: String) -> some View {
        Group {
            if let assetName = manager?.variant(id: id)?.iconAssetName {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "paintpalette.fill")
                    .foregroundStyle(.tint)
                    .background(Color(.quaternarySystemFill))
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private var stepRange: ClosedRange<Int> {
        isInpainting
            ? InpaintingGenerationLimits.minimumStepCount
                ... InpaintingGenerationLimits.maximumStepCount
            : 4...100
    }

    private var stepCount: Binding<Int> {
        Binding(
            get: {
                isInpainting
                    ? InpaintingGenerationLimits.clampedStepCount(settings.stepCount)
                    : settings.stepCount
            },
            set: { newValue in
                settings.stepCount = isInpainting
                    ? InpaintingGenerationLimits.clampedStepCount(newValue)
                    : min(max(newValue, 4), 100)
            }
        )
    }

    private var previewIntervalLimit: Int {
        min(max(stepCount.wrappedValue, 1), 10)
    }

    private var previewIntervalTitle: String {
        let interval = min(settings.previewInterval, previewIntervalLimit)
        return "Every \(interval) \(interval == 1 ? "step" : "steps")"
    }

    private var previewIntervalBinding: Binding<Int> {
        Binding(
            get: {
                min(max(settings.previewInterval, 1), previewIntervalLimit)
            },
            set: {
                settings.previewInterval = min(max($0, 1), previewIntervalLimit)
            }
        )
    }
}
