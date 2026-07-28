import AppKit

/// Terminals and agent CLIs run real commands, so a drafted reply or
/// auto-typed confirmation landing in one could in principle trigger a real
/// command. Left empty at the user's explicit request (everything runs on
/// their own machine) — the residual guard against that is that
/// `ScreenPlanKey` still excludes Return everywhere except a browser
/// address/search bar (see `isSafeAddressBarSubmit`), so Clippy can still type
/// into a terminal but can't press Enter to submit it. Re-add bundle
/// identifiers/name fragments here to restore the restriction.
enum AutomationSafety {
    private static let blockedBundleIdentifiers: Set<String> = []

    private static let blockedNameFragments: [String] = []

    static func isRestricted(_ application: NSRunningApplication) -> Bool {
        if let bundleIdentifier = application.bundleIdentifier,
           blockedBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        return isRestrictedName(application.localizedName ?? "")
    }

    /// Used when a plan names an app that isn't running yet, so a restricted
    /// target is refused before it is ever launched.
    static func isRestrictedName(_ name: String) -> Bool {
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

    static func isFinalAction(_ label: String) -> Bool {
        let normalized = label.lowercased()
        return finalActionFragments.contains { normalized.contains($0) }
    }

    private static let addressFieldFragments = [
        "address", "url", "location bar", "omnibox", "search bar", "search or type"
    ]

    /// The one narrow exception to "Clippy never sends the Return key":
    /// submitting a browser's own address/search field, whether that's a URL
    /// (navigate) or plain text (search with the default engine). Either way
    /// it's the browser's own "go" action — never a form submission, a
    /// purchase, or anything else `isFinalAction` guards against. Only the
    /// destination field has to look the part; any single-line, non-empty
    /// text qualifies, since there's no bare-URL-vs-search-query distinction
    /// worth gatekeeping when the field itself is what's actually safe here.
    /// A step that doesn't satisfy this must fall back to leaving the text
    /// typed and letting the user press Return themselves.
    static func isSafeAddressBarSubmit(target: String, text: String) -> Bool {
        let normalizedTarget = target.lowercased()
        guard addressFieldFragments.contains(where: normalizedTarget.contains) else {
            return false
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedText.isEmpty && !trimmedText.contains("\n")
    }
}
