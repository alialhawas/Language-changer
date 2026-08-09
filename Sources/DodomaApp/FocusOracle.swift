import ApplicationServices
import DodomaCore
import Foundation

/// What the accessibility API had to say about the focused element.
struct FocusInspection: Equatable {
    var security: SecureFieldState
    /// The text immediately before the caret, when it was asked for and could
    /// be read. Nil otherwise — including whenever `security` is not
    /// `.notSecure`, because a password field's contents are never read.
    var caretText: String?

    /// The answer when nothing could be asked: no pid, no grant, or the
    /// deadline expired. The two fields fail in opposite directions on purpose
    /// — see `SafetyGate`.
    static let unavailable = FocusInspection(security: .unknown, caretText: nil)
}

/// Reads the focused UI element over the accessibility API.
///
/// Every call in here can block. `AXUIElementCopyAttributeValue` is a
/// synchronous IPC round trip into the target application, and a target that is
/// busy — an Electron app rebuilding its accessibility tree, a terminal running
/// something — answers in its own time. So none of it may ever run on the
/// pipeline queue, which has to stay responsive to the event tap.
///
/// Three separate limits keep it bounded:
///
/// 1. a dedicated serial queue, so a stall costs only the next AX call;
/// 2. `AXUIElementSetMessagingTimeout` at 50 ms, per element, so a single
///    unanswered attribute read cannot hold the queue;
/// 3. a 250 ms deadline over the whole inspection, enforced by the caller's
///    completion being fired by whichever finishes first.
///
/// The verdict is cached per focused element, so typing a sentence into one
/// field costs one round trip rather than one per evaluation.
final class FocusOracle {
    /// Per attribute read. Three reads worst case, so well inside the deadline.
    static let messagingTimeout: Float = 0.05
    /// For the whole inspection, from the caller's point of view.
    static let deadline: TimeInterval = 0.25

    private let queue = DispatchQueue(label: "com.ali.dodoma.ax", qos: .userInitiated)
    private let timeoutQueue = DispatchQueue(label: "com.ali.dodoma.ax.deadline", qos: .utility)

    /// Queue-confined cache of the last security verdict.
    private var cachedElement: AXUIElement?
    private var cachedSecurity: SecureFieldState = .unknown

    // MARK: - Public API

    /// Inspects the focused element of `pid` and answers on the oracle's own
    /// queue (or on `timeoutQueue` if the deadline wins). Called exactly once.
    ///
    /// - Parameter caretTextLength: number of UTF-16 units to read back from
    ///   the caret, or nil to skip the text read entirely. Only the auto-apply
    ///   path asks for text.
    func inspect(
        pid: pid_t?,
        caretTextLength: Int?,
        completion: @escaping (FocusInspection) -> Void
    ) {
        let once = Once(completion)
        guard let pid else {
            once.fire(.unavailable)
            return
        }

        let expiry = DispatchWorkItem { [once] in
            Log.pipeline.debug("accessibility inspection hit its deadline")
            once.fire(.unavailable)
        }
        timeoutQueue.asyncAfter(deadline: .now() + Self.deadline, execute: expiry)

        queue.async { [weak self] in
            let result = self?.perform(pid: pid, caretTextLength: caretTextLength) ?? .unavailable
            expiry.cancel()
            once.fire(result)
        }
    }

    /// Finds the caret of `pid` for the suggestion panel, under the same three
    /// limits as `inspect`: this queue, the per-element messaging timeout, and
    /// one deadline over the whole lookup. Answers exactly once.
    ///
    /// The deadline's answer is not a failure but the pointer, because the
    /// panel has to appear somewhere and the pointer is where the user is
    /// looking. `CaretLocator` documents the rest of the ladder.
    ///
    /// - Parameter geometry: taken on the main thread by the caller. Nothing in
    ///   here may touch `NSScreen`.
    func locateCaret(
        pid: pid_t?,
        geometry: ScreenGeometry,
        rightToLeftText: Bool,
        completion: @escaping (CaretAnchor) -> Void
    ) {
        let once = Once(completion)
        guard let pid else {
            once.fire(geometry.pointerAnchor)
            return
        }

        let expiry = DispatchWorkItem { [once] in
            Log.pipeline.debug("caret lookup hit its deadline")
            once.fire(geometry.pointerAnchor)
        }
        timeoutQueue.asyncAfter(deadline: .now() + Self.deadline, execute: expiry)

        queue.async {
            let anchor = CaretLocator.locate(
                pid: pid, geometry: geometry, rightToLeftText: rightToLeftText)
            expiry.cancel()
            once.fire(anchor)
        }
    }

    /// Forgets the cached verdict. Called when the frontmost app changes: the
    /// focused element belongs to the app that had focus.
    func invalidate() {
        queue.async { [weak self] in
            self?.cachedElement = nil
            self?.cachedSecurity = .unknown
        }
    }

    // MARK: - The reads

    private func perform(pid: pid_t, caretTextLength: Int?) -> FocusInspection {
        dispatchPrecondition(condition: .onQueue(queue))

        let application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)

        guard let focused = element(application, kAXFocusedUIElementAttribute) else {
            return .unavailable
        }
        _ = AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        let security = cachedSecurity(of: focused)
        guard security == .notSecure, let caretTextLength else {
            return FocusInspection(security: security, caretText: nil)
        }
        return FocusInspection(
            security: security, caretText: caretText(of: focused, length: caretTextLength))
    }

    /// A password field answers with the secure subrole. A few older Carbon and
    /// cross-platform toolkits report it as a role instead, so both are treated
    /// as secure. An element that answers neither attribute is not a text field
    /// we can reason about, so it stays `.unknown`.
    private func securityOf(_ element: AXUIElement) -> SecureFieldState {
        let subrole = string(element, kAXSubroleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) { return .secure }
        let role = string(element, kAXRoleAttribute)
        if role == "AXSecureTextField" { return .secure }
        if subrole == nil, role == nil { return .unknown }
        return .notSecure
    }

    private func cachedSecurity(of focused: AXUIElement) -> SecureFieldState {
        if let cachedElement, CFEqual(cachedElement, focused), cachedSecurity != .unknown {
            return cachedSecurity
        }
        let security = securityOf(focused)
        cachedElement = focused
        cachedSecurity = security
        return security
    }

    /// The `length` UTF-16 units immediately before the caret.
    ///
    /// The caret is read first, from the selected-text range, and everything is
    /// measured back from it. Reading the element's whole value and taking its
    /// suffix would be wrong whenever the caret is not at the end of the field,
    /// which is exactly the desynchronisation this check exists to catch — so
    /// a field that will not report a caret gets nil, and the caller downgrades.
    private func caretText(of element: AXUIElement, length: Int) -> String? {
        guard length > 0, let selection = range(element, kAXSelectedTextRangeAttribute) else {
            return nil
        }
        // A live selection means the delete burst would eat the selection
        // first, so the count no longer describes what would be removed.
        guard selection.length == 0 else { return nil }

        let caret = selection.location
        guard caret >= 0 else { return nil }
        let wanted = min(caret, length)
        var wantedRange = CFRange(location: caret - wanted, length: wanted)

        if let argument = AXValueCreate(.cfRange, &wantedRange),
           let text = string(element, kAXStringForRangeParameterizedAttribute, parameter: argument)
        {
            return text
        }

        // Fields that expose a value but no parameterized string attribute —
        // plain AXTextField mostly — can still be cut at the caret by hand.
        guard let value = string(element, kAXValueAttribute) else { return nil }
        let units = Array(value.utf16)
        guard caret <= units.count else { return nil }
        return String(decoding: units[(caret - wanted)..<caret], as: UTF16.self)
    }

    // MARK: - Attribute helpers

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func string(_ element: AXUIElement, _ attribute: String, parameter: AXValue) -> String?
    {
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, attribute as CFString, parameter, &value) == .success
        else { return nil }
        return value as? String
    }

    private func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range
    }
}

/// Fires its handler exactly once, whoever gets there first.
private final class Once<Value> {
    private let lock = NSLock()
    private var handler: ((Value) -> Void)?

    init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    func fire(_ value: Value) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        handler?(value)
    }
}
