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
                    Text("Inpainting supports 4–50 steps on device. More steps can improve detail but take longer.")
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
                    Picker("Scheduler", selection: $settings.scheduler) {
                        ForEach(GenerationSettings.Scheduler.allCases) { scheduler in
                            VStack(alignment: .leading) {
                                Text(scheduler.title)
                                Text(scheduler.detail)
                            }
                            .tag(scheduler)
                        }
                    }
                    .accessibilityIdentifier("inpainting-scheduler-picker")

                    Picker("Random generator", selection: $settings.randomGenerator) {
                        ForEach(GenerationSettings.RandomGenerator.allCases) { generator in
                            Text(generator.title).tag(generator)
                        }
                    }
                    .accessibilityIdentifier("inpainting-rng-picker")
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
}
