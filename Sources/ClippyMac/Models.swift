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
