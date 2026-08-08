import XCTest
@testable import ClippyMac

/// The gate on the (expensive) screen capture. It is deliberately biased
/// towards capturing: a needless capture costs a second, a missed one costs a
/// wrong answer — so these tests mostly pin down that the *skip* side stays
/// narrow.
final class ScreenGateTests: XCTestCase {
    func testCapturesForDemonstratives() {
        for request in [
            "what does this mean?",
            "fix it",
            "summarise that for me",
            "what's wrong here"
        ] {
            XCTAssertTrue(ChatViewModel.mightNeedScreen(request), request)
        }
    }

    func testCapturesForScreenFurniture() {
        for request in [
            "which button do I press",
            "turn on dark mode in settings",
            "open Safari",
            "scroll down and tell me what you see"
        ] {
            XCTAssertTrue(ChatViewModel.mightNeedScreen(request), request)
        }
    }

    func testCapturesForBareImperatives() {
        for request in ["do it", "go", "try again", "check", "continue"] {
            XCTAssertTrue(ChatViewModel.mightNeedScreen(request), request)
        }
    }

    /// The whole point of the gate: self-contained questions skip the
    /// screenshot, which also lets them stream.
    func testSkipsSelfContainedQuestions() {
        for request in [
            "what is the capital of France",
            "explain tail recursion",
            "write a haiku about paperclips",
            "how many grams in an ounce"
        ] {
            XCTAssertFalse(ChatViewModel.mightNeedScreen(request), request)
        }
    }

    func testSkipsAnEmptyRequest() {
        XCTAssertFalse(ChatViewModel.mightNeedScreen("   "))
    }
}
