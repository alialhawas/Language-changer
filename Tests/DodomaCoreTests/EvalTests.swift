import XCTest

@testable import DodomaCore

final class EvalTests: XCTestCase {
    private func loadCorpus() throws -> [EvalRow] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "corpus", withExtension: "tsv", subdirectory: "Fixtures"),
            "corpus.tsv is missing from the test bundle")
        return try EvalHarness.parse(try String(contentsOf: url, encoding: .utf8))
    }

    func testCorpusIsWellFormedAndCoversEveryClass() throws {
        let rows = try loadCorpus()
        XCTAssertGreaterThanOrEqual(rows.count, 50)
        for label in EvalLabel.allCases {
            XCTAssertGreaterThan(
                rows.filter { $0.expected == label }.count, 0, "no \(label.rawValue) rows")
        }
    }

    func testCorpusRunsClean() throws {
        let fixture = try DetectorFixture.make()
        let report = EvalHarness.run(
            rows: try loadCorpus(), detector: fixture.detector,
            keyboardType: fixture.keyboardType)

        XCTAssertTrue(
            report.falsePositives.isEmpty,
            "ignore rows were auto-applied:\n"
                + report.falsePositives.map { "  \($0.row.text) → \($0.detail)" }
                    .joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(
            report.autoAccuracy, 0.9,
            "auto-labelled rows below 90%:\n" + report.render())
        XCTAssertEqual(
            report.failures.count, 0, "corpus regressions:\n" + report.render())
    }

    // MARK: - Parsing

    func testParseSkipsCommentsAndBlankLines() throws {
        let rows = try EvalHarness.parse(
            """
            # a comment

            hello\tignore
            HGDML\tauto_ar
            """)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].expected, .ignore)
        XCTAssertEqual(rows[0].lineNumber, 3)
        XCTAssertEqual(rows[1].expected, .autoArabic)
    }

    func testParseRejectsUnknownLabels() {
        XCTAssertThrowsError(try EvalHarness.parse("hello\tmaybe"))
    }

    func testParseRejectsMissingTab() {
        XCTAssertThrowsError(try EvalHarness.parse("hello ignore"))
    }

    func testReportRendersAConfusionMatrix() throws {
        let fixture = try DetectorFixture.make()
        let report = EvalHarness.run(
            rows: try loadCorpus(), detector: fixture.detector,
            keyboardType: fixture.keyboardType)
        let text = report.render()
        XCTAssertTrue(text.contains("confusion"))
        for label in EvalLabel.allCases {
            XCTAssertTrue(text.contains(label.rawValue), label.rawValue)
        }
        XCTAssertTrue(text.contains("false-positive canary: clean"))
    }
}
