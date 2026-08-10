import SwiftUI

struct ArtworkImage: View {
    @Environment(ArtworkLibrary.self) private var library
    let artwork: Artwork

    var body: some View {
        Group {
            if let image = library.image(for: artwork) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ContentUnavailableView(
                    "Image Missing",
                    systemImage: "photo.badge.exclamationmark"
                )
            }
        }
        .clipped()
    }
}

struct ArtworkFrameImage: View {
    @Environment(ArtworkLibrary.self) private var library

    let artwork: Artwork
    let frameIndex: Int

    var body: some View {
        Group {
            if let image = library.frameImage(
                for: artwork,
                at: frameIndex
            ) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ContentUnavailableView(
                    "Image Missing",
                    systemImage: "photo.badge.exclamationmark"
                )
            }
        }
        .clipped()
    }
}

struct ArtworkTimelineControls: View {
    @Environment(ArtworkLibrary.self) private var library

    let artwork: Artwork
    @Binding var selection: Int
    var showsExportAction = false

    private var previews: [ArtworkPreviewFrame] {
        library.previewFrames(for: artwork)
    }

    private var finalIndex: Int { previews.count }

    private var selectedIndex: Int {
        min(max(selection, 0), finalIndex)
    }

    private var selectedStep: Int {
        library.frameStep(for: artwork, at: selectedIndex)
    }

    var body: some View {
        if !previews.isEmpty {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Label(
                        "Step \(selectedStep) of \(artwork.generation.stepCount)",
                        systemImage: selectedIndex == finalIndex
                            ? "checkmark.circle.fill"
                            : "circle.dotted"
                    )
                    .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text("\(selectedIndex + 1) of \(finalIndex + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if showsExportAction {
                        ShareLink(
                            item: library.frameURL(
                                for: artwork,
                                at: selectedIndex
                            )
                        ) {
                            Label(
                                "Export Frame",
                                systemImage: "square.and.arrow.up"
                            )
                            .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Export selected frame")
                    }
                }

                HapticlessIntegerSlider(
                    value: $selection,
                    in: 0...finalIndex,
                    accessibilityLabel: "Generation timeline",
                    accessibilityValue:
                        "Step \(selectedStep) of \(artwork.generation.stepCount)",
                    accessibilityIdentifier: "artwork-timeline-slider"
                )
            }
            .onAppear {
                selection = selectedIndex
            }
        }
    }
}

/// A drag-based integer control that avoids UIKit/SwiftUI slider tick feedback.
struct HapticlessIntegerSlider: View {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Int

    let range: ClosedRange<Int>
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityIdentifier: String

    private let thumbDiameter: CGFloat = 28
    private let trackHeight: CGFloat = 4

    init(
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        accessibilityLabel: String,
        accessibilityValue: String,
        accessibilityIdentifier: String
    ) {
        _value = value
        self.range = range
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, thumbDiameter)
            let travel = max(width - thumbDiameter, 1)
            let thumbCenter = thumbDiameter / 2 + travel * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumbDiameter / 2)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: max(0, thumbCenter - thumbDiameter / 2),
                        height: trackHeight
                    )
                    .offset(x: thumbDiameter / 2)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                Color.black.opacity(0.14),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: .black.opacity(0.32), radius: 2, y: 1)
                    .position(x: thumbCenter, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        updateValue(
                            at: gesture.location.x,
                            availableWidth: width
                        )
                    }
            )
        }
        .frame(height: 32)
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment:
                value = clamped(value + 1)
            case .decrement:
                value = clamped(value - 1)
            @unknown default:
                break
            }
        }
    }

    private var progress: CGFloat {
        let span = max(range.upperBound - range.lowerBound, 1)
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
        return CGFloat(clampedValue - range.lowerBound) / CGFloat(span)
    }

    private func updateValue(at location: CGFloat, availableWidth: CGFloat) {
        let travel = max(availableWidth - thumbDiameter, 1)
        let fraction = min(
            max((location - thumbDiameter / 2) / travel, 0),
            1
        )
        let span = range.upperBound - range.lowerBound
        value = clamped(
            range.lowerBound + Int((CGFloat(span) * fraction).rounded())
        )
    }

    private func clamped(_ candidate: Int) -> Int {
        min(max(candidate, range.lowerBound), range.upperBound)
    }
}
