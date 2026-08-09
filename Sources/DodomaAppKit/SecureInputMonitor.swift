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
/// The two questions the typing pipeline asks about secure input. A protocol so
/// a test can answer them without the machine's real flag deciding whether the
/// test passes.
protocol SecureInputReading: AnyObject {
    var isEnabled: Bool { get }
    func readNow() -> Bool
}

final class SecureInputMonitor: SecureInputReading {
    static let pollInterval: TimeInterval = 1.0

    private let lock = NSLock()
    private var enabled = false
    private var timer: Timer?

    /// Called on the main thread whenever the flag changes.
    var onChange: ((Bool) -> Void)?

    /// The last polled value. Up to `pollInterval` stale, which is fine for the
    /// menu and for suppressing capture, and not fine for the evaluation —
    /// see `readNow()`. Readable from any thread.
    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    /// Asks the system, now, bypassing the poll's cache.
    ///
    /// The evaluation needs this rather than `isEnabled`: the poll runs once a
    /// second and the flag can have gone up at any point inside that second,
    /// which is exactly the window in which a user finishes typing a password
    /// and stops. It is one function call, on the pipeline queue, and it
    /// deliberately does not touch the cached value — ownership of that, and of
    /// the change notification the menu depends on, stays with `refresh()` on
    /// the main thread.
    func readNow() -> Bool {
        IsSecureEventInputEnabled()
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
        let now = readNow()

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
