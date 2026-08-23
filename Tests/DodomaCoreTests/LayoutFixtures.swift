import Foundation
import XCTest

@testable import DodomaCore

/// A layout rebuilt from the committed snapshot, together with the keyboard
/// type it was captured against. Tests must build their keys through
/// `keys(_:)` so a JIS or ISO host renders exactly what the ANSI host that
/// produced the fixture did.
struct FixtureLayout {
    let layout: KeyboardLayout
    let keyboardType: UInt32

    func keys(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> [CapturedKey]
    {
        try XCTUnwrap(
            KeycodeMap.keys(forLatin: text, keyboardType: keyboardType), file: file, line: line)
    }

    /// A key the `KeycodeMap` table cannot express, e.g. an option chord.
    func key(_ keycode: UInt16, _ flags: KeyFlags = []) -> CapturedKey {
        CapturedKey(
            keycode: keycode, flags: flags, producedText: "", keyboardType: keyboardType)
    }
}

/// Loads the committed `uchr` snapshot so renderer tests never touch the Text
/// Input Sources of the machine they run on.
enum LayoutFixtures {
    static let abcSourceID = "com.apple.keylayout.ABC"
    static let arabicSourceID = "com.apple.keylayout.Arabic"

    static func abc(file: StaticString = #filePath, line: UInt = #line) throws -> FixtureLayout {
        try fixtureLayout(abcSourceID, file: file, line: line)
    }

    static func arabic(file: StaticString = #filePath, line: UInt = #line) throws -> FixtureLayout {
        try fixtureLayout(arabicSourceID, file: file, line: line)
    }

    static func fixtureLayout(
        _ sourceID: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> FixtureLayout {
        let all = try load(file: file, line: line)
        let fixture = try XCTUnwrap(
            all.first { $0.sourceID == sourceID },
            "fixture layout-tables.json has no entry for \(sourceID); run `make fixtures`",
            file: file, line: line)
        let layout = try XCTUnwrap(
            fixture.makeLayout(), "fixture \(sourceID) has malformed uchr base64", file: file,
            line: line)
        return FixtureLayout(layout: layout, keyboardType: fixture.keyboardType)
    }

    private static func load(file: StaticString, line: UInt) throws -> [LayoutFixture] {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "layout-tables", withExtension: "json", subdirectory: "Fixtures"),
            "layout-tables.json is missing from the test bundle; run `make fixtures`",
            file: file, line: line)
        return try JSONDecoder().decode([LayoutFixture].self, from: Data(contentsOf: url))
    }
}
