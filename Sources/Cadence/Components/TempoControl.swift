import SwiftUI

/// The playing song's tempo, with − and + to slow it down or speed it up a
/// beat per minute at a time (hold to keep going). The speed is kept for the
/// song, so it plays that way every time. Songs whose tempo can't be measured
/// change speed in steps of 2% instead.
struct TempoControl: View {
    @Environment(AppModel.self) private var model
    var large = false

    var body: some View {
        if let track = model.player.current {
            content(track)
        }
    }

    private func content(_ track: TrackItem) -> some View {
        let tempo = model.tempo
        let rate = tempo.rate(for: track)
        let adjusted = tempo.isAdjusted(track)
        let bpm = tempo.bpm(for: track)
        let measuring = bpm == nil && tempo.isMeasuring(track)
        let percent = Int(((rate - 1) * 100).rounded())

        return HStack(spacing: 6) {
            Button { model.nudgeTempo(by: -1) } label: { Image(systemName: "minus") }
                .buttonStyle(IconButtonStyle(size: large ? 34 : 28))
                .buttonRepeatBehavior(.enabled)
                .disabled(rate <= TempoStore.rates.lowerBound || measuring)
                .help(bpm == nil ? "Slower (⌥⌘↓)" : "1 BPM slower (⌥⌘↓)")
                .accessibilityLabel("Slower")

            // The tempo; once changed, clicking it goes back to the original.
            Button { model.resetTempo() } label: {
                VStack(spacing: 1) {
                    Group {
                        if let bpm {
                            Text("\(Int((bpm * rate).rounded())) BPM")
                        } else if measuring {
                            Text("— BPM")
                        } else {
                            Text("\(Int((rate * 100).rounded()))% speed")
                        }
                    }
                    .font(.system(size: large ? 15 : 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(adjusted ? Theme.accent : Theme.text)
                    .contentTransition(.numericText(value: rate))

                    Group {
                        if measuring {
                            Text("Measuring tempo…")
                        } else if adjusted, let bpm {
                            Text("\(Image(systemName: "arrow.counterclockwise")) \(Int(bpm.rounded())) original · \(percent > 0 ? "+" : "")\(percent)%")
                        } else if adjusted {
                            Text("\(Image(systemName: "arrow.counterclockwise")) Original speed")
                        } else {
                            Text(bpm == nil ? "No tempo found" : "Original tempo")
                        }
                    }
                    .font(.system(size: large ? 11.5 : 10.5).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                }
                .lineLimit(1)
                .frame(minWidth: large ? 130 : 112)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(!adjusted)
            .help(adjusted ? "Back to the original tempo" : "")
            .accessibilityHint(adjusted ? "Goes back to the original tempo" : "")
            .animation(.snappy(duration: 0.2), value: rate)

            Button { model.nudgeTempo(by: 1) } label: { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle(size: large ? 34 : 28))
                .buttonRepeatBehavior(.enabled)
                .disabled(rate >= TempoStore.rates.upperBound || measuring)
                .help(bpm == nil ? "Faster (⌥⌘↑)" : "1 BPM faster (⌥⌘↑)")
                .accessibilityLabel("Faster")

        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.card))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tempo")
    }
}
