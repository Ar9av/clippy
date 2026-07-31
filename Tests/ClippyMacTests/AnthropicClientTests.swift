import XCTest
@testable import ClippyCore

/// Intercepts every request made through a `URLSession` configured with it,
/// so `AnthropicClient` can be tested end-to-end (request construction,
/// response parsing, SSE stream parsing) without any network access.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    /// Set by each test right before making a request. Not thread-hopped —
    /// tests run serially against a single client instance.
    nonisolated(unsafe) static var stub: Stub?
    nonisolated(unsafe) static var capturedRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let bodyStream = request.httpBodyStream {
            bodyStream.open()
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while bodyStream.hasBytesAvailable {
                let read = bodyStream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            bodyStream.close()
            Self.capturedRequestBody = data
        } else {
            Self.capturedRequestBody = request.httpBody
        }

        guard let stub = Self.stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class AnthropicClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.stub = nil
        MockURLProtocol.capturedRequestBody = nil
        super.tearDown()
    }

    private func jsonBody() -> [String: Any] {
        guard let data = MockURLProtocol.capturedRequestBody,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("no captured request body")
            return [:]
        }
        return json
    }

    func testCompleteSendsToolsAndSystemPromptAndParsesTextResponse() async throws {
        let responseJSON: [String: Any] = [
            "content": [["type": "text", "text": "Hello there"]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 10, "output_tokens": 5]
        ]
        MockURLProtocol.stub = MockURLProtocol.Stub(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: responseJSON)
        )
        let client = AnthropicClient(apiKey: "test-key", session: MockURLProtocol.makeSession())
        let request = CompletionRequest(
            system: "You are Clippy.",
            messages: [.text(.user, "hi")],
            tools: [ToolDefinition(name: "task_complete", description: "done", inputSchema: .object(["type": .string("object")]))],
            model: "claude-opus-4-5-20251101"
        )
        let response = try await client.complete(request)
        XCTAssertEqual(response.text, "Hello there")
        XCTAssertEqual(response.stopReason, .endTurn)
        XCTAssertEqual(response.usage, CompletionUsage(inputTokens: 10, outputTokens: 5))

        let body = jsonBody()
        // The system prompt goes as a block array, not a bare string, so it can
        // carry a cache breakpoint.
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.first?["text"] as? String, "You are Clippy.")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(body["stream"])
    }

    // MARK: - Prompt caching

    private func lastContentBlock(of body: [String: Any]) throws -> [String: Any] {
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        return try XCTUnwrap(content.last)
    }

    private func stubEmptyReply() throws {
        MockURLProtocol.stub = MockURLProtocol.Stub(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": "ok"]],
                "stop_reason": "end_turn"
            ])
        )
    }

    /// Caching is a prefix match, so the breakpoint has to sit on the very last
    /// block — anything after it is outside the cached region on the next
    /// request, and in the agent loop that would be the newest screenshot and
    /// accessibility dump, which is most of what repeats.
    func testBreakpointIsOnTheFinalContentBlock() async throws {
        try stubEmptyReply()
        let client = AnthropicClient(apiKey: "k", session: MockURLProtocol.makeSession())
        _ = try await client.complete(CompletionRequest(
            system: "sys",
            messages: [
                .text(.user, "first"),
                CompletionMessage(role: .user, content: [
                    .text("second"),
                    .image(mediaType: "image/png", base64: "AAAA")
                ])
            ],
            model: "m"
        ))

        let body = jsonBody()
        let final = try lastContentBlock(of: body)
        XCTAssertEqual(final["type"] as? String, "image")
        XCTAssertEqual(final["cache_control"] as? [String: String], ["type": "ephemeral"])

        // Only the final block carries one — earlier blocks must not, or each
        // request would burn breakpoints on prefixes it never reads back.
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let firstContent = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertNil(firstContent.first?["cache_control"])
    }

    func testSystemPromptCarriesABreakpoint() async throws {
        try stubEmptyReply()
        let client = AnthropicClient(apiKey: "k", session: MockURLProtocol.makeSession())
        _ = try await client.complete(
            CompletionRequest(system: "sys", messages: [.text(.user, "hi")], model: "m")
        )

        let system = try XCTUnwrap(jsonBody()["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system.first?["cache_control"] as? [String: String], ["type": "ephemeral"])
    }

    /// The cache key is the literal bytes of the rendered prefix, and Foundation
    /// makes no ordering promise for a dictionary — an unstable key order would
    /// mean a prefix that never changed still missed.
    func testIdenticalRequestsSerializeToIdenticalBytes() async throws {
        func bodyBytes() async throws -> Data {
            try stubEmptyReply()
            let client = AnthropicClient(apiKey: "k", session: MockURLProtocol.makeSession())
            _ = try await client.complete(CompletionRequest(
                system: "sys",
                messages: [.text(.user, "hi")],
                tools: [ToolDefinition(
                    name: "t",
                    description: "d",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "zeta": .object(["type": .string("string")]),
                            "alpha": .object(["type": .string("number")]),
                            "mid": .object(["type": .string("boolean")])
                        ])
                    ])
                )],
                model: "m"
            ))
            return try XCTUnwrap(MockURLProtocol.capturedRequestBody)
        }

        let first = try await bodyBytes()
        let second = try await bodyBytes()
        XCTAssertEqual(first, second)
    }

    /// A request with no messages must not crash reaching for a block to mark.
    func testEmptyMessageListIsHandled() async throws {
        try stubEmptyReply()
        let client = AnthropicClient(apiKey: "k", session: MockURLProtocol.makeSession())
        _ = try await client.complete(CompletionRequest(system: "sys", messages: [], model: "m"))
        XCTAssertEqual((jsonBody()["messages"] as? [[String: Any]])?.count, 0)
    }

    func testCompleteParsesToolUseBlock() async throws {
        let responseJSON: [String: Any] = [
            "content": [
                ["type": "text", "text": "Let me check."],
                ["type": "tool_use", "id": "toolu_1", "name": "task_complete", "input": ["summary": "done"]]
            ],
            "stop_reason": "tool_use"
        ]
        MockURLProtocol.stub = MockURLProtocol.Stub(status: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: responseJSON))
        let client = AnthropicClient(apiKey: "test-key", session: MockURLProtocol.makeSession())
        let response = try await client.complete(CompletionRequest(system: "sys", messages: [.text(.user, "go")], model: "m"))
        XCTAssertEqual(response.stopReason, .toolUse)
        let toolUse = try XCTUnwrap(response.firstToolUse)
        XCTAssertEqual(toolUse.name, "task_complete")
        XCTAssertEqual(toolUse.input, .object(["summary": .string("done")]))
    }

    func testCompleteThrowsMissingAPIKeyWithoutMakingARequest() async {
        let client = AnthropicClient(apiKey: "", session: MockURLProtocol.makeSession())
        do {
            _ = try await client.complete(CompletionRequest(system: "s", messages: [.text(.user, "hi")], model: "m"))
            XCTFail("expected missingAPIKey")
        } catch let error as CompletionError {
            guard case .missingAPIKey = error else {
                return XCTFail("expected missingAPIKey, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testCompleteSurfacesHTTPErrorMessage() async {
        let errorJSON: [String: Any] = ["error": ["message": "rate limited"]]
        MockURLProtocol.stub = MockURLProtocol.Stub(status: 429, headers: [:], body: try! JSONSerialization.data(withJSONObject: errorJSON))
        let client = AnthropicClient(apiKey: "test-key", session: MockURLProtocol.makeSession())
        do {
            _ = try await client.complete(CompletionRequest(system: "s", messages: [.text(.user, "hi")], model: "m"))
            XCTFail("expected an error")
        } catch let error as CompletionError {
            guard case .http(let status, let message) = error else {
                return XCTFail("expected http error, got \(error)")
            }
            XCTAssertEqual(status, 429)
            XCTAssertEqual(message, "rate limited")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// Feeds the SSE line sequence directly into the accumulator that backs
    /// `AnthropicClient.stream(_:)`, rather than routing through
    /// `URLSession.bytes(for:)` + a mock `URLProtocol` — that combination is
    /// unreliable in practice for streaming responses, while this exercises
    /// exactly the same parsing logic the live network path uses.
    func testStreamAccumulatorYieldsTextDeltasThenCompletedResponse() throws {
        let lines = [
            "event: content_block_start",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}",
            "",
            "event: message_delta",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}",
            "",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
            ""
        ]
        var accumulator = SSEAccumulator()
        var deltas: [String] = []
        for line in lines {
            if let event = accumulator.consume(line: line) {
                if case .textDelta(let text) = event { deltas.append(text) }
            }
        }
        XCTAssertEqual(deltas, ["Hel", "lo"])
        let response = try XCTUnwrap(accumulator.finish())
        XCTAssertEqual(response.text, "Hello")
        XCTAssertEqual(response.stopReason, .endTurn)
    }

    func testStreamAccumulatorParsesToolUseDeltas() throws {
        let lines = [
            "event: content_block_start",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"task_complete\"}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"sum\"}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"mary\\\":\\\"done\\\"}\"}}",
            "",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
            ""
        ]
        var accumulator = SSEAccumulator()
        for line in lines { _ = accumulator.consume(line: line) }
        let response = try XCTUnwrap(accumulator.finish())
        let toolUse = try XCTUnwrap(response.firstToolUse)
        XCTAssertEqual(toolUse.name, "task_complete")
        XCTAssertEqual(toolUse.input, .object(["summary": .string("done")]))
    }
}
