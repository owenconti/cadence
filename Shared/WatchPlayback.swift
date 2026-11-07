import Foundation

/// The wire format is shared; the phone's Player remains the playback authority.
struct WatchPlayback: Codable {
    var title = "Nothing playing"
    var artist = "Open Cadence on iPhone"
    var position: Double = 0
    var duration: Double = 0
    var playing = false
}
