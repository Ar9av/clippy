import AppKit

/// Terminals and agent CLIs run real commands, so a drafted reply or
/// auto-typed confirmation landing in one could in principle trigger a real
/// command. Left empty at the user's explicit request (everything runs on
/// their own machine) — the residual guard against that is that
/// `ScreenPlanKey` still excludes Return everywhere except a browser
/// address/search bar (see `isSafeAddressBarSubmit`), so Clippy can still type
/// into a terminal but can't press Enter to submit it. Re-add bundle
/// identifiers/name fragments here to restore the restriction.
public enum AutomationSafety {
    private static let blockedBundleIdentifiers: Set<String> = []

    private static let blockedNameFragments: [String] = []

    public static func isRestricted(_ application: NSRunningApplication) -> Bool {
        if let bundleIdentifier = application.bundleIdentifier,
           blockedBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        return isRestrictedName(application.localizedName ?? "")
    }

    /// Used when a plan names an app that isn't running yet, so a restricted
    /// target is refused before it is ever launched.
    public static func isRestrictedName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return blockedNameFragments.contains { normalized.contains($0) }
    }

    /// Controls Clippy must never operate: the last click of a form, a
    /// purchase, a deletion, or anything that hands over credentials. One list
    /// shared by the plan validator, the runner, and the single-click path so
    /// they can't drift apart.
    private static let finalActionFragments = [
        "send", "submit", "publish", "post", "buy", "purchase", "pay",
        "delete", "remove", "accept", "agree", "place order", "transfer",
        "password", "passcode", "confirm", "checkout", "sign out", "log out"
    ]

    public static func isFinalAction(_ label: String) -> Bool {
        containsWord(label, in: finalActionFragments)
    }

    /// Splits `text` on anything that isn't a letter/digit and checks whether
    /// any resulting word (or, for multi-word fragments like "place order",
    /// the raw substring) matches a fragment. This is deliberately stricter
    /// than a bare `contains`: "sender name" and "repost" must not match
    /// "send"/"post", while "Send message" and "Buy now" still must.
    private static func containsWord(_ text: String, in fragments: [String]) -> Bool {
        let normalized = text.lowercased()
        let words = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        for fragment in fragments {
            if fragment.contains(" ") {
                if normalized.contains(fragment) { return true }
            } else if words.contains(fragment) {
                return true
            }
        }
        return false
    }

    /// Fields whose contents must never be read back, retyped, or auto-typed
    /// into: passwords, passcodes, and anything the OS itself marks as a
    /// secure text field. Kept alongside the label-based checks so the
    /// AX-role-based check (`ScreenAwarenessService.put`) and any future
    /// label-only callers share the same judgment about what counts as secure.
    public static func isSecureField(role: String, subrole: String) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    /// Fragments that indicate a field belongs to a real browser location/search
    /// bar, never a form field that merely happens to be labelled "address".
    private static let addressFieldFragments = [
        "address and search", "address or search", "location bar", "omnibox",
        "search or type", "search bar"
    ]

    private static let addressFieldExactFragments: Set<String> = ["url", "address bar"]

    /// Labels that mean a field belongs to a form (shipping, billing, contact,
    /// account) rather than a browser chrome control, even though the word
    /// "address" appears in both. Checked first and unconditionally disqualifies
    /// a target, so a browser-chrome match can never be masked by these.
    private static let formFieldFragments = [
        "email", "billing", "shipping", "street", "mailing", "home address",
        "form", "contact", "recipient"
    ]

    /// The one narrow exception to "Clippy never sends the Return key":
    /// submitting a browser's own address/search field, whether that's a URL
    /// (navigate) or plain text (search with the default engine). Either way
    /// it's the browser's own "go" action — never a form submission, a
    /// purchase, or anything else `isFinalAction` guards against. The
    /// destination field must specifically look like browser chrome — bare
    /// "address" is not enough, since "Email address"/"Billing address" form
    /// fields also contain that word. A step that doesn't satisfy this must
    /// fall back to leaving the text typed and letting the user press Return
    /// themselves.
    public static func isSafeAddressBarSubmit(target: String, text: String) -> Bool {
        let normalizedTarget = target.lowercased()
        guard !formFieldFragments.contains(where: normalizedTarget.contains) else {
            return false
        }
        let matchesChrome = addressFieldFragments.contains(where: normalizedTarget.contains)
            || containsWord(normalizedTarget, in: Array(addressFieldExactFragments))
        guard matchesChrome else {
            return false
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedText.isEmpty && !trimmedText.contains("\n")
    }
}
