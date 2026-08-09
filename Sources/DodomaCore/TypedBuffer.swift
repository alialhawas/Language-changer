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
