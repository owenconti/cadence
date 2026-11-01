import SwiftUI

/// The Cadence mark: three rising bars inside a rounded square.
struct LogoMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accent, Color(hex: 0xC0397A)], startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(alignment: .bottom, spacing: size * 0.08) {
                ForEach([0.32, 0.55, 0.42], id: \.self) { h in
                    Capsule().fill(.white).frame(width: size * 0.11, height: size * h)
                }
            }
        }
        .frame(width: size, height: size)
    }
}
