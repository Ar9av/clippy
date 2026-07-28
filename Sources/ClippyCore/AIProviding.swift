import Foundation

/// A minimal, dependency-free JSON value used for tool schemas and tool
/// call input/output, so `CompletionRequest`/`CompletionResponse` can be
/// `Sendable` and `Equatable` without pulling in `[String: Any]`.
public indirect enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public var foundationValue: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(\.foundationValue)
        case .array(let value): value.map(\.foundationValue)
        case .null: NSNull()
        }
    }

    public init(foundationValue value: Any) {
        switch value {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as NSNumber:
            // NSNumber can box a Bool as well; Bool is checked above first.
            self = .number(value.doubleValue)
        case let value as [String: Any]: self = .object(value.mapValues { JSONValue(foundationValue: $0) })
        case let value as [Any]: self = .array(value.map { JSONValue(foundationValue: $0) })
        default: self = .null
        }
    }
}

/// One tool definition offered to the model, described as JSON Schema.
public struct ToolDefinition: Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// A single turn's content — a user/assistant message may carry any mix of
/// these blocks (an assistant turn that both explains and calls a tool, or a
/// user turn that both shows a screenshot and reports a tool's result).
public enum CompletionContentBlock: Equatable, Sendable {
    case text(String)
    case image(mediaType: String, base64: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

public struct CompletionMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }

    public let role: Role
    public let content: [CompletionContentBlock]

    public init(role: Role, content: [CompletionContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func text(_ role: Role, _ text: String) -> CompletionMessage {
        CompletionMessage(role: role, content: [.text(text)])
    }
}

public struct CompletionRequest: Sendable {
    public let system: String
    public let messages: [CompletionMessage]
    public let tools: [ToolDefinition]
    public let model: String
    public let maxTokens: Int

    public init(
        system: String,
        messages: [CompletionMessage],
        tools: [ToolDefinition] = [],
        model: String,
        maxTokens: Int = 8192
    ) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.model = model
        self.maxTokens = maxTokens
    }
}

public enum CompletionStopReason: String, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case toolUse = "tool_use"
    case stopSequence = "stop_sequence"
    case other
}

public struct CompletionUsage: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct CompletionResponse: Sendable {
    public let content: [CompletionContentBlock]
    public let stopReason: CompletionStopReason
    public let usage: CompletionUsage?

    public init(content: [CompletionContentBlock], stopReason: CompletionStopReason, usage: CompletionUsage?) {
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    /// Concatenates every text block — the common case for a plain-answer
    /// turn with no tool call.
    public var text: String {
        content.compactMap {
            if case .text(let value) = $0 { return value }
            return nil
        }.joined()
    }

    /// The first tool call, if the model made one. A response may in
    /// principle contain more than one; callers that need every call should
    /// filter `content` directly.
    public var firstToolUse: (id: String, name: String, input: JSONValue)? {
        for block in content {
            if case .toolUse(let id, let name, let input) = block {
                return (id, name, input)
            }
        }
        return nil
    }
}

/// Streaming events for a text-only turn (tool-use turns are always
/// requested via `complete(_:)`, since a caller needs the full parsed call
/// before it can act — there's nothing useful to show incrementally).
public enum CompletionEvent: Sendable {
    case textDelta(String)
    case completed(CompletionResponse)
}

public enum CompletionError: LocalizedError, Sendable {
    case missingAPIKey(String)
    case http(status: Int, message: String)
    case invalidResponse(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider): "Add your \(provider) API key in Settings first."
        case .http(let status, let message): "\(message) (HTTP \(status))"
        case .invalidResponse(let message): message
        case .transport(let message): message
        }
    }
}

/// A single point of variation between model providers: build a completion
/// request, get a response back (or stream it). `ScreenAgent` and the
/// `clippy-eval` harness are written against this protocol so they can run
/// against a real provider or a scripted mock interchangeably.
public protocol AIProviding: Sendable {
    var supportsVision: Bool { get }
    var supportsTools: Bool { get }
    func complete(_ request: CompletionRequest) async throws -> CompletionResponse
    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error>
}
