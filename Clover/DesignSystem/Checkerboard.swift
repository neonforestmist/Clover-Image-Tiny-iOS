import SwiftUI

struct Checkerboard: View {
    var cell: CGFloat = 14
    @Environment(\.self) private var environment

    var body: some View {
        let light = Color(StudioPalette.checkLight.resolve(in: environment))
        let dark = Color(StudioPalette.checkDark.resolve(in: environment))
        Canvas { context, size in
            let columns = Int(ceil(size.width / cell))
            let rows = Int(ceil(size.height / cell))

            for row in 0..<rows {
                for column in 0..<columns {
                    let rect = CGRect(
                        x: CGFloat(column) * cell,
                        y: CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                    context.fill(
                        Path(rect),
                        with: .color(
                            (row + column).isMultiple(of: 2) ? light : dark
                        )
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}
