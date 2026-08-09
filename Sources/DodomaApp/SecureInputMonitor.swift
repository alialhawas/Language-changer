import Carbon.HIToolbox
import Foundation

/// Watches the system-wide secure event input flag.
///
/// Any process can turn secure input on (`EnableSecureEventInput`), and while
/// it is on the window server stops delivering keystrokes to event taps at all.
/// Loginwindow, the password fields in Safari and Chrome, `sudo` in a terminal
/// and every password manager use it. It is therefore both the strongest and
/// the cheapest of the three password defences: no accessibility grant, no AX
/// round trip, one function call.
///
/// There is no notification for it, so it is polled. One second is fast enough:
/// the window between the flag going up and the next evaluation is at least the
/// one-second trigger delay, and the flag is re-read synchronously at
/// evaluation time as well.
final class SecureInputMonitor {
    static let pollInterval: TimeInterval = 1.0

    private let lock = NSLock()
    private var enabled = false
    private var timer: Timer?

    /// Called on the main thread whenever the flag changes.
    var onChange: ((Bool) -> Void)?

    /// Readable from any thread; the pipeline reads it on its own queue.
    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    /// Main thread only.
    func start() {
        assert(Thread.isMainThread)
        refresh()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Main thread only.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads the flag now. Called on the poll and on every app activation,
    /// because activating a password manager is the common way for it to come
    /// on between two polls. Main thread only.
    @discardableResult
    func refresh() -> Bool {
        assert(Thread.isMainThread)
        let now = IsSecureEventInputEnabled()

        lock.lock()
        let changed = now != enabled
        enabled = now
        lock.unlock()

        if changed {
            Log.pipeline.info("secure event input \(now ? "enabled" : "disabled", privacy: .public)")
            onChange?(now)
        }
        return now
    }
}
