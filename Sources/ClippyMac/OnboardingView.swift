import AppKit
import Speech
import SwiftUI

/// First-run permission priming. Shown once (tracked by a UserDefaults
/// flag) instead of leaving permissions to be discovered lazily the first
/// time a feature silently fails — the app previously had no first-run flow
/// at all.
struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsModel
    // `SpeechService` is a nested ObservableObject on ChatViewModel, not a
    // `@Published` property of it — reading it through
    // `@EnvironmentObject var viewModel: ChatViewModel` alone would not
    // subscribe this view to its changes, so it's passed in and observed
    // directly instead (same reason `permissions` above is its own
    // `@ObservedObject` rather than read off `viewModel`).
    @ObservedObject var speech: SpeechService
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

            // Scrollable: the permission + feature rows can grow past a
            // fixed height (as the Whisper row did the moment it was
            // added), and a plain VStack silently clips overflow instead
            // of resizing the sheet.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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

                    whisperDictationRow
                }
                .padding(.vertical, 2)
            }

            HStack {
                Spacer()
                Button("Get Started") {
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 560)
        .onAppear { permissions.refresh() }
    }

    /// Optional: which recogniser dictation runs through. Distinct from
    /// `permissionRow` above since there's no system permission to grant —
    /// just a one-time model download the user opts into. Apple's engine is
    /// the default and needs nothing.
    private var whisperDictationRow: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        "Dictation Engine",
                        systemImage: speech.engine.needsModelDownload ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(speech.engine.needsModelDownload ? Color.green : Color.primary)
                    Spacer()
                    Text("Optional").font(.caption).foregroundStyle(.secondary)
                }
                Text("The local engines transcribe entirely on this Mac — your voice never leaves it — and each downloads its model once. Apple's needs no download but may send audio off the machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if speech.isPreparingModel {
                    ProgressView(value: speech.modelDownloadProgress)
                    Text("Downloading model…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: Binding(
                        get: { speech.engine },
                        set: { newValue in
                            speech.engine = newValue
                            Task { await speech.prepareModel() }
                        }
                    )) {
                        ForEach(DictationEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    Text(speech.engine.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if speech.engine.needsModelDownload, let error = speech.authorizationError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(6)
        }
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
