import Foundation

/// Talks to the Anthropic Messages API directly (not through a CLI). This is
/// the flagship path: tool use for structured screen actions (`ScreenAgent`),
/// real streaming for the plain-answer path, and a configurable `maxTokens`
/// instead of the 2048 that used to be hardcoded across every call.
public final class AnthropicClient: AIProviding {
    public static let defaultModel = "claude-opus-4-5-20251101"

    public let supportsVision = true
    public let supportsTools = true

    private let apiKey: String
    private let session: URLSession
    private let apiVersion: String
    private let baseURL: URL

    public init(
        apiKey: String,
        session: URLSession = .shared,
        apiVersion: String = "2023-06-01",
        baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    ) {
        self.apiKey = apiKey
        self.session = session
        self.apiVersion = apiVersion
        self.baseURL = baseURL
    }

    public func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        guard !apiKey.isEmpty else { throw CompletionError.missingAPIKey("Anthropic") }
        let urlRequest = try makeURLRequest(request, stream: false)
        let (data, response) = try await session.data(for: urlRequest)
        try Self.validate(response: response, data: data)
        return try Self.decodeResponse(data)
    }

    public func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw CompletionError.missingAPIKey("Anthropic") }
                    let urlRequest = try makeURLRequest(request, stream: true)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw CompletionError.invalidResponse("Anthropic did not return an HTTP response.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var errorBody = Data()
                        for try await byte in bytes { errorBody.append(byte) }
                        throw Self.httpError(status: http.statusCode, data: errorBody)
                    }
                    var accumulator = SSEAccumulator()
                    for try await line in bytes.lines {
                        if let event = accumulator.consume(line: line) {
                            continuation.yield(event)
                        }
                    }
                    if let final = accumulator.finish() {
                        continuation.yield(.completed(final))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Request construction

    private func makeURLRequest(_ request: CompletionRequest, stream: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": request.model.isEmpty ? Self.defaultModel : request.model,
            "max_tokens": request.maxTokens,
            "system": request.system,
            "messages": request.messages.map(Self.encodeMessage)
        ]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map(Self.encodeTool)
        }
        if stream {
            body["stream"] = true
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private static func encodeMessage(_ message: CompletionMessage) -> [String: Any] {
        [
            "role": message.role.rawValue,
            "content": message.content.map(encodeBlock)
        ]
    }

    private static func encodeBlock(_ block: CompletionContentBlock) -> [String: Any] {
        switch block {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let mediaType, let base64):
            return [
                "type": "image",
                "source": ["type": "base64", "media_type": mediaType, "data": base64]
            ]
        case .toolUse(let id, let name, let input):
            return ["type": "tool_use", "id": id, "name": name, "input": input.foundationValue]
        case .toolResult(let toolUseId, let content, let isError):
            var result: [String: Any] = ["type": "tool_result", "tool_use_id": toolUseId, "content": content]
            if isError { result["is_error"] = true }
            return result
        }
    }

    private static func encodeTool(_ tool: ToolDefinition) -> [String: Any] {
        [
            "name": tool.name,
            "description": tool.description,
            "input_schema": tool.inputSchema.foundationValue
        ]
    }

    // MARK: Response parsing

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CompletionError.invalidResponse("Anthropic did not return an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw httpError(status: http.statusCode, data: data)
        }
    }

    private static func httpError(status: Int, data: Data) -> CompletionError {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let message = error?["message"] as? String
        return .http(status: status, message: message ?? "Anthropic request failed.")
    }

    private static func decodeResponse(_ data: Data) throws -> CompletionResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CompletionError.invalidResponse("Anthropic returned an unfamiliar response.")
        }
        return try decodeMessage(json)
    }

    fileprivate static func decodeMessage(_ json: [String: Any]) throws -> CompletionResponse {
        guard let contentArray = json["content"] as? [[String: Any]] else {
            throw CompletionError.invalidResponse("Anthropic returned an unfamiliar response.")
        }
        let blocks: [CompletionContentBlock] = contentArray.compactMap { item in
            guard let type = item["type"] as? String else { return nil }
            switch type {
            case "text":
                guard let text = item["text"] as? String else { return nil }
                return .text(text)
            case "tool_use":
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                let input = JSONValue(foundationValue: item["input"] ?? [:])
                return .toolUse(id: id, name: name, input: input)
            default:
                return nil
            }
        }
        let stopReasonRaw = json["stop_reason"] as? String
        let stopReason = stopReasonRaw.flatMap(CompletionStopReason.init) ?? .other
        var usage: CompletionUsage?
        if let usageJSON = json["usage"] as? [String: Any],
           let input = usageJSON["input_tokens"] as? Int,
           let output = usageJSON["output_tokens"] as? Int {
            usage = CompletionUsage(inputTokens: input, outputTokens: output)
        }
        return CompletionResponse(content: blocks, stopReason: stopReason, usage: usage)
    }
}

/// Accumulates Anthropic's `message_start`/`content_block_start`/
/// `content_block_delta`/`content_block_stop`/`message_delta`/`message_stop`
/// SSE event sequence into content blocks, yielding a `.textDelta` for every
/// text delta as it arrives and a final `CompletionResponse` at
/// `message_stop`. Tool-use blocks are accumulated (their `partial_json` is
/// buffered) but not streamed incrementally — nothing meaningful to show a
/// user for a tool call in progress.
struct SSEAccumulator {
    private var currentEventName: String?
    private var dataLines: [String] = []

    private var blocks: [Int: PartialBlock] = [:]
    private var order: [Int] = []
    private var stopReason: CompletionStopReason = .other
    private var usage: CompletionUsage?

    private enum PartialBlock {
        case text(String)
        case toolUse(id: String, name: String, jsonBuffer: String)
    }

    mutating func consume(line: String) -> CompletionEvent? {
        if line.isEmpty {
            defer { currentEventName = nil; dataLines = [] }
            return dispatch(event: currentEventName, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix("event:") {
            currentEventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    mutating func finish() -> CompletionResponse? {
        buildResponse()
    }

    private mutating func dispatch(event: String?, data: String) -> CompletionEvent? {
        guard let event, !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            return nil
        }
        switch event {
        case "content_block_start":
            guard let index = json["index"] as? Int,
                  let block = json["content_block"] as? [String: Any],
                  let type = block["type"] as? String else { return nil }
            order.append(index)
            if type == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                blocks[index] = .toolUse(id: id, name: name, jsonBuffer: "")
            } else {
                blocks[index] = .text("")
            }
            return nil
        case "content_block_delta":
            guard let index = json["index"] as? Int, let delta = json["delta"] as? [String: Any] else { return nil }
            let deltaType = delta["type"] as? String
            if deltaType == "text_delta", let text = delta["text"] as? String {
                if case .text(let existing) = blocks[index] {
                    blocks[index] = .text(existing + text)
                }
                return .textDelta(text)
            }
            if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                if case .toolUse(let id, let name, let buffer) = blocks[index] {
                    blocks[index] = .toolUse(id: id, name: name, jsonBuffer: buffer + partial)
                }
            }
            return nil
        case "message_delta":
            if let delta = json["delta"] as? [String: Any],
               let reasonRaw = delta["stop_reason"] as? String {
                stopReason = CompletionStopReason(rawValue: reasonRaw) ?? .other
            }
            if let usageJSON = json["usage"] as? [String: Any],
               let output = usageJSON["output_tokens"] as? Int {
                usage = CompletionUsage(inputTokens: usage?.inputTokens ?? 0, outputTokens: output)
            }
            return nil
        case "message_start":
            if let message = json["message"] as? [String: Any],
               let usageJSON = message["usage"] as? [String: Any],
               let input = usageJSON["input_tokens"] as? Int {
                usage = CompletionUsage(inputTokens: input, outputTokens: 0)
            }
            return nil
        default:
            return nil
        }
    }

    private func buildResponse() -> CompletionResponse? {
        guard !order.isEmpty else { return nil }
        let content: [CompletionContentBlock] = order.compactMap { index in
            switch blocks[index] {
            case .text(let text):
                return .text(text)
            case .toolUse(let id, let name, let jsonBuffer):
                let data = jsonBuffer.isEmpty ? Data("{}".utf8) : Data(jsonBuffer.utf8)
                let object = (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
                return .toolUse(id: id, name: name, input: JSONValue(foundationValue: object))
            case nil:
                return nil
            }
        }
        return CompletionResponse(content: content, stopReason: stopReason, usage: usage)
    }
}
