import AppKit

/// Terminals and agent CLIs run real commands. Clippy must never read their
/// content as "a message to reply to" or write text into them — a drafted
/// reply or auto-typed confirmation could silently trigger a destructive or
/// long-running command (a build, a delete, a deploy) with no real consent.
enum AutomationSafety {
    private static let blockedBundleIdentifiers: Set<String> = [
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "io.alacritty",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "com.openai.chat",
        "com.anthropic.claudefordesktop",
        "com.anthropic.claude"
    ]

    private static let blockedNameFragments = [
        "warp", "terminal", "iterm", "alacritty", "hyper", "kitty",
        "wezterm", "ghostty", "codex", "claude"
    ]

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
    /// typing a URL into a browser's own address/search field and pressing
    /// Return to navigate. That's what "go to a page" means — it isn't a
    /// form submission, a purchase, or anything else `isFinalAction` guards
    /// against. Both the destination field AND the text have to look the
    /// part; a step that doesn't satisfy this must fall back to leaving the
    /// text typed and letting the user press Return themselves.
    static func isSafeURLNavigation(target: String, text: String) -> Bool {
        let normalizedTarget = target.lowercased()
        guard addressFieldFragments.contains(where: normalizedTarget.contains) else {
            return false
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.contains("\n") == false else { return false }
        return trimmedText.lowercased().hasPrefix("http://")
            || trimmedText.lowercased().hasPrefix("https://")
    }
}
