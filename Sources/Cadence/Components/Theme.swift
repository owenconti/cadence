import SwiftUI

enum Theme {
    static let canvas = Color(hex: 0x0C0C10)
    static let panel = Color.white.opacity(0.03)
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.09)
    static let hairline = Color.white.opacity(0.07)
    static let text = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)
    static let accent = Color(hex: 0xFF6A55)

    /// Top inset that clears the window's traffic-light buttons.
    static let titlebarInset: CGFloat = 46
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension Font {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension View {
    func eyebrow() -> some View {
        font(.system(size: 11, weight: .semibold))
            .tracking(1.3)
            .foregroundStyle(Theme.tertiary)
    }
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 18)
            .frame(height: 36)
            .foregroundStyle(prominent ? Color.black : Theme.text)
            .background(Capsule().fill(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.card)))
            .overlay(Capsule().stroke(prominent ? .clear : Theme.hairline))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var active = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(active ? Theme.accent : (hovering ? Theme.text : Theme.secondary))
            .frame(width: size, height: size)
            .background(Circle().fill(hovering ? Theme.card : .clear))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Round play button that floats on top of artwork.
struct PlayFab: View {
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.black)
                .offset(x: 1)
                .frame(width: size, height: size)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(PressableStyle())
    }
}

struct FilterField: View {
    let prompt: String
    @Binding var text: String
    /// Nil fills the row (the phone).
    var width: CGFloat? = 220

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 32)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.hairline))
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Theme.canvas)
            .frame(width: 14, height: 14)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.tertiary))
    }
}

/// Text that goes somewhere (an artist, an album): brightens and underlines on
/// hover, with a pointing-hand cursor.
struct LinkButtonStyle: ButtonStyle {
    var color: Color = Theme.secondary

    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(label: configuration.label, color: color, pressed: configuration.isPressed)
    }

    private struct LinkLabel<Label: View>: View {
        let label: Label
        let color: Color
        let pressed: Bool
        @State private var hovering = false

        var body: some View {
            label
                .foregroundStyle(hovering ? Theme.text : color)
                .underline(hovering)
                .opacity(pressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                #if os(macOS)
                .pointerStyle(.link)
                #endif
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
