import SwiftUI

/// A width-adaptive row of whole blocks. The adjacent label carries the exact value.
struct DSSegmentedBar: View {
    let fraction: Double
    var tint: Color = DS.Palette.primary

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width)
            let count = max(1, Int((width + DS.Meter.gap) / (DS.Meter.blockWidth + DS.Meter.gap)))
            let blockWidth = max(0, (width - CGFloat(count - 1) * DS.Meter.gap) / CGFloat(count))
            let value = fraction.isFinite ? min(max(fraction, 0), 1) : 0
            let lit = value > 0 ? max(1, Int((value * Double(count)).rounded())) : 0
            HStack(spacing: DS.Meter.gap) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: DS.Meter.radius)
                        .fill(index < lit ? tint : DS.Palette.border)
                        .frame(width: blockWidth)
                }
            }
        }
        .frame(height: DS.Meter.height)
        .accessibilityHidden(true)
    }
}

extension DS {
    enum Meter {
        static let blockWidth: CGFloat = 5
        static let gap: CGFloat = 2
        static let height: CGFloat = 8
        static let radius: CGFloat = 1
    }
}
