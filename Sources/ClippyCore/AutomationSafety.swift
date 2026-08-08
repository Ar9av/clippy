import AppKit

/// The call sites' view of the guardrail. Every question here is answered by
/// the Prismor Warden policy in `Resources/prismor-policy.yaml` — this type
/// holds no rule text of its own, only the knowledge of which direction
/// "refuse" points for each question when the policy can't be loaded.
///
/// The API is unchanged from the hand-written version it replaced, so the plan
/// validator, the runner, the single-click path, and the offline safety eval
/// all keep working against the same three questions.
public enum AutomationSafety {
    /// Rule and allowlist identifiers, matching the policy file. Typos here
    /// would silently disable a guardrail (an unknown rule id matches
    /// nothing), so they're named once and asserted by
    /// `PrismorPolicyTests.testEveryIdentifierThisCodeAsksForExists`.
    enum PolicyID {
        static let finalAction = "gui-final-action"
        static let secureField = "gui-secure-field"
        static let returnKey = "gui-return-key"
        static let restrictedApp = "gui-restricted-app"
        static let addressBarSubmit = "browser-address-bar-submit"
    }

    static var policy: PrismorPolicy { .active }

    /// Apps that run real commands, which Clippy must not drive. Disabled in
    /// the shipped policy at the user's explicit request — see the
    /// `gui-restricted-app` rule, which documents the reasoning and can be
    /// flipped back on without touching Swift.
    public static func isRestricted(_ application: NSRunningApplication) -> Bool {
        isRestrictedName(application.localizedName ?? "")
    }

    /// Used when a plan names an app that isn't running yet, so a restricted
    /// target is refused before it is ever launched.
    public static func isRestrictedName(_ name: String) -> Bool {
        policy.matches(ruleID: PolicyID.restrictedApp, value: name)
    }

    /// Controls Clippy must never operate: the last click of a form, a
    /// purchase, a deletion, or anything that hands over credentials.
    ///
    /// Fails closed. With no usable policy there is no way to tell a harmless
    /// button from "Confirm payment", so every control is treated as final and
    /// Clippy stops asking to click things.
    public static func isFinalAction(_ label: String) -> Bool {
        if policy.isFailClosed { return true }
        return policy.matches(ruleID: PolicyID.finalAction, value: label)
    }

    /// Fields whose contents must never be read back, retyped, or auto-typed
    /// into. Matched on the accessibility role rather than the label, so it
    /// holds even when a password field is labelled something harmless.
    public static func isSecureField(role: String, subrole: String) -> Bool {
        if policy.isFailClosed { return true }
        return policy.matches(ruleID: PolicyID.secureField, value: role)
            || policy.matches(ruleID: PolicyID.secureField, value: subrole)
    }

    /// The one narrow exception to "Clippy never sends the Return key":
    /// submitting a browser's own address/search field, whether that's a URL
    /// (navigate) or plain text (search with the default engine). Either way
    /// it's the browser's own "go" — never a form submission or a purchase.
    ///
    /// Fails closed in the other direction: an exception that can't be
    /// verified isn't granted, so Clippy types the text and leaves Return to
    /// the user.
    public static func isSafeAddressBarSubmit(target: String, text: String) -> Bool {
        guard !policy.isFailClosed else { return false }
        guard policy.isAllowed(entryID: PolicyID.addressBarSubmit, value: target) else {
            return false
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedText.isEmpty && !trimmedText.contains("\n")
    }

    /// What this build will refuse, in the user's words rather than the
    /// policy's. Surfaced in Settings so the guardrail is inspectable without
    /// reading YAML.
    public static var activeRuleSummaries: [String] {
        policy.isFailClosed
            ? ["Policy unavailable — every screen action is being refused."]
            : policy.activeRuleSummaries
    }
}
