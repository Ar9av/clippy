import XCTest
@testable import ClippyCore

/// A finished CLI session is handed to Clippy as a file, so the summary is
/// waiting whether or not Clippy was running when the session ended.
final class SessionHandoffTests: XCTestCase {
    private var directory: URL!
    private var inbox: SessionHandoffInbox!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandoffTests-\(UUID().uuidString)")
        inbox = SessionHandoffInbox(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func handoff(
        id: String = "sess-1",
        summary: String = "Fixed the flaky test.",
        endedAt: Date = Date()
    ) -> SessionHandoff {
        SessionHandoff(
            id: id,
            projectPath: "/Users/x/projects/clippy",
            summary: summary,
            endedAt: endedAt
        )
    }

    func testAWrittenHandoffIsPendingAndSurvivesAFreshInbox() throws {
        try inbox.write(handoff())
        let reread = SessionHandoffInbox(directory: directory).pending()
        XCTAssertEqual(reread.count, 1)
        XCTAssertEqual(reread.first?.summary, "Fixed the flaky test.")
        XCTAssertEqual(reread.first?.projectName, "clippy")
    }

    /// Showing the same summary twice would be worse than not showing it, so
    /// consuming removes it.
    func testConsumingRemovesIt() throws {
        try inbox.write(handoff())
        inbox.consume(id: "sess-1")
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    func testNewestFirst() throws {
        let now = Date()
        try inbox.write(handoff(id: "old", endedAt: now.addingTimeInterval(-600)))
        try inbox.write(handoff(id: "new", endedAt: now))
        XCTAssertEqual(inbox.pending(now: now).map(\.id), ["new", "old"])
    }

    /// A session that ended while Clippy was closed for a day should not be
    /// announced as though it just happened.
    func testStaleHandoffsAreDroppedRatherThanAnnounced() throws {
        let now = Date()
        try inbox.write(handoff(id: "ancient", endedAt: now.addingTimeInterval(-60 * 60 * 24)))
        XCTAssertTrue(inbox.pending(now: now).isEmpty)
        // And cleaned up, not left to be re-examined forever.
        XCTAssertTrue(inbox.pending(now: now).isEmpty)
    }

    /// A half-written or hand-edited file would otherwise be retried on every
    /// look.
    func testUnreadableFilesAreDiscarded() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "not json".write(
            to: directory.appendingPathComponent("broken.json"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("broken.json").path)
        )
    }

    // MARK: - What the balloon says

    func testNotificationTextIsCondensedToALine() {
        let long = String(repeating: "Refactored the runner. ", count: 40)
        let text = handoff(summary: long).notificationText
        XCTAssertLessThanOrEqual(text.count, 161)
        XCTAssertFalse(text.contains("\n"))
    }

    /// A session with nothing to report still says something useful rather
    /// than showing an empty bubble.
    func testAnEmptySummaryFallsBackToTheProjectAndTool() {
        let text = handoff(summary: "   ").notificationText
        XCTAssertTrue(text.contains("Claude Code"), text)
        XCTAssertTrue(text.contains("clippy"), text)
    }

    /// The id is what `--resume` takes, so it must survive the round trip
    /// exactly.
    func testTheResumeIdentifierRoundTrips() throws {
        let original = handoff(id: "01936f2a-5a79-4142-966a-47a1da99c3bb")
        try inbox.write(original)
        XCTAssertEqual(inbox.pending().first?.id, original.id)
    }

    /// The hook writes ISO-8601 timestamps; decoding must accept them.
    func testDecodesTheShapeTheHookWrites() throws {
        let json = """
        {"id":"sess-9","provider":"claude","projectPath":"/Users/x/proj",
         "summary":"Did the thing.","endedAt":"2026-08-01T10:06:59Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionHandoff.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, "sess-9")
        XCTAssertEqual(decoded.provider, .claude)
        XCTAssertEqual(decoded.projectName, "proj")
    }
}

/// Clippy drives these CLIs itself, so its own calls end sessions too. Left
/// unfiltered, the hook reported Clippy's own queries back to Clippy — the
/// balloon announcing "Hey there! What can I help with?" as finished work.
final class InternalSessionFilterTests: XCTestCase {
    private var directory: URL!
    private var inbox: SessionHandoffInbox!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InternalFilter-\(UUID().uuidString)")
        inbox = SessionHandoffInbox(directory: directory)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func handoff(path: String) -> SessionHandoff {
        SessionHandoff(id: UUID().uuidString, projectPath: path, summary: "did a thing")
    }

    func testASessionFromARealProjectIsReported() throws {
        try inbox.write(handoff(path: "/Users/x/projects/clippy"))
        XCTAssertEqual(inbox.pending().count, 1)
    }

    /// Clippy runs the CLI with the temp directory as its working directory,
    /// which is how its own calls are recognisable after the fact.
    func testASessionFromATemporaryDirectoryIsNotReported() throws {
        let temporary = FileManager.default.temporaryDirectory.path
        try inbox.write(handoff(path: temporary))
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    func testTheUsualTemporaryLocationsAreAllRecognised() {
        for path in ["/var/folders/5c/abc/T/", "/private/var/folders/5c/abc/T/", "/tmp/x"] {
            XCTAssertTrue(
                handoff(path: path).ranInTemporaryDirectory,
                "\(path) should not be reported as a project"
            )
        }
        for path in ["/Users/x/projects/clippy", "/Users/x/Developer/app"] {
            XCTAssertFalse(handoff(path: path).ranInTemporaryDirectory, path)
        }
    }

    /// Filtered ones are deleted, not merely skipped, or they accumulate and
    /// are re-examined on every poll.
    func testFilteredSessionsAreCleanedUp() throws {
        try inbox.write(handoff(path: FileManager.default.temporaryDirectory.path))
        _ = inbox.pending()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(remaining.isEmpty, "left behind: \(remaining)")
    }
}

/// The floating balloon is narrow and wraps to a few lines before truncating
/// mid-word, so its line is much shorter than the full window's.
final class BalloonTextTests: XCTestCase {
    private func handoff(_ summary: String) -> SessionHandoff {
        SessionHandoff(id: "s", projectPath: "/Users/x/projects/clippy-mac", summary: summary)
    }

    /// However long the summary, the balloon line is the headline alone — a
    /// line cut mid-word reads worse than one that simply says what finished.
    func testBalloonLineNeverTruncatesHoweverLongTheSummaryIs() {
        for summary in [
            "short",
            "Fixed the session-handoff notification: it now renders in the floating balloon rather than only the expanded window.",
            String(repeating: "very long summary text ", count: 50)
        ] {
            let text = handoff(summary).balloonText
            XCTAssertEqual(text, "Claude Code finished in clippy-mac.", text)
            XCTAssertFalse(text.contains("…"), "balloon line must never be cut: \(text)")
        }
    }

    /// The balloon line is a strict subset of what the full window shows.
    func testBalloonLineIsShorterThanTheWindowLine() {
        let long = String(repeating: "refactored the runner ", count: 20)
        XCTAssertLessThan(
            handoff(long).balloonText.count,
            handoff(long).notificationText.count + 40
        )
    }

    func testAnEmptySummaryStillNamesTheProject() {
        let text = handoff("  ").balloonText
        XCTAssertEqual(text, "Claude Code finished in clippy-mac.")
    }
}
