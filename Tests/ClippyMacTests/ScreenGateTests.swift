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

/// Regressions from an exploratory sweep of the gate: both directions were
/// wrong for the same reason — surface terms were matched as substrings.
extension ScreenGateTests {
    /// "how do I center a div" took a screenshot because "center" contains
    /// "enter"; "a good approach" because it contains "app". Pure knowledge
    /// questions are exactly what the gate exists to make fast.
    func testSurfaceTermsMatchWholeWordsNotSubstrings() {
        for request in [
            "how do I center a div",
            "a good approach to caching",
            "what is the diameter of Jupiter",
            "explain the concept of entropy"
        ] {
            XCTAssertFalse(ChatViewModel.mightNeedScreen(request), request)
        }
    }

    /// The README's flagship example. It reached the model with no screenshot
    /// on this path, and was only rescued by `requestsScreenPlan` matching it
    /// separately — not a guarantee worth resting on.
    func testSettingsChangesAlwaysLook() {
        for request in [
            "turn on dark mode",
            "enable reduce motion",
            "disable notifications",
            "set the volume to 50%",
            "change my wallpaper",
            "toggle bluetooth"
        ] {
            XCTAssertTrue(ChatViewModel.mightNeedScreen(request), request)
        }
    }
}
