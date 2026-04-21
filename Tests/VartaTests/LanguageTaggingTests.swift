import XCTest
@testable import Varta

final class LanguageTaggingTests: XCTestCase {
    func testMixedTaggingDetectsEnglishAndNepali() {
        XCTAssertEqual(
            TranscriptionService.languageTag(for: "We reviewed backlog and next sprint", languageMode: .mixed),
            .english
        )

        XCTAssertEqual(
            TranscriptionService.languageTag(for: "हामीले अर्को हप्ताको योजना बनायौं", languageMode: .mixed),
            .nepali
        )

        XCTAssertEqual(
            TranscriptionService.languageTag(for: "Sprint को निर्णय final गरौं", languageMode: .mixed),
            .mixed
        )
    }

    func testForcedLanguageModeOverridesDetection() {
        XCTAssertEqual(
            TranscriptionService.languageTag(for: "हामी meeting गरौं", languageMode: .english),
            .english
        )

        XCTAssertEqual(
            TranscriptionService.languageTag(for: "hello world", languageMode: .nepali),
            .nepali
        )
    }
}
