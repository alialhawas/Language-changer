import AppKit
import Carbon.HIToolbox
import DodomaCore
import Foundation

/// Thin app-side shell around `TypingSession`.
///
/// Responsibilities kept here (and only here): the serial queue, the AppKit
/// notification subscriptions, the clock, logging, and publishing snapshots.
/// All state-machine behaviour lives in `DodomaCore.TypingSession`, which is
/// unit tested directly.
final class TypingPipeline {
    let queue = DispatchQueue(label: "com.ali.dodoma.pipeline", qos: .userInitiated)

    /// Called on `queue` after every processed event.
    var onChange: ((BufferSnapshot) -> Void)?

    /// Shared, cached view of the enabled keyboard layouts. Owned here because
    /// this is where the invalidation notification is observed.
    let layoutEngine = LayoutEngine()

    private let session: TypingSession
    private var workspaceObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var enabledSourcesObserver: NSObjectProtocol?

    init() {
        session = TypingSession(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func start() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            self?.submit(.appActivated(bundleID: bundleID, at: Self.now()))
        }

        let inputSourceName = Notification.Name(
            kTISNotifySelectedKeyboardInputSourceChanged as String)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: inputSourceName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.submit(.inputSourceChanged(at: Self.now()))
        }

        let enabledSourcesName = Notification.Name(
            kTISNotifyEnabledKeyboardInputSourcesChanged as String)
        enabledSourcesObserver = DistributedNotificationCenter.default().addObserver(
            forName: enabledSourcesName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.layoutEngine.invalidate()
        }
    }

    func stop() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
            self.inputSourceObserver = nil
        }
        if let enabledSourcesObserver {
            DistributedNotificationCenter.default().removeObserver(enabledSourcesObserver)
            self.enabledSourcesObserver = nil
        }
    }

    /// Must be called on `queue`. Called by the event tap.
    func handle(_ event: TapEvent) {
        switch event {
        case .key(let key):
            process(.key(key))
        case .mouseDown:
            process(.mouseDown(at: Self.now()))
        }
    }

    /// Hops onto `queue` from wherever the caller is.
    private func submit(_ input: SessionInput) {
        queue.async { [weak self] in
            self?.process(input)
        }
    }

    /// Queue-confined.
    private func process(_ input: SessionInput) {
        dispatchPrecondition(condition: .onQueue(queue))
        let outcome = session.handle(input)

        if let reason = outcome.performedReset {
            Log.pipeline.debug("buffer reset reason=\(reason.rawValue, privacy: .public)")
        }
        onChange?(outcome.snapshot)
    }

    private static func now() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }
}
