import Foundation

/// One row of the floating balloon's home menu.
///
/// The behaviour is fixed per `kind` — these rows switch panels, expand the
/// window, or dismiss the balloon, so they can't be reduced to arbitrary text
/// without losing what they do. What the user controls is the wording, the
/// order, and whether a row appears at all.
struct BalloonAction: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case askHere
        case lookAtScreen
        case codingSessions
        case openSomething
        case fullChat
        case dismiss

        var defaultTitle: String {
            switch self {
            case .askHere: "Ask Clippy here"
            case .lookAtScreen: "Look at this screen"
            case .codingSessions: "Continue a coding session"
            case .openSomething: "Open something"
            case .fullChat: "Open the full chat window"
            case .dismiss: "Don’t show me this right now"
            }
        }

        /// Shown in Settings so it's clear what a renamed row still does.
        var behaviourNote: String {
            switch self {
            case .askHere: "Focuses the reply box"
            case .lookAtScreen: "Reads the current window"
            case .codingSessions: "Lists Codex/Claude sessions"
            case .openSomething: "Opens an app or folder"
            case .fullChat: "Expands to the chat window"
            case .dismiss: "Hides the balloon"
            }
        }
    }

    var id: UUID
    var kind: Kind
    var title: String
    var isVisible: Bool

    init(id: UUID = UUID(), kind: Kind, title: String? = nil, isVisible: Bool = true) {
        self.id = id
        self.kind = kind
        self.title = title ?? kind.defaultTitle
        self.isVisible = isVisible
    }

    /// What a fresh install starts with: every row, in the original order.
    static var defaults: [BalloonAction] {
        Kind.allCases.map { BalloonAction(kind: $0) }
    }

    /// Restores anything the stored list is missing — a build that adds a new
    /// `Kind` would otherwise leave existing users unable to reach it, since
    /// their persisted list predates it. Appended hidden so it can't silently
    /// rearrange a menu the user has already arranged.
    static func merged(stored: [BalloonAction]) -> [BalloonAction] {
        var result = stored
        for kind in Kind.allCases where !stored.contains(where: { $0.kind == kind }) {
            result.append(BalloonAction(kind: kind, isVisible: false))
        }
        return result
    }

    /// Falls back to the built-in wording rather than rendering a blank row if
    /// the user clears the field.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.defaultTitle : trimmed
    }
}
