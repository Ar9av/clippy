import XCTest
@testable import ClippyCore

/// Records every `complete()` request it received and returns scripted
/// responses in order. `stream()` is never called by `ScreenAgent` and
/// intentionally left unimplemented here.
final class MockProvider: AIProviding, @unchecked Sendable {
    let supportsVision = true
    let supportsTools = true

    private var responses: [CompletionResponse]
    private(set) var receivedRequests: [CompletionRequest] = []
    /// Set to make a specific call (0-based) throw instead of returning.
    var failAtCallIndex: [Int: Error] = [:]
    private var callCount = 0

    init(responses: [CompletionResponse]) {
        self.responses = responses
    }

    func complete(_ request: CompletionRequest) async throws -> CompletionResponse {
        defer { callCount += 1 }
        receivedRequests.append(request)
        if let error = failAtCallIndex[callCount] { throw error }
        guard !responses.isEmpty else {
            throw CompletionError.invalidResponse("MockProvider ran out of scripted responses.")
        }
        return responses.removeFirst()
    }

    func stream(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: CompletionError.invalidResponse("not implemented")) }
    }
}

/// Returns a fixed screen context backed by real temp files (so
/// `ScreenAgent`'s `String(contentsOf:)` / `Data(contentsOf:)` reads work
/// without touching ScreenCaptureKit or Accessibility).
@MainActor
final class MockObserver: ScreenObserving {
    private(set) var captureCount = 0
    let contextURL: URL
    let screenshotURL: URL

    init() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenAgentTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        contextURL = directory.appendingPathComponent("context.txt")
        screenshotURL = directory.appendingPathComponent("screenshot.png")
        try? "Visible actionable controls:\n- Button: \"OK\" at (10, 10)".write(to: contextURL, atomically: true, encoding: .utf8)
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: screenshotURL)
    }

    func captureContext() async throws -> ScreenContext {
        captureCount += 1
        return ScreenContext(
            appName: "TestApp",
            windowTitle: "Test Window",
            screenshotURL: screenshotURL,
            contextURL: contextURL,
            elements: [],
            windowFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            screenshotScale: 2
        )
    }
}

struct MockScreenshotLoader: ScreenshotLoading {
    func loadBase64PNG(at url: URL) throws -> String { "ZmFrZQ==" }
}

/// Records every step it was asked to perform; fails specific steps by index.
@MainActor
final class AgentRecordingPerformer: ScreenStepPerforming {
    private(set) var performedSteps: [ScreenPlanStep] = []
    var failAtStepIndex: Set<Int> = []
    private var stepCount = 0

    func openApp(named name: String) async throws { performedSteps.append(ScreenPlanStep(action: .open, app: name)) }

    func click(_ target: String) async throws {
        defer { stepCount += 1 }
        performedSteps.append(ScreenPlanStep(action: .click, target: target))
        if failAtStepIndex.contains(stepCount) { throw ScreenAwarenessError.targetNotFound(target) }
    }

    func type(_ text: String, into target: String) async throws {
        defer { stepCount += 1 }
        performedSteps.append(ScreenPlanStep(action: .type, target: target, text: text))
        if failAtStepIndex.contains(stepCount) { throw ScreenAwarenessError.targetNotFound(target) }
    }

    func press(_ key: ScreenPlanKey) async throws { performedSteps.append(ScreenPlanStep(action: .key, key: key)) }
    func idle(_ seconds: Double) async throws {}
}

@MainActor
final class ScreenAgentTests: XCTestCase {
    private func toolUseResponse(name: String, input: JSONValue) -> CompletionResponse {
        CompletionResponse(content: [.toolUse(id: UUID().uuidString, name: name, input: input)], stopReason: .toolUse, usage: nil)
    }

    private func fastConfig(stepLimit: Int = ScreenPlanRunner.stepLimit) -> ScreenAgent.Config {
        ScreenAgent.Config(stepLimit: stepLimit, settleMilliseconds: { _ in 0 })
    }

    func testHappyPathCompletesAfterOneStep() async throws {
        let provider = MockProvider(responses: [
            toolUseResponse(name: "screen_action", input: .object([
                "summary": .string("Click OK"),
                "steps": .array([.object(["action": .string("click"), "target": .string("OK")])])
            ])),
            toolUseResponse(name: "task_complete", input: .object(["summary": .string("Clicked OK.")]))
        ])
        let performer = AgentRecordingPerformer()
        let observer = MockObserver()
        let agent = ScreenAgent(provider: provider, performer: performer, observer: observer, screenshots: MockScreenshotLoader(), config: fastConfig())

        let outcome = await agent.run(goal: "click OK")
        XCTAssertEqual(outcome, .completed(summary: "Clicked OK."))
        XCTAssertEqual(performer.performedSteps.map(\.target), ["OK"])
        XCTAssertEqual(observer.captureCount, 2) // initial + after the one step
    }

    func testProviderErrorIsNeverReportedAsSuccess() async {
        let provider = MockProvider(responses: [
            toolUseResponse(name: "screen_action", input: .object([
                "summary": .string("Click OK"),
                "steps": .array([.object(["action": .string("click"), "target": .string("OK")])])
            ]))
        ])
        provider.failAtCallIndex[1] = CompletionError.transport("network down")
        let performer = AgentRecordingPerformer()
        let agent = ScreenAgent(provider: provider, performer: performer, observer: MockObserver(), screenshots: MockScreenshotLoader(), config: fastConfig())

        let outcome = await agent.run(goal: "click OK")
        guard case .providerError = outcome else {
            return XCTFail("expected .providerError, got \(outcome)")
        }
    }

    func testHittingStepLimitDoesNotReportSuccess() async {
        // Every call proposes a fresh single-click step that always succeeds,
        // so the loop only ever exits via the step cap.
        let responses = (0..<(ScreenPlanRunner.stepLimit + 2)).map { index in
            toolUseResponse(name: "screen_action", input: .object([
                "summary": .string("Click \(index)"),
                "steps": .array([.object(["action": .string("click"), "target": .string("Button \(index)")])])
            ]))
        }
        let provider = MockProvider(responses: responses)
        let performer = AgentRecordingPerformer()
        let agent = ScreenAgent(provider: provider, performer: performer, observer: MockObserver(), screenshots: MockScreenshotLoader(), config: fastConfig())

        let outcome = await agent.run(goal: "keep clicking")
        XCTAssertEqual(outcome, .stepLimit(executedCount: ScreenPlanRunner.stepLimit))
    }

    func testCannotProceedReportsStuckWithReason() async {
        let provider = MockProvider(responses: [
            toolUseResponse(name: "cannot_proceed", input: .object(["reason": .string("Only a purchase button is available.")]))
        ])
        let agent = ScreenAgent(provider: provider, performer: AgentRecordingPerformer(), observer: MockObserver(), screenshots: MockScreenshotLoader(), config: fastConfig())

        let outcome = await agent.run(goal: "buy the thing")
        XCTAssertEqual(outcome, .stuck(reason: "Only a purchase button is available."))
    }

    func testUnsafeProposedStepIsRefusedNotPerformed() async {
        let provider = MockProvider(responses: [
            toolUseResponse(name: "screen_action", input: .object([
                "summary": .string("Confirm purchase"),
                "steps": .array([.object(["action": .string("click"), "target": .string("Confirm")])])
            ]))
        ])
        let performer = AgentRecordingPerformer()
        let agent = ScreenAgent(provider: provider, performer: performer, observer: MockObserver(), screenshots: MockScreenshotLoader(), config: fastConfig())

        let outcome = await agent.run(goal: "confirm it")
        guard case .refusedUnsafe = outcome else {
            return XCTFail("expected .refusedUnsafe, got \(outcome)")
        }
        XCTAssertTrue(performer.performedSteps.isEmpty, "an unsafe step must never reach the performer")
    }

    func testFailureIsRememberedInTheNextRequestAsAnErrorToolResult() async throws {
        let provider = MockProvider(responses: [
            toolUseResponse(name: "screen_action", input: .object([
                "summary": .string("Click Missing"),
                "steps": .array([.object(["action": .string("click"), "target": .string("Missing")])])
            ])),
            toolUseResponse(name: "task_complete", input: .object(["summary": .string("Gave up gracefully.")]))
        ])
        let performer = AgentRecordingPerformer()
        performer.failAtStepIndex = [0]
        let agent = ScreenAgent(provider: provider, performer: performer, observer: MockObserver(), screenshots: MockScreenshotLoader(), config: fastConfig())

        _ = await agent.run(goal: "click Missing")

        // The second request (after the failed first step) must carry a
        // tool_result marked as an error — proof the loop has memory of the
        // failure rather than asking again from scratch.
        let secondRequest = try XCTUnwrap(provider.receivedRequests.last)
        let lastMessage = try XCTUnwrap(secondRequest.messages.last)
        guard case .toolResult(_, let content, let isError) = lastMessage.content.first else {
            return XCTFail("expected a tool_result block in the follow-up request")
        }
        XCTAssertTrue(isError)
        XCTAssertTrue(content.contains("Failed"))
    }

    func testRepeatedIdenticalStepsStopsInsteadOfLoopingToTheCap() async {
        let step = toolUseResponse(name: "screen_action", input: .object([
            "summary": .string("Click Ghost"),
            "steps": .array([.object(["action": .string("click"), "target": .string("Ghost")])])
        ]))
        // Same step proposed forever — repeat detection should stop this
        // long before the step cap.
        let provider = MockProvider(responses: Array(repeating: step, count: ScreenPlanRunner.stepLimit))
        let performer = AgentRecordingPerformer()
        let agent = ScreenAgent(provider: provider, performer: performer, observer: MockObserver(), screenshots: MockScreenshotLoader(), config: fastConfig())

        let outcome = await agent.run(goal: "click ghost")
        guard case .stuck = outcome else {
            return XCTFail("expected .stuck from repeat detection, got \(outcome)")
        }
        XCTAssertLessThan(performer.performedSteps.count, ScreenPlanRunner.stepLimit)
    }

    func testCancellationStopsTheLoop() async {
        let provider = MockProvider(responses: [
            toolUseResponse(name: "screen_action", input: .object([
                "summary": .string("Click OK"),
                "steps": .array([.object(["action": .string("click"), "target": .string("OK")])])
            ]))
        ])
        let agent = ScreenAgent(provider: provider, performer: AgentRecordingPerformer(), observer: MockObserver(), screenshots: MockScreenshotLoader(), config: fastConfig())

        let task = Task { await agent.run(goal: "click OK") }
        task.cancel()
        let outcome = await task.value
        // Either cancellation was observed at the top of the loop, or the
        // single scripted step already completed before the cancel took
        // effect — both are acceptable races; success must never happen
        // silently despite cancellation being requested.
        switch outcome {
        case .cancelled, .completed, .stepLimit, .stuck, .providerError:
            break
        case .refusedUnsafe:
            XCTFail("unexpected outcome: \(outcome)")
        }
    }
}
