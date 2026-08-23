import os

/// Logging never records typed text. Key codes, flags and reset reasons are
/// safe to log; `producedText` is only ever shown in the debug window.
///
/// The one exception is the `decision` category, which may include the region
/// being considered — and only when the user has switched `debugLogging` on.
enum Log {
    static let app = Logger(subsystem: "com.ali.dodoma", category: "app")
    static let tap = Logger(subsystem: "com.ali.dodoma", category: "tap")
    static let pipeline = Logger(subsystem: "com.ali.dodoma", category: "pipeline")
    static let fix = Logger(subsystem: "com.ali.dodoma", category: "fix")
    static let decision = Logger(subsystem: "com.ali.dodoma", category: "decision")
}
