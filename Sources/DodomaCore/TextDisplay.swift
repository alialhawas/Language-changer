import Foundation

/// Shortening rules for text shown in the UI.
///
/// Lives in the core, away from the views, because the arithmetic is fiddly
/// enough to be worth testing and none of it needs AppKit.
public enum TextDisplay {
    public static let ellipsis: Character = "…"

    /// Shortens `text` to `limit` characters by dropping the middle.
    ///
    /// Both ends are kept because that is what makes two similar fixes
    /// distinguishable in a menu: a common prefix is exactly the part that
    /// carries no information. The result is never longer than `limit`, the
    /// ellipsis included, and newlines are flattened to spaces so a multi-line
    /// region cannot break the layout. A `limit` below 2 leaves no room for
    /// both an ellipsis and a character, so the text is returned unshortened.
    public static func middleTruncate(_ text: String, limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard limit > 1, flattened.count > limit else { return flattened }
        let kept = limit - 1
        let tail = kept / 2
        let head = kept - tail
        return "\(flattened.prefix(head))\(ellipsis)\(flattened.suffix(tail))"
    }

    /// Arabic script blocks: the main one, the supplements, and the two
    /// presentation-forms blocks that some applications hand back.
    private static let arabicScalarRanges: [ClosedRange<UInt32>] = [
        0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF,
    ]

    /// True when the letters in `text` are mostly Arabic.
    ///
    /// Used to lay the suggestion card out right-to-left. Dominance rather than
    /// presence: a wrong-layout fix is almost entirely one script, but the
    /// trailing separator and any digits the user typed are shared between the
    /// two, and a single stray character should not flip the whole card.
    public static func isRightToLeftDominant(_ text: String) -> Bool {
        var rightToLeft = 0
        var leftToRight = 0
        for character in text where character.isLetter {
            guard let scalar = character.unicodeScalars.first else { continue }
            if arabicScalarRanges.contains(where: { $0.contains(scalar.value) }) {
                rightToLeft += 1
            } else {
                leftToRight += 1
            }
        }
        return rightToLeft > leftToRight
    }
}
