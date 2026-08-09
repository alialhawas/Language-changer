import XCTest

@testable import DodomaCore

final class GuardTests: XCTestCase {
    private func vetoes(_ text: String, recentlyUndone: Set<String> = []) -> Set<GuardReason> {
        Set(TextGuards.evaluate(text, recentlyUndone: recentlyUndone).vetoes)
    }

    func testUrlPathAndEnvironmentTokensVeto() {
        XCTAssertTrue(vetoes("open https://example.com/docs now").contains(.urlOrPath))
        XCTAssertTrue(vetoes("mail ali@example.com today").contains(.urlOrPath))
        XCTAssertTrue(vetoes("cat /usr/local/bin/swift now").contains(.urlOrPath))
        XCTAssertTrue(vetoes("cd C:\\Users\\ali today").contains(.urlOrPath))
        XCTAssertTrue(vetoes("echo $HOME please now").contains(.urlOrPath))
        XCTAssertTrue(vetoes("set flag=true please").contains(.urlOrPath))
        XCTAssertTrue(vetoes("open ~/notes please").contains(.urlOrPath))
    }

    /// A sentence-final full stop is punctuation, not a path separator.
    func testTrailingPunctuationIsNotAPath() {
        XCTAssertFalse(vetoes("we are finally done.").contains(.urlOrPath))
        XCTAssertFalse(vetoes("first item, second item;").contains(.urlOrPath))
        XCTAssertFalse(vetoes("are you sure about that?").contains(.urlOrPath))
    }

    func testDigitsAdjacentToLettersVeto() {
        XCTAssertTrue(vetoes("bump to v2 today").contains(.digitsAdjacent))
        XCTAssertTrue(vetoes("the sha1 hash there").contains(.digitsAdjacent))
        XCTAssertFalse(vetoes("we shipped 42 builds today").contains(.digitsAdjacent))
    }

    func testIdentifierCaseVetoes() {
        XCTAssertTrue(vetoes("call someCamelCaseName here").contains(.identifierCase))
        XCTAssertTrue(vetoes("call snake_case_name here").contains(.identifierCase))
        XCTAssertTrue(vetoes("use ALL_CAPS_CONST here").contains(.identifierCase))
        XCTAssertFalse(vetoes("Sentence case is fine here").contains(.identifierCase))
    }

    func testConsecutivePunctuationVetoes() {
        XCTAssertTrue(vetoes("really?! are you sure").contains(.consecutivePunct))
        XCTAssertTrue(vetoes("wait... let me check").contains(.consecutivePunct))
        XCTAssertFalse(vetoes("one, two, three, four").contains(.consecutivePunct))
    }

    func testShortSingleTokenVetoes() {
        XCTAssertTrue(vetoes("sghl").contains(.shortSingleToken))
        XCTAssertTrue(vetoes("fdjkh").contains(.shortSingleToken))
        XCTAssertFalse(vetoes("hsmdih").contains(.shortSingleToken))
        XCTAssertFalse(vetoes("sghl fdjkh").contains(.shortSingleToken))
    }

    func testCurrentLanguageCoverageVetoes() {
        let english = LanguageModel.shared(.english)
        XCTAssertTrue(
            TextGuards.evaluate("the report is ready", currentModel: english)
                .vetoes.contains(.currentLangCoverage))
        XCTAssertFalse(
            TextGuards.evaluate("hkh hsmdih hgdml", currentModel: english)
                .vetoes.contains(.currentLangCoverage))
    }

    func testMixedScriptTokenVetoes() {
        XCTAssertTrue(vetoes("helloمرحبا there").contains(.mixedScriptToken))
        XCTAssertFalse(vetoes("hello مرحبا there").contains(.mixedScriptToken))
    }

    func testRecentlyUndoneVetoes() {
        XCTAssertTrue(
            vetoes("hkh hsmdih hgdml", recentlyUndone: ["HKH HSMDIH HGDML"])
                .contains(.recentlyUndone))
        XCTAssertFalse(
            vetoes("hkh hsmdih hgdml", recentlyUndone: ["something else"])
                .contains(.recentlyUndone))
    }

    func testCleanProseFiresNothing() {
        XCTAssertEqual(vetoes("hkh hsmdih hgdml"), [])
    }

    // MARK: - Decision rule

    func testOneVetoBlocksAutoAndTwoBlockSuggest() {
        let none = GuardResult(vetoes: [])
        XCTAssertFalse(none.blocksAuto)
        XCTAssertFalse(none.blocksSuggest)

        let one = GuardResult(vetoes: [.shortSingleToken])
        XCTAssertTrue(one.blocksAuto)
        XCTAssertFalse(one.blocksSuggest)

        let two = GuardResult(vetoes: [.shortSingleToken, .digitsAdjacent])
        XCTAssertTrue(two.blocksAuto)
        XCTAssertTrue(two.blocksSuggest)
    }

    func testVersionStringTripsEnoughGuardsToBlockSuggestions() {
        let result = TextGuards.evaluate("v2.1.3")
        XCTAssertTrue(result.blocksSuggest, "fired: \(result.summary)")
    }
}
