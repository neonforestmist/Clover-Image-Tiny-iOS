import SwiftUI

struct InpaintingSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: GenerationSettings
    let manager: ModelManager

    var body: some View {
        NavigationStack {
            ParameterForm(
                settings: $settings,
                mode: .inpaint,
                manager: manager
            )
                .navigationTitle("Inpainting Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
