import Foundation

/// Splits text into pieces small enough to hand to one synthetic key event.
///
/// `CGEventKeyboardSetUnicodeString` takes a UTF-16 buffer and both AppKit and
/// several third-party text views mishandle very long ones, so the injector
/// sends the replacement in chunks. Splitting naively at a UTF-16 offset would
/// cut a surrogate pair — or a combining sequence — in half and put a lone
/// half-character on screen, so the split always happens on a grapheme
/// boundary.
public enum TextChunker {
    /// Chunks of at most `max` UTF-16 code units, in order, concatenating back
    /// to the input exactly.
    ///
    /// A single grapheme cluster longer than `max` (a flag emoji against a
    /// two-unit limit, say) is emitted alone and over the limit: breaking it
    /// would be worse than a long chunk. `max` below 1 is treated as 1.
    public static func chunkUTF16(_ text: String, max limit: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        let limit = Swift.max(1, limit)

        var chunks: [String] = []
        var current = ""
        var currentUnits = 0

        for character in text {
            let units = character.utf16.count
            if currentUnits > 0 && currentUnits + units > limit {
                chunks.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
