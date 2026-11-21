import ClippyCore
import XCTest
@testable import ClippyMac

final class FeelingMarkerTests: XCTestCase {
    func testExtractsTheFeelingAndStripsTheMarker() {
        let result = AIService.extractFeeling(from: "[[CLIPPY_FEEL: happy]] Nice, that worked.")
        XCTAssertEqual(result.feeling, .happy)
        XCTAssertEqual(result.response, "Nice, that worked.")
    }

    func testUnknownFeelingIsStillStripped() {
        let result = AIService.extractFeeling(from: "[[CLIPPY_FEEL: smug]] Told you.")
        XCTAssertNil(result.feeling)
        XCTAssertEqual(result.response, "Told you.")
    }

    func testLeavesAnOrdinaryReplyAlone() {
        let result = AIService.extractFeeling(from: "Plain answer.")
        XCTAssertNil(result.feeling)
        XCTAssertEqual(result.response, "Plain answer.")
    }

    /// A plan reply that leads with the marker must still parse as a plan.
    func testStrippingLeavesPlanJSONAtTheFront() {
        let stripped = AIService.extractFeeling(from: "[[CLIPPY_FEEL: neutral]]\n{\"steps\":[]}").response
        XCTAssertTrue(stripped.hasPrefix("{"))
    }

    func testStreamingHidesAnUnclosedMarker() {
        XCTAssertEqual(AIService.streamingDisplayText("[[CLIPPY_FE"), "")
        XCTAssertEqual(AIService.streamingDisplayText("[[CLIPPY_FEEL: sad]] Sorry"), "Sorry")
        XCTAssertEqual(AIService.streamingDisplayText("Got it.\n[[CLIPPY_REMEM"), "Got it.")
        XCTAssertEqual(AIService.streamingDisplayText("Use `[[ -f x ]]` here"), "Use `[[ -f x ]]` here")
    }

    func testPromptAsksForTheMarker() {
        XCTAssertTrue(AIService.systemPrompt.contains("[[CLIPPY_FEEL:"))
    }
}

final class FeelingAnimationTests: XCTestCase {
    /// Every feeling must play something real on every bundled character,
    /// or the reaction silently degrades to the rest pose.
    func testEveryFeelingHasAnAnimationOnEveryCharacter() throws {
        let characters = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ClippyMac/Resources/Characters")
        for character in ClippyCharacter.allCases {
            let data = try Data(contentsOf: characters.appendingPathComponent("\(character.rawValue).json"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let names = Set((json["animations"] as? [String: Any] ?? [:]).keys)
            for feeling in ClippyFeeling.allCases where feeling != .neutral {
                XCTAssertFalse(
                    names.isDisjoint(with: ClippyMood.reactions(for: feeling)),
                    "\(character.rawValue) has no animation for \(feeling.rawValue)"
                )
            }
        }
    }
}
