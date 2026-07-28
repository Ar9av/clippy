import ClippyCore
import Foundation

/// What a case expects the model to do — checked against whichever tool
/// call (or plain-text answer) the model actually produced.
struct EvalExpectation: Decodable {
    /// "plan" (screen_action), "type" (type_text), "highlight"
    /// (highlight_control), "stop" (task_complete), "refuse"
    /// (cannot_proceed), or "answer" (plain text, no tool call).
    let kind: String
    /// For "plan"/"type"/"highlight": the target must be one of these
    /// (case-insensitive substring match), if given.
    let targetOneOf: [String]?
    /// None of a plan's step targets (nor a single type/highlight target)
    /// may contain any of these substrings (case-insensitive) — the
    /// safety-suite's core check.
    let mustNotTargetContaining: [String]?
    /// If false (default true), a plan containing any pressReturnAfter
    /// step fails this case regardless of target.
    let pressReturnAllowed: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind, targetOneOf, mustNotTargetContaining, pressReturnAllowed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        targetOneOf = try container.decodeIfPresent([String].self, forKey: .targetOneOf)
        mustNotTargetContaining = try container.decodeIfPresent([String].self, forKey: .mustNotTargetContaining)
        pressReturnAllowed = try container.decodeIfPresent(Bool.self, forKey: .pressReturnAllowed)
    }
}

/// A recorded (or, in `--record` mode, freshly captured) model response —
/// exactly one tool call, or plain text with no tool call at all.
struct RecordedResponse: Decodable {
    let tool: String?
    let input: JSONValue?
    let text: String?
}

struct EvalCase: Decodable {
    let id: String
    let suite: String
    let goal: String
    /// A synthetic "Visible actionable controls" style AX dump — these
    /// fixtures are text-only (no real screenshot), which is sufficient for
    /// scoring intent/safety/target-selection; a live run still sends the
    /// same text as the only context block.
    let context: String
    let expect: EvalExpectation
    let recordedResponse: RecordedResponse?

    static func loadAll() -> [EvalCase] {
        guard let fixturesRoot = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            return []
        }
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: fixturesRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.hasDirectoryPath }
            .compactMap { directory -> EvalCase? in
                let caseURL = directory.appendingPathComponent("case.json")
                guard let data = try? Data(contentsOf: caseURL) else { return nil }
                return try? JSONDecoder().decode(EvalCase.self, from: data)
            }
            .sorted { $0.id < $1.id }
    }
}
