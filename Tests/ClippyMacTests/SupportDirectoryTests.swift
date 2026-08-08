import XCTest
@testable import ClippyMac

/// Found by running the suite and then looking at what was left in
/// `~/Library/Application Support/Clippy`: nothing. Both stores resolved the
/// real directory, and the suite's own cleanup deleted the transcript,
/// archived chats and memory of whoever ran `swift test`.
final class SupportDirectoryTests: XCTestCase {
    /// Its own directory, not the shared per-process one. These tests write
    /// the same `memory.json` that `MemoryStoreTests` does, and two suites
    /// mutating one file is how a suite becomes order-dependent.
    private var previousOverride: URL?

    override func setUp() {
        super.setUp()
        previousOverride = SupportDirectory.override
        SupportDirectory.override = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClippySupportDirectoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory = SupportDirectory.override {
            try? FileManager.default.removeItem(at: directory)
        }
        SupportDirectory.override = previousOverride
        super.tearDown()
    }

    /// The guard is "are we inside XCTest", so this test asserting it holds
    /// is the guard testing itself — which is the point: if the detection
    /// ever breaks, this fails long before anyone loses data.
    /// With no override in play — the state a plain `swift test` runs in —
    /// the base must still not be the real directory.
    func testStoresNeverResolveTheRealDirectoryUnderTest() {
        let override = SupportDirectory.override
        SupportDirectory.override = nil
        defer { SupportDirectory.override = override }

        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
        XCTAssertNotEqual(SupportDirectory.base.standardizedFileURL, real.standardizedFileURL)
        XCTAssertTrue(SupportDirectory.base.path.contains("ClippyTests-"))
    }

    /// Writing through a store's real API must land in the redirected
    /// directory, not merely resolve to it.
    func testEveryStoreSharesTheRedirect() {
        MemoryStore.remember("isolation probe")
        ChatStore.saveMessages([])
        let contents = try? FileManager.default.contentsOfDirectory(atPath: SupportDirectory.base.path)
        XCTAssertEqual(contents?.contains("memory.json"), true)
        XCTAssertEqual(contents?.contains("messages.json"), true)
    }

    /// The stores resolve their paths per call, so an override set after they
    /// were first touched still takes effect.
    func testAnOverrideSetAfterFirstUseStillApplies() {
        MemoryStore.remember("first directory")
        let moved = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClippyMoved-\(UUID().uuidString)", isDirectory: true)
        SupportDirectory.override = moved
        defer { try? FileManager.default.removeItem(at: moved) }

        XCTAssertTrue(MemoryStore.load().isEmpty, "the new directory starts empty")
        MemoryStore.remember("second directory")
        XCTAssertEqual(MemoryStore.load().map(\.text), ["second directory"])
    }
}
