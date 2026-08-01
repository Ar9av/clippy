import XCTest
@testable import ClippyCore

/// The Claude Code CLI is handed attachments as paths to open itself, and they
/// live outside its working directory: screenshots in Caches/Clippy/
/// ScreenContext, pasted files in PastedAttachments. Reading outside the
/// workspace needs approval, and `-p` is non-interactive so it cannot ask —
/// the read is refused and Clippy reports it cannot see the screen. These pin
/// the directory grant that makes those files readable.
final class AttachmentDirectoryTests: XCTestCase {
    private let screenshot = URL(fileURLWithPath: "/Users/x/Library/Caches/Clippy/ScreenContext/Screen-A.png")
    private let screenshot2 = URL(fileURLWithPath: "/Users/x/Library/Caches/Clippy/ScreenContext/Screen-B.png")
    private let contextFile = URL(fileURLWithPath: "/Users/x/Library/Caches/Clippy/ScreenContext/Screen-Context-A.txt")
    private let pasted = URL(fileURLWithPath: "/Users/x/Library/Caches/Clippy/PastedAttachments/Pasted Image.png")

    func testGrantsTheDirectoryHoldingAScreenshot() {
        XCTAssertEqual(
            AIService.attachmentDirectories([screenshot]),
            ["/Users/x/Library/Caches/Clippy/ScreenContext"]
        )
    }

    /// Both kinds of attachment must be covered: the user's own pasted file is
    /// in a different directory from Clippy's captures, and it was just as
    /// unreadable.
    func testCoversBothCapturesAndPastedFiles() {
        let directories = AIService.attachmentDirectories([screenshot, contextFile, pasted])
        XCTAssertEqual(directories, [
            "/Users/x/Library/Caches/Clippy/ScreenContext",
            "/Users/x/Library/Caches/Clippy/PastedAttachments"
        ])
    }

    /// One grant per directory, not per file — a multi-display capture attaches
    /// several images from the same place, and a long session would otherwise
    /// grow the argument list without bound.
    func testDeduplicatesByDirectory() {
        let directories = AIService.attachmentDirectories([
            screenshot, screenshot2, contextFile, screenshot
        ])
        XCTAssertEqual(directories.count, 1)
    }

    /// Order is stable so the same set of attachments always produces the same
    /// command line.
    func testOrderIsStableAndFirstSeenWins() {
        XCTAssertEqual(
            AIService.attachmentDirectories([pasted, screenshot]),
            [
                "/Users/x/Library/Caches/Clippy/PastedAttachments",
                "/Users/x/Library/Caches/Clippy/ScreenContext"
            ]
        )
    }

    func testNoAttachmentsGrantsNothing() {
        XCTAssertTrue(AIService.attachmentDirectories([]).isEmpty)
    }

    /// Only the containing directories are granted — never a broad parent that
    /// would hand the CLI more of the filesystem than the request involves.
    func testGrantsOnlyTheContainingDirectories() {
        for directory in AIService.attachmentDirectories([screenshot, pasted]) {
            XCTAssertTrue(
                directory.hasPrefix("/Users/x/Library/Caches/Clippy/"),
                "unexpectedly broad grant: \(directory)"
            )
            XCTAssertNotEqual(directory, "/Users/x")
            XCTAssertNotEqual(directory, "/")
        }
    }

    /// Paths are normalised, so a traversal segment cannot smuggle in a
    /// different directory than the one the file actually lives in.
    func testPathsAreStandardised() {
        let messy = URL(fileURLWithPath: "/Users/x/Library/Caches/Clippy/ScreenContext/../ScreenContext/Screen-A.png")
        XCTAssertEqual(
            AIService.attachmentDirectories([messy]),
            ["/Users/x/Library/Caches/Clippy/ScreenContext"]
        )
    }
}
