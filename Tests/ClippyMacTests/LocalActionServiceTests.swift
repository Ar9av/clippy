import XCTest
@testable import ClippyMac

final class LocalActionServiceTests: XCTestCase {
    /// Builds a small real directory tree containing a hyphenated component
    /// (mirroring "ar9av-portfolio" in this repo's own path) so the decoder
    /// is exercised against the filesystem it's meant to walk, not a mock.
    private func makeTempTree() throws -> (root: URL, encodedLeaf: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClippyDecoderTest-\(UUID().uuidString)")
        let nested = base.appendingPathComponent("my-project").appendingPathComponent("sub-dir")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        return (base, "\(base.path)/my-project/sub-dir".replacingOccurrences(of: "/", with: "-"))
    }

    func testDecodesAHyphenatedDirectoryNameCorrectly() throws {
        let (root, encoded) = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let decoded = LocalActionService.decodedClaudeProjectPath(from: encoded)
        XCTAssertEqual(decoded, "\(root.path)/my-project/sub-dir")
    }

    func testFallsBackToHomeDirectoryWhenNothingMatches() {
        let decoded = LocalActionService.decodedClaudeProjectPath(from: "-definitely-not-a-real-path-anywhere-xyz123")
        XCTAssertEqual(decoded, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func testDecodesASimpleNonHyphenatedPath() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClippyDecoderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let encoded = base.path.replacingOccurrences(of: "/", with: "-")
        XCTAssertEqual(LocalActionService.decodedClaudeProjectPath(from: encoded), base.path)
    }
}
