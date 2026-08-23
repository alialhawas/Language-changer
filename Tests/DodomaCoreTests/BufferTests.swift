import XCTest
@testable import DodomaCore

final class BufferTests: XCTestCase {
    private func key(_ text: String, keycode: UInt16 = 0, at time: TimeInterval = 0) -> CapturedKey {
        CapturedKey(keycode: keycode, producedText: text, timestamp: time)
    }

    func testStartsEmpty() {
        let buffer = TypedBuffer()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.currentText, "")
        XCTAssertNil(buffer.lastResetReason)
        XCTAssertNil(buffer.lastKey)
    }

    func testAppendKeepsOrder() {
        let buffer = TypedBuffer()
        buffer.append(key("h", keycode: 4))
        buffer.append(key("i", keycode: 34))

        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.keys.map(\.keycode), [4, 34])
        XCTAssertEqual(buffer.currentText, "hi")
        XCTAssertEqual(buffer.lastKey?.producedText, "i")
    }

    func testCurrentTextConcatenatesMultiCodepointProducedText() {
        let buffer = TypedBuffer()
        buffer.append(key("لا"))
        buffer.append(key("م"))

        XCTAssertEqual(buffer.currentText, "لام")
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.currentText.unicodeScalars.count, 3)
    }

    func testCurrentTextPreservesEmptyAndMultiCharEntries() {
        let buffer = TypedBuffer()
        buffer.append(key("a"))
        buffer.append(key(""))
        buffer.append(key("bc"))

        XCTAssertEqual(buffer.currentText, "abc")
        XCTAssertEqual(buffer.count, 3)
    }

    func testBackspaceRemovesLastKey() {
        let buffer = TypedBuffer()
        buffer.append(key("a"))
        buffer.append(key("b"))
        buffer.backspace()

        XCTAssertEqual(buffer.currentText, "a")
        XCTAssertEqual(buffer.count, 1)
    }

    func testBackspacePastEmptyIsNoOp() {
        let buffer = TypedBuffer()
        buffer.backspace()
        buffer.backspace()

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.currentText, "")

        buffer.append(key("z"))
        XCTAssertEqual(buffer.currentText, "z")
    }

    func testOverflowDropsFromTheHeadAtCapacity() {
        let buffer = TypedBuffer()
        for index in 0..<(TypedBuffer.capacity + 5) {
            buffer.append(CapturedKey(keycode: UInt16(index % 100), producedText: "x"))
        }

        XCTAssertEqual(buffer.count, TypedBuffer.capacity)
        XCTAssertEqual(buffer.currentText.count, TypedBuffer.capacity)
        XCTAssertEqual(buffer.keys.first?.keycode, 5)
    }

    func testCapacityIsTwoHundred() {
        XCTAssertEqual(TypedBuffer.capacity, 200)
    }

    func testResetClearsAndRecordsReason() {
        let buffer = TypedBuffer()
        buffer.append(key("a"))
        buffer.append(key("b"))
        buffer.reset(reason: .enterKey)

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.currentText, "")
        XCTAssertEqual(buffer.keys, [])
        XCTAssertEqual(buffer.lastResetReason, .enterKey)

        buffer.reset(reason: .appChanged)
        XCTAssertEqual(buffer.lastResetReason, .appChanged)
    }

    func testKeyFlagsSymbols() {
        XCTAssertEqual(KeyFlags([]).symbols, "")
        XCTAssertEqual(KeyFlags([.command, .shift]).symbols, "⇧⌘")
        XCTAssertEqual(KeyFlags([.capsLock, .control, .option]).symbols, "⇪⌃⌥")
    }
}
