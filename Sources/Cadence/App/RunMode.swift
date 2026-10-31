import Foundation

/// How this copy was launched. The user's own app is `.normal`; the others are
/// throwaway copies for automated checks that must leave the user's saved
/// state and library alone.
enum RunMode {
    case normal
    /// `CADENCE_SNAPSHOTS`: the debug snapshot tour.
    case snapshots
    /// `CADENCE_CHECK_DIR`: a check copy driven by `CheckHooks`, on the demo library.
    case check

    static let current: RunMode = {
        let env = ProcessInfo.processInfo.environment
        if env["CADENCE_SNAPSHOTS"] != nil { return .snapshots }
        if env["CADENCE_CHECK_DIR"] != nil { return .check }
        return .normal
    }()

    static var isThrowaway: Bool { current != .normal }

    /// Carried into a restarted copy so it runs the same way.
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("CADENCE_") }
    }
}
