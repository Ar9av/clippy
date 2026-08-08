import Foundation

/// Evaluates the Prismor Warden policy that defines Clippy's on-screen
/// guardrail. Every refusal Clippy makes comes from here; no rule text lives
/// in Swift any more.
///
/// Implements the subset of Warden's documented semantics that a GUI agent
/// needs — rule matching by field, `enabled`, `mode`, `add_patterns`,
/// `disable_patterns`, and allowlist suppression — against `ui_action`
/// events (`Resources/prismor-policy.yaml` explains that event type).
///
/// **Fail-closed.** A policy that is missing, unreadable, or contains a regex
/// the evaluator can't compile does not degrade into "allow": `load()`
/// substitutes `.denyAll`, under which every consequential action is refused
/// and Clippy falls back to answering in words. A guardrail that silently
/// stops guarding is worse than one that visibly stops working.
public struct PrismorPolicy: Sendable {
    public struct Rule: Decodable, Sendable {
        public let id: String
        public let severity: String
        public let category: String
        public let title: String
        public let eventTypes: [String]
        public let fields: [String]?
        public let patterns: [String]
        public let action: String
        public let mode: String?
        public let enabled: Bool?
        public let addPatterns: [String]?
        public let disablePatterns: [String]?

        enum CodingKeys: String, CodingKey {
            case id, severity, category, title, patterns, action, mode, enabled, fields
            case eventTypes = "event_types"
            case addPatterns = "add_patterns"
            case disablePatterns = "disable_patterns"
        }

        /// Warden's strengthen-only override semantics: `add_patterns` extends
        /// a rule, `disable_patterns` removes defaults by exact regex string,
        /// and an entry matching nothing is ignored — drift fails towards more
        /// detection, not less.
        var effectivePatterns: [String] {
            let disabled = Set(disablePatterns ?? [])
            return (patterns + (addPatterns ?? [])).filter { !disabled.contains($0) }
        }

        var isEnabled: Bool { enabled ?? true }
        var isEnforced: Bool { (mode ?? "observe") == "enforce" }
    }

    public struct Allowlist: Decodable, Sendable {
        public let id: String
        public let ruleIDs: [String]
        public let patterns: [String]
        public let reason: String?

        enum CodingKeys: String, CodingKey {
            case id, patterns, reason
            case ruleIDs = "rule_ids"
        }
    }

    struct Settings: Decodable, Sendable {
        let defaultMode: String?

        enum CodingKeys: String, CodingKey {
            case defaultMode = "default_mode"
        }
    }

    struct Document: Decodable, Sendable {
        let version: String
        let rules: [Rule]
        let allowlists: [Allowlist]?
        let settings: Settings?
    }

    /// The pseudo rule id an allowlist entry targets when it is a veto rather
    /// than a permission — matching it disqualifies every other allowlist for
    /// that value. See `gui-form-field-guard` in the policy.
    private static let vetoRuleID = "__veto__"

    private let rules: [Rule]
    private let allowlists: [Allowlist]
    private let compiled: [String: [NSRegularExpression]]
    private let compiledAllowlists: [String: [NSRegularExpression]]
    public let isFailClosed: Bool

    /// The policy used when the real one can't be loaded: no rules, and every
    /// query answers in the most restrictive direction available.
    public static let denyAll = PrismorPolicy(
        rules: [], allowlists: [], compiled: [:], compiledAllowlists: [:], isFailClosed: true
    )

    private init(
        rules: [Rule],
        allowlists: [Allowlist],
        compiled: [String: [NSRegularExpression]],
        compiledAllowlists: [String: [NSRegularExpression]],
        isFailClosed: Bool
    ) {
        self.rules = rules
        self.allowlists = allowlists
        self.compiled = compiled
        self.compiledAllowlists = compiledAllowlists
        self.isFailClosed = isFailClosed
    }

    /// The policy shipped with this build, compiled from
    /// `Resources/prismor-policy.yaml` by `scripts/compile-policy.sh`.
    /// Resolved once — a guardrail consulted on every plan step can't be
    /// re-parsing JSON each time.
    /// `Bundle.main` first, `Bundle.module` second, matching how
    /// `ClippySpriteView` finds the sprite sheet: `build-dmg.sh` copies the
    /// policy straight into Contents/Resources, while a `swift run` build has
    /// only the SwiftPM resource bundle.
    public static let active: PrismorPolicy = {
        let url = Bundle.main.url(forResource: "prismor-policy", withExtension: "json")
            ?? Bundle.module.url(forResource: "prismor-policy", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else { return .denyAll }
        return (try? PrismorPolicy(data: data)) ?? .denyAll
    }()

    public init(data: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: data)
        var compiled: [String: [NSRegularExpression]] = [:]
        for rule in document.rules where rule.isEnabled {
            // A rule whose pattern won't compile is a rule that would silently
            // never match. Refuse the whole policy rather than quietly
            // shipping a guardrail with a hole in it.
            compiled[rule.id] = try rule.effectivePatterns.map {
                try NSRegularExpression(pattern: $0, options: [.caseInsensitive])
            }
        }
        var compiledAllowlists: [String: [NSRegularExpression]] = [:]
        for entry in document.allowlists ?? [] {
            compiledAllowlists[entry.id] = try entry.patterns.map {
                try NSRegularExpression(pattern: $0, options: [.caseInsensitive])
            }
        }
        self.rules = document.rules
        self.allowlists = document.allowlists ?? []
        self.compiled = compiled
        self.compiledAllowlists = compiledAllowlists
        self.isFailClosed = false
    }

    /// Whether `value` trips the given rule, after allowlist suppression.
    ///
    /// `isFailClosed` deliberately does not force `true` here: a deny-all
    /// policy has no rules, so callers ask it through the intent-named helpers
    /// in `AutomationSafety`, which know which direction "most restrictive"
    /// points for each question. (For `isFinalAction` that's `true`; for
    /// `isSafeAddressBarSubmit` it's `false`.)
    public func matches(ruleID: String, value: String) -> Bool {
        guard let rule = rules.first(where: { $0.id == ruleID }), rule.isEnabled,
              let expressions = compiled[ruleID] else {
            return false
        }
        guard expressions.contains(where: { $0.matches(value) }) else { return false }
        guard rule.isEnforced else { return false }
        return !isSuppressed(ruleID: ruleID, value: value)
    }

    /// Allowlist suppression, with the veto entries checked first so a
    /// permission can never be granted to something a veto claims.
    private func isSuppressed(ruleID: String, value: String) -> Bool {
        for entry in allowlists where entry.ruleIDs.contains(Self.vetoRuleID) {
            if compiledAllowlists[entry.id]?.contains(where: { $0.matches(value) }) == true {
                return false
            }
        }
        for entry in allowlists where entry.ruleIDs.contains(ruleID) || entry.ruleIDs.contains("*") {
            if compiledAllowlists[entry.id]?.contains(where: { $0.matches(value) }) == true {
                return true
            }
        }
        return false
    }

    /// Whether an allowlist entry positively grants `value` — the question
    /// "may Clippy press Return here?", which is an exception being claimed
    /// rather than a rule being tripped. Vetoes win.
    public func isAllowed(entryID: String, value: String) -> Bool {
        guard let entry = allowlists.first(where: { $0.id == entryID }),
              let expressions = compiledAllowlists[entryID] else {
            return false
        }
        for veto in allowlists where veto.ruleIDs.contains(Self.vetoRuleID) {
            if compiledAllowlists[veto.id]?.contains(where: { $0.matches(value) }) == true {
                return false
            }
        }
        _ = entry
        return expressions.contains(where: { $0.matches(value) })
    }

    /// One line per active rule, for the Settings screen and `--explain`
    /// style output. A user should be able to read what Clippy will refuse
    /// without opening the policy file.
    public var activeRuleSummaries: [String] {
        rules.filter(\.isEnabled).map { "[\($0.severity)] \($0.id): \($0.title)" }
    }
}

private extension NSRegularExpression {
    func matches(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return firstMatch(in: value, range: range) != nil
    }
}
