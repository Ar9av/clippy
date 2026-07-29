import XCTest
@testable import ClippyMac

final class BalloonMenuTests: XCTestCase {
    // MARK: - Defaults

    func testDefaultsContainEveryRowInOrder() {
        XCTAssertEqual(BalloonAction.defaults.map(\.kind), BalloonAction.Kind.allCases)
        XCTAssertTrue(BalloonAction.defaults.allSatisfy(\.isVisible))
    }

    func testDefaultTitlesAreUsedWhenNoneGiven() {
        XCTAssertEqual(BalloonAction(kind: .askHere).title, "Ask Clippy here")
        XCTAssertEqual(BalloonAction(kind: .fullChat).title, "Open the full chat window")
    }

    // MARK: - displayTitle

    func testBlankTitleFallsBackToTheBuiltInWording() {
        let cleared = BalloonAction(kind: .openSomething, title: "   ")
        XCTAssertEqual(cleared.displayTitle, "Open something")
    }

    func testCustomTitleIsUsedAndTrimmed() {
        let renamed = BalloonAction(kind: .openSomething, title: "  Launch an app  ")
        XCTAssertEqual(renamed.displayTitle, "Launch an app")
    }

    // MARK: - Merging forward

    /// A build that adds a new row must not leave it unreachable for anyone
    /// whose stored menu predates it.
    func testMergeRestoresMissingRowsAsHidden() {
        let stored = [BalloonAction(kind: .askHere)]
        let merged = BalloonAction.merged(stored: stored)

        XCTAssertEqual(Set(merged.map(\.kind)), Set(BalloonAction.Kind.allCases))
        XCTAssertEqual(merged.first?.kind, .askHere, "existing rows keep their position")
        XCTAssertTrue(
            merged.filter { $0.kind != .askHere }.allSatisfy { !$0.isVisible },
            "restored rows are hidden so they can't rearrange an arranged menu"
        )
    }

    func testMergePreservesUserOrderingAndVisibility()  {
        let stored = [
            BalloonAction(kind: .dismiss, title: "Go away"),
            BalloonAction(kind: .askHere, isVisible: false)
        ]
        let merged = BalloonAction.merged(stored: stored)

        XCTAssertEqual(merged[0].kind, .dismiss)
        XCTAssertEqual(merged[0].title, "Go away")
        XCTAssertEqual(merged[1].kind, .askHere)
        XCTAssertFalse(merged[1].isVisible)
    }

    func testMergeIsIdempotent() {
        let once = BalloonAction.merged(stored: BalloonAction.defaults)
        let twice = BalloonAction.merged(stored: once)
        XCTAssertEqual(once.map(\.kind), twice.map(\.kind))
    }

    // MARK: - CustomPrompt forward compatibility

    /// Prompts saved before `showsInBalloon` existed must still decode. The
    /// synthesized initializer throws on the missing key, and the real decode
    /// site uses `try?` — so getting this wrong wipes every saved prompt.
    func testLegacyPromptJSONWithoutShowsInBalloonStillDecodes() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","command":"review","prompt":"Review this."}]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([CustomPrompt].self, from: legacy)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.command, "review")
        XCTAssertEqual(decoded.first?.showsInBalloon, false)
    }

    func testPromptRoundTripsThroughCoding() throws {
        let original = CustomPrompt(command: "review", prompt: "Review this.", showsInBalloon: true)
        let decoded = try JSONDecoder().decode(
            CustomPrompt.self,
            from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    /// Decoding normalizes too, so a command hand-edited into the stored JSON
    /// can't become permanently unmatchable.
    func testDecodingNormalizesTheCommand() throws {
        let json = """
        {"id":"\(UUID().uuidString)","command":"Deep Review","prompt":"x","showsInBalloon":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CustomPrompt.self, from: json)
        XCTAssertEqual(decoded.command, "deep-review")
    }

    // MARK: - Balloon labels

    func testBalloonTitleUsesTheFirstLineOfThePrompt() {
        let prompt = CustomPrompt(command: "draft", prompt: "Look at the screen and draft a reply\nBe brief.")
        XCTAssertEqual(prompt.balloonTitle, "Look at the screen and draft a reply")
    }

    func testBalloonTitleIsTruncatedForTheNarrowBalloon() {
        let long = String(repeating: "word ", count: 40)
        let prompt = CustomPrompt(command: "x", prompt: long)
        XCTAssertLessThanOrEqual(prompt.balloonTitle.count, 44)
        XCTAssertTrue(prompt.balloonTitle.hasSuffix("…"))
    }
}
