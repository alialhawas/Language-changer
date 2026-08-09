import Foundation

/// Why the typed buffer was cleared. Recorded so the debug window (and later the
/// fix engine) can explain why a candidate word disappeared.
public enum ResetReason: String, Equatable, Hashable, Sendable, CaseIterable {
    case enterKey
    case tabKey
    case escapeKey
    case arrowNav
    case modifierChord
    case mouseDown
    case appChanged
    case focusChanged
    case inputSourceChanged
    case idleTimeout
    case manual
    case secureInput
    case overflow

    /// Whether clearing the buffer must also throw away the debug event log.
    ///
    /// The log keeps the produced text of the last fifty keystrokes and
    /// deliberately survives an ordinary reset — watching what happened either
    /// side of a reset is most of what the debug window is for.
    ///
    /// `secureInput` is the one reason that says those keystrokes were never
    /// ours to keep. It is set when the focused field turns out to be a
    /// password field, and by then the characters are already in the log; the
    /// clear has to be retroactive or the drop protects nothing. Keyed off the
    /// reason rather than left to each caller so that no future reset path can
    /// forget it.
    public var purgesHistory: Bool {
        switch self {
        case .secureInput:
            return true
        case .enterKey, .tabKey, .escapeKey, .arrowNav, .modifierChord, .mouseDown, .appChanged,
             .focusChanged, .inputSourceChanged, .idleTimeout, .manual, .overflow:
            return false
        }
    }
}

/// Ordered record of the keys the user has typed since the last reset.
///
/// Plain class, not thread safe: it is owned by a single serial queue (the
/// typing pipeline). It emits no notifications; the owner observes it directly.
public final class TypedBuffer {
    /// Maximum retained keys. Appending past the cap drops from the head.
    public static let capacity = 200

    private var storage: [CapturedKey] = []

    public private(set) var lastResetReason: ResetReason?

    public init() {
        storage.reserveCapacity(Self.capacity)
    }

    public var keys: [CapturedKey] { storage }

    public var count: Int { storage.count }

    public var isEmpty: Bool { storage.isEmpty }

    /// Concatenation of every retained key's produced text.
    public var currentText: String {
        storage.map(\.producedText).joined()
    }

    public var lastKey: CapturedKey? { storage.last }

    public func append(_ key: CapturedKey) {
        storage.append(key)
        if storage.count > Self.capacity {
            storage.removeFirst(storage.count - Self.capacity)
        }
    }

    /// Removes the most recent key. No-op when the buffer is already empty.
    public func backspace() {
        guard !storage.isEmpty else { return }
        storage.removeLast()
    }

    public func reset(reason: ResetReason) {
        storage.removeAll(keepingCapacity: true)
        lastResetReason = reason
    }
}
