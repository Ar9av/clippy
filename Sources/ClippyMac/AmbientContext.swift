import AppKit
import Foundation

/// The cheap half of situational awareness: what Clippy can know about the
/// user's desk without taking a screenshot or reading an accessibility tree.
///
/// This exists because the expensive half is now conditional — a plain
/// question no longer triggers a full screen capture (see
/// `ChatViewModel.startRequest`), and without this it would also lose the
/// small amount of context that made replies feel situated rather than
/// generic. Every value here comes from an API that needs no permission and
/// returns immediately, so it can go on every request.
enum AmbientContext {
    static func promptBlock(now: Date = Date()) -> String {
        var lines = ["Right now: \(timestamp(now))."]
        if let front = frontmostAppName() {
            lines.append("The app in front of them is \(front). You have not looked at its contents.")
        }
        lines.append("""
        This is background, not a topic. Mention it only when it actually bears on the answer — \
        don't greet them with the time or remark on what they have open.
        """)
        return lines.joined(separator: " ")
    }

    /// Excludes Clippy itself. Clippy is a floating always-available panel, so
    /// it is frequently the frontmost application at the moment the user hits
    /// send — reporting "the app in front of them is Clippy" would be true,
    /// useless, and actively misleading about what they were just doing.
    private static func frontmostAppName() -> String? {
        let bundleID = Bundle.main.bundleIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != bundleID,
              let name = app.localizedName,
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEEE d MMMM, h:mm a"
        return formatter.string(from: date)
    }
}
