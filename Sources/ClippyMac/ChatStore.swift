import ClippyCore
import Foundation

/// Chat transcript and archive persistence — moved off UserDefaults, which
/// isn't meant for anything beyond small preference values, onto plain JSON
/// files in Application Support with atomic writes. Reads migrate a
/// pre-existing UserDefaults value exactly once, then remove the key so the
/// migration only ever runs a single time.
enum ChatStore {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static let messagesURL = directory.appendingPathComponent("messages.json")
    private static let historyURL = directory.appendingPathComponent("history.json")
    private static let pendingPlanURL = directory.appendingPathComponent("pendingPlan.json")

    /// Deletes both store files outright, as opposed to saving an empty
    /// array to them — an empty-but-present file still decodes successfully
    /// and would short-circuit the UserDefaults migration path in
    /// `loadMessages()`/`loadHistory()`. Test-only.
    static func resetForTesting() {
        try? FileManager.default.removeItem(at: messagesURL)
        try? FileManager.default.removeItem(at: historyURL)
        try? FileManager.default.removeItem(at: pendingPlanURL)
    }

    /// A plan awaiting "Run plan" confirmation is in-memory-only `@Published`
    /// state, but the chat message that introduced it (the model's own
    /// commentary, e.g. "Review and confirm to run it.") is a persisted
    /// `ChatMessage` — without this, quitting/relaunching mid-confirmation
    /// left that message sitting in the transcript with no plan left to
    /// confirm. Restored plans are still subject to the same staleness
    /// window `ChatViewModel` already applies to a live pending plan.
    static func loadPendingPlan() -> PendingScreenPlan? {
        decode(PendingScreenPlan.self, at: pendingPlanURL)
    }

    static func savePendingPlan(_ plan: PendingScreenPlan?) {
        guard let plan else {
            try? FileManager.default.removeItem(at: pendingPlanURL)
            return
        }
        encode(plan, to: pendingPlanURL)
    }

    static func loadMessages() -> [ChatMessage] {
        if let decoded = decode([ChatMessage].self, at: messagesURL) {
            return decoded
        }
        if let migrated = migrate([ChatMessage].self, userDefaultsKey: "messages", to: messagesURL) {
            return migrated
        }
        return []
    }

    static func saveMessages(_ messages: [ChatMessage]) {
        encode(Array(messages.suffix(100)), to: messagesURL)
    }

    static func loadHistory() -> [ArchivedChatSession] {
        if let decoded = decode([ArchivedChatSession].self, at: historyURL) {
            return decoded
        }
        if let migrated = migrate([ArchivedChatSession].self, userDefaultsKey: "chatHistory", to: historyURL) {
            return migrated
        }
        return []
    }

    static func saveHistory(_ sessions: [ArchivedChatSession]) {
        encode(sessions, to: historyURL)
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func migrate<T: Decodable>(_ type: T.Type, userDefaultsKey: String, to url: URL) -> T? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return nil
        }
        if let encodable = decoded as? Encodable {
            encode(AnyEncodable(encodable), to: url)
        }
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        return decoded
    }
}

/// Type-erased wrapper so `migrate`'s generic `Decodable` result (whose
/// concrete type is statically known at the call site, but not expressible
/// as `T: Encodable` without a second constraint on every caller) can still
/// be written back out with `JSONEncoder`.
private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeClosure = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
