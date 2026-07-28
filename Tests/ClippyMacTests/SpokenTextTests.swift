import XCTest
@testable import ClippyMac

final class SpokenTextTests: XCTestCase {
    func testStripsHeadingMarkers() {
        XCTAssertEqual(ChatViewModel.spokenText(from: "## Setup"), "Setup")
    }

    func testStripsBoldAndItalicMarkers() {
        XCTAssertEqual(ChatViewModel.spokenText(from: "This is **bold** and __also bold__."), "This is bold and also bold.")
    }

    func testConvertsLinksToTheirLabel() {
        XCTAssertEqual(ChatViewModel.spokenText(from: "See [the docs](https://example.com) for more."), "See the docs for more.")
    }

    func testDropsFencedCodeBlocksEntirely() {
        let markdown = """
        Here's how:
        ```swift
        let x = 1
        print(x)
        ```
        Done.
        """
        let result = ChatViewModel.spokenText(from: markdown)
        XCTAssertFalse(result.contains("print"))
        XCTAssertTrue(result.contains("Code omitted"))
        XCTAssertTrue(result.contains("Here's how"))
        XCTAssertTrue(result.contains("Done."))
    }

    func testStripsBulletMarkers() {
        let markdown = "- first\n- second"
        let result = ChatViewModel.spokenText(from: markdown)
        XCTAssertFalse(result.contains("-"))
        XCTAssertTrue(result.contains("first"))
        XCTAssertTrue(result.contains("second"))
    }

    func testCollapsesWhitespace() {
        let result = ChatViewModel.spokenText(from: "line one\n\n\nline two")
        XCTAssertEqual(result, "line one line two")
    }
}
