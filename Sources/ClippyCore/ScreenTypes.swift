import CoreGraphics
import Foundation

/// One actionable control found on screen via the accessibility tree.
public struct ScreenElementSummary: Identifiable, Equatable {
    public let id: UUID
    public let label: String
    public let role: String
    public let frame: CGRect
    public let enabled: Bool
    /// The control's current contents, when it has readable ones: the text
    /// already in a field, or a popup button's selected option. Without this
    /// a model cannot tell an empty search box from one that already holds
    /// the query it was about to type, so it retypes into a field that was
    /// already correct, or appends to one it meant to replace.
    public let value: String?
    /// Checked/selected state for checkboxes, radio buttons, and tabs. Same
    /// reasoning as `value`: "click Enable" is the wrong step when Enable is
    /// already on, and the label alone never reveals that.
    public let checked: Bool?
    /// Whether this control currently holds keyboard focus — the difference
    /// between "type here" needing a click first and not.
    public let focused: Bool

    public init(
        id: UUID,
        label: String,
        role: String,
        frame: CGRect,
        enabled: Bool,
        value: String? = nil,
        checked: Bool? = nil,
        focused: Bool = false
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.frame = frame
        self.enabled = enabled
        self.value = value
        self.checked = checked
        self.focused = focused
    }

    /// Long field contents are truncated: the point is to tell the model what
    /// is already there, not to paste an entire document into every request.
    private var valueFragment: String {
        guard let value else { return "" }
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return " = (empty)" }
        let shown = collapsed.count > 80 ? String(collapsed.prefix(80)) + "…" : collapsed
        return " = \"\(shown)\""
    }

    public var contextLine: String {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var line = "- \(role): \"\(label)\" at (\(Int(center.x)), \(Int(center.y)))"
        line += valueFragment
        if let checked {
            line += checked ? " [checked]" : " [unchecked]"
        }
        if focused { line += " [focused]" }
        if !enabled { line += " [disabled]" }
        return line
    }
}

extension ScreenElementSummary {
    private static let editableRoles: Set<String> = ["TextField", "TextArea", "ComboBox", "SearchField"]

    /// True when the label is a real name rather than the role fallback the
    /// scanner substitutes for an unnamed control. An unnamed "Button" is
    /// almost useless to a model — it can't be matched by label, and there are
    /// usually dozens of them — so it's the first thing dropped when the list
    /// has to be cut.
    var hasMeaningfulLabel: Bool {
        !label.isEmpty && label != role
    }

    var promptPriority: Int {
        var score = 0
        if focused { score += 5 }
        if Self.editableRoles.contains(role) { score += 4 }
        if hasMeaningfulLabel { score += 3 }
        if role == "MenuBarItem" || role == "MenuItem" { score += 2 }
        if !enabled { score -= 4 }
        return score
    }

    /// Chooses which controls go into the prompt, and in what order.
    ///
    /// The scan finds far more than fits in a request, and taking the first
    /// N in traversal order is close to arbitrary — traversal order follows
    /// the view hierarchy, so a cut there can drop every control in the pane
    /// the user is actually looking at while keeping a toolbar's worth of
    /// unnamed buttons. Rank first, then present the survivors in reading
    /// order, which is the order a model reads a screenshot in.
    public static func promptOrdered(_ elements: [ScreenElementSummary], limit: Int) -> [ScreenElementSummary] {
        let kept: [ScreenElementSummary]
        if elements.count <= limit {
            kept = elements
        } else {
            kept = Array(
                elements
                    .enumerated()
                    .sorted { left, right in
                        let leftScore = left.element.promptPriority
                        let rightScore = right.element.promptPriority
                        if leftScore != rightScore { return leftScore > rightScore }
                        return left.offset < right.offset
                    }
                    .prefix(limit)
                    .map(\.element)
            )
        }
        // Band the y axis so controls sitting on the same visual row stay
        // together instead of being split by a few points of height jitter.
        return kept.sorted { left, right in
            let leftRow = Int(left.frame.midY / 24)
            let rightRow = Int(right.frame.midY / 24)
            if leftRow != rightRow { return leftRow < rightRow }
            return left.frame.midX < right.frame.midX
        }
    }
}

/// One display, captured whole.
public struct DisplayShot: Equatable {
    /// Human-readable name for the prompt ("Built-in", "DELL S2725QC").
    public let name: String
    public let url: URL
    /// The display's frame in the same global point space as
    /// `ScreenElementSummary.frame` — displays tile side by side in that
    /// space, so a control on the second monitor simply has a larger x.
    public let frame: CGRect
    /// Pixels per point in the written image, after downscaling.
    public let scale: CGFloat
    /// Whether this is the display holding the window being acted on. Exactly
    /// one shot is the anchor, and it defines the coordinate space every
    /// model-supplied x/y is interpreted in.
    public let isAnchor: Bool

    public init(name: String, url: URL, frame: CGRect, scale: CGFloat, isAnchor: Bool) {
        self.name = name
        self.url = url
        self.frame = frame
        self.scale = scale
        self.isAnchor = isAnchor
    }
}

/// A single observation of the screen: one image per display, an accessibility
/// scan of the active app, and the metadata needed to validate/correct
/// model-supplied coordinates.
public struct ScreenContext {
    public let appName: String
    public let windowTitle: String
    public let contextURL: URL
    public let elements: [ScreenElementSummary]
    /// Every attached display, captured in full. Ordered anchor-first so a
    /// consumer that only wants one image gets the one being acted on.
    public let displayShots: [DisplayShot]
    /// The coordinate space model-supplied x/y are interpreted in: the frame
    /// of the display holding the active window. Actions are bounded to this
    /// display — Clippy can see every screen but only acts on the active one.
    public let windowFrame: CGRect
    /// The anchor image's pixel-per-point scale. A model that reads
    /// coordinates off the image itself (rather than the point-space list in
    /// the context text) produces values roughly `scale` times too large —
    /// this lets the dispatch path detect and correct that.
    public let screenshotScale: CGFloat

    /// The anchor display's image — what every existing single-image consumer
    /// should use when it wants just one.
    public var screenshotURL: URL {
        (displayShots.first(where: \.isAnchor) ?? displayShots[0]).url
    }

    /// Every captured image, anchor first.
    public var screenshotURLs: [URL] { displayShots.map(\.url) }

    public init(
        appName: String,
        windowTitle: String,
        contextURL: URL,
        elements: [ScreenElementSummary],
        displayShots: [DisplayShot],
        windowFrame: CGRect,
        screenshotScale: CGFloat
    ) {
        precondition(!displayShots.isEmpty, "a capture always has at least one display")
        self.appName = appName
        self.windowTitle = windowTitle
        self.contextURL = contextURL
        self.elements = elements
        self.displayShots = displayShots
        self.windowFrame = windowFrame
        self.screenshotScale = screenshotScale
    }
}

public struct PendingScreenAction: Identifiable, Equatable {
    public let id = UUID()
    public let label: String
    public let detail: String

    public init(label: String, detail: String) {
        self.label = label
        self.detail = detail
    }
}

public enum ScreenAwarenessError: LocalizedError {
    case accessibilityPermission
    case screenRecordingPermission
    case noExternalApp
    case noWindow
    case targetNotFound(String)
    case targetUnavailable
    case unsafeAction(String)
    case notEditable(String)
    case restrictedApp(String)
    case appNotFound(String)
    case textNotAccepted(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermission:
            "Allow Clippy in System Settings → Privacy & Security → Accessibility."
        case .screenRecordingPermission:
            "Allow Clippy in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Clippy."
        case .noExternalApp:
            "Open the app you want help with, then ask Clippy to look again."
        case .noWindow:
            "I couldn’t find a visible window to inspect."
        case .targetNotFound(let label):
            "I couldn’t find “\(label)” on the current screen."
        case .targetUnavailable:
            "That control moved or disappeared. Ask Clippy to look again."
        case .unsafeAction(let label):
            "Clippy won’t automatically activate “\(label)”. Please do that final step yourself."
        case .notEditable(let label):
            "“\(label)” is not an editable text field."
        case .restrictedApp(let name):
            "Clippy won’t drive \(name) — terminals and agent CLIs run real commands."
        case .appNotFound(let name):
            "I couldn’t find an app called “\(name)”."
        case .textNotAccepted(let label):
            "“\(label)” didn’t accept the text. Click into it yourself and ask me again."
        }
    }
}
