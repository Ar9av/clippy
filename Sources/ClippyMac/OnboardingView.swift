import AppKit
import Speech
import SwiftUI

/// First-run permission priming. Shown once (tracked by a UserDefaults
/// flag) instead of leaving permissions to be discovered lazily the first
/// time a feature silently fails — the app previously had no first-run flow
/// at all.
struct OnboardingView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject var permissions: PermissionsModel
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Clippy")
                    .font(.title2.bold())
                Text("A desktop assistant that can chat, see your screen, and carefully guide or click through tasks with your confirmation. A couple of permissions make that possible — you can grant them now or later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            permissionRow(
                title: "Accessibility",
                why: "Lets Clippy type finished text into a field you've focused, when you ask it to.",
                granted: permissions.accessibilityGranted,
                enable: { ScreenTypingService.shared.requestAccessibilityPermission() },
                openSettings: { ScreenTypingService.shared.openAccessibilitySettings() }
            )

            permissionRow(
                title: "Screen Recording",
                why: "Lets Clippy look at the current app to answer questions about what's on screen, or find a control to click.",
                granted: permissions.screenRecordingGranted,
                enable: { ScreenAwarenessService.shared.requestPermissions() },
                openSettings: { ScreenAwarenessService.shared.openScreenRecordingSettings() }
            )

            permissionRow(
                title: "Speech Recognition",
                why: "Optional — only used if you tap the dictation button to speak a message instead of typing.",
                granted: permissions.speechRecognitionStatus == .authorized,
                enable: { SFSpeechRecognizer.requestAuthorization { _ in } },
                openSettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Get Started") {
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 460)
        .onAppear { permissions.refresh() }
    }

    private func permissionRow(
        title: String,
        why: String,
        granted: Bool,
        enable: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(granted ? Color.green : Color.primary)
                    Spacer()
                    if granted {
                        Text("Granted").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Enable…") {
                            enable()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                permissions.refresh()
                            }
                        }
                        Button("Open Settings") { openSettings() }
                    }
                }
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }
}
