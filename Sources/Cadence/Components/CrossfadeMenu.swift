import SwiftUI

/// Picks how long each song fades into the next, or no crossfade. Shown
/// only where Apple's player can crossfade (iPhone and iPad); kept on the
/// device and used for everything that plays.
struct CrossfadeMenu: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 40

    var body: some View {
        if Player.canCrossfade {
            let player = model.player
            let on = player.crossfade > 0
            Menu {
                Picker("Crossfade", selection: Binding(get: { player.crossfade }, set: { player.crossfade = $0 })) {
                    Text("Off").tag(TimeInterval(0))
                    ForEach(Player.crossfadeChoices, id: \.self) { seconds in
                        Text("\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: size * 0.36, weight: .bold))
                    if on {
                        Text("\(Int(player.crossfade))s")
                            .font(.system(size: size * 0.32, weight: .bold).monospacedDigit())
                    }
                }
                .foregroundStyle(on ? Theme.canvas : Theme.text)
                .padding(.horizontal, on ? size * 0.3 : 0)
                .frame(minWidth: size, minHeight: size)
                .background(Capsule().fill(on ? AnyShapeStyle(Theme.text) : AnyShapeStyle(.ultraThinMaterial)))
                .contentShape(Capsule())
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Crossfade")
            .accessibilityValue(on ? "\(Int(player.crossfade)) seconds" : "Off")
        }
    }
}
