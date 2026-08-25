import SwiftUI

struct ModelsScreen: View {
    @Binding var settings: GenerationSettings
    let manager: ModelManager
    let inpaintingManager: InpaintingModelManager

    var body: some View {
        ModelPickerView(
            settings: $settings,
            manager: manager,
            inpaintingManager: inpaintingManager,
            presentation: .page
        )
    }
}
