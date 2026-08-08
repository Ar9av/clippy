import Foundation

/// One durable thing Clippy knows about the user, written as a standalone
/// sentence so it still makes sense months later with no surrounding chat.
struct MemoryFact: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var recorded: Date = Date()
}

/// Long-term memory, separate from the chat transcript on purpose: the
/// transcript is capped at the last 40 messages and archived away whenever a
/// chat is cleared, so anything the user said about themselves stopped
/// existing the moment they started a new conversation. Facts here survive
/// both, and are the only thing carried into a fresh chat.
///
/// Stored as JSON next to the transcript rather than in UserDefaults, for the
/// same reason `ChatStore` moved: this grows, and UserDefaults is for small
/// preference values.
enum MemoryStore {
    /// Enough to be useful, small enough that the whole set can go into every
    /// system prompt without meaningfully costing tokens or attention. Past
    /// this, the oldest fact is dropped.
    private static let limit = 40

    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("memory.json")
    }()

    static func load() -> [MemoryFact] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([MemoryFact].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ facts: [MemoryFact]) {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Records a fact unless an equivalent one is already known. The model is
    /// told not to repeat what it already knows, but it re-states facts
    /// anyway across long sessions, and forty copies of "the user's name is
    /// Arnav" would crowd out everything else — so dedupe here rather than
    /// trusting the instruction.
    @discardableResult
    static func remember(_ text: String) -> [MemoryFact] {
        var facts = load()
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return facts }
        let key = normalized(candidate)
        guard !facts.contains(where: { normalized($0.text) == key }) else { return facts }
        facts.append(MemoryFact(text: candidate))
        if facts.count > limit { facts.removeFirst(facts.count - limit) }
        save(facts)
        return facts
    }

    static func forget(id: UUID) -> [MemoryFact] {
        let facts = load().filter { $0.id != id }
        save(facts)
        return facts
    }

    static func forgetAll() {
        try? FileManager.default.removeItem(at: url)
    }

    /// The block handed to the model. Empty when nothing is known, so a fresh
    /// install doesn't ship a header with nothing under it — an empty
    /// "What you know about this user:" reads as "you know nothing about
    /// them", which is a slightly different and less useful claim.
    static func promptBlock(_ facts: [MemoryFact]) -> String {
        guard !facts.isEmpty else { return "" }
        let lines = facts.map { "- \($0.text)" }.joined(separator: "\n")
        return """
        What you know about this user, from earlier conversations:
        \(lines)

        Use this the way a colleague would — silently, to skip questions you already know the answer to. \
        Don't recite it back, don't thank them for it, and don't mention having a memory unless they ask.
        """
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
    }
}
