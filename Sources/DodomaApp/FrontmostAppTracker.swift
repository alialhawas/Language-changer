import AppKit
import Foundation

/// The frontmost application's bundle identifier, readable from any thread
/// without hopping to the main one.
///
/// The injector has to re-check the frontmost app between individual
/// keystrokes: the backspace burst alone runs for a few hundred milliseconds
/// and every event in it is destructive. Asking `NSWorkspace` on the main
/// thread once per event would cost a round trip per 10 ms of sleep, so the
/// value is cached here instead, refreshed by the activation notification and
/// read under a lock.
///
/// The cache is *best effort*: the notification lands on the main run loop some
/// small time after the switch, so a check can be that much stale. It closes
/// the window from hundreds of milliseconds to a couple of events; the hard
/// containment (accessibility-verified focus) is M5.
final class FrontmostAppTracker {
    private let lock = NSLock()
    private var cached: String?
    private var observer: NSObjectProtocol?

    /// Must be created on the main thread; `NSWorkspace` is read once to seed
    /// the cache before any notification can arrive.
    init() {
        cached = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.store(app?.bundleIdentifier)
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Cheap enough to call between individual injected key events.
    var bundleID: String? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Authoritative read, straight from `NSWorkspace` on the main thread.
    ///
    /// Used at the coarse checkpoints, where the cost of a round trip is
    /// irrelevant and being a notification behind is not acceptable. Safe from
    /// the fix queue for the same reason as every other `main.sync` in the
    /// injector: nothing on the main thread ever waits on that queue.
    func currentBundleID() -> String? {
        var current: String?
        DispatchQueue.main.sync {
            current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        store(current)
        return current
    }

    private func store(_ bundleID: String?) {
        lock.lock()
        cached = bundleID
        lock.unlock()
    }
}
