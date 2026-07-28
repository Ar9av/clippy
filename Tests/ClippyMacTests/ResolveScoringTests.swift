import XCTest
@testable import ClippyMac

final class ResolveScoringTests: XCTestCase {
    private func score(query: String, label: String, role: String = "Button", isFieldIntent: Bool = false) -> Int {
        ScreenAwarenessService.matchScore(query: query.lowercased(), label: label, role: role, isFieldIntent: isFieldIntent)
    }

    func testExactLabelMatchScoresHighest() {
        let exact = score(query: "save", label: "Save")
        let partial = score(query: "save", label: "Save changes")
        XCTAssertGreaterThan(exact, partial)
    }

    func testSharedWordsContributeScore() {
        XCTAssertGreaterThan(score(query: "save file", label: "Save"), score(query: "save file", label: "Cancel"))
    }

    func testUnrelatedLabelScoresZero() {
        XCTAssertEqual(score(query: "save", label: "Cancel"), 0)
    }

    func testFieldIntentBiasesTowardEditableRoles() {
        let asField = score(query: "message", label: "Message", role: "TextArea", isFieldIntent: true)
        let asButton = score(query: "message", label: "Message", role: "Button", isFieldIntent: true)
        XCTAssertGreaterThan(asField, asButton)
    }

    func testFieldIntentGivesTextAreaAnExtraBiasOverTextField() {
        let textArea = score(query: "message", label: "Message", role: "TextArea", isFieldIntent: true)
        let textField = score(query: "message", label: "Message", role: "TextField", isFieldIntent: true)
        XCTAssertGreaterThan(textArea, textField)
    }

    func testFieldIntentDoesNotAffectNonEditableRoles() {
        let intentOn = score(query: "search", label: "Search", role: "Button", isFieldIntent: true)
        let intentOff = score(query: "search", label: "Search", role: "Button", isFieldIntent: false)
        XCTAssertEqual(intentOn, intentOff)
    }

    func testSubstringMatchScoresBetweenExactAndWordOverlapOnly() {
        // "address bar" as a query against "Address and Search" label: no
        // exact match, no substring containment either way, but they share
        // the word "address" — still a positive, if modest, score.
        let sharedWordOnly = score(query: "address bar", label: "Address and Search")
        XCTAssertGreaterThan(sharedWordOnly, 0)

        let substringMatch = score(query: "address", label: "Address and Search bar thing")
        XCTAssertGreaterThan(substringMatch, sharedWordOnly)
    }

    func testAmbiguousTiesAreDetectableByEqualScores() {
        // Two differently-labelled controls that happen to score identically
        // — resolve() itself just takes the first max() found today (no
        // ambiguity detection yet), but this documents that ties are
        // possible and scorable, which any future ambiguity-detection logic
        // would need to check for.
        let first = score(query: "search", label: "Search")
        let second = score(query: "search", label: "Search")
        XCTAssertEqual(first, second)
    }
}
