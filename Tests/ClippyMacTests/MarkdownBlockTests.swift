import XCTest
@testable import ClippyMac

final class MarkdownBlockTests: XCTestCase {
    func testParsesAHeading() {
        let blocks = MarkdownBlock.parse("## Setup")
        XCTAssertEqual(blocks.map(\.kind), [.heading(2, "Setup")])
    }

    func testClampsHeadingLevelToThree() {
        let blocks = MarkdownBlock.parse("###### Deep heading")
        XCTAssertEqual(blocks.map(\.kind), [.heading(3, "Deep heading")])
    }

    func testJoinsConsecutiveLinesIntoOneParagraph() {
        let blocks = MarkdownBlock.parse("line one\nline two")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph("line one line two")])
    }

    func testBlankLineSeparatesParagraphs() {
        let blocks = MarkdownBlock.parse("first\n\nsecond")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph("first"), .paragraph("second")])
    }

    func testParsesDashAndAsteriskBullets() {
        let blocks = MarkdownBlock.parse("- one\n* two")
        XCTAssertEqual(blocks.map(\.kind), [.bullet("one"), .bullet("two")])
    }

    func testParsesNumberedItems() {
        let blocks = MarkdownBlock.parse("1. first\n2. second")
        XCTAssertEqual(blocks.map(\.kind), [.numbered(1, "first"), .numbered(2, "second")])
    }

    func testParsesAFencedCodeBlockAsOneBlock() {
        let markdown = """
        ```swift
        let x = 1
        print(x)
        ```
        """
        let blocks = MarkdownBlock.parse(markdown)
        XCTAssertEqual(blocks.map(\.kind), [.code("let x = 1\nprint(x)")])
    }

    func testCodeFenceDoesNotConsumeAnEarlierParagraph() {
        let markdown = """
        Here's the code:
        ```
        let x = 1
        ```
        Done.
        """
        let blocks = MarkdownBlock.parse(markdown)
        XCTAssertEqual(blocks.map(\.kind), [
            .paragraph("Here's the code:"),
            .code("let x = 1"),
            .paragraph("Done.")
        ])
    }

    func testFirstBlockIsMarkedIsFirst() {
        let blocks = MarkdownBlock.parse("first\n\nsecond")
        XCTAssertEqual(blocks.first?.isFirst, true)
        XCTAssertEqual(blocks.last?.isFirst, false)
    }
}
