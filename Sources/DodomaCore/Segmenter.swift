import Foundation

/// The current and alternate language models for one detection pass.
public struct LanguageModelPair: Sendable {
    public let current: LanguageModel
    public let alternate: LanguageModel

    public init(current: LanguageModel, alternate: LanguageModel) {
        self.current = current
        self.alternate = alternate
    }
}

/// The trailing slice of the buffer that is a candidate for rewriting.
public struct CandidateRegion: Equatable, Sendable {
    /// Contiguous keys, from the first key of the first bad token through the
    /// END OF THE BUFFER — trailing whitespace included.
    ///
    /// The region has to run to the caret, because a fix deletes backwards
    /// from it. Stopping at the last letter would leave the trailing space
    /// between the caret and the text being replaced, and deleting
    /// `typedText.count` clusters would then eat one letter too many and
    /// strand the space. The space is cheap to carry: it renders to itself
    /// under either layout, so it reappears unchanged in `insertText`.
    public let keys: [CapturedKey]
    /// What is actually on screen for those keys, trailing whitespace included.
    /// Exactly the text a fix replaces.
    public let typedText: String
    /// Letters only: punctuation and spaces do not count towards length gates.
    public let letterCount: Int
    /// Tokens in the region that were finished with a space. A region with at
    /// least one is far safer to auto-fix than a word still being typed.
    public let completedTokenCount: Int

    public init(
        keys: [CapturedKey], typedText: String, letterCount: Int, completedTokenCount: Int
    ) {
        self.keys = keys
        self.typedText = typedText
        self.letterCount = letterCount
        self.completedTokenCount = completedTokenCount
    }

    /// Whitespace-separated token count of the as-typed text.
    public var tokenCount: Int {
        typedText.split(whereSeparator: \.isWhitespace).count
    }
}

/// Picks the trailing run of tokens that the user probably typed in the wrong
/// layout.
///
/// Walking backwards from the caret is what makes mid-sentence switches work:
/// `check this HSMDIH` must offer to fix only the last word. The walk stops at
/// the first token the current language recognises, because a real word is a
/// hard boundary — whatever precedes it was typed deliberately.
public enum Segmenter {
    /// A token is considered current-language text at or above this coverage.
    public static let coveredThreshold = 0.5

    /// Keys whose produced text is a space. Tab and newline never reach here:
    /// the reset policy clears the buffer on both.
    private static let whitespaceTexts: Set<String> = [" ", "\u{00A0}"]

    public static func candidate(
        in keys: [CapturedKey],
        currentLayout: KeyboardLayout,
        alternateLayout: KeyboardLayout,
        models: LanguageModelPair
    ) -> CandidateRegion? {
        let tokens = tokenRanges(in: keys)
        guard !tokens.isEmpty else { return nil }

        var firstAccepted: Int?
        for position in stride(from: tokens.count - 1, through: 0, by: -1) {
            let token = tokens[position]
            let tokenKeys = Array(keys[token.range])
            let typed = onScreenText(of: tokenKeys, layout: currentLayout)

            if models.current.dictCoverage(typed) >= coveredThreshold { break }

            let currentScore = models.current.combined(typed).combined
            let bestAlternate = CapsMode.allCases
                .map { models.alternate.combined(
                    LayoutRenderer.render(tokenKeys, layout: alternateLayout, capsMode: $0)
                ).combined }
                .max() ?? 0

            if bestAlternate > currentScore {
                firstAccepted = position
                continue
            }

            // A one-letter token is evidence of nothing. Both languages score
            // it the same, so the comparison above ties and the walk would
            // stop — stranding everything before it. That is how "how i did
            // what" typed on the wrong layout came back as "اخص ه did what":
            // the lone "i" was a wall, not a word. Step over it. It cannot
            // start a region, because `firstAccepted` only moves for a token
            // that earns it, so a genuine leading "I" or "a" is still left
            // alone; one merely sitting between two rewritten words is
            // carried along by the region that reaches the caret.
            if carriesNoSignal(typed) { continue }

            break
        }

        guard let firstAccepted else { return nil }
        let start = tokens[firstAccepted].range.lowerBound
        // Through the end of the buffer, not the end of the last token: the
        // region must reach the caret. See `CandidateRegion.keys`.
        let regionKeys = Array(keys[start...])
        let typedText = onScreenText(of: regionKeys, layout: currentLayout)

        return CandidateRegion(
            keys: regionKeys,
            typedText: typedText,
            letterCount: typedText.filter(\.isLetter).count,
            completedTokenCount: tokens[firstAccepted...].filter(\.isCompleted).count)
    }

    /// Whether a token is too short to be evidence for either language.
    ///
    /// Scoring one letter is a coin toss: the dictionaries exclude length-one
    /// tokens by design, and a single character's bigram score says nothing.
    private static func carriesNoSignal(_ typed: String) -> Bool {
        typed.filter(\.isLetter).count <= 1
    }

    /// What those keys put on screen.
    ///
    /// A real capture carries the text each event produced, which is the
    /// authority: the fix has to delete exactly that many grapheme clusters.
    /// Synthetic keys (tests, the CLI harnesses) may carry none, so they are
    /// rendered through the layout they were "typed" under instead.
    private static func onScreenText(of keys: [CapturedKey], layout: KeyboardLayout) -> String {
        let produced = keys.map(\.producedText).joined()
        guard produced.isEmpty else { return produced }
        return LayoutRenderer.render(keys, layout: layout, capsMode: .asTyped)
    }

    private struct TokenRange {
        let range: Range<Int>
        /// Followed by a whitespace key, i.e. the user finished the word.
        let isCompleted: Bool
    }

    private static func tokenRanges(in keys: [CapturedKey]) -> [TokenRange] {
        var ranges: [TokenRange] = []
        var start: Int?
        for (index, key) in keys.enumerated() {
            if whitespaceTexts.contains(key.producedText) {
                if let begin = start {
                    ranges.append(TokenRange(range: begin..<index, isCompleted: true))
                    start = nil
                }
            } else if start == nil {
                start = index
            }
        }
        if let begin = start {
            ranges.append(TokenRange(range: begin..<keys.count, isCompleted: false))
        }
        return ranges
    }
}
