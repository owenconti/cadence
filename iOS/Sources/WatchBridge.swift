import WatchConnectivity
import Foundation

@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()
    private var player: Player?
    private var timer: Timer?
    func start(_ player: Player) {
        guard WCSession.isSupported(), self.player == nil else { return }
        self.player = player
        WCSession.default.delegate = self
        WCSession.default.activate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
    }
    private func publish() {
        guard let player, WCSession.default.activationState == .activated else { return }
        let state = WatchPlayback(title: player.current?.title ?? "Nothing playing", artist: player.current?.artistName ?? "Open Cadence on iPhone", position: player.position, duration: player.current?.duration ?? 0, playing: player.isPlaying)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? WCSession.default.updateApplicationContext(["state": data])
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { Task { @MainActor in self.publish() } }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let command = message["command"] as? String
        Task { @MainActor in
            switch command {
            case "toggle": self.player?.toggle()
            case "previous": self.player?.previous()
            case "next": self.player?.next()
            default: break
            }
            self.publish()
        }
    }
}
