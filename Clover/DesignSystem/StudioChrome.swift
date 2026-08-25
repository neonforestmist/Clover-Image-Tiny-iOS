import SwiftUI

struct ResourceAdvisoryBanner: View {
    let verdict: ResourceGuard.Verdict

    var body: some View {
        if let text = verdict.advisoryText {
            Label(text, systemImage: "thermometer.medium")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("resource-advisory")
        }
    }
}
