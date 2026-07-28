import Foundation

/// Tool-use replacement for the marker-based protocol
/// (`[[CLIPPY_PLAN]]`/`[[CLIPPY_TYPE]]`/etc.) used by the CLI providers.
/// Anthropic enforces the input schema server-side, so a malformed call is
/// caught before it ever reaches app code — brace-matching a hand-rolled
/// marker was the CLI path's only option, not a good one for an API that
/// supports structured tool calls natively.
public enum ClippyTools {
    /// Propose a multi-step screen plan — the tool-use equivalent of
    /// `[[CLIPPY_PLAN]]`. Decodes straight into `PendingScreenPlan`.
    public static let screenAction = ToolDefinition(
        name: "screen_action",
        description: """
        Propose a sequence of screen actions (open an app, click a control, type text, \
        press a navigation key, or wait) to accomplish the user's request. Every target must \
        exactly match a label in the supplied "Visible actionable controls" list, or supply x/y \
        coordinates in that same point space when a label match would be unreliable. Never \
        include a step that sends, submits, publishes, purchases, deletes, accepts terms, or \
        enters a password — call cannot_proceed instead if the goal requires one of those as \
        the very next step.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "summary": .object(["type": .string("string"), "description": .string("One sentence describing what this plan will do.")]),
                "steps": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "action": .object(["type": .string("string"), "enum": .array([.string("open"), .string("click"), .string("type"), .string("wait"), .string("key")])]),
                            "target": .object(["type": .string("string")]),
                            "text": .object(["type": .string("string")]),
                            "app": .object(["type": .string("string")]),
                            "key": .object(["type": .string("string"), "enum": .array([.string("tab"), .string("escape"), .string("up"), .string("down"), .string("left"), .string("right")])]),
                            "seconds": .object(["type": .string("number")]),
                            "x": .object(["type": .string("number")]),
                            "y": .object(["type": .string("number")]),
                            "pressReturnAfter": .object(["type": .string("boolean")])
                        ]),
                        "required": .array([.string("action")])
                    ])
                ])
            ]),
            "required": .array([.string("summary"), .string("steps")])
        ])
    )

    /// Type text into a single named field — the tool-use equivalent of
    /// `[[CLIPPY_TYPE]]`. Decodes into a single `.type` `ScreenPlanStep`.
    public static let typeText = ToolDefinition(
        name: "type_text",
        description: "Type exact finished text into a specific editable field already visible on screen.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "target": .object(["type": .string("string"), "description": .string("Exact label from Visible actionable controls.")]),
                "text": .object(["type": .string("string")])
            ]),
            "required": .array([.string("target"), .string("text")])
        ])
    )

    /// Highlight (but do not click) one visible control — the tool-use
    /// equivalent of `[[CLIPPY_GUIDE]]`.
    public static let highlightControl = ToolDefinition(
        name: "highlight_control",
        description: "Visually point out one control on screen without clicking it.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["label": .object(["type": .string("string")])]),
            "required": .array([.string("label")])
        ])
    )

    /// The goal is done (or was already done) — an explicit terminator so a
    /// stop reason is always structured data, never a discarded sentence
    /// buried in a rejected empty-steps plan.
    public static let taskComplete = ToolDefinition(
        name: "task_complete",
        description: "Call this when the stated goal is already accomplished, or just was by the previous step. Ends the task.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["summary": .object(["type": .string("string"), "description": .string("One sentence describing what was accomplished.")])]),
            "required": .array([.string("summary")])
        ])
    )

    /// The goal cannot be safely continued — e.g. the only next step would
    /// be a final action, or nothing on screen matches what's needed.
    public static let cannotProceed = ToolDefinition(
        name: "cannot_proceed",
        description: "Call this when the goal cannot be safely continued — e.g. the only next step would send, submit, pay, delete, or requires a password, or nothing on screen matches what's needed.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["reason": .object(["type": .string("string")])]),
            "required": .array([.string("reason")])
        ])
    )

    public static let all: [ToolDefinition] = [screenAction, typeText, highlightControl, taskComplete, cannotProceed]

    /// A structured decode of whichever tool the model actually called,
    /// replacing marker-parsing for the Anthropic path. `nil` fields decode
    /// to sensible defaults; malformed required fields make the call `nil`.
    public enum Call {
        case screenAction(PendingScreenPlan)
        case typeText(target: String, text: String)
        case highlightControl(label: String)
        case taskComplete(summary: String)
        case cannotProceed(reason: String)
    }

    /// Decodes a `CompletionResponse`'s first tool call (if any) into a
    /// `Call`. Returns `nil` for a plain-text response or an unrecognized/
    /// malformed tool name — callers should fall back to `response.text`.
    public static func call(from response: CompletionResponse) -> Call? {
        guard let toolUse = response.firstToolUse else { return nil }
        return decode(name: toolUse.name, input: toolUse.input)
    }

    static func decode(name: String, input: JSONValue) -> Call? {
        guard case .object(let fields) = input else { return nil }
        switch name {
        case screenAction.name:
            guard case .string(let summary)? = fields["summary"],
                  case .array(let stepValues)? = fields["steps"] else { return nil }
            let steps = stepValues.compactMap(decodeStep)
            return .screenAction(PendingScreenPlan(summary: summary, steps: steps))
        case typeText.name:
            guard case .string(let target)? = fields["target"],
                  case .string(let text)? = fields["text"] else { return nil }
            return .typeText(target: target, text: text)
        case highlightControl.name:
            guard case .string(let label)? = fields["label"] else { return nil }
            return .highlightControl(label: label)
        case taskComplete.name:
            guard case .string(let summary)? = fields["summary"] else { return nil }
            return .taskComplete(summary: summary)
        case cannotProceed.name:
            guard case .string(let reason)? = fields["reason"] else { return nil }
            return .cannotProceed(reason: reason)
        default:
            return nil
        }
    }

    private static func decodeStep(_ value: JSONValue) -> ScreenPlanStep? {
        guard case .object(let fields) = value,
              case .string(let actionRaw)? = fields["action"],
              let action = ScreenPlanAction(rawValue: actionRaw) else { return nil }
        func string(_ key: String) -> String? {
            if case .string(let value)? = fields[key] { return value }
            return nil
        }
        func number(_ key: String) -> Double? {
            if case .number(let value)? = fields[key] { return value }
            return nil
        }
        func boolean(_ key: String) -> Bool? {
            if case .bool(let value)? = fields[key] { return value }
            return nil
        }
        let key = string("key").flatMap(ScreenPlanKey.init)
        return ScreenPlanStep(
            action: action,
            target: string("target"),
            text: string("text"),
            seconds: number("seconds"),
            app: string("app"),
            key: key,
            x: number("x"),
            y: number("y"),
            pressReturnAfter: boolean("pressReturnAfter")
        )
    }
}
