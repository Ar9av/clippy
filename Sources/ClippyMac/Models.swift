import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case claudeCLI
    case codexCLI
    case openAI
    case anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCLI: "Claude Code"
        case .codexCLI: "Codex"
        case .openAI: "OpenAI API"
        case .anthropic: "Anthropic API"
        }
    }

    var shortTitle: String {
        switch self {
        case .claudeCLI: "Claude"
        case .codexCLI: "Codex"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    var detail: String {
        switch self {
        case .claudeCLI:
            "Uses your locally installed and authenticated Claude Code CLI."
        case .codexCLI:
            "Uses your locally installed and authenticated Codex CLI in read-only mode."
        case .openAI:
            "Calls OpenAI directly with an API key stored in macOS Keychain."
        case .anthropic:
            "Calls Anthropic directly with an API key stored in macOS Keychain."
        }
    }

    var needsAPIKey: Bool {
        self == .openAI || self == .anthropic
    }

    var defaultModel: String {
        switch self {
        case .claudeCLI, .codexCLI: ""
        case .openAI: "gpt-4.1-mini"
        case .anthropic: "claude-sonnet-4-20250514"
        }
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let content: String
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

struct ArchivedChatSession: Identifiable, Codable, Equatable {
    let id: UUID
    let endedAt: Date
    let messages: [ChatMessage]

    init(id: UUID = UUID(), endedAt: Date = Date(), messages: [ChatMessage]) {
        self.id = id
        self.endedAt = endedAt
        self.messages = messages
    }

    var title: String {
        messages.first(where: { $0.role == .user })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init)
            ?? "Conversation"
    }

    var preview: String {
        let title = self.title
        return title.count > 80 ? String(title.prefix(80)) + "…" : title
    }
}

enum ScreenPlanAction: String, Codable {
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
}

/// The only keystrokes a plan may send. Anything that could submit, delete, or
/// confirm is absent by construction rather than filtered later.
enum ScreenPlanKey: String, Codable, CaseIterable {
    case tab
    case escape
    case up
    case down
    case left
    case right

    var displayName: String {
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
    var keyCode: UInt16 {
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
enum ScreenPlanStepStatus: String, Codable, Equatable {
    case pending
    case running
    case done
    case failed
    case skipped
}

struct ScreenPlanStep: Identifiable, Codable, Equatable {
    let id = UUID()
    let action: ScreenPlanAction
    let target: String?
    let text: String?
    let seconds: Double?
    let app: String?
    let key: ScreenPlanKey?
    /// Optional screen-point fallback for `.click` and `.type`: the exact
    /// pixel the model picked off the screenshot, in the same coordinate
    /// space as the frames in "Visible actionable controls". Used when
    /// accessibility-label matching would be unreliable — generic toolbar
    /// labels, custom-drawn controls, or a browser's address bar (whose
    /// exact AX label varies by version, and can collide with a page's own
    /// look-alike search box). Clippy clicks the exact point directly
    /// instead of resolving `target` through the accessibility tree.
    let x: Double?
    let y: Double?
    /// `.type` only, and only honored when `AutomationSafety` confirms this
    /// is text (a URL or a plain search query) typed into a browser's own
    /// address/search field — see `AutomationSafety.isSafeAddressBarSubmit`.
    /// Navigating or searching from that field isn't a "final action" the
    /// way sending, buying, or deleting is, so it's exempted from the
    /// no-Return rule on `ScreenPlanKey`, but only for exactly this case,
    /// not as a general submit key.
    let pressReturnAfter: Bool?

    init(
        action: ScreenPlanAction,
        target: String? = nil,
        text: String? = nil,
        seconds: Double? = nil,
        app: String? = nil,
        key: ScreenPlanKey? = nil,
        x: Double? = nil,
        y: Double? = nil,
        pressReturnAfter: Bool? = nil
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
    }

    var displayText: String {
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
        }
    }
}

struct PendingScreenPlan: Identifiable, Codable, Equatable {
    let id = UUID()
    let summary: String
    let steps: [ScreenPlanStep]
    /// When this plan was created — never decoded from a model response
    /// (the JSON never includes it); used to refuse confirming a plan that's
    /// sat around too long, rather than letting an old banner get triggered
    /// by an unrelated later "ok".
    var createdAt: Date = Date()
    /// Set once the plan has actually been run to completion, failure, or a
    /// stall. A plan that finished (in any of those ways) is kept visible so
    /// the user can see what happened, but must never be re-run — neither by
    /// the banner's "Run plan" button nor by a later affirmative message.
    var hasExecuted = false

    init(summary: String, steps: [ScreenPlanStep]) {
        self.summary = summary
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case steps
    }
}

enum ClippyError: LocalizedError {
    case missingCLI(String)
    case missingAPIKey(String)
    case emptyResponse
    case processFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
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
