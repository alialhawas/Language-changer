import AppKit
import Carbon.HIToolbox
import DodomaCore
import Foundation

/// One row of the debug window's event table. Values are pre-rendered because
/// the snapshot crosses a queue boundary and the view should do no formatting work.
struct DebugEvent: Identifiable, Equatable {
    let id: UInt64
    let keycodeText: String
    let flagsText: String
    let producedText: String
    let actionText: String
    let timestamp: TimeInterval
}

/// Immutable view of the buffer, published to observers after every event.
struct BufferSnapshot: Equatable {
    var text: String
    var keyCount: Int
    var lastReset: ResetReason?
    var frontmostBundleID: String?
    /// Newest first, capped at `TypingPipeline.debugEventLimit`.
    var recentEvents: [DebugEvent]
    /// When the snapshot was taken; event ages are measured against it.
    var capturedAt: TimeInterval
}

/// Owns the serial queue, the typed buffer and the reset policy application.
///
/// Everything that mutates state runs on `queue`. AppKit notifications are
/// received on the main thread and hop onto `queue` immediately.
final class TypingPipeline {
    static let debugEventLimit = 50

    let queue = DispatchQueue(label: "com.ali.dodoma.pipeline", qos: .userInitiated)

    /// Called on `queue` after every processed event.
    var onChange: ((BufferSnapshot) -> Void)?

    private let buffer = TypedBuffer()
    private var lastKeyTimestamp: TimeInterval?
    private var frontmostBundleID: String?
    private var recentEvents: [DebugEvent] = []
    private var nextEventID: UInt64 = 0
    private var workspaceObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?

    func start() {
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            self?.queue.async { self?.applicationDidChange(to: bundleID) }
        }

        let inputSourceName = Notification.Name(
            kTISNotifySelectedKeyboardInputSourceChanged as String)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: inputSourceName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.queue.async { self?.handleExternalReset(reason: .inputSourceChanged) }
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
    }

    // MARK: - Queue-confined event handling

    /// Must be called on `queue`.
    func handle(_ event: TapEvent) {
        switch event {
        case .mouseDown:
            handleMouseDown()
        case .key(let key):
            handleKey(key)
        }
        publish()
    }

    private func handleKey(_ key: CapturedKey) {
        let action = BufferResetPolicy.action(for: key)

        switch action {
        case .append, .backspace:
            // The buffer only describes an uninterrupted burst of typing. A long
            // pause means the caret has probably moved somewhere unrelated.
            if let last = lastKeyTimestamp,
               BufferResetPolicy.isIdle(lastKeyTimestamp: last, now: key.timestamp),
               !buffer.isEmpty {
                buffer.reset(reason: .idleTimeout)
                Log.pipeline.debug("buffer reset reason=idleTimeout")
            }
            lastKeyTimestamp = key.timestamp
            if action == .append {
                buffer.append(key)
            } else {
                buffer.backspace()
            }
        case .reset(let reason):
            lastKeyTimestamp = key.timestamp
            if !buffer.isEmpty || buffer.lastResetReason != reason {
                buffer.reset(reason: reason)
                Log.pipeline.debug(
                    "buffer reset reason=\(reason.rawValue, privacy: .public) keycode=\(key.keycode, privacy: .public)"
                )
            }
        case .ignore:
            break
        }

        record(key: key, action: action)
    }

    private func handleMouseDown() {
        if !buffer.isEmpty {
            buffer.reset(reason: .mouseDown)
            Log.pipeline.debug("buffer reset reason=mouseDown")
        }
        recordMouseDown()
    }

    private func applicationDidChange(to bundleID: String?) {
        let changed = bundleID != frontmostBundleID
        frontmostBundleID = bundleID
        if changed && !buffer.isEmpty {
            buffer.reset(reason: .appChanged)
            Log.pipeline.debug("buffer reset reason=appChanged")
        }
        publish()
    }

    private func handleExternalReset(reason: ResetReason) {
        if !buffer.isEmpty {
            buffer.reset(reason: reason)
            Log.pipeline.debug("buffer reset reason=\(reason.rawValue, privacy: .public)")
        }
        publish()
    }

    // MARK: - Debug event log

    private func record(key: CapturedKey, action: BufferAction) {
        append(
            DebugEvent(
                id: takeEventID(),
                keycodeText: String(key.keycode),
                flagsText: key.flags.symbols,
                producedText: key.producedText,
                actionText: Self.describe(action),
                timestamp: key.timestamp))
    }

    private func recordMouseDown() {
        append(
            DebugEvent(
                id: takeEventID(),
                keycodeText: "mouse",
                flagsText: "",
                producedText: "",
                actionText: "reset(mouseDown)",
                timestamp: Date().timeIntervalSinceReferenceDate))
    }

    private func append(_ event: DebugEvent) {
        recentEvents.insert(event, at: 0)
        if recentEvents.count > Self.debugEventLimit {
            recentEvents.removeLast(recentEvents.count - Self.debugEventLimit)
        }
    }

    private func takeEventID() -> UInt64 {
        nextEventID &+= 1
        return nextEventID
    }

    private static func describe(_ action: BufferAction) -> String {
        switch action {
        case .append: return "append"
        case .backspace: return "backspace"
        case .ignore: return "ignore"
        case .reset(let reason): return "reset(\(reason.rawValue))"
        }
    }

    private func publish() {
        guard let onChange else { return }
        onChange(
            BufferSnapshot(
                text: buffer.currentText,
                keyCount: buffer.count,
                lastReset: buffer.lastResetReason,
                frontmostBundleID: frontmostBundleID,
                recentEvents: recentEvents,
                capturedAt: Date().timeIntervalSinceReferenceDate))
    }
}
