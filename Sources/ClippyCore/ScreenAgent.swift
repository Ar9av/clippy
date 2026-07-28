import CoreGraphics
import Foundation

/// Captures one screenshot + accessibility scan. `ScreenAwarenessService`
/// (app target) is the live conformer; tests supply a scripted mock.
@MainActor
public protocol ScreenObserving: AnyObject {
    func captureContext() async throws -> ScreenContext
}

/// Reads a captured screenshot off disk as base64 — split out so tests can
/// substitute an in-memory fixture instead of a real file on disk.
public protocol ScreenshotLoading: Sendable {
    func loadBase64PNG(at url: URL) throws -> String
}

public struct FileScreenshotLoader: ScreenshotLoading {
    public init() {}
    public func loadBase64PNG(at url: URL) throws -> String {
        try Data(contentsOf: url).base64EncodedString()
    }
}

/// A real observe → act → verify agent loop: each round captures a fresh
/// screenshot + AX scan, asks the model (via tool use, not markers) for the
/// single next step given everything tried so far, performs it, and folds
/// the result back into the conversation before asking again. Unlike the
/// original `ChatViewModel.decideNextStep`/`executeScreenPlan` pair this
/// replaces, every round's prior actions and failures stay in the model's
/// own context (as tool_use/tool_result turns) instead of each round being a
/// standalone, memory-less call.
@MainActor
public final class ScreenAgent {
    public enum Outcome: Equatable {
        case completed(summary: String)
        case stepLimit(executedCount: Int)
        case stuck(reason: String)
        case providerError(String)
        case cancelled
        case refusedUnsafe(String)
    }

    public enum Event: Equatable {
        case stepStarted(ScreenPlanStep)
        case stepSucceeded(ScreenPlanStep)
        case stepFailed(ScreenPlanStep, reason: String)
    }

    public struct Config: Sendable {
        public var stepLimit: Int
        public var maxConsecutiveFailures: Int
        public var maxConsecutiveRepeats: Int
        public var model: String
        public var settleMilliseconds: @Sendable (ScreenPlanStep) -> UInt64

        public init(
            stepLimit: Int = ScreenPlanRunner.stepLimit,
            maxConsecutiveFailures: Int = 3,
            maxConsecutiveRepeats: Int = 2,
            model: String = AnthropicClient.defaultModel,
            settleMilliseconds: @escaping @Sendable (ScreenPlanStep) -> UInt64 = { step in
                (step.action == .type && step.pressReturnAfter == true) ? 1400 : 500
            }
        ) {
            self.stepLimit = stepLimit
            self.maxConsecutiveFailures = maxConsecutiveFailures
            self.maxConsecutiveRepeats = maxConsecutiveRepeats
            self.model = model
            self.settleMilliseconds = settleMilliseconds
        }
    }

    private let provider: AIProviding
    private let performer: ScreenStepPerforming
    private let observer: ScreenObserving
    private let screenshots: ScreenshotLoading
    private let config: Config

    public init(
        provider: AIProviding,
        performer: ScreenStepPerforming,
        observer: ScreenObserving,
        screenshots: ScreenshotLoading = FileScreenshotLoader(),
        config: Config = Config()
    ) {
        self.provider = provider
        self.performer = performer
        self.observer = observer
        self.screenshots = screenshots
        self.config = config
    }

    public func run(goal: String, onEvent: (Event) -> Void = { _ in }) async -> Outcome {
        var transcript: [CompletionMessage]
        do {
            transcript = [try await userTurn(goal: goal, isFirst: true)]
        } catch {
            return .providerError(error.localizedDescription)
        }

        var executedCount = 0
        var consecutiveFailures = 0
        var consecutiveRepeats = 0
        var lastStep: ScreenPlanStep?

        while executedCount < config.stepLimit {
            if Task.isCancelled { return .cancelled }

            let response: CompletionResponse
            do {
                response = try await provider.complete(
                    CompletionRequest(system: SystemPrompt.text, messages: transcript, tools: ClippyTools.all, model: config.model)
                )
            } catch {
                return .providerError(error.localizedDescription)
            }

            guard let toolUse = response.firstToolUse, let call = ClippyTools.call(from: response) else {
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return .stuck(reason: text.isEmpty ? "The model didn't return a usable next step." : text)
            }
            transcript.append(CompletionMessage(role: .assistant, content: [.toolUse(id: toolUse.id, name: toolUse.name, input: toolUse.input)]))

            switch call {
            case .taskComplete(let summary):
                return .completed(summary: summary)
            case .cannotProceed(let reason):
                return .stuck(reason: reason)
            case .highlightControl(let label):
                // Highlighting alone doesn't advance the task or need a
                // fresh screenshot — acknowledge and let the model continue.
                do {
                    let resolved = try await performer.highlight(label)
                    transcript.append(toolResultTurn(toolUseId: toolUse.id, content: "Highlighted \"\(resolved)\".", isError: false))
                } catch {
                    transcript.append(toolResultTurn(toolUseId: toolUse.id, content: "Couldn't highlight \"\(label)\": \(error.localizedDescription)", isError: true))
                }
                continue
            case .typeText(let target, let text):
                let step = ScreenPlanStep(action: .type, target: target, text: text)
                let outcome = await perform(
                    step: step,
                    toolUseId: toolUse.id,
                    executedCount: &executedCount,
                    consecutiveFailures: &consecutiveFailures,
                    consecutiveRepeats: &consecutiveRepeats,
                    lastStep: &lastStep,
                    transcript: &transcript,
                    onEvent: onEvent
                )
                if let outcome { return outcome }
            case .screenAction(let plan):
                guard let step = plan.steps.first else {
                    return .completed(summary: plan.summary)
                }
                let outcome = await perform(
                    step: step,
                    toolUseId: toolUse.id,
                    executedCount: &executedCount,
                    consecutiveFailures: &consecutiveFailures,
                    consecutiveRepeats: &consecutiveRepeats,
                    lastStep: &lastStep,
                    transcript: &transcript,
                    onEvent: onEvent
                )
                if let outcome { return outcome }
            }

            if consecutiveFailures >= config.maxConsecutiveFailures {
                return .stuck(reason: "Stopped after \(consecutiveFailures) failed attempts in a row.")
            }
            if consecutiveRepeats >= config.maxConsecutiveRepeats {
                return .stuck(reason: "Kept proposing the same step without anything changing.")
            }
        }
        return .stepLimit(executedCount: executedCount)
    }

    /// Validates, performs, settles, and re-observes one step, folding the
    /// result back into `transcript` as a tool_result turn (with a fresh
    /// screenshot attached) so the next round judges from what actually
    /// happened rather than a stale prediction. Returns a non-nil `Outcome`
    /// only when the step itself must end the run (an unsafe target).
    private func perform(
        step: ScreenPlanStep,
        toolUseId: String,
        executedCount: inout Int,
        consecutiveFailures: inout Int,
        consecutiveRepeats: inout Int,
        lastStep: inout ScreenPlanStep?,
        transcript: inout [CompletionMessage],
        onEvent: (Event) -> Void
    ) async -> Outcome? {
        do {
            try ScreenPlanRunner.validate(PendingScreenPlan(summary: "step", steps: [step]))
        } catch {
            return .refusedUnsafe(error.localizedDescription)
        }

        if let lastStep, Self.isEquivalentAction(step, lastStep) {
            consecutiveRepeats += 1
        } else {
            consecutiveRepeats = 0
        }
        lastStep = step

        onEvent(.stepStarted(step))
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0)
        do {
            _ = try await runner.run(PendingScreenPlan(summary: "step", steps: [step]))
            consecutiveFailures = 0
            executedCount += 1
            onEvent(.stepSucceeded(step))
            try? await Task.sleep(nanoseconds: config.settleMilliseconds(step) * 1_000_000)
            let followUp = try await userTurn(goal: nil, isFirst: false, priorStep: step, failureReason: nil, toolUseId: toolUseId)
            transcript.append(followUp)
            return nil
        } catch {
            consecutiveFailures += 1
            let reason = error.localizedDescription
            onEvent(.stepFailed(step, reason: reason))
            executedCount += 1
            let followUp = (try? await userTurn(goal: nil, isFirst: false, priorStep: step, failureReason: reason, toolUseId: toolUseId))
                ?? toolResultTurn(toolUseId: toolUseId, content: "Failed: \(reason)", isError: true)
            transcript.append(followUp)
            return nil
        }
    }

    /// Builds the user turn that follows a tool call: a `tool_result` block
    /// (required by the API to close out the assistant's tool_use) plus a
    /// fresh screenshot + AX text, so the next round always judges from a
    /// post-action observation rather than a pre-action prediction.
    private func userTurn(
        goal: String?,
        isFirst: Bool,
        priorStep: ScreenPlanStep? = nil,
        failureReason: String? = nil,
        toolUseId: String? = nil
    ) async throws -> CompletionMessage {
        let context = try await observer.captureContext()
        let base64 = try screenshots.loadBase64PNG(at: context.screenshotURL)
        let contextText = try String(contentsOf: context.contextURL, encoding: .utf8)

        var blocks: [CompletionContentBlock] = []
        if let toolUseId {
            let resultText: String
            if let failureReason {
                resultText = "Failed: \(failureReason). Current screen (after the failed attempt):\n\(contextText)"
            } else {
                resultText = "Done. Current screen (after this step):\n\(contextText)"
            }
            blocks.append(.toolResult(toolUseId: toolUseId, content: resultText, isError: failureReason != nil))
        } else if let goal {
            blocks.append(.text("Goal: \(goal)\n\n\(contextText)"))
        }
        blocks.append(.image(mediaType: "image/png", base64: base64))
        return CompletionMessage(role: .user, content: blocks)
    }

    private func toolResultTurn(toolUseId: String, content: String, isError: Bool) -> CompletionMessage {
        CompletionMessage(role: .user, content: [.toolResult(toolUseId: toolUseId, content: content, isError: isError)])
    }

    /// Ignores pixel-level x/y jitter — a model nudging coordinates to
    /// correct itself is still progress, not a repeat.
    static func isEquivalentAction(_ a: ScreenPlanStep, _ b: ScreenPlanStep) -> Bool {
        a.action == b.action && a.target == b.target && a.text == b.text && a.app == b.app && a.key == b.key
    }
}

