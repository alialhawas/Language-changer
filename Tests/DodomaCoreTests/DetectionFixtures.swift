import XCTest

@testable import DodomaCore

/// A `Detector` wired to the committed `uchr` snapshots rather than to the
/// input sources of whatever machine runs the tests.
struct DetectorFixture {
    let abc: FixtureLayout
    let arabic: FixtureLayout
    let detector: Detector

    var keyboardType: UInt32 { abc.keyboardType }

    static func make(file: StaticString = #filePath, line: UInt = #line) throws
        -> DetectorFixture
    {
        let abc = try LayoutFixtures.abc(file: file, line: line)
        let arabic = try LayoutFixtures.arabic(file: file, line: line)
        XCTAssertEqual(
            abc.keyboardType, arabic.keyboardType,
            "fixture layouts were captured against different keyboard types",
            file: file, line: line)
        return DetectorFixture(
            abc: abc,
            arabic: arabic,
            detector: Detector(englishLayout: abc.layout, arabicLayout: arabic.layout))
    }

    /// Keys for Latin text as typed on a US/ANSI keyboard.
    func latinKeys(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> [CapturedKey]
    {
        try abc.keys(text, file: file, line: line)
    }

    /// Keys for Arabic text as typed on the Arabic layout.
    func arabicKeys(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> [CapturedKey]
    {
        try XCTUnwrap(
            InverseKeymap.keys(
                for: text, layout: arabic.layout, keyboardType: arabic.keyboardType),
            "Arabic layout cannot type \(text)", file: file, line: line)
    }

    var models: LanguageModelPair {
        LanguageModelPair(
            current: detector.englishModel, alternate: detector.arabicModel)
    }

    func segment(_ keys: [CapturedKey], typedLanguage: Language = .english) -> CandidateRegion? {
        let alternate: Language = typedLanguage == .english ? .arabic : .english
        return Segmenter.candidate(
            in: keys,
            currentLayout: detector.layout(for: typedLanguage),
            alternateLayout: detector.layout(for: alternate),
            models: LanguageModelPair(
                current: detector.model(for: typedLanguage),
                alternate: detector.model(for: alternate)))
    }

    func detect(
        _ text: String,
        typedLanguage: Language? = nil,
        policy: AppPolicy = .normal,
        aggressiveness: Aggressiveness = .balanced,
        recentlyUndone: Set<String> = []
    ) -> Detector.Detection? {
        detector.detect(
            text: text, typedLanguage: typedLanguage, policy: policy,
            aggressiveness: aggressiveness, recentlyUndone: recentlyUndone,
            keyboardType: keyboardType)
    }
}
