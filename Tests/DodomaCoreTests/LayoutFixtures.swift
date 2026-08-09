import Foundation
import XCTest

@testable import DodomaCore

/// Loads the committed `uchr` snapshot so renderer tests never touch the Text
/// Input Sources of the machine they run on.
enum LayoutFixtures {
    static let abcSourceID = "com.apple.keylayout.ABC"
    static let arabicSourceID = "com.apple.keylayout.Arabic"

    static func layout(_ sourceID: String, file: StaticString = #filePath, line: UInt = #line)
        throws -> KeyboardLayout
    {
        let all = try load(file: file, line: line)
        let fixture = try XCTUnwrap(
            all.first { $0.sourceID == sourceID },
            "fixture layout-tables.json has no entry for \(sourceID); run `make fixtures`",
            file: file, line: line)
        return try XCTUnwrap(
            fixture.makeLayout(), "fixture \(sourceID) has malformed uchr base64", file: file,
            line: line)
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
