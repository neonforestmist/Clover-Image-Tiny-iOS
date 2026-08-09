import SwiftUI

struct GenerationSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: GenerationSettings

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper(
                            "\(settings.stepCount) steps",
                            value: $settings.stepCount,
                            in: 4...100
                        )
                        .accessibilityIdentifier("steps-stepper")

                        // Keep integer values without discrete slider tick haptics.
                        Slider(
                            value: Binding(
                                get: { Double(settings.stepCount) },
                                set: {
                                    settings.stepCount = Int($0.rounded())
                                }
                            ),
                            in: 4...100
                        )
                        .accessibilityLabel("Inference steps")
                        .accessibilityValue("\(settings.stepCount)")
                        .accessibilityIdentifier("steps-slider")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Guidance", systemImage: "scope")
                            Spacer()
                            Text(settings.guidanceScale, format: .number.precision(.fractionLength(1)))
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.guidanceScale,
                            in: 1...20,
                            step: 0.5
                        )
                        .accessibilityLabel("Guidance scale")
                        .accessibilityIdentifier("guidance-slider")
                    }

                    Stepper(
                        "\(settings.imageCount) \(settings.imageCount == 1 ? "image" : "images")",
                        value: $settings.imageCount,
                        in: 1...4
                    )
                    .accessibilityIdentifier("image-count-stepper")
                } header: {
                    Text("Generation")
                } footer: {
                    Text("Clover generates natively at 512 × 512.")
                }

                Section("Seed") {
                    TextField(
                        "Seed",
                        value: $settings.seed,
                        format: .number.grouping(.never)
                    )
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("seed-field")

                    Button {
                        settings.seed = .random(in: .min ... .max)
                        HapticManager.selection()
                    } label: {
                        Label("Randomize Seed", systemImage: "dice")
                    }
                }

                Section("Sampler") {
                    Picker("Scheduler", selection: $settings.scheduler) {
                        ForEach(GenerationSettings.Scheduler.allCases) { scheduler in
                            VStack(alignment: .leading) {
                                Text(scheduler.title)
                                Text(scheduler.detail)
                            }
                            .tag(scheduler)
                        }
                    }
                    .accessibilityIdentifier("scheduler-picker")

                    Picker("Random generator", selection: $settings.randomGenerator) {
                        ForEach(GenerationSettings.RandomGenerator.allCases) { generator in
                            Text(generator.title).tag(generator)
                        }
                    }
                    .accessibilityIdentifier("rng-picker")
                }

                Section {
                    Toggle(isOn: $settings.livePreviewEnabled) {
                        Label("Live Step Previews", systemImage: "photo.on.rectangle.angled")
                    }
                    .accessibilityIdentifier("live-preview-toggle")

                    Stepper(
                        previewIntervalTitle,
                        value: previewIntervalBinding,
                        in: 1...previewIntervalLimit
                    )
                    .disabled(!settings.livePreviewEnabled)
                    .accessibilityIdentifier("preview-interval-stepper")

                    // Keep integer values without discrete slider tick haptics.
                    Slider(
                        value: previewIntervalSliderBinding,
                        in: 1...Double(previewIntervalLimit)
                    )
                    .disabled(!settings.livePreviewEnabled)
                    .accessibilityLabel("Preview interval")
                    .accessibilityValue(previewIntervalTitle)
                    .accessibilityIdentifier("preview-interval-slider")
                } header: {
                    Text("Progress Preview")
                } footer: {
                    Text("Preview frames are saved with the finished artwork and can be scrubbed or exported later. More frequent previews use additional storage, can slow generation, and use more battery.")
                }

                Section {
                    Picker("Compute", selection: $settings.computeTarget) {
                        ForEach(GenerationSettings.ComputeTarget.allCases) { target in
                            Label(target.title, systemImage: target.systemImage)
                                .tag(target)
                        }
                    }
                    .accessibilityIdentifier("compute-picker")
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Clover automatically routes its LoRA model to a compatible processor. Changing compute mode reloads the pipeline.")
                }

                Section {
                    LabeledContent("Resolution", value: "512 × 512")
                    LabeledContent("Model", value: settings.modelID.capitalized)
                    LabeledContent("Runs", value: "On device")
                }
            }
            .accessibilityIdentifier("parameters-form")
            .navigationTitle("Parameters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        settings.persist()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var previewIntervalLimit: Int {
        min(max(settings.stepCount, 1), 10)
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

    private var previewIntervalSliderBinding: Binding<Double> {
        Binding(
            get: { Double(previewIntervalBinding.wrappedValue) },
            set: {
                previewIntervalBinding.wrappedValue = Int($0.rounded())
            }
        )
    }
}
