import XCTest

@testable import DodomaCore

/// The counter that both deferred safety checks compare against: the
/// accessibility gate before it acts on an answer, and the injector before it
/// posts the first backspace against a caret verified up to 450 ms earlier.
final class InputSerialTests: XCTestCase {
    func testStartsAtZeroAndCountsUp() {
        let serial = InputSerial()
        XCTAssertEqual(serial.current, 0)
        XCTAssertEqual(serial.bump(), 1)
        XCTAssertEqual(serial.bump(), 2)
        XCTAssertEqual(serial.current, 2)
    }

    func testHasMovedIsFalseUntilSomethingArrives() {
        let serial = InputSerial()
        let taken = serial.current
        XCTAssertFalse(serial.hasMoved(since: taken))
        serial.bump()
        XCTAssertTrue(serial.hasMoved(since: taken))
    }

    /// A serial taken after some input still only cares about what happened
    /// after *it* was taken.
    func testHasMovedIsRelativeToWhenTheSerialWasTaken() {
        let serial = InputSerial()
        serial.bump()
        serial.bump()
        let taken = serial.current
        XCTAssertFalse(serial.hasMoved(since: taken))
        serial.bump()
        XCTAssertTrue(serial.hasMoved(since: taken))
        XCTAssertFalse(serial.hasMoved(since: serial.current))
    }

    /// The whole point of the type: bumps happen on the pipeline queue, reads
    /// happen on the injector's queue and on the accessibility queue.
    func testBumpsFromManyThreadsAreAllCounted() {
        let serial = InputSerial()
        let bumps = 2_000
        DispatchQueue.concurrentPerform(iterations: bumps) { _ in
            serial.bump()
        }
        XCTAssertEqual(serial.current, UInt64(bumps))
    }

    /// Reads taken from another thread while bumps are landing must never see
    /// the count go backwards or exceed what was actually recorded.
    func testConcurrentReadsNeverSeeATornOrGoingBackwardsValue() {
        let serial = InputSerial()
        let bumps = 1_000
        let reader = DispatchQueue(label: "reader")
        let finished = expectation(description: "reads finished")
        var observed: [UInt64] = []

        reader.async {
            for _ in 0..<bumps { observed.append(serial.current) }
            finished.fulfill()
        }
        DispatchQueue.concurrentPerform(iterations: bumps) { _ in serial.bump() }
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(serial.current, UInt64(bumps))
        XCTAssertEqual(observed, observed.sorted(), "a read saw the count go backwards")
        XCTAssertLessThanOrEqual(observed.max() ?? 0, UInt64(bumps))
    }
}
