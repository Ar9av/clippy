import XCTest
@testable import ClippyCore

final class AIServiceTests: XCTestCase {
    func testParsesTrailingReplyAtMarker() {
        let response = """
        Thanks for reaching out! I'd be happy to connect.
        [[CLIPPY_REPLY_AT:420,780]]
        """
        let target = AIService.screenReplyTarget(from: response)
        XCTAssertEqual(target?.point, CGPoint(x: 420, y: 780))
        XCTAssertEqual(target?.response, "Thanks for reaching out! I'd be happy to connect.")
    }

    func testParsesMarkerWithDecimalCoordinates() {
        let response = "Sounds good, see you then. [[CLIPPY_REPLY_AT:301.5,64.25]]"
        let target = AIService.screenReplyTarget(from: response)
        XCTAssertEqual(target?.point, CGPoint(x: 301.5, y: 64.25))
        XCTAssertEqual(target?.response, "Sounds good, see you then.")
    }

    func testReturnsNilWithNoMarker() {
        XCTAssertNil(AIService.screenReplyTarget(from: "Just a plain reply with nothing after it."))
    }

    func testReturnsNilWhenMarkerIsNotAtTheEnd() {
        // The marker is a suffix-only convention — mid-string occurrences
        // (e.g. echoed back from an earlier turn) must not be picked up.
        XCTAssertNil(AIService.screenReplyTarget(from: "[[CLIPPY_REPLY_AT:10,20]] then some more text"))
    }

    func testReturnsNilWhenMarkerLeavesNoReplyText() {
        // A marker with nothing in front of it isn't a real reply to draft.
        XCTAssertNil(AIService.screenReplyTarget(from: "[[CLIPPY_REPLY_AT:10,20]]"))
    }

    func testModelFlagIsOmittedWhenNoModelChosen() {
        XCTAssertEqual(AIService.modelArguments("--model", ""), [])
        XCTAssertEqual(AIService.modelArguments("--model", "   "), [])
    }

    func testModelFlagIsPassedWhenChosen() {
        XCTAssertEqual(AIService.modelArguments("--model", "sonnet"), ["--model", "sonnet"])
        XCTAssertEqual(AIService.modelArguments("--model", " gpt-5.6-luna "), ["--model", "gpt-5.6-luna"])
    }
}
