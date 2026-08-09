import AppKit
import DodomaCore
import SwiftUI

/// The floating card that offers a fix.
///
/// Everything about the window configuration is there to keep it from taking
/// focus. Dodoma is an `LSUIElement` app, the panel is non-activating, it
/// becomes key only if something inside it asks to be — nothing does — and
/// `makeKey` is never called on it. The user must be able to keep typing into
/// the application underneath while the card is on screen, because that is
/// precisely how a suggestion is declined.
///
/// It also has to survive the two places the plain `.floating` level does not:
/// a full-screen space, and a space switch. Hence the status-bar level and the
/// collection behaviour.
final class SuggestionPanel: NSPanel {
    /// Never. Not even if AppKit thinks it would be convenient.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 72),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)

        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        // The card draws its own rounded background, so the window itself is
        // transparent. Mouse events are *not* ignored: a click has to be
        // swallowed by this window rather than reaching the application below,
        // where it would move the caret the fix is measured from.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        alphaValue = 0
        animationBehavior = .none
    }
}

/// The card itself.
///
/// The proposed text is the only thing shown at full size: it is what the user
/// has to read to decide. The text being replaced is shown struck through and
/// small, because recognising it is what makes the proposal trustworthy, and
/// the hint line names the two keys.
struct SuggestionCard: View {
    /// Widest the card may get before the proposed text wraps.
    static let maximumWidth: CGFloat = 360

    let insertText: String
    let replacedText: String
    let rightToLeft: Bool
    /// Set while the tap watchdog has the key swallowing switched off, when
    /// clicking the card is the only way to accept it.
    let clickOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(insertText)
                .font(.system(size: 16, weight: .medium))
                .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
                .lineLimit(3)

            if !replacedText.isEmpty {
                Text(replacedText)
                    .font(.system(size: 11))
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: Self.maximumWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5))
        )
    }

    private var hint: String {
        clickOnly ? "click to replace" : "⇥ replace   esc dismiss"
    }
}
