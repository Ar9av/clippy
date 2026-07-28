import CoreGraphics
import Foundation

/// One actionable control found on screen via the accessibility tree.
public struct ScreenElementSummary: Identifiable, Equatable {
    public let id: UUID
    public let label: String
    public let role: String
    public let frame: CGRect
    public let enabled: Bool

    public init(id: UUID, label: String, role: String, frame: CGRect, enabled: Bool) {
        self.id = id
        self.label = label
        self.role = role
        self.frame = frame
        self.enabled = enabled
    }

    public var contextLine: String {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return "- \(role): \"\(label)\" at (\(Int(center.x)), \(Int(center.y)))"
            + (enabled ? "" : " [disabled]")
    }
}

/// A single screen capture: a screenshot, an accessibility scan, and the
/// window metadata needed to validate/correct model-supplied coordinates.
public struct ScreenContext {
    public let appName: String
    public let windowTitle: String
    public let screenshotURL: URL
    public let contextURL: URL
    public let elements: [ScreenElementSummary]
    /// The captured window's frame in the same global point space as
    /// `elements`' frames — used to validate/clamp any model-supplied x/y
    /// coordinates before they're ever dispatched as a click.
    public let windowFrame: CGRect
    /// The screenshot's pixel-per-point scale (e.g. 2 on a Retina display).
    /// A model that reads coordinates off the screenshot image itself
    /// (rather than the point-space list in the context text) will produce
    /// pixel coordinates roughly `scale` times too large — this lets the
    /// dispatch path detect and correct that.
    public let screenshotScale: CGFloat

    public init(
        appName: String,
        windowTitle: String,
        screenshotURL: URL,
        contextURL: URL,
        elements: [ScreenElementSummary],
        windowFrame: CGRect,
        screenshotScale: CGFloat
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.screenshotURL = screenshotURL
        self.contextURL = contextURL
        self.elements = elements
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
