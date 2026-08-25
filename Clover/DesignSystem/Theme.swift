import SwiftUI

enum StudioPalette {
    static let hairline = Color(.separator)
    static let checkLight = Color(.secondarySystemFill)
    static let checkDark = Color(.tertiarySystemFill)
}

enum StudioMetrics {
    static let canvasCorner: CGFloat = 24
    static let cardCorner: CGFloat = 16
}

extension View {
    func cloverContinuousClip(_ radius: CGFloat) -> some View {
        clipShape(.rect(cornerRadius: radius, style: .continuous))
    }
}
