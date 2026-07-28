import ClippyCore
import Foundation

struct EvalReport: Codable {
    let promptVersion: String
    let model: String
    let mode: String
    let results: [CaseResult]
    let passCount: Int
    let totalCount: Int
    let safetyPassRate: Double
}

enum EvalError: Error, CustomStringConvertible {
    case missingAPIKey
    case noCases

    var description: String {
        switch self {
        case .missingAPIKey: "Set ANTHROPIC_API_KEY to run in live mode (or pass --offline)."
        case .noCases: "No fixture cases found under Sources/ClippyEval/Fixtures."
        }
    }
}

enum EvalRunner {
    /// `offline: true` replays each fixture's recorded response instead of
    /// calling the network — deterministic, free, CI-safe. `offline: false`
    /// calls the real Anthropic API with the given model, exercising the
    /// exact same tool definitions and system prompt the live app's
    /// tool-use path uses (`ClippyTools.all`, `SystemPrompt.text`).
    static func run(cases: [EvalCase], model: String, offline: Bool) async throws -> EvalReport {
        guard !cases.isEmpty else { throw EvalError.noCases }

        var provider: AIProviding?
        if !offline {
            guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
                throw EvalError.missingAPIKey
            }
            provider = AnthropicClient(apiKey: apiKey)
        }

        var results: [CaseResult] = []
        for evalCase in cases {
            let (call, rawText) = try await resolveResponse(for: evalCase, provider: provider, model: model)
            results.append(Scoring.score(evalCase, call: call, rawText: rawText))
        }

        let safetyResults = results.filter { $0.suite == "safety" }
        let safetyRate = safetyResults.isEmpty ? 1.0 : Double(safetyResults.filter(\.passed).count) / Double(safetyResults.count)

        return EvalReport(
            promptVersion: SystemPrompt.version,
            model: model,
            mode: offline ? "offline" : "live",
            results: results,
            passCount: results.filter(\.passed).count,
            totalCount: results.count,
            safetyPassRate: safetyRate
        )
    }

    private static func resolveResponse(
        for evalCase: EvalCase,
        provider: AIProviding?,
        model: String
    ) async throws -> (ClippyTools.Call?, String) {
        guard let provider else {
            // Offline: replay the fixture's recorded response verbatim.
            guard let recorded = evalCase.recordedResponse else {
                return (nil, "")
            }
            if let tool = recorded.tool, let input = recorded.input {
                let response = CompletionResponse(
                    content: [.toolUse(id: "offline", name: tool, input: input)],
                    stopReason: .toolUse,
                    usage: nil
                )
                return (ClippyTools.call(from: response), "")
            }
            return (nil, recorded.text ?? "")
        }

        let request = CompletionRequest(
            system: SystemPrompt.text,
            messages: [.text(.user, "Goal: \(evalCase.goal)\n\n\(evalCase.context)")],
            tools: ClippyTools.all,
            model: model
        )
        let response = try await provider.complete(request)
        return (ClippyTools.call(from: response), response.text)
    }
}
