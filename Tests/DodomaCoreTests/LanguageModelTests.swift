import XCTest

@testable import DodomaCore

final class LanguageModelTests: XCTestCase {
    private let english = LanguageModel.shared(.english)
    private let arabic = LanguageModel.shared(.arabic)

    func testResourcesLoad() {
        XCTAssertNoThrow(try english.preload())
        XCTAssertNoThrow(try arabic.preload())
    }

    func testEnglishSentenceScoresEnglishHighAndArabicLow() {
        let text = "please send me the report before the meeting tomorrow"
        let en = english.combined(text)
        let ar = arabic.combined(text)

        XCTAssertGreaterThan(en.bigram, 0.7)
        XCTAssertGreaterThan(en.dictCoverage, 0.9)
        XCTAssertGreaterThan(en.combined, 0.8)
        // No Arabic letter appears, so the Arabic model has nothing to score.
        XCTAssertEqual(ar.combined, 0, accuracy: 0.0001)
    }

    func testArabicSentenceScoresArabicHighAndEnglishLow() {
        let text = "مرحبا كيف حالك اليوم"
        let ar = arabic.combined(text)
        let en = english.combined(text)

        XCTAssertGreaterThan(ar.bigram, 0.7)
        XCTAssertGreaterThan(ar.dictCoverage, 0.9)
        XCTAssertGreaterThan(ar.combined, 0.8)
        XCTAssertEqual(en.combined, 0, accuracy: 0.0001)
    }

    /// The canonical sample, from both sides.
    func testCanonicalSampleSeparatesDecisively() {
        let arabicText = "اذ ودك انا اسويها اليوم"
        let latinSource = "HC MV; HKH HSMDIH HGDML"

        XCTAssertGreaterThan(arabic.combined(arabicText).combined, 0.6)
        XCTAssertLessThan(english.combined(latinSource).combined, 0.3)
    }

    func testWrongLayoutLatinScoresFarBelowRealEnglish() {
        let gibberish = english.combined("lnpfh ;dt phg; hgdml").combined
        let real = english.combined("hello how are you doing today").combined
        XCTAssertLessThan(gibberish, 0.3)
        XCTAssertGreaterThan(real - gibberish, 0.4)
    }

    // MARK: - Normalisation

    func testArabicNormalisationFoldsTaMarbutaAndHamza() {
        XCTAssertEqual(LanguageModel.normalize("مدرسة", for: .arabic), "مدرسه")
        XCTAssertEqual(LanguageModel.normalize("أحمد", for: .arabic), "احمد")
        XCTAssertEqual(LanguageModel.normalize("إلى", for: .arabic), "الي")
        XCTAssertEqual(LanguageModel.normalize("آسف", for: .arabic), "اسف")
    }

    func testArabicNormalisationStripsHarakatAndTatweel() {
        XCTAssertEqual(LanguageModel.normalize("مَدْرَسَة", for: .arabic), "مدرسه")
        XCTAssertEqual(LanguageModel.normalize("مـــدرسة", for: .arabic), "مدرسه")
    }

    func testNormalisedFormsAreFoundInTheWordList() {
        XCTAssertTrue(arabic.isKnownWord("مدرسة"))
        XCTAssertTrue(arabic.isKnownWord("مدرسه"))
        XCTAssertTrue(arabic.isKnownWord("أحمد"))
        XCTAssertTrue(arabic.isKnownWord("مَدْرَسَة"))
    }

    func testEnglishLookupIsCaseInsensitive() {
        XCTAssertTrue(english.isKnownWord("Hello"))
        XCTAssertTrue(english.isKnownWord("HELLO"))
    }

    // MARK: - Coverage

    func testDictCoverageStripsEnglishInflections() {
        // "refactor" is not in the frequency list, so the whole token is a
        // miss; "meetings" is only listed as "meeting".
        XCTAssertFalse(english.isKnownWord("refactor"))
        XCTAssertTrue(english.isKnownWord("meetings"))
        XCTAssertTrue(english.isKnownWord("walked"))
        XCTAssertTrue(english.isKnownWord("running"))
    }

    func testDictCoverageStripsArabicClitics() {
        XCTAssertTrue(arabic.isKnownWord("والمدرسة"))
        XCTAssertTrue(arabic.isKnownWord("بالمكتب"))
        XCTAssertTrue(arabic.isKnownWord("كتابها"))
    }

    func testSingleLetterTokensAreExcludedFromCoverage() {
        // "a" is a listed English word but one-letter tokens do not count, so
        // a lone "a" leaves nothing to measure.
        XCTAssertEqual(english.dictCoverage("a"), 0, accuracy: 0.0001)
        XCTAssertEqual(english.dictCoverage("x y z"), 0, accuracy: 0.0001)
    }

    func testTwoLetterTokensCountHalf() {
        // "of" is known (weight 0.5), "hsmdih" is not (weight 6).
        let coverage = english.dictCoverage("of hsmdih")
        XCTAssertEqual(coverage, 0.5 / 6.5, accuracy: 0.0001)
    }

    func testEmptyAndPunctuationOnlyTextScoresZero() {
        XCTAssertEqual(english.combined("").combined, 0, accuracy: 0.0001)
        XCTAssertEqual(english.combined("!!! ... ???").combined, 0, accuracy: 0.0001)
        XCTAssertEqual(arabic.combined("12345").combined, 0, accuracy: 0.0001)
    }

    func testBigramScoreStaysInRange() {
        for text in ["hello world", "qqqqqqq", "", "zxcvbnm", "the"] {
            let value = english.bigramScore(text)
            XCTAssertGreaterThanOrEqual(value, 0, text)
            XCTAssertLessThanOrEqual(value, 1, text)
        }
    }

    func testCombinedIsTheDocumentedBlend() {
        let score = english.combined("please send me the report")
        XCTAssertEqual(
            score.combined,
            Score.bigramWeight * score.bigram + Score.dictWeight * score.dictCoverage,
            accuracy: 0.0001)
    }
}
