import XCTest

@testable import DodomaCore

/// The injector hands each chunk to one `CGEventKeyboardSetUnicodeString`
/// call, so a chunk that ends mid-character puts a broken glyph on screen.
final class TextChunkerTests: XCTestCase {
    /// Chunks concatenate back to the input and no chunk begins or ends inside
    /// a surrogate pair.
    @discardableResult
    private func chunk(
        _ text: String, max limit: Int, file: StaticString = #filePath, line: UInt = #line
    ) -> [String] {
        let chunks = TextChunker.chunkUTF16(text, max: limit)
        XCTAssertEqual(chunks.joined(), text, "chunks must concatenate back", file: file, line: line)
        for chunk in chunks {
            let units = Array(chunk.utf16)
            XCTAssertFalse(units.isEmpty, "empty chunk", file: file, line: line)
            XCTAssertFalse(
                UTF16.isTrailSurrogate(units[0]), "chunk starts on a trail surrogate: \(chunk)",
                file: file, line: line)
            XCTAssertFalse(
                UTF16.isLeadSurrogate(units[units.count - 1]),
                "chunk ends on a lead surrogate: \(chunk)", file: file, line: line)
        }
        return chunks
    }

    func testEmptyTextProducesNoChunks() {
        XCTAssertEqual(TextChunker.chunkUTF16("", max: 20), [])
    }

    func testTextShorterThanTheLimitIsOneChunk() {
        XCTAssertEqual(chunk("اذ ودك", max: 20), ["اذ ودك"])
    }

    func testChunksStayWithinTheLimit() {
        let chunks = chunk("اذ ودك انا اسويها اليوم ", max: 20)
        XCTAssertEqual(chunks.count, 2)
        for piece in chunks {
            XCTAssertLessThanOrEqual(piece.utf16.count, 20, piece)
        }
    }

    func testSurrogatePairsAreNeverSplit() {
        // Each emoji is two UTF-16 units, so an odd limit is exactly where a
        // naive offset split would cut one in half.
        XCTAssertEqual(chunk("😀😀😀😀😀", max: 3), ["😀", "😀", "😀", "😀", "😀"])
    }

    func testMixedEmojiAndArabicKeepsEveryCharacterWhole() {
        let text = "اليوم 😀 اسويها 🇸🇦 كذا"
        let chunks = chunk(text, max: 8)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.count).reduce(0, +), text.count)
    }

    func testAGraphemeLongerThanTheLimitIsEmittedWhole() {
        // The regional-indicator pair is four UTF-16 units and one character;
        // splitting it would turn the flag into two letters.
        XCTAssertEqual(chunk("🇸🇦", max: 2), ["🇸🇦"])
    }

    func testNonPositiveLimitFallsBackToOneCharacterPerChunk() {
        XCTAssertEqual(TextChunker.chunkUTF16("abc", max: 0), ["a", "b", "c"])
        XCTAssertEqual(TextChunker.chunkUTF16("abc", max: -5), ["a", "b", "c"])
    }
}
