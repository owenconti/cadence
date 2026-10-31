import SwiftUI

struct Scrubber: View {
    @Environment(AppModel.self) private var model
    var tint: Color = .white

    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        let duration = max(model.player.current?.duration ?? 1, 1)
        let fraction = dragFraction ?? min(model.player.position / duration, 1)
        let engaged = hovering || dragFraction != nil

        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(tint).frame(width: max(0, width * fraction))
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                        .offset(x: width * fraction - 6)
                        .opacity(engaged ? 1 : 0)
                }
                .frame(height: engaged ? 6 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { dragFraction = min(max($0.location.x / width, 0), 1) }
                        .onEnded { _ in
                            if let dragFraction { model.player.seek(to: dragFraction * duration) }
                            dragFraction = nil
                        }
                )
                .onHover { h in withAnimation(.snappy(duration: 0.15)) { hovering = h } }
            }
            .frame(height: 14)

            HStack {
                Text((fraction * duration).clock)
                Spacer()
                Text("-" + (duration - fraction * duration).clock)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.tertiary)
        }
    }
}

struct TransportControls: View {
    @Environment(AppModel.self) private var model
    var large = false

    var body: some View {
        let player = model.player
        let mainSize: CGFloat = large ? 64 : 50

        HStack(spacing: large ? 22 : 10) {
            Button(action: player.toggleShuffle) { Image(systemName: "shuffle") }
                .buttonStyle(IconButtonStyle(size: 34, active: player.isShuffled))
                .overlay(alignment: .bottom) {
                    if player.isShuffled {
                        Circle().fill(Theme.accent).frame(width: 4, height: 4).offset(y: 3)
                    }
                }
                .help(player.isShuffled ? "Shuffle is on" : "Shuffle is off")
                .accessibilityValue(player.isShuffled ? "On" : "Off")
            Spacer(minLength: 0)
            Button(action: player.previous) { Image(systemName: "backward.fill") }
                .buttonStyle(IconButtonStyle(size: large ? 46 : 40))
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: mainSize * 0.36, weight: .bold))
                    .foregroundStyle(.black)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: mainSize, height: mainSize)
                    .background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            }
            .buttonStyle(PressableStyle())
            .help("Play / Pause (Space)")
            Button(action: player.next) { Image(systemName: "forward.fill") }
                .buttonStyle(IconButtonStyle(size: large ? 46 : 40))
            Spacer(minLength: 0)
            Button {
                if let track = player.current { model.openArtist(id: track.artistID, name: track.artistName) }
            } label: {
                Image(systemName: "person.fill")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Go to artist")
        }
    }
}

/// Color wash behind the whole window, tinted by whatever is playing.
struct AmbientBackground: View {
    @Environment(AppModel.self) private var model
    var intensity: Double = 0.32

    var body: some View {
        let palette = model.player.current?.artwork.palette ?? Palette(primary: Theme.accent.opacity(0.5), secondary: Color(hex: 0x3A0CA3))
        ZStack {
            Theme.canvas
            RadialGradient(colors: [palette.primary.opacity(intensity), .clear], center: .topTrailing, startRadius: 0, endRadius: 900)
            RadialGradient(colors: [palette.secondary.opacity(intensity * 0.9), .clear], center: .bottomLeading, startRadius: 0, endRadius: 800)
        }
        .animation(.easeInOut(duration: 1.4), value: model.player.current?.id)
        .ignoresSafeArea()
    }
}
