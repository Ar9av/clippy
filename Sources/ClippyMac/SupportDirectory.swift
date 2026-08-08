import Foundation

/// Where Clippy keeps everything it persists — the transcript, archived
/// chats, a pending plan, and long-term memory.
///
/// This exists because `ChatStore` and `MemoryStore` each resolved
/// Application Support themselves, which meant the test suite's cleanup
/// (`ChatStore.resetForTesting`, `MemoryStore.forgetAll`) deleted the real
/// user's chat history and memory every time anyone ran `swift test`. A test
/// run must not be able to destroy the data of the person running it, and
/// relying on every future test to remember to opt out is not a guard — so
/// the redirect happens here, once, for every store at the same time.
enum SupportDirectory {
    /// Set by tests that want an explicit location. Anything already resolved
    /// through `url(for:)` keeps its old path, so set this before first use.
    static var override: URL?

    /// True when running inside XCTest. Checked by class lookup rather than
    /// by an environment variable so it cannot be forgotten or mis-set: if
    /// the test runner is in the process, no store touches real data.
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    private static let testDirectory: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ClippyTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    static var base: URL {
        if let override { return override }
        if isRunningTests { return testDirectory }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
    }

    /// Resolves a file inside the support directory, creating the directory
    /// if it isn't there yet.
    static func url(for filename: String) -> URL {
        let directory = base
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename)
    }
}
