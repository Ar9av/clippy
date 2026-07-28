import XCTest
@testable import ClippyCore
@testable import ClippyMac

final class ChatStoreTests: XCTestCase {
    private let messagesKey = "messages"
    private let historyKey = "chatHistory"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: messagesKey)
        UserDefaults.standard.removeObject(forKey: historyKey)
        ChatStore.resetForTesting()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: messagesKey)
        UserDefaults.standard.removeObject(forKey: historyKey)
        ChatStore.resetForTesting()
        super.tearDown()
    }

    func testMessagesRoundTripThroughFiles() {
        let messages = [
            ChatMessage(role: .user, content: "hello"),
            ChatMessage(role: .assistant, content: "hi there")
        ]
        ChatStore.saveMessages(messages)
        let loaded = ChatStore.loadMessages()
        XCTAssertEqual(loaded.map(\.content), messages.map(\.content))
        XCTAssertEqual(loaded.map(\.role), messages.map(\.role))
    }

    func testHistoryRoundTripsThroughFiles() {
        let session = ArchivedChatSession(messages: [ChatMessage(role: .user, content: "old chat")])
        ChatStore.saveHistory([session])
        let loaded = ChatStore.loadHistory()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.messages.first?.content, "old chat")
    }

    func testMessagesMigrateFromUserDefaultsOnce() throws {
        let legacyMessages = [ChatMessage(role: .user, content: "from user defaults")]
        let data = try JSONEncoder().encode(legacyMessages)
        UserDefaults.standard.set(data, forKey: messagesKey)

        let loaded = ChatStore.loadMessages()
        XCTAssertEqual(loaded.first?.content, "from user defaults")
        // The key must be cleared so migration only ever runs once.
        XCTAssertNil(UserDefaults.standard.data(forKey: messagesKey))
        // And the file must now hold it, independent of UserDefaults.
        XCTAssertEqual(ChatStore.loadMessages().first?.content, "from user defaults")
    }

    func testEmptySavedMessagesDoNotOverwriteExistingTranscriptOnLoad() {
        // loadMessages() returning [] must not be treated by callers as
        // "clear the transcript" — ChatViewModel.loadMessages() specifically
        // guards on this. Verify the store itself faithfully returns empty
        // when nothing was ever saved.
        XCTAssertTrue(ChatStore.loadMessages().isEmpty)
    }
}
