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
