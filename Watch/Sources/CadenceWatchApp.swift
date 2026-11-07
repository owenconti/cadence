import SwiftUI
import WatchConnectivity

@MainActor
final class WatchRemote: NSObject, ObservableObject, WCSessionDelegate {
    @Published var state = WatchPlayback()
    @Published var reachable = false
    override init() {
        super.init()
        if ProcessInfo.processInfo.arguments.contains("--snapshot") {
            state = WatchPlayback(title: "Midnight City", artist: "M83", position: 93, duration: 244, playing: true)
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    func command(_ value: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": value], replyHandler: nil, errorHandler: { _ in })
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        receive(session.receivedApplicationContext)
        sessionReachabilityDidChange(session)
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachable = reachable }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { receive(applicationContext) }
    nonisolated private func receive(_ context: [String: Any]) {
        guard let data = context["state"] as? Data, let state = try? JSONDecoder().decode(WatchPlayback.self, from: data) else { return }
        Task { @MainActor in self.state = state }
    }
}

@main
struct CadenceWatchApp: App {
    @StateObject private var remote = WatchRemote()
    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    Text(remote.state.title).font(.headline).lineLimit(1)
                    Text(remote.state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(Color.yellow).frame(width: geometry.size.width * min(1, max(0, remote.state.position / max(1, remote.state.duration))))
                    }
                }.frame(height: 28)
                    .accessibilityLabel("Track progress")
                    .accessibilityValue("\(time(remote.state.position)) elapsed, \(time(remote.state.duration - remote.state.position)) remaining")
                HStack {
                    Text(time(remote.state.position))
                    Spacer()
                    Text("−" + time(remote.state.duration - remote.state.position))
                }.font(.system(.body, design: .monospaced).bold())
                HStack {
                    control("backward.end.fill", "Previous", "previous")
                    control(remote.state.playing ? "pause.fill" : "play.fill", remote.state.playing ? "Pause" : "Play", "toggle")
                    control("forward.end.fill", "Next", "next")
                }.disabled(!remote.reachable || remote.state.duration <= 0)
                if !remote.reachable { Text("Open Cadence on iPhone").font(.caption2).foregroundStyle(.secondary) }
            }.padding(.horizontal, 4).background(.black)
        }
    }
    private func control(_ icon: String, _ label: String, _ command: String) -> some View {
        Button { remote.command(command) } label: { Image(systemName: icon).frame(maxWidth: .infinity, minHeight: 44) }
            .accessibilityLabel(label).buttonStyle(.plain)
    }
}
