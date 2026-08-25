import SwiftUI

/// A native toolbar entry point for app-level settings.
struct SettingsToolbarButton: View {
    @Environment(Route.self) private var route

    var body: some View {
        Button("Settings", systemImage: "gearshape") {
            route.settingsPresented = true
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("settings-button")
    }
}
