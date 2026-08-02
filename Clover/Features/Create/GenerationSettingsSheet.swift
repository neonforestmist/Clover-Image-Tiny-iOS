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

                        Slider(
                            value: Binding(
                                get: { Double(settings.stepCount) },
                                set: {
                                    settings.stepCount = Int($0.rounded())
                                }
                            ),
                            in: 4...100,
                            step: 1
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

                    Picker("Aspect Ratio", selection: $settings.outputRatio) {
                        ForEach(GenerationSettings.OutputRatio.allCases) { ratio in
                            Label {
                                Text(ratio == .custom
                                    ? ratio.title
                                    : "\(ratio.title) · \(ratio.dimensions)")
                            } icon: {
                                Image(systemName: ratio.systemImage)
                            }
                                .tag(ratio)
                        }
                    }
                    .accessibilityIdentifier("output-ratio-picker")

                    if settings.outputRatio == .custom {
                        Stepper(
                            value: $settings.customAspectWidth,
                            in: 1...32
                        ) {
                            Label(
                                "Width · \(settings.customAspectWidth)",
                                systemImage: "arrow.left.and.right"
                            )
                        }
                        .accessibilityIdentifier("custom-ratio-width-stepper")

                        Stepper(
                            value: $settings.customAspectHeight,
                            in: 1...32
                        ) {
                            Label(
                                "Height · \(settings.customAspectHeight)",
                                systemImage: "arrow.up.and.down"
                            )
                        }
                        .accessibilityIdentifier("custom-ratio-height-stepper")
                    }
                } header: {
                    Text("Generation")
                } footer: {
                    Text("Clover generates at 512×512. Non-square output uses a centered crop, so it adds no model download.")
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
                    Text("Neural Engine is recommended for this model. Changing compute mode reloads the pipeline.")
                }

                Section {
                    LabeledContent(
                        "Output",
                        value: settings.outputDimensions
                    )
                    LabeledContent("Generation", value: "512 × 512")
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
}
