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
    /// Contiguous keys, first key of the first bad token through the last
    /// non-whitespace key. Trailing whitespace is excluded so the fix does not
    /// have to reinsert it.
    public let keys: [CapturedKey]
    /// What is actually on screen for those keys.
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
            guard bestAlternate > currentScore else { break }

            firstAccepted = position
        }

        guard let firstAccepted else { return nil }
        let start = tokens[firstAccepted].range.lowerBound
        let end = tokens[tokens.count - 1].range.upperBound
        let regionKeys = Array(keys[start..<end])
        let typedText = onScreenText(of: regionKeys, layout: currentLayout)

        return CandidateRegion(
            keys: regionKeys,
            typedText: typedText,
            letterCount: typedText.filter(\.isLetter).count,
            completedTokenCount: tokens[firstAccepted...].filter(\.isCompleted).count)
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
