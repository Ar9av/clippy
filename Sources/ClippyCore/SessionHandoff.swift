import Foundation

/// A finished coding session, handed from a CLI to Clippy so it can say what
/// happened and offer to pick the thread back up.
///
/// Deliberately a file dropped in a directory rather than a socket or a URL
/// scheme: the hook that writes it is a short shell script that must work
/// whether or not Clippy is running, and a file left on disk is exactly the
/// behaviour that wants — the summary is waiting the next time Clippy looks,
/// instead of being lost because nothing was listening.
public struct SessionHandoff: Identifiable, Codable, Equatable {
    public enum Provider: String, Codable, Equatable {
        case claude
        case codex

        public var displayName: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            }
        }
    }

    /// The CLI's own session identifier — what `--resume` takes.
    public var id: String
    public var provider: Provider
    /// Where the session was working, so resuming lands in the same place.
    public var projectPath: String
    /// A sentence or two about what happened, for the balloon.
    public var summary: String
    public var endedAt: Date

    public init(
        id: String,
        provider: Provider = .claude,
        projectPath: String,
        summary: String,
        endedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.projectPath = projectPath
        self.summary = summary
        self.endedAt = endedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? .claude
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt) ?? Date()
    }

    /// Whether this ran somewhere no real project lives.
    public var ranInTemporaryDirectory: Bool {
        let path = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        return path.hasPrefix(temporary) || path.hasPrefix("/private/var/folders")
            || path.hasPrefix("/var/folders") || path.hasPrefix("/tmp")
    }

    /// The last path component of the project, which is what a person calls it.
    public var projectName: String {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        return name.isEmpty ? "your project" : name
    }

    /// What the floating balloon says. Much shorter than `notificationText`:
    /// the balloon is narrow and wraps to a few lines before truncating
    /// mid-word, so the summary is cut to what actually fits beside the
    /// project name rather than spilling over.
    public var balloonText: String {
        // Headline only. Any amount of summary overflowed the balloon and got
        // cut mid-word, which reads worse than not showing it: the point of
        // this line is to say a session finished and which one, and the full
        // summary is a click away in the window. Never truncates.
        "\(provider.displayName) finished in \(projectName)."
    }

    /// What the full window says. Kept to roughly one line, since the compact
    /// balloon truncates anything longer anyway.
    public var notificationText: String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "\(provider.displayName) finished in \(projectName)."
        }
        return ResponsePresentation.compactText(trimmed, limit: 160)
    }
}

/// The directory the hook writes into and Clippy reads from.
///
/// The two ends are deliberately decoupled: a hook can drop a handoff while
/// Clippy is closed, and Clippy picks it up whenever it next looks.
public final class SessionHandoffInbox {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Alongside Clippy's other saved state, and the path the installed hook
    /// script writes to.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Clippy", isDirectory: true)
            .appendingPathComponent("SessionHandoffs", isDirectory: true)
    }

    /// A handoff older than this is stale — from a session that ended while
    /// Clippy was closed for a long time — and is dropped rather than
    /// announced as though it just happened.
    public static let maximumAge: TimeInterval = 60 * 60 * 12

    @discardableResult
    public func write(_ handoff: SessionHandoff) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(handoff.id).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(handoff).write(to: url, options: .atomic)
        return url
    }

    /// Everything waiting, newest first, with stale and unreadable entries
    /// cleaned up rather than returned.
    public func pending(now: Date = Date()) -> [SessionHandoff] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        var handoffs: [SessionHandoff] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let handoff = try? decoder.decode(SessionHandoff.self, from: data) else {
                // A truncated or hand-edited file would otherwise be retried
                // forever.
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard now.timeIntervalSince(handoff.endedAt) <= Self.maximumAge else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            // Nobody's project lives in a temp directory, so a session that
            // ran in one came from a tool driving the CLI rather than from
            // work worth reporting. Covers handoffs written before the hook
            // learned to skip them.
            guard !handoff.ranInTemporaryDirectory else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            handoffs.append(handoff)
        }
        return handoffs.sorted { $0.endedAt > $1.endedAt }
    }

    /// Removes a handoff once it has been shown, so the same session is not
    /// announced twice.
    public func consume(id: String) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(id).json")
        )
    }

    public func consumeAll() {
        for handoff in pending() { consume(id: handoff.id) }
    }
}
