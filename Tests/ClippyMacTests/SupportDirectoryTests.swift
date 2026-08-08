import XCTest
@testable import ClippyMac

/// Found by running the suite and then looking at what was left in
/// `~/Library/Application Support/Clippy`: nothing. Both stores resolved the
/// real directory, and the suite's own cleanup deleted the transcript,
/// archived chats and memory of whoever ran `swift test`.
final class SupportDirectoryTests: XCTestCase {
    /// The guard is "are we inside XCTest", so this test asserting it holds
    /// is the guard testing itself — which is the point: if the detection
    /// ever breaks, this fails long before anyone loses data.
    func testStoresNeverResolveTheRealDirectoryUnderTest() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
        XCTAssertNotEqual(SupportDirectory.base.standardizedFileURL, real.standardizedFileURL)
        XCTAssertTrue(SupportDirectory.base.path.contains("ClippyTests-"))
    }

    func testEveryStoreSharesTheRedirect() {
        // Writing through the real API must land in the test directory, not
        // just the resolved base path.
        MemoryStore.remember("isolation probe")
        let contents = try? FileManager.default.contentsOfDirectory(atPath: SupportDirectory.base.path)
        XCTAssertEqual(contents?.contains("memory.json"), true)
        MemoryStore.forgetAll()
    }

    func testAnExplicitOverrideWins() {
        let previous = SupportDirectory.override
        defer { SupportDirectory.override = previous }
        let custom = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-override-test")
        SupportDirectory.override = custom
        XCTAssertEqual(SupportDirectory.base, custom)
        XCTAssertEqual(SupportDirectory.url(for: "x.json").deletingLastPathComponent(), custom)
    }
}
