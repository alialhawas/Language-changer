import XCTest

@testable import DodomaCore

final class UserLexiconTests: XCTestCase {
    private func lexicon() -> UserLexicon { UserLexicon(url: nil) }

    /// A word is not vocabulary because it appeared once.
    func testAWordIsNotKnownUntilItIsSeenEnough() {
        let lex = lexicon()
        for seen in 1..<UserLexicon.promotionThreshold {
            lex.observe(["endpoint"], language: .english)
            XCTAssertFalse(
                lex.contains("endpoint", language: .english),
                "promoted after only \(seen) sightings")
        }
        lex.observe(["endpoint"], language: .english)
        XCTAssertTrue(lex.contains("endpoint", language: .english))
    }

    /// Manual entries skip the counting, which is the point of having them.
    func testAManualWordCountsImmediately() {
        let lex = lexicon()
        lex.add("kubectl", language: .english)
        XCTAssertTrue(lex.contains("kubectl", language: .english))
    }

    /// Removal takes a word back whichever list put it there.
    func testRemovalClearsBothRoutes() {
        let lex = lexicon()
        lex.add("dto", language: .english)
        for _ in 0..<UserLexicon.promotionThreshold { lex.observe(["async"], language: .english) }
        lex.remove("dto", language: .english)
        lex.remove("async", language: .english)
        XCTAssertFalse(lex.contains("dto", language: .english))
        XCTAssertFalse(lex.contains("async", language: .english))
    }

    /// Languages keep their own vocabulary: one lexicon, two rooms.
    func testALanguageDoesNotInheritTheOtherWords() {
        let lex = lexicon()
        for _ in 0..<UserLexicon.promotionThreshold { lex.observe(["repo"], language: .english) }
        XCTAssertTrue(lex.contains("repo", language: .english))
        XCTAssertFalse(lex.contains("repo", language: .arabic))
    }

    /// Two letters is noise, not vocabulary, however often it appears.
    func testShortTokensAreNeverLearned() {
        let lex = lexicon()
        for _ in 0..<(UserLexicon.promotionThreshold * 3) {
            lex.observe(["pr", "ok"], language: .english)
        }
        XCTAssertFalse(lex.contains("pr", language: .english))
        XCTAssertFalse(lex.contains("ok", language: .english))
    }

    /// The list survives the session it was learned in.
    func testItRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lex-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = UserLexicon(url: url)
        for _ in 0..<UserLexicon.promotionThreshold {
            first.observe(["backoffice"], language: .english)
        }
        first.add("خوارزمية", language: .arabic)
        XCTAssertTrue(first.save())

        let second = UserLexicon(url: url)
        XCTAssertTrue(second.contains("backoffice", language: .english))
        XCTAssertTrue(second.contains("خوارزمية", language: .arabic))
    }

    /// A learned word lifts the score of text containing it, which is the only
    /// reason the lexicon exists.
    func testALearnedWordRaisesDictionaryCoverage() throws {
        let model = try LanguageModel.shared(.english)
        let before = model.dictCoverage("the endpoint returned")
        let lex = lexicon()
        for _ in 0..<UserLexicon.promotionThreshold { lex.observe(["endpoint"], language: .english) }
        model.lexicon = lex
        defer { model.lexicon = nil }
        XCTAssertGreaterThan(model.dictCoverage("the endpoint returned"), before)
    }
}

extension UserLexiconTests {
    /// The personal list holds what the shipped one lacks, and nothing else.
    ///
    /// Recording every word would have put a frequency profile of ordinary
    /// writing on disk while changing no score, since those words were already
    /// known.
    func testOnlyWordsMissingFromTheShippedListAreWorthRecording() throws {
        let model = try LanguageModel.shared(.english)
        let sentence = "we should create the endpoint and merge the pr"
        let unknown = model.vocabulary(in: sentence).filter { !model.isKnownWord($0) }

        XCTAssertTrue(unknown.contains("endpoint"), "jargon the subtitle corpus lacks")
        for ordinary in ["should", "create", "the", "and", "merge"] {
            XCTAssertFalse(unknown.contains(ordinary), "\(ordinary) is already known")
        }
    }
}
