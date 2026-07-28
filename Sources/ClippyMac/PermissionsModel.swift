import AppKit
import ApplicationServices
import Speech

/// Consolidates the three permission checks that were previously scattered
/// across `ScreenAwarenessService`, `ScreenTypingService`, and `SpeechService`
/// into one read surface, re-checked whenever the app becomes active (the
/// only reliable moment to notice the user just granted something in System
/// Settings). Used by Settings' permission cards today; a first-run
/// onboarding flow is the natural next consumer.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var speechRecognitionStatus = SFSpeechRecognizer.authorizationStatus()

    private var activationObserver: Any?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        speechRecognitionStatus = SFSpeechRecognizer.authorizationStatus()
    }

    var allCoreGranted: Bool {
        accessibilityGranted && screenRecordingGranted
    }
}
