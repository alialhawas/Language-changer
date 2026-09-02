import ApplicationServices
import DodomaCore
import Foundation

/// What the accessibility API had to say about the focused element.
struct FocusInspection: Equatable {
    var security: SecureFieldState
    /// The text immediately before the caret, and — just as importantly — why
    /// it is missing when it is. `.unavailable` whenever the read was not asked
    /// for at all, and whenever `security` is not `.notSecure`, because a
    /// password field's contents are never read.
    var caretRead: CaretRead

    /// The answer when nothing could be asked: no pid, no grant, or the
    /// deadline expired. The two fields fail in opposite directions on purpose
    /// — see `SafetyGate`.
    static let unavailable = FocusInspection(security: .unknown, caretRead: .unavailable)
}

/// The half of `FocusOracle` the typing pipeline uses.
///
/// A protocol so the pipeline's gate can be driven from tests without an
/// accessibility grant, a focused element or a real application to ask. The
/// panel's caret lookup deliberately stays off it: that is the concrete
/// oracle's business and nothing decides anything destructive on it.
protocol FocusInspecting: AnyObject {
    func inspect(pid: pid_t?, caretTextLength: Int?, completion: @escaping (FocusInspection) -> Void)
    func invalidate()
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

        queue.async { [weak self] in
            let anchor =
                self?.performLocate(
                    pid: pid, geometry: geometry, rightToLeftText: rightToLeftText)
                ?? geometry.pointerAnchor
            expiry.cancel()
            once.fire(anchor)
        }
    }

    /// An instance method for the same reason `perform` is one: the queue is
    /// the oracle's, so work that outlives the oracle must not run on it.
    private func performLocate(pid: pid_t, geometry: ScreenGeometry, rightToLeftText: Bool)
        -> CaretAnchor
    {
        dispatchPrecondition(condition: .onQueue(queue))
        return CaretLocator.locate(
            pid: pid, geometry: geometry, rightToLeftText: rightToLeftText)
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
            return Self.withoutFocusedElement(trusted: AXIsProcessTrusted())
        }
        _ = AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        let security = cachedSecurity(of: focused)
        guard security == .notSecure, let caretTextLength else {
            return FocusInspection(security: security, caretRead: .unavailable)
        }
        return FocusInspection(
            security: security, caretRead: caretRead(of: focused, length: caretTextLength))
    }

    /// What an application that reports no focused element at all means.
    ///
    /// It has two very different causes and they were collapsed into one.
    /// Without the accessibility grant the nil says only that we are blind: the
    /// app may well have text and a caret, and nothing may be concluded. With
    /// the grant in hand, the same nil is the application telling us it has no
    /// accessibility text surface — Ghostty and other terminals that draw their
    /// own cells answer exactly this, no focused element and no windows.
    ///
    /// That second case is the structural silence `caretRead` already names
    /// `.unreadable` one level down for an element that exposes no value. The
    /// distinction matters: `.unreadable` lets a rewrite the user *asked* for
    /// by pressing the accept key go ahead, while `.unavailable` refuses it.
    /// Collapsing them meant Harf could do nothing in such an app — not an
    /// automatic fix, which is right, but not an accepted suggestion either,
    /// which left the user with a card that did nothing when pressed.
    ///
    /// Automatic rewrites stay blocked either way: `.unreadable` only proceeds
    /// under `.bestEffort`, and the automatic path asks for `.required`.
    ///
    /// Split out as a pure function so both branches are testable; everything
    /// around it needs a live accessibility grant and a focused application.
    static func withoutFocusedElement(trusted: Bool) -> FocusInspection {
        guard trusted else { return .unavailable }
        return FocusInspection(security: .unknown, caretRead: .unreadable)
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

    /// The `length` UTF-16 units immediately before the caret, or why not.
    ///
    /// The caret is read first, from the selected-text range, and everything is
    /// measured back from it. Reading the element's whole value and taking its
    /// suffix would be wrong whenever the caret is not at the end of the field,
    /// which is exactly the desynchronisation this check exists to catch.
    ///
    /// What the caller does with each answer is `CaretVerification`'s business.
    /// This function's only job is to keep the reasons apart, and in particular
    /// to keep `.unreadable` — "this element has no text to give anybody" —
    /// away from `.unavailable`, which means "it has text and would not hand it
    /// over". Only the first is a safe thing for an explicitly requested
    /// rewrite to proceed on.
    private func caretRead(of element: AXUIElement, length: Int) -> CaretRead {
        guard length > 0 else { return .unavailable }

        guard let selection = range(element, kAXSelectedTextRangeAttribute) else {
            // No caret. An element that also has no value is not a text field
            // we can reason about at all — a terminal surface, a canvas — and
            // that is the structural silence `.unreadable` names. One that does
            // have a value but will not say where the caret is cannot be
            // measured back from, which is a refusal, not a silence.
            return string(element, kAXValueAttribute) == nil ? .unreadable : .unavailable
        }
        // A live selection means the delete burst would eat the selection
        // first, so the count no longer describes what would be removed.
        guard selection.length == 0 else { return .selectionPresent }

        let caret = selection.location
        guard caret >= 0 else { return .unavailable }
        let wanted = min(caret, length)
        var wantedRange = CFRange(location: caret - wanted, length: wanted)

        if let argument = AXValueCreate(.cfRange, &wantedRange),
           let text = string(element, kAXStringForRangeParameterizedAttribute, parameter: argument)
        {
            return .value(text)
        }

        // Fields that expose a value but no parameterized string attribute —
        // plain AXTextField mostly — can still be cut at the caret by hand.
        // Anything past here answered a caret and then would not produce the
        // text behind it, which is the noisy kind of failure.
        guard let value = string(element, kAXValueAttribute) else { return .unavailable }
        let units = Array(value.utf16)
        guard caret <= units.count else { return .unavailable }
        return .value(String(decoding: units[(caret - wanted)..<caret], as: UTF16.self))
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

extension FocusOracle: FocusInspecting {}

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
