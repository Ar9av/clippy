import Foundation

/// A user-defined slash command that expands to a longer prompt, so a request
/// you make often doesn't have to be retyped. Managed in Settings.
struct CustomPrompt: Identifiable, Codable, Hashable {
    var id: UUID
    /// The command word, without its leading slash, lowercased.
    var command: String
    /// What actually gets sent in place of the command.
    var prompt: String
    /// Also offer this prompt as a row in the floating balloon's menu, so it's
    /// one click away rather than something you have to remember to type.
    var showsInBalloon: Bool

    init(id: UUID = UUID(), command: String, prompt: String, showsInBalloon: Bool = false) {
        self.id = id
        self.command = CustomPrompt.normalize(command)
        self.prompt = prompt
        self.showsInBalloon = showsInBalloon
    }

    /// Hand-written so that prompts saved before `showsInBalloon` existed still
    /// decode. The synthesized version throws on a missing key rather than
    /// applying the default above, and the decode site uses `try?` — so a
    /// synthesized initializer here would silently wipe every saved prompt on
    /// the first launch after this field was added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        command = CustomPrompt.normalize(try container.decode(String.self, forKey: .command))
        prompt = try container.decode(String.self, forKey: .prompt)
        showsInBalloon = try container.decodeIfPresent(Bool.self, forKey: .showsInBalloon) ?? false
    }

    /// Commands are matched case-insensitively against a single leading token,
    /// so anything that would break that — spaces, a leading slash the user
    /// typed out of habit — is stripped rather than silently never matching.
    static func normalize(_ command: String) -> String {
        command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
            .drop(while: { $0 == "/" })
            .description
    }

    /// Label for this prompt's balloon row. The built-in rows read as short
    /// sentences, so the prompt's own opening words fit better there than the
    /// command would — truncated, since the balloon is narrow.
    var balloonTitle: String {
        let firstLine = prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = firstLine.isEmpty ? "/\(command)" : firstLine
        return label.count > 44 ? label.prefix(43).trimmingCharacters(in: .whitespaces) + "…" : label
    }

    var isValid: Bool {
        !command.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !CustomPrompt.reservedCommands.contains(command)
    }

    /// Built-ins can't be shadowed — a custom `/clear` that silently stopped
    /// clearing the chat would be worse than refusing to save it.
    static let reservedCommands: Set<String> = ["clear", "help"]
}

/// Result of interpreting a draft that begins with `/`.
enum SlashCommand: Equatable {
    /// Clear the conversation and start a fresh session.
    case clear
    /// Show the list of available commands.
    case help
    /// A custom prompt matched; send `text` instead of what was typed.
    case expanded(text: String)
    /// Started with `/` but matched nothing.
    case unknown(command: String)

    /// Parses `input` against `prompts`. Returns nil when the text isn't a
    /// command at all, so ordinary messages fall straight through.
    ///
    /// Anything typed after the command is appended to the expansion, which
    /// makes `/review this function` work as well as a bare `/review`.
    static func parse(_ input: String, prompts: [CustomPrompt]) -> SlashCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }

        let withoutSlash = trimmed.dropFirst()
        let split = withoutSlash.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let rawCommand = split.first else { return nil }
        let command = rawCommand.lowercased()
        let remainder = split.count > 1
            ? String(split[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        switch command {
        case "clear":
            return .clear
        case "help":
            return .help
        default:
            guard let match = prompts.first(where: { $0.command == command }) else {
                return .unknown(command: command)
            }
            let text = remainder.isEmpty ? match.prompt : "\(match.prompt)\n\n\(remainder)"
            return .expanded(text: text)
        }
    }

    /// The help text listing built-ins plus whatever the user has configured.
    static func helpText(prompts: [CustomPrompt]) -> String {
        var lines = [
            "**Commands**",
            "- `/clear` — clear the chat and start a new session",
            "- `/help` — show this list"
        ]
        if prompts.isEmpty {
            lines.append("")
            lines.append("No custom prompts yet. Add them in Settings ▸ Custom prompts.")
        } else {
            lines.append("")
            lines.append("**Your prompts**")
            for prompt in prompts.sorted(by: { $0.command < $1.command }) {
                let preview = prompt.prompt
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(70)
                lines.append("- `/\(prompt.command)` — \(preview)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
