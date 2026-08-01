import Foundation

/// How much a workflow is allowed to do when it runs.
public enum WorkflowMode: String, Codable, Equatable, CaseIterable, Sendable {
    /// Look, don't touch. Navigating and reading only — the mode a scheduled
    /// run uses, because a workflow that fires while nobody is watching must
    /// not be clicking and typing on an unattended machine.
    case monitor
    /// Everything a plan can normally do, still subject to the usual
    /// confirmation and final-action refusal.
    case interactive

    /// Whether this mode permits an action at all. `click` and `type` change
    /// state somewhere; `open`, `scroll`, `wait`, and `key` only change what is
    /// on view, which is what monitoring needs.
    public func allows(_ action: ScreenPlanAction) -> Bool {
        switch self {
        case .interactive: true
        case .monitor:
            switch action {
            case .open, .scroll, .wait, .key: true
            case .click, .type: false
            }
        }
    }
}

public enum WorkflowError: LocalizedError, Equatable {
    case missingArgument(placeholder: String)
    case emptyArgument(placeholder: String)
    case actionNotAllowedWhileMonitoring(ScreenPlanAction)
    case unsafeAfterSubstitution(String)
    case invalidName

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let placeholder):
            "This workflow needs a value for \(placeholder)."
        case .emptyArgument(let placeholder):
            "\(placeholder) can't be blank."
        case .actionNotAllowedWhileMonitoring(let action):
            "A scheduled check can look but not act, so it can't \(action.rawValue)."
        case .unsafeAfterSubstitution(let target):
            "With those values this workflow would act on “\(target)”, which Clippy always refuses."
        case .invalidName:
            "A workflow needs a one-word name."
        }
    }
}

/// A saved, re-runnable screen plan with placeholders for the parts that
/// change between runs — so a sequence that worked once becomes `/prices AAPL`
/// rather than something to describe again from scratch.
public struct Workflow: Identifiable, Codable, Equatable {
    public var id: UUID
    /// The command word, without its leading slash, lowercased — matched the
    /// same way `CustomPrompt` matches.
    public var name: String
    public var summary: String
    public var steps: [ScreenPlanStep]
    public var mode: WorkflowMode
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        steps: [ScreenPlanStep],
        mode: WorkflowMode = .interactive,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = Workflow.normalize(name)
        self.summary = summary
        self.steps = steps
        self.mode = mode
        self.createdAt = createdAt
    }

    /// Hand-written for the same reason `CustomPrompt`'s is: the decode site
    /// uses `try?`, so a synthesized initializer would silently discard every
    /// saved workflow the first time a field is added.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = Workflow.normalize(try container.decode(String.self, forKey: .name))
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        steps = try container.decode([ScreenPlanStep].self, forKey: .steps)
        mode = try container.decodeIfPresent(WorkflowMode.self, forKey: .mode) ?? .interactive
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    public static func normalize(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
            .drop(while: { $0 == "/" })
            .description
    }

    public var isValid: Bool {
        !name.isEmpty
            && name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && !steps.isEmpty
    }

    // MARK: Placeholders

    /// `$1`…`$9` for individual arguments, `$*` for everything the user typed.
    /// Only the text-bearing fields are substitutable: coordinates and scroll
    /// amounts stay numeric literals, so an argument can never move a click.
    static let placeholderPattern = #"\$(\*|[1-9])"#

    /// Every distinct placeholder this workflow uses, in ascending order, with
    /// `$*` last. Drives both the "needs N arguments" hint and validation.
    public var placeholders: [String] {
        var found = Set<String>()
        for step in steps {
            for field in [step.target, step.text, step.app] {
                guard let field else { continue }
                for match in Self.matches(in: field) { found.insert(match) }
            }
        }
        let numbered = found.filter { $0 != "$*" }.sorted()
        return numbered + (found.contains("$*") ? ["$*"] : [])
    }

    /// How many positional arguments must be supplied. `$*` needs at least one.
    public var requiredArgumentCount: Int {
        let numbered = placeholders
            .compactMap { Int($0.dropFirst()) }
            .max() ?? 0
        return max(numbered, placeholders.contains("$*") ? 1 : 0)
    }

    private static func matches(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: placeholderPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: Running

    /// Fills in the placeholders and returns a plan ready to run.
    ///
    /// The substituted plan is re-validated rather than trusted. A workflow is
    /// checked when it is saved, but the arguments arrive later and go straight
    /// into the fields the safety rules read — `/open $1` is harmless until
    /// someone passes "Send". Re-running `ScreenPlanRunner.validate` on the
    /// result is what stops an argument smuggling a final action past a check
    /// that already passed.
    public func instantiate(
        arguments: [String],
        bounds: CGRect? = nil,
        scale: CGFloat? = nil
    ) throws -> PendingScreenPlan {
        for placeholder in placeholders {
            let value = try resolve(placeholder, from: arguments)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowError.emptyArgument(placeholder: placeholder)
            }
        }

        let substituted = try steps.map { step -> ScreenPlanStep in
            guard mode.allows(step.action) else {
                throw WorkflowError.actionNotAllowedWhileMonitoring(step.action)
            }
            return ScreenPlanStep(
                action: step.action,
                target: try substitute(step.target, arguments),
                text: try substitute(step.text, arguments),
                seconds: step.seconds,
                app: try substitute(step.app, arguments),
                key: step.key,
                x: step.x,
                y: step.y,
                pressReturnAfter: step.pressReturnAfter,
                direction: step.direction,
                amount: step.amount
            )
        }

        let plan = PendingScreenPlan(summary: substitutedSummary(arguments), steps: substituted)
        do {
            try ScreenPlanRunner.validate(plan, bounds: bounds, scale: scale)
        } catch let error as ScreenPlanError {
            if case .unsafeStep(_, let target) = error {
                throw WorkflowError.unsafeAfterSubstitution(target)
            }
            throw error
        }
        return plan
    }

    private func substitutedSummary(_ arguments: [String]) -> String {
        (try? substitute(summary, arguments)) ?? summary
    }

    private func substitute(_ field: String?, _ arguments: [String]) throws -> String? {
        guard let field else { return nil }
        var result = field
        for placeholder in Self.matches(in: field) {
            result = result.replacingOccurrences(
                of: placeholder,
                with: try resolve(placeholder, from: arguments)
            )
        }
        return result
    }

    private func resolve(_ placeholder: String, from arguments: [String]) throws -> String {
        if placeholder == "$*" {
            guard !arguments.isEmpty else {
                throw WorkflowError.missingArgument(placeholder: placeholder)
            }
            return arguments.joined(separator: " ")
        }
        guard let index = Int(placeholder.dropFirst()), index >= 1 else {
            throw WorkflowError.missingArgument(placeholder: placeholder)
        }
        guard arguments.count >= index else {
            throw WorkflowError.missingArgument(placeholder: placeholder)
        }
        return arguments[index - 1]
    }
}

/// When a workflow should run unattended.
///
/// Deliberately a plain value with no timer in it: whether a check is due is a
/// question about two dates, and keeping it that way means the scheduling rules
/// are testable without waiting for wall-clock time to pass.
public struct WorkflowSchedule: Identifiable, Codable, Equatable {
    public var id: UUID
    public var workflowID: UUID
    /// How long to wait between runs.
    public var interval: TimeInterval
    public var lastRunAt: Date?
    public var isEnabled: Bool

    /// Anything faster than this is a busy-loop against someone's screen, not
    /// a monitor. Each firing wakes an app, captures every display, and runs a
    /// model call, so the floor is about what the machine can sustain rather
    /// than a policy preference.
    public static let minimumInterval: TimeInterval = 30

    public init(
        id: UUID = UUID(),
        workflowID: UUID,
        interval: TimeInterval,
        lastRunAt: Date? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.workflowID = workflowID
        self.interval = max(interval, Self.minimumInterval)
        self.lastRunAt = lastRunAt
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        workflowID = try container.decode(UUID.self, forKey: .workflowID)
        interval = max(
            try container.decode(TimeInterval.self, forKey: .interval),
            Self.minimumInterval
        )
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// A schedule that has never run is due immediately, so adding one gives
    /// an answer now rather than after a full interval of silence.
    public func nextRun(after now: Date = Date()) -> Date {
        guard let lastRunAt else { return now }
        return lastRunAt.addingTimeInterval(interval)
    }

    public func isDue(at now: Date = Date()) -> Bool {
        isEnabled && nextRun(after: now) <= now
    }

    public func markingRun(at now: Date = Date()) -> WorkflowSchedule {
        var updated = self
        updated.lastRunAt = now
        return updated
    }
}
