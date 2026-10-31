import MusicKit
import SwiftUI

struct ArtworkView: View {
    let source: ArtworkSource
    var cornerRadius: CGFloat = 10
    var circular = false
    /// Pixel size requested from the artwork service.
    var resolution = 400

    var body: some View {
        let shape = circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(0.07), lineWidth: 0.5))
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case .generated(let seed, let style, let palette):
            GeneratedArt(seed: seed, style: style, palette: palette)
        case .musicKit(let artwork, let palette):
            // Library artwork uses musickit:// URLs that only ArtworkImage can load.
            GeometryReader { geo in
                ArtworkImage(artwork, width: geo.size.width, height: geo.size.height)
            }
            .background(palette.primary.opacity(0.6))
        case .none:
            ZStack {
                LinearGradient(colors: [Palette.neutral.primary, Palette.neutral.secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: circular ? "person.fill" : "music.note")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

/// Deterministic abstract cover art for the demo library.
struct GeneratedArt: View {
    let seed: UInt64
    let style: Int
    let palette: Palette

    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: seed)
            let w = min(size.width, size.height)
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [palette.primary, palette.secondary]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: size.width, y: size.height)
            ))

            switch style % 5 {
            case 0: // drifting orbs
                for _ in 0..<4 {
                    let r = w * rng.double(in: 0.12...0.42)
                    let c = CGPoint(x: w * rng.unit(), y: w * rng.unit())
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(rng.double(in: 0.06...0.2))))
                }
            case 1: // horizon sun
                let r = w * 0.27
                let c = CGPoint(x: w * 0.5, y: w * 0.56)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .linearGradient(Gradient(colors: [.white.opacity(0.95), palette.primary.opacity(0.9)]),
                                               startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)))
                for i in 0..<6 {
                    let y = c.y + CGFloat(i) * w * 0.045
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: w * 0.012 * CGFloat(i + 1) * 0.5)),
                             with: .color(palette.secondary))
                }
            case 2: // concentric rings
                let c = CGPoint(x: w * rng.double(in: 0.3...0.7), y: w * rng.double(in: 0.3...0.7))
                for i in stride(from: 9, through: 1, by: -1) {
                    let r = w * 0.09 * CGFloat(i)
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(.white.opacity(0.05 + 0.02 * Double(10 - i))), lineWidth: w * 0.012)
                }
            case 3: // diagonal bands
                var path = Path()
                for i in 0..<7 {
                    let x = w * (CGFloat(i) * 0.3 - 0.6)
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + w * 0.9, y: 0))
                }
                ctx.stroke(path, with: .color(.white.opacity(0.16)), lineWidth: w * 0.07)
            default: // soft portrait glow, used for artists
                let c = CGPoint(x: w * 0.5, y: w * 0.42)
                let r = w * 0.2
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.28)))
                let body = CGRect(x: w * 0.2, y: w * 0.68, width: w * 0.6, height: w * 0.6)
                ctx.fill(Path(ellipseIn: body), with: .color(.white.opacity(0.18)))
            }

            // A thin film of grain-like noise makes flat gradients feel printed.
            ctx.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [.white.opacity(0.08), .clear, .black.opacity(0.18)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
        }
    }
}

/// Static level bars marking the track that's playing; low when paused.
struct EqualizerBars: View {
    var active: Bool
    var color: Color = Theme.accent

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach([7.0, 12.0, 9.0], id: \.self) { height in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: active ? height : 4)
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}
