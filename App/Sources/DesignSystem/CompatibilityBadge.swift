import SwiftUI

struct CompatibilityBadge: View {
    let compatibility: Compatibility

    private var tint: Color {
        switch compatibility {
        case .great: .green
        case .runs: .blue
        case .tight: .orange
        case .wontFit: .red
        }
    }

    var body: some View {
        Label(compatibility.label, systemImage: compatibility.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
