import XCTest
@testable import ClippyCore
@testable import ClippyMac

/// Found by driving the built app: asked for "the Untitled TextEdit document"
/// and Clippy typed into clippy-selftest.txt instead — a different document,
/// in the same app, whose contents it then replaced.
final class DestinationTargetingTests: XCTestCase {
    func testPicksOutADestinationTheRequestNames() {
        XCTAssertEqual(
            ChatViewModel.namedDestination(in: "type \"hi\" into the clippy-precious document"),
            "clippy-precious"
        )
        XCTAssertEqual(
            ChatViewModel.namedDestination(in: "put that in the Untitled TextEdit window"),
            "Untitled TextEdit"
        )
    }

    /// Most requests name nothing in particular, and those must go on using
    /// the focused window exactly as before.
    func testNoDestinationNamedIsNotAMismatch() {
        for request in ["type hello for me", "put that here", "write a haiku"] {
            XCTAssertNil(ChatViewModel.namedDestination(in: request), request)
        }
    }

    /// The exact failure: "textedit" matches the app, "untitled" does not
    /// match the window — so every distinctive word has to land, not just one.
    func testTheObservedMismatchIsCaught() {
        XCTAssertFalse(ChatViewModel.destination(
            "Untitled TextEdit",
            matchesAppNamed: "TextEdit",
            windowTitle: "clippy-selftest.txt"
        ))
    }

    func testTheRightWindowStillMatches() {
        XCTAssertTrue(ChatViewModel.destination(
            "Untitled TextEdit",
            matchesAppNamed: "TextEdit",
            windowTitle: "Untitled"
        ))
        XCTAssertTrue(ChatViewModel.destination(
            "clippy-precious",
            matchesAppNamed: "TextEdit",
            windowTitle: "clippy-precious.txt"
        ))
    }

    /// A destination made entirely of filler words tells us nothing, so it
    /// must not start refusing ordinary requests.
    func testAnUninformativeDestinationDoesNotBlock() {
        XCTAssertTrue(ChatViewModel.destination(
            "the current",
            matchesAppNamed: "Notes",
            windowTitle: "Groceries"
        ))
    }

    func testTheMessageNamesBothWindows() {
        let screen = ScreenContext(
            appName: "TextEdit",
            windowTitle: "clippy-selftest.txt",
            contextURL: URL(fileURLWithPath: "/dev/null"),
            elements: [],
            displayShots: [
                DisplayShot(
                    name: "Built-in",
                    url: URL(fileURLWithPath: "/dev/null"),
                    frame: .zero,
                    scale: 1,
                    isAnchor: true
                )
            ],
            windowFrame: .zero,
            screenshotScale: 1
        )
        let message = ChatViewModel.destinationMismatch(
            request: "type \"x\" into the Untitled TextEdit document",
            screen: screen
        )
        XCTAssertNotNil(message)
        XCTAssertEqual(message?.contains("Untitled TextEdit"), true)
        XCTAssertEqual(message?.contains("clippy-selftest.txt"), true)
    }
}

/// The caret ends up at position 0 simply because that's where a freshly
/// opened document puts it — inserting flush there produced
/// "a second lineImportant draft I must not lose."
final class CaretSeparationTests: XCTestCase {
    func testSeparatesAtTheStartOfADocument() {
        XCTAssertEqual(
            ScreenAwarenessService.separated("a second line", forCaretIn: "Important draft.", at: 0),
            "a second line\n"
        )
    }

    func testSeparatesAtTheEndOfADocument() {
        XCTAssertEqual(
            ScreenAwarenessService.separated("a second line", forCaretIn: "Important draft.", at: 16),
            "\na second line"
        )
    }

    /// A caret in the middle is somewhere the user put it on purpose.
    func testLeavesADeliberateMidTextCaretAlone() {
        XCTAssertEqual(
            ScreenAwarenessService.separated("XX", forCaretIn: "Important draft.", at: 9),
            "XX"
        )
    }

    func testDoesNotDoubleUpExistingNewlines() {
        XCTAssertEqual(ScreenAwarenessService.separated("b", forCaretIn: "a\n", at: 2), "b")
        XCTAssertEqual(ScreenAwarenessService.separated("b", forCaretIn: "\na", at: 0), "b")
    }

    func testAnEmptyFieldNeedsNoSeparator() {
        XCTAssertEqual(ScreenAwarenessService.separated("hello", forCaretIn: "", at: 0), "hello")
    }

    /// Some web composers expose no selection at all; treat that as mid-text
    /// rather than inventing a newline.
    func testAnUnknownCaretIsLeftAlone() {
        XCTAssertEqual(ScreenAwarenessService.separated("b", forCaretIn: "a", at: nil), "b")
    }
}
