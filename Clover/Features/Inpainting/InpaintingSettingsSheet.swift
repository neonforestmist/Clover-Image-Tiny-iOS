import SwiftUI

struct InpaintingSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: GenerationSettings

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper(
                            "\(stepCount.wrappedValue) steps",
                            value: stepCount,
                            in: InpaintingGenerationLimits.minimumStepCount
                                ... InpaintingGenerationLimits.maximumStepCount
                        )
                        .accessibilityIdentifier("inpainting-steps-stepper")

                        HapticlessIntegerSlider(
                            value: stepCount,
                            in: InpaintingGenerationLimits.minimumStepCount
                                ... InpaintingGenerationLimits.maximumStepCount,
                            accessibilityLabel: "Inpainting steps",
                            accessibilityValue: "\(stepCount.wrappedValue)",
                            accessibilityIdentifier: "inpainting-steps-slider"
                        )
                    }

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
                        .accessibilityIdentifier("inpainting-guidance-slider")
                    }
                } header: {
                    Text("Generation")
                } footer: {
                    Text("Inpainting supports 4–50 steps on device. Twenty steps is the recommended balance of detail, speed, and memory use.")
                }

                Section("Seed") {
                    TextField(
                        "Seed",
                        value: $settings.seed,
                        format: .number.grouping(.never)
                    )
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("inpainting-seed-field")

                    Button {
                        settings.seed = .random(in: .min ... .max)
                        HapticManager.selection()
                    } label: {
                        Label("Randomize Seed", systemImage: "dice")
                    }
                }

                Section("Sampler") {
                    LabeledContent("Scheduler", value: "DPM-Solver++")

                    Picker("Random generator", selection: $settings.randomGenerator) {
                        ForEach(GenerationSettings.RandomGenerator.allCases) { generator in
                            Text(generator.title).tag(generator)
                        }
                    }
                    .accessibilityIdentifier("inpainting-rng-picker")
                }

                Section {
                    Toggle(isOn: $settings.livePreviewEnabled) {
                        Label(
                            "Live Step Previews",
                            systemImage: "photo.on.rectangle.angled"
                        )
                    }
                    .accessibilityIdentifier("inpainting-live-preview-toggle")

                    Stepper(
                        previewIntervalTitle,
                        value: previewIntervalBinding,
                        in: 1...previewIntervalLimit
                    )
                    .disabled(!settings.livePreviewEnabled)
                    .accessibilityIdentifier("inpainting-preview-interval-stepper")

                    HapticlessIntegerSlider(
                        value: previewIntervalBinding,
                        in: 1...previewIntervalLimit,
                        accessibilityLabel: "Inpainting preview interval",
                        accessibilityValue: previewIntervalTitle,
                        accessibilityIdentifier: "inpainting-preview-interval-slider"
                    )
                    .disabled(!settings.livePreviewEnabled)
                } header: {
                    Text("Progress Preview")
                } footer: {
                    Text("Preview frames are saved with the finished edit and can be scrubbed or exported later. Turning previews off reduces decoding work, storage use, and battery use.")
                }

                Section {
                    Picker("Compute", selection: $settings.computeTarget) {
                        ForEach(GenerationSettings.ComputeTarget.allCases) { target in
                            Label(target.title, systemImage: target.systemImage)
                                .tag(target)
                        }
                    }
                    .accessibilityIdentifier("inpainting-compute-picker")
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Neural Engine is the default for supported iPhone hardware.")
                }

                Section {
                    LabeledContent("Working canvas", value: "512 × 512")
                    LabeledContent("Mask", value: "White regenerates")
                    LabeledContent("Unmasked pixels", value: "Preserved")
                }
            }
            .accessibilityIdentifier("inpainting-settings-form")
            .navigationTitle("Inpainting Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            settings.scheduler = .dpmSolver
        }
    }

    private var stepCount: Binding<Int> {
        Binding(
            get: {
                InpaintingGenerationLimits.clampedStepCount(settings.stepCount)
            },
            set: {
                settings.stepCount = InpaintingGenerationLimits.clampedStepCount($0)
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
                settings.previewInterval = min(
                    max($0, 1),
                    previewIntervalLimit
                )
            }
        )
    }
}
