import AppKit
import Foundation

/// A user-defined slash command that expands to a longer prompt, so a request
/// you make often doesn't have to be retyped. Managed in Settings.
struct CustomPrompt: Identifiable, Codable, Hashable {
    static let defaultTerminalActionID = UUID(uuidString: "8B505324-78D4-4AE5-A317-3FBFC2CFEA65")!

    static var defaultTerminalAction: CustomPrompt {
        CustomPrompt(
            id: defaultTerminalActionID,
            command: "command",
            prompt: "Convert the spoken request into one safe executable shell command for the current terminal. Return only the command and never run it.",
            voiceShortcut: DictationShortcut(
                keyCode: 49,
                modifiersRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue,
                keyDisplay: "Space"
            ),
            voiceOutputKey: "command"
        )
    }

    var id: UUID
    /// The command word, without its leading slash, lowercased.
    var command: String
    /// What actually gets sent in place of the command.
    var prompt: String
    /// Also offer this prompt as a row in the floating balloon's menu, so it's
    /// one click away rather than something you have to remember to type.
    var showsInBalloon: Bool
    /// Optional hold-to-talk binding. When present, the spoken text is passed
    /// through this prompt and the selected JSON value is inserted into the
    /// previously focused app without submitting it.
    var voiceShortcut: DictationShortcut?
    var voiceOutputKey: String

    init(
        id: UUID = UUID(),
        command: String,
        prompt: String,
        showsInBalloon: Bool = false,
        voiceShortcut: DictationShortcut? = nil,
        voiceOutputKey: String = "result"
    ) {
        self.id = id
        self.command = CustomPrompt.normalize(command)
        self.prompt = prompt
        self.showsInBalloon = showsInBalloon
        self.voiceShortcut = voiceShortcut
        self.voiceOutputKey = voiceOutputKey
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
        voiceShortcut = try container.decodeIfPresent(DictationShortcut.self, forKey: .voiceShortcut)
        voiceOutputKey = try container.decodeIfPresent(String.self, forKey: .voiceOutputKey) ?? "result"
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

    var hasVoiceAction: Bool {
        voiceShortcut != nil && isValid
    }

    /// Terminal actions need stronger output handling than general rewriting:
    /// spoken "git" is commonly heard as "get" or "good", and explanatory
    /// prose pasted at a shell prompt is both useless and potentially unsafe.
    var isShellCommandVoiceAction: Bool {
        let context = "\(command) \(prompt)".lowercased()
        return ["terminal", "shell", "command line", "command-line", "cli command"]
            .contains { context.contains($0) }
    }

    static func normalizeVoiceOutputKey(_ key: String) -> String {
        String(key.filter { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    static func extractedVoiceValue(from response: String, key: String) throws -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String?
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last {
            jsonText = String(trimmed[first...last])
        } else {
            jsonText = nil
        }
        if let jsonText,
           let data = jsonText.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let value = object[key] {
                if let string = value as? String { return string }
                if let number = value as? NSNumber { return number.stringValue }
                throw VoiceActionError.nonScalarOutput(key)
            }
            // Older saved prompts may name a different field. If the model
            // still returns a one-field object, the sole scalar value is
            // unambiguous and is safer than inserting raw JSON.
            if object.count == 1, let value = object.values.first {
                if let string = value as? String { return string }
                if let number = value as? NSNumber { return number.stringValue }
            }
            throw VoiceActionError.missingOutputKey(key)
        }

        // Most providers follow the fast path and return plain text. Also
        // accept a fenced value because smaller local models occasionally add
        // one despite being told not to; only the fence is removed.
        if trimmed.hasPrefix("```"), trimmed.hasSuffix("```") {
            var lines = trimmed.components(separatedBy: .newlines)
            if !lines.isEmpty { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            let value = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        guard !trimmed.isEmpty else { throw VoiceActionError.emptyOutput }
        return trimmed
    }

    static func extractedShellCommand(from response: String, key: String) throws -> String {
        let value = try extractedVoiceValue(from: response, key: key)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer an explicit fenced command block when one exists inside a
        // verbose answer. This also handles ```sh and ```bash fences.
        if let opening = value.range(of: #"```(?:bash|sh|zsh)?\s*"#, options: .regularExpression),
           let closing = value.range(of: "```", range: opening.upperBound..<value.endIndex) {
            let command = value[opening.upperBound..<closing.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty { return command }
        }

        // Smaller models sometimes explain themselves but put the actual
        // command in an inline code span. In the reported failure this turns
        // the whole paragraph containing `git pull` into exactly "git pull".
        if let regex = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#) {
            let range = NSRange(value.startIndex..., in: value)
            let candidates = regex.matches(in: value, range: range).compactMap { match -> String? in
                guard let swiftRange = Range(match.range(at: 1), in: value) else { return nil }
                let candidate = String(value[swiftRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return looksLikeShellCommand(candidate) ? candidate : nil
            }
            if let command = candidates.last { return command }
        }

        let lines = value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.count == 1 {
            let command = lines[0].hasPrefix("$ ") ? String(lines[0].dropFirst(2)) : lines[0]
            guard looksLikeShellCommand(command) else { throw VoiceActionError.invalidShellCommand }
            return command
        }
        let commandLines = lines.compactMap { line -> String? in
            let candidate = line.hasPrefix("$ ") ? String(line.dropFirst(2)) : line
            return looksLikeShellCommand(candidate) ? candidate : nil
        }
        guard !commandLines.isEmpty else { throw VoiceActionError.invalidShellCommand }
        return commandLines.joined(separator: "\n")
    }

    /// Resolve the short, common command that exposed the STT ambiguity
    /// without spending a model round trip. Keep this intentionally narrow:
    /// requests containing a remote, branch, or other arguments still go to
    /// the configured prompt so those details are not discarded.
    static func obviousShellCommand(from transcript: String) -> String? {
        let words = transcript.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let gitWords: Set<String> = ["git", "get", "good"]
        let ignored: Set<String> = [
            "can", "could", "you", "please", "take", "a", "do", "run", "make", "me", "the"
        ]
        let meaningful = words.filter { !ignored.contains($0) }
        guard meaningful.count == 2,
              gitWords.contains(meaningful[0]),
              meaningful[1] == "pull" else { return nil }
        return "git pull"
    }

    private static func looksLikeShellCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return false }
        let first = trimmed.split(whereSeparator: \Character.isWhitespace).first.map(String.init) ?? ""
        let executable = first.hasPrefix("./")
            || first.hasPrefix("/")
            || first.range(of: #"^[A-Za-z0-9_.+-]+$"#, options: .regularExpression) != nil
        let prosePrefixes = ["i ", "if ", "this ", "that ", "the ", "you ", "here ", "sure ", "note "]
        let capitalizedProse = first.first?.isUppercase == true && !first.contains("=")
        return executable && !capitalizedProse
            && !prosePrefixes.contains { trimmed.lowercased().hasPrefix($0) }
    }

    /// Built-ins can't be shadowed — a custom `/clear` that silently stopped
    /// clearing the chat would be worse than refusing to save it.
    static let reservedCommands: Set<String> = ["clear", "help"]
}

enum VoiceActionError: LocalizedError {
    case alreadyRunning
    case invalidOutputKey
    case emptyOutput
    case invalidShellCommand
    case missingOutputKey(String)
    case nonScalarOutput(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Another voice action is still running."
        case .invalidOutputKey: "Choose a JSON field name using letters, numbers, or underscores."
        case .emptyOutput: "The voice action returned no text."
        case .invalidShellCommand: "The model did not return a usable terminal command. Nothing was inserted."
        case .missingOutputKey(let key): "The voice action response did not contain “\(key)”."
        case .nonScalarOutput(let key): "The “\(key)” value must be text or a number."
        }
    }
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
