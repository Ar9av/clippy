import Foundation

public enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case claudeCLI
    case codexCLI
    case openAI
    case anthropic
    case local

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCLI: "Claude Code"
        case .codexCLI: "Codex"
        case .openAI: "OpenAI API"
        case .anthropic: "Anthropic API"
        case .local: "Local Model"
        }
    }

    public var shortTitle: String {
        switch self {
        case .claudeCLI: "Claude"
        case .codexCLI: "Codex"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .local: "your local model"
        }
    }

    public var detail: String {
        switch self {
        case .claudeCLI:
            "Uses your locally installed and authenticated Claude Code CLI."
        case .codexCLI:
            "Uses your locally installed and authenticated Codex CLI in read-only mode."
        case .openAI:
            "Calls OpenAI directly with an API key stored in macOS Keychain."
        case .anthropic:
            "Calls Anthropic directly with an API key stored in macOS Keychain."
        case .local:
            "Calls an OpenAI-compatible local server — Ollama, LM Studio, or llama.cpp's server — running on your Mac. No API key, no data leaves your machine."
        }
    }

    public var needsAPIKey: Bool {
        self == .openAI || self == .anthropic
    }

    /// `.local` needs configuration too — a server URL and a model name —
    /// just not a Keychain-stored API key. Kept distinct from `needsAPIKey`
    /// so the Settings UI can show the right fields for each.
    public var needsLocalServerConfig: Bool {
        self == .local
    }

    public var defaultModel: String {
        switch self {
        case .claudeCLI, .codexCLI: ""
        case .openAI: "gpt-4.1-mini"
        case .anthropic: "claude-sonnet-4-20250514"
        case .local: ""
        }
    }

    /// Default base URL offered for `.local` — Ollama's own OpenAI-compatible
    /// endpoint, the most common local runner. LM Studio and llama.cpp's
    /// `llama-server` both expose the same `/v1/chat/completions` shape on a
    /// different default port, so this is a starting point, not a constant.
    public static let defaultLocalBaseURL = "http://localhost:11434/v1"
}

public struct ChatMessage: Identifiable, Codable, Equatable {
    public enum Role: String, Codable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    /// `var`, not `let` — the streaming path mutates a message's content
    /// in place as text deltas arrive, rather than replacing the message.
    public var content: String
    public let createdAt: Date

    public init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct ArchivedChatSession: Identifiable, Codable, Equatable {
    public let id: UUID
    public let endedAt: Date
    public let messages: [ChatMessage]

    public init(id: UUID = UUID(), endedAt: Date = Date(), messages: [ChatMessage]) {
        self.id = id
        self.endedAt = endedAt
        self.messages = messages
    }

    public var title: String {
        messages.first(where: { $0.role == .user })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init)
            ?? "Conversation"
    }

    public var preview: String {
        let title = self.title
        return title.count > 80 ? String(title.prefix(80)) + "…" : title
    }
}

public enum ScreenPlanAction: String, Codable {
    case click
    case type
    case wait
    /// Bring another app to the front so later steps act on its windows.
    case open
    /// Press one navigation key. Deliberately excludes Return: Clippy moves
    /// through an interface but never commits the form at the end of it.
    /// The one exception is `ScreenPlanStep.pressReturnAfter` on a `.type`
    /// step — submitting a browser's own address/search field, gated by
    /// `AutomationSafety.isSafeAddressBarSubmit` — which is a distinct,
    /// narrowly-validated path, not a general key.
    case key
    /// Scroll the content under a point. Without this, anything below the
    /// fold is permanently unreachable: an accessibility scan only reports
    /// what's currently on screen, so a control the user would find by
    /// scrolling simply never appears in "Visible actionable controls" and
    /// the agent concludes the target doesn't exist. Arrow keys are not a
    /// substitute — they move focus or a caret, and most web and Electron
    /// views ignore them entirely unless something inside is already focused.
    case scroll
}

/// Which way the content moves under a `.scroll` step. Named for the
/// direction the *content* travels, matching how a person describes it:
/// "scroll down" reveals what was below the fold.
public enum ScreenScrollDirection: String, Codable, CaseIterable {
    case up
    case down
    case left
    case right

    public var displayName: String {
        switch self {
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        }
    }

    /// Per-tick scroll deltas in the sign convention of
    /// `CGEvent(scrollWheelEvent2Source:)`: positive vertical scrolls the
    /// content up (revealing what's above), positive horizontal scrolls left.
    public var unitDelta: (vertical: Int32, horizontal: Int32) {
        switch self {
        case .up: (1, 0)
        case .down: (-1, 0)
        case .left: (0, 1)
        case .right: (0, -1)
        }
    }
}

/// The only keystrokes a plan may send. Anything that could submit, delete, or
/// confirm is absent by construction rather than filtered later.
public enum ScreenPlanKey: String, Codable, CaseIterable {
    case tab
    case escape
    case up
    case down
    case left
    case right

    public var displayName: String {
        switch self {
        case .tab: "Tab"
        case .escape: "Escape"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .left: "Left arrow"
        case .right: "Right arrow"
        }
    }

    /// Virtual key codes, from `Carbon/Events.h`.
    public var keyCode: UInt16 {
        switch self {
        case .tab: 48
        case .escape: 53
        case .left: 123
        case .right: 124
        case .down: 125
        case .up: 126
        }
    }
}

/// Where a step got to. Drives the live checklist in the plan banner, so a
/// long sequence shows what already ran and exactly where it stopped.
public enum ScreenPlanStepStatus: String, Codable, Equatable {
    case pending
    case running
    case done
    case failed
    case skipped
}

public struct ScreenPlanStep: Identifiable, Codable, Equatable {
    public let id = UUID()
    public let action: ScreenPlanAction
    public let target: String?
    public let text: String?
    public let seconds: Double?
    public let app: String?
    public let key: ScreenPlanKey?
    /// Optional screen-point fallback for `.click` and `.type`: the exact
    /// pixel the model picked off the screenshot, in the same coordinate
    /// space as the frames in "Visible actionable controls". Used when
    /// accessibility-label matching would be unreliable — generic toolbar
    /// labels, custom-drawn controls, or a browser's address bar (whose
    /// exact AX label varies by version, and can collide with a page's own
    /// look-alike search box). Clippy clicks the exact point directly
    /// instead of resolving `target` through the accessibility tree.
    public let x: Double?
    public let y: Double?
    /// `.type` only, and only honored when `AutomationSafety` confirms this
    /// is text (a URL or a plain search query) typed into a browser's own
    /// address/search field — see `AutomationSafety.isSafeAddressBarSubmit`.
    /// Navigating or searching from that field isn't a "final action" the
    /// way sending, buying, or deleting is, so it's exempted from the
    /// no-Return rule on `ScreenPlanKey`, but only for exactly this case,
    /// not as a general submit key.
    public let pressReturnAfter: Bool?
    /// `.scroll` only — which way the content should move.
    public let direction: ScreenScrollDirection?
    /// `.scroll` only — how many wheel ticks to send, clamped by
    /// `ScreenPlanRunner.scrollTickRange`. Defaults to
    /// `ScreenPlanRunner.defaultScrollTicks` (roughly one comfortable
    /// flick) when the model doesn't say.
    public let amount: Double?

    public init(
        action: ScreenPlanAction,
        target: String? = nil,
        text: String? = nil,
        seconds: Double? = nil,
        app: String? = nil,
        key: ScreenPlanKey? = nil,
        x: Double? = nil,
        y: Double? = nil,
        pressReturnAfter: Bool? = nil,
        direction: ScreenScrollDirection? = nil,
        amount: Double? = nil
    ) {
        self.action = action
        self.target = target
        self.text = text
        self.seconds = seconds
        self.app = app
        self.key = key
        self.x = x
        self.y = y
        self.pressReturnAfter = pressReturnAfter
        self.direction = direction
        self.amount = amount
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case target
        case text
        case seconds
        case app
        case key
        case x
        case y
        case pressReturnAfter
        case direction
        case amount
    }

    /// Hand-written purely so an unrecognised `key` or `direction` decodes to
    /// `nil` instead of throwing.
    ///
    /// The CLI providers hand back free-text JSON with no server-side schema
    /// to enforce the enum, so a plausible near-miss ("downward", "pagedown")
    /// is a question of when, not if. With the synthesized decoder that threw
    /// on the whole container, one bad value on step 5 destroyed steps 1-4
    /// too — and destroyed them at parse time, where `screenPlan(from:)` just
    /// returns nil and the response falls through as ordinary prose with no
    /// indication a plan was ever meant. Decoding leniently leaves
    /// `ScreenPlanRunner.validate` as the single place a step is rejected,
    /// which fails loudly, names the step, and keeps the rest of the plan
    /// intact. It is never more permissive: a step that needs a key or a
    /// direction and hasn't got one still can't run.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(ScreenPlanAction.self, forKey: .action)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        seconds = try container.decodeIfPresent(Double.self, forKey: .seconds)
        app = try container.decodeIfPresent(String.self, forKey: .app)
        x = try container.decodeIfPresent(Double.self, forKey: .x)
        y = try container.decodeIfPresent(Double.self, forKey: .y)
        pressReturnAfter = try container.decodeIfPresent(Bool.self, forKey: .pressReturnAfter)
        amount = try container.decodeIfPresent(Double.self, forKey: .amount)
        key = try container.decodeIfPresent(String.self, forKey: .key)
            .flatMap(ScreenPlanKey.init(rawValue:))
        direction = try container.decodeIfPresent(String.self, forKey: .direction)
            .flatMap(ScreenScrollDirection.init(rawValue:))
    }

    public var displayText: String {
        switch action {
        case .click:
            "Click “\(target ?? "control")”"
        case .type:
            "Put “\(text ?? "")” into “\(target ?? "field")”"
        case .wait:
            "Wait \(String(format: "%.1f", seconds ?? 0.8)) seconds"
        case .open:
            "Switch to \(app ?? "the app")"
        case .key:
            "Press \(key?.displayName ?? "a key")"
        case .scroll:
            "Scroll \(direction?.displayName ?? "down")\(target.map { " in “\($0)”" } ?? "")"
        }
    }
}

public struct PendingScreenPlan: Identifiable, Codable, Equatable {
    public let id = UUID()
    public let summary: String
    public let steps: [ScreenPlanStep]
    /// When this plan was created — never decoded from a model response
    /// (the JSON never includes it); used to refuse confirming a plan that's
    /// sat around too long, rather than letting an old banner get triggered
    /// by an unrelated later "ok".
    public var createdAt: Date = Date()
    /// Set once the plan has actually been run to completion, failure, or a
    /// stall. A plan that finished (in any of those ways) is kept visible so
    /// the user can see what happened, but must never be re-run — neither by
    /// the banner's "Run plan" button nor by a later affirmative message.
    public var hasExecuted = false

    public init(summary: String, steps: [ScreenPlanStep]) {
        self.summary = summary
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case steps
    }
}

public enum ClippyError: LocalizedError {
    case missingCLI(String)
    case missingAPIKey(String)
    case emptyResponse
    case processFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingCLI(let name):
            "\(name) is not installed or could not be found. Install it, sign in from Terminal, then try again."
        case .missingAPIKey(let provider):
            "Add your \(provider) API key in Settings first."
        case .emptyResponse:
            "The provider returned an empty response."
        case .processFailed(let detail), .invalidResponse(let detail):
            detail
        }
    }
}
