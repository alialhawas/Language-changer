import AppKit
import DodomaCore
import SwiftUI

/// Shows the learned-word card and takes it away again.
///
/// Deliberately thinner than `SuggestionController`: nothing here decides
/// anything, nothing swallows a key, and dismissing costs the user nothing.
/// The card is a notification with one control on it, so the machinery it
/// needs is a window, a placement and a timer.
@MainActor
final class LearnedController {
    /// Longer than the suggestion card's four seconds. That card interrupts a
    /// decision the user is in the middle of; this one reports something
    /// already done, and the only reason to read it is to disagree.
    static let autoDismissDelay: TimeInterval = 6.0
    static let fadeDuration: TimeInterval = 0.12

    private let oracle: FocusOracle
    private var panel: SuggestionPanel?
    private var hosting: NSHostingView<LearnedCard>?
    private var dismissTimer: Timer?
    /// Guards against a caret lookup answering after its card was superseded.
    private var generation = 0

    init(oracle: FocusOracle) {
        self.oracle = oracle
    }

    func show(words: [String], language: Language, pid: pid_t?, onUndo: @escaping () -> Void) {
        guard !words.isEmpty else { return }
        generation += 1
        let generation = self.generation

        let rightToLeft = language == .arabic
        let card = LearnedCard(words: words, rightToLeft: rightToLeft) { [weak self] in
            onUndo()
            self?.dismiss()
        }
        let size = measure(card)
        let geometry = ScreenGeometry.current()

        oracle.locateCaret(pid: pid, geometry: geometry, rightToLeftText: rightToLeft) {
            [weak self] anchor in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.present(
                    card: card, size: size, anchor: anchor, geometry: geometry,
                    rightToLeft: rightToLeft)
            }
        }
    }

    func dismiss() {
        generation += 1
        let generation = self.generation
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let panel, panel.isVisible else { return }
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard let self, self.generation == generation else { return }
                panel.orderOut(nil)
            })
    }

    // MARK: - Placement

    private func present(
        card: LearnedCard, size: CGSize, anchor: CaretAnchor, geometry: ScreenGeometry,
        rightToLeft: Bool
    ) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // A fresh hosting view each time, so `onAppear` runs and the card
        // animates in. Reusing one and swapping `rootView` would leave the
        // second card already settled.
        let hosting = NSHostingView(rootView: card)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        self.hosting = hosting

        let frame = PanelPlacement.compute(
            anchor: anchor.point, panelSize: size,
            screen: geometry.visibleFrame(containing: anchor.point),
            rtl: rightToLeft, quality: anchor.quality)

        panel.setFrame(frame, display: false)
        panel.invalidateShadow()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoDismissDelay, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }

        Log.pipeline.debug("learned-word card shown")
    }

    private func makePanel() -> SuggestionPanel {
        let panel = SuggestionPanel()
        panel.contentView = NSView()
        return panel
    }

    private func measure(_ card: LearnedCard) -> CGSize {
        let hosting = NSHostingView(rootView: card)
        return hosting.fittingSize
    }
}
