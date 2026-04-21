import XCTest
@testable import Varta

final class GlossaryReplacementTests: XCTestCase {
    func testGlossaryReplacementRespectsLanguageHint() {
        let terms = [
            GlossaryTerm(id: 1, term: "Varta", replacement: "VARTA", languageCode: .mixed),
            GlossaryTerm(id: 2, term: "meeting", replacement: "बैठक", languageCode: .english),
            GlossaryTerm(id: 3, term: "निर्णय", replacement: "decision", languageCode: .nepali),
        ]

        let english = SummariserService.applyGlossary(
            text: "Varta meeting recap",
            languageHint: .english,
            terms: terms
        )

        let nepali = SummariserService.applyGlossary(
            text: "Varta निर्णय बाँकी छ",
            languageHint: .nepali,
            terms: terms
        )

        XCTAssertEqual(english, "VARTA बैठक recap")
        XCTAssertEqual(nepali, "VARTA decision बाँकी छ")
    }
}
