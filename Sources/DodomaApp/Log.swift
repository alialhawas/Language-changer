import os

/// Logging never records typed text. Key codes, flags and reset reasons are
/// safe to log; `producedText` is only ever shown in the debug window.
enum Log {
    static let app = Logger(subsystem: "com.ali.dodoma", category: "app")
    static let tap = Logger(subsystem: "com.ali.dodoma", category: "tap")
    static let pipeline = Logger(subsystem: "com.ali.dodoma", category: "pipeline")
}
