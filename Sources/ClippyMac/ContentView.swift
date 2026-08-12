import AppKit
import ClippyCore
import SwiftUI

private enum CompactPanel: Equatable {
    case home
    case sessions
    case open
}

/// SwiftUI's `NSHostingView` repaints its own opaque layer background on
/// every re-render (new chat messages, plan cards, animation frames), which
/// silently undoes the one-shot `NSWindow` transparency setup done in
/// `AppDelegate.configureWindows()`. `updateNSView` runs alongside every
/// SwiftUI diff pass, so re-asserting clarity here keeps it from reverting.
private struct TransparentWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSView) {
        guard let window = view.window else { return }
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

struct ContentView: View {
    /// Swaps the expanded window's conversation area for the scheduled-checks
    /// dashboard.
    @State private var showScheduleDashboard = false

    @EnvironmentObject private var viewModel: ChatViewModel
    // `SpeechService` is a nested ObservableObject on ChatViewModel, not one
    // of its `@Published` properties — reading `speech.X` here
    // does NOT subscribe this view to speech's own changes, so isListening
    // toggling, dictation errors, and the model-download state only ever
    // appeared to update when something else (draft, isLoading, a hover
    // state) happened to force a re-render at the same time. Observed
    // directly instead, same reasoning as OnboardingView/SettingsView.
    @ObservedObject var speech: SpeechService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveringClippy = false
    @State private var compactInputActive = false
    @State private var compactBalloonVisible = true
    @State private var pasteMonitor: Any?
    @State private var pushToTalk: PushToTalkMonitor?
    /// Whether the in-flight push-to-talk session was started while another
    /// app was frontmost. Captured at press time, because by the time the keys
    /// come back up the answer may have changed — and it decides whether the
    /// text lands in that app's text field or in Clippy's own composer.
    @State private var dictationTargetsExternalApp = false
    @State private var compactInputFocused = false
    @State private var compactPanel: CompactPanel = .home
    @State private var showHistory = false
    /// Snapshot of the draft the moment dictation starts, so live transcript
    /// updates append to whatever the user already typed instead of
    /// replacing it outright — `SpeechService.transcript` resets to "" at
    /// the start of every dictation session.
    @State private var draftBeforeDictation = ""
    /// Set while the chat window is maximised; holds the frame to put back.
    @State private var scrollMetrics = RetroScrollMetrics()
    @State private var frameBeforeMaximize: NSRect?
    @State private var isMaximized = false

    private let suggestions = [
        "Help me think through an idea",
        "Rewrite something for me",
        "Explain a hard concept",
        "Plan my day"
    ]

    private var clippyMood: ClippyMood {
        if speech.isListening { return .listening }
        // isLoading only covers the initial chat request — a running or
        // retrying screen plan (including the decide-next-step follow-up
        // calls between actions) is a separate flag, and without this check
        // the sprite falls through to idle for the entire time Clippy is
        // actually working through a task.
        if viewModel.isLoading || viewModel.isRunningScreenPlan { return .thinking }
        if speech.isSpeaking { return .talking }
        if viewModel.errorMessage != nil { return .alert }
        if viewModel.recentlyCompleted { return .success }
        return .idle
    }

    var body: some View {
        Group {
            if viewModel.isExpanded {
                expandedAssistant
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                floatingAssistant
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: viewModel.isExpanded
        )
        .background(TransparentWindowConfigurator().allowsHitTesting(false))
        .ignoresSafeArea()
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(speech: viewModel.speech)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showOnboarding) {
            OnboardingView(permissions: viewModel.permissions, speech: viewModel.speech) {
                viewModel.finishOnboarding()
            }
            .environmentObject(viewModel)
        }
        .sheet(isPresented: $showHistory) {
            ChatHistoryView()
                .environmentObject(viewModel)
        }
        .onChange(of: speech.isListening) { _, isListening in
            if isListening { draftBeforeDictation = viewModel.draft }
        }
        // errorMessage previously stuck around indefinitely once set — the
        // compact balloon kept showing "I couldn't finish that: …" through
        // every later panel switch, since nothing but starting a brand new
        // request/retry/paste ever cleared it. Switching panels is itself a
        // clear enough signal the user has moved on from that error.
        .onChange(of: compactPanel) { _, _ in
            viewModel.errorMessage = nil
        }
        .onChange(of: viewModel.isExpanded) { _, _ in
            viewModel.errorMessage = nil
        }
        .onChange(of: speech.transcript) { _, newValue in
            applyDictationToDraft(newValue)
        }
        .onAppear {
            installPasteMonitor()
            installPushToTalkMonitor()
            publishBalloonVisibility()
            // A session may have ended while Clippy was closed, so this both
            // picks up what is already waiting and starts the poll.
            viewModel.startWatchingForFinishedSessions()
            // Push-to-talk is unusable if the first hold spends its whole
            // duration loading the model: you speak, release, and nothing was
            // ever recorded. Warm it up at launch instead so the microphone
            // opens as soon as the chord engages.
            Task { await speech.prepareModel() }
        }
        .onDisappear {
            if let pasteMonitor {
                NSEvent.removeMonitor(pasteMonitor)
                self.pasteMonitor = nil
            }
            pushToTalk?.stopMonitoring()
            pushToTalk = nil
        }
        .alert(
            "\(viewModel.character.title) needs permission",
            isPresented: Binding(
                get: { speech.authorizationError != nil },
                set: { if !$0 { speech.authorizationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(speech.authorizationError ?? "")
        }
    }

    private var expandedAssistant: some View {
        VStack(spacing: 0) {
            header
            // The transcript is a sunken white well, the way every chat client
            // of the era framed its log. Without it the messages floated
            // directly on the window face with nothing containing them, which
            // is what made the window look unfinished — and made a message
            // scrolled under the toolbar look clipped rather than scrolled.
            Group {
                // The dashboard takes the conversation's place rather than
                // opening a sheet: a background check is something you glance
                // at beside the chat, not something worth losing the chat to
                // look at.
                if showScheduleDashboard {
                    ScheduleDashboardView()
                } else {
                    conversation
                }
            }
            .background(RetroPalette.fieldBackground)
            .retroBevel(.sunken)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            if let plan = viewModel.pendingScreenPlan {
                screenPlanBanner(plan)
            }
            if let action = viewModel.pendingScreenAction {
                screenActionBanner(action)
            }
            if let handoff = viewModel.pendingSessionHandoff {
                sessionHandoffBanner(handoff)
            }
            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
            composer
        }
        .background(RetroFace())
        .frame(minWidth: 420, minHeight: 560)
        // Nothing may paint outside the window's own frame. Without this a
        // subview that overshoots its bounds renders over the desktop, beyond
        // the bevel, which reads as the window being broken rather than the
        // subview being wrong.
        .clipped()
        // Square, bevelled, and forced to light: the palette is fixed 1995
        // values with no dark variant, so an inherited dark scheme would put
        // white label text on grey.
        .retroBevel(.raised)
        .environment(\.colorScheme, .light)
        // Kept, though Windows 95 had no window shadow — this floats over the
        // desktop rather than sitting in a desktop of its own, and without it
        // the edge disappears against a light wallpaper.
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .padding(8)
    }

    private var floatingAssistant: some View {
        VStack(spacing: -5) {
            if compactBalloonVisible {
                classicBalloon
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            } else {
                Spacer()
                    .frame(height: 218)
            }

            Group {
                if viewModel.animateClippy && !reduceMotion {
                    AnimatedClippyView(mood: clippyMood)
                } else {
                    StaticClippyView()
                }
            }
                .frame(width: 110, height: 110)
                .offset(x: 31)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        setCompactBalloonVisible(!compactBalloonVisible)
                    }
                }
                .onTapGesture(count: 2) { viewModel.setExpanded(true) }
                .help(compactBalloonVisible ? "Hide balloon; double-click to open chat" : "Show balloon")
        }
        // Measures the balloon+sprite's real rendered size and relays it to
        // AppDelegate so the click-catching window can shrink to match — a
        // PreferenceKey/.onPreferenceChange here never delivered anything
        // past its (0, 0) default despite the GeometryReader itself
        // reporting correct sizes, so this reads proxy.size directly instead.
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear { publishBalloonContentSize(proxy.size) }
                    .onChange(of: proxy.size) { _, newSize in publishBalloonContentSize(newSize) }
            }
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
        .frame(width: 250, height: 340, alignment: .bottom)
    }

    private var classicBalloon: some View {
        VStack(alignment: .leading, spacing: 11) {
            // The balloon is the surface a notification should appear on — it
            // is what is on screen when you are not in the full window, which
            // is exactly when a terminal session finishing is worth telling
            // you about.
            HStack(alignment: .top, spacing: 8) {
                Text(compactStatusMessage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.black)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                Button {
                    viewModel.setExpanded(true)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        // A bare SF Symbol is only ~13pt across, and the window
                        // is `isMovableByWindowBackground`, so a near-miss got
                        // interpreted as a window drag rather than a click —
                        // the button looked dead. Give it a real target, like
                        // the expanded window's header buttons already have.
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .help("Open full chat")
            }

            if viewModel.isLoading {
                compactActivityRow
            }

            if let action = viewModel.pendingScreenAction {
                compactScreenConfirmation(action)
            }

            if let plan = viewModel.pendingScreenPlan {
                compactScreenPlan(plan)
            }

            if compactInputActive {
                if !viewModel.pendingAttachments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.pendingAttachments.prefix(3), id: \.self) { attachment in
                            HStack(spacing: 5) {
                                Image(systemName: attachmentIcon(for: attachment))
                                    .foregroundStyle(Color.blue)
                                Text(attachment.lastPathComponent)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    viewModel.removeAttachment(attachment)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.black)
                        }
                    }
                }

                HStack(spacing: 8) {
                    PasteAwareTextField(
                        text: $viewModel.draft,
                        isFocused: $compactInputFocused,
                        placeholder: "Type your reply…",
                        onSubmit: sendCompactMessage,
                        onPasteAttachment: viewModel.importPasteboardAttachments
                    )
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .frame(minHeight: 16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.gray.opacity(0.8), lineWidth: 1)
                        )

                    Button(viewModel.isLoading ? "Stop" : "Send") {
                        if viewModel.isLoading {
                            viewModel.cancelRequest()
                        } else {
                            sendCompactMessage()
                        }
                    }
                    .buttonStyle(ClassicButtonStyle())
                    .disabled(
                        (viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         && viewModel.pendingAttachments.isEmpty)
                        && !viewModel.isLoading
                    )
                }

                if viewModel.errorMessage != nil {
                    HStack(spacing: 12) {
                        Button("Try again") { viewModel.retryLastRequest() }
                        Button("Full chat") { viewModel.setExpanded(true) }
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.blue)
                }
            } else {
                compactMenu
            }
        }
        .padding(.top, 13)
        .padding(.leading, 14)
        .padding(.trailing, 11)
        .padding(.bottom, 27)
        .frame(width: 212)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            ClassicBalloonShape()
                .fill(Color(red: 1.0, green: 1.0, blue: 0.8))
                .shadow(color: .black.opacity(0.25), radius: 2, x: 2, y: 2)
        )
        .overlay(
            ClassicBalloonShape()
                .stroke(Color.black.opacity(0.9), lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func balloonRow(_ action: BalloonAction) -> some View {
        switch action.kind {
        case .askHere:
            ClassicOptionButton(action.displayTitle) {
                compactInputActive = true
                compactInputFocused = true
            }
        case .lookAtScreen:
            ClassicOptionButton(action.displayTitle) {
                compactInputActive = true
                viewModel.inspectCurrentScreen()
            }
        case .codingSessions:
            ClassicOptionButton(action.displayTitle) {
                viewModel.refreshSessions()
                compactPanel = .sessions
            }
        case .openSomething:
            ClassicOptionButton(action.displayTitle) {
                compactPanel = .open
            }
        case .fullChat:
            ClassicOptionButton(action.displayTitle) {
                viewModel.setExpanded(true)
            }
        case .dismiss:
            // Deliberately not a ClassicOptionButton: this one dismisses rather
            // than navigating, and the checkbox styling says so.
            Button {
                setCompactBalloonVisible(false)
            } label: {
                Label(action.displayTitle, systemImage: "square")
                    .font(.system(size: 11))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var compactMenu: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch compactPanel {
            case .home:
                // Rows, their wording, and their order all come from Settings;
                // the behaviour behind each is fixed by its `kind`.
                // A finished session gets its own row above the usual ones,
                // because the balloon's rows are the only controls that
                // reliably fit at this size — a reply field does not.
                if let handoff = viewModel.pendingSessionHandoff {
                    ClassicOptionButton("Continue \(handoff.projectName) in Terminal") {
                        viewModel.resumeSessionHandoff()
                    }
                    ClassicOptionButton("Dismiss this") {
                        viewModel.dismissSessionHandoff()
                    }
                }
                ForEach(viewModel.visibleBalloonActions) { action in
                    balloonRow(action)
                }
                ForEach(viewModel.balloonPrompts) { prompt in
                    ClassicOptionButton(prompt.balloonTitle) {
                        compactInputActive = true
                        setCompactBalloonVisible(true)
                        viewModel.send(prompt.prompt)
                    }
                }

            case .sessions:
                if viewModel.recentSessions.isEmpty {
                    Text("No saved Codex or Claude sessions found.")
                        .font(.system(size: 11))
                        .foregroundStyle(.black.opacity(0.72))
                } else {
                    ForEach(viewModel.recentSessions.prefix(4)) { session in
                        ClassicOptionButton(
                            "\(session.provider.rawValue) · \(session.projectName)\n\(session.relativeDate)"
                        ) {
                            viewModel.resume(session)
                            compactPanel = .home
                        }
                    }
                }
                compactBackButton

            case .open:
                ClassicOptionButton("Finder") {
                    LocalActionService.openApp("Finder")
                }
                ClassicOptionButton("Terminal") {
                    LocalActionService.openApp("Terminal")
                }
                ClassicOptionButton("Safari") {
                    LocalActionService.openApp("Safari")
                }
                ClassicOptionButton("Visual Studio Code") {
                    LocalActionService.openApp("VS Code")
                }
                ClassicOptionButton("Downloads folder") {
                    LocalActionService.openFolder(.downloadsDirectory)
                }
                ClassicOptionButton("Applications folder") {
                    LocalActionService.openFolder(.applicationDirectory)
                }
                compactBackButton
            }
        }
    }

    private var compactBackButton: some View {
        Button {
            compactPanel = .home
        } label: {
            Label("Back", systemImage: "arrow.left")
                .font(.system(size: 11))
                .foregroundStyle(Color.blue)
        }
        .buttonStyle(.plain)
    }

    private var compactActivityRow: some View {
        HStack(spacing: 7) {
            MiniActivityIndicator()
            Text("\(viewModel.provider.shortTitle) · \(elapsedText)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.68))
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(viewModel.activityMessage), elapsed time \(elapsedText)")
    }

    private func compactScreenConfirmation(_ action: PendingScreenAction) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(action.detail, systemImage: "cursorarrow.click.2")
                .font(.system(size: 10))
                .foregroundStyle(.black)
                .lineLimit(3)
            HStack(spacing: 10) {
                Button("Click \(action.label)") {
                    viewModel.confirmPendingScreenAction()
                }
                .buttonStyle(ClassicButtonStyle())
                Button("Cancel") {
                    viewModel.cancelPendingScreenAction()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.blue)
            }
            .font(.system(size: 10))
        }
        .padding(7)
        .background(Color.orange.opacity(0.16))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.orange.opacity(0.45))
        )
    }

    private func compactScreenPlan(_ plan: PendingScreenPlan) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                viewModel.isRunningScreenPlan
                    ? "Running \(plan.steps.count)-step plan…"
                    : "\(plan.steps.count)-step plan",
                systemImage: "point.topleft.down.to.point.bottomright.curvepath"
            )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.black)
            Text(plan.summary)
                .font(.system(size: 10))
                .foregroundStyle(.black.opacity(0.78))
                .lineLimit(2)
            HStack(spacing: 10) {
                Button("Watch steps") {
                    viewModel.setExpanded(true)
                }
                .buttonStyle(ClassicButtonStyle())
                Button(viewModel.isRunningScreenPlan ? "Stop" : "Cancel") {
                    viewModel.cancelPendingScreenPlan()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.blue)
            }
            .font(.system(size: 10))
        }
        .padding(7)
        .background(Color.blue.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.blue.opacity(0.35))
        )
    }

    private func sendCompactMessage() {
        guard !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !viewModel.pendingAttachments.isEmpty else { return }
        viewModel.send()
        compactInputFocused = true
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.title = "Attach to \(viewModel.character.title)"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            viewModel.addAttachments(panel.urls)
            compactInputActive = true
            compactInputFocused = true
        }
    }

    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  !viewModel.showSettings,
                  viewModel.importPasteboardAttachments() else {
                return event
            }
            compactInputActive = true
            setCompactBalloonVisible(true)
            compactInputFocused = true
            return nil
        }
    }

    private func installPushToTalkMonitor() {
        guard pushToTalk == nil else { return }
        let monitor = PushToTalkMonitor(
            start: { route in
                // Only the ⌘⌥ route aimed at another app bypasses the
                // composer; dictating to Clippy (or to Clippy's own window)
                // should still show up live as you speak.
                dictationTargetsExternalApp = route == .focusedApp && !NSApp.isActive
                if route == .clippy {
                    // Switch the balloon into conversation mode up front.
                    // `compactStatusMessage` shows the generic "what would you
                    // like to do?" menu whenever `compactInputActive` is false,
                    // ahead of any check for the latest reply — so without
                    // this the answer lands in the expanded window but the
                    // balloon silently reverts to the menu.
                    setCompactBalloonVisible(true)
                    compactInputActive = true
                }
                Task { await speech.beginPushToTalk() }
            },
            stop: { route in
                let external = dictationTargetsExternalApp
                Task {
                    let dictated = await speech.endPushToTalk()
                    dictationTargetsExternalApp = false
                    guard !dictated.isEmpty else { return }
                    if external {
                        await deliverDictationToFocusedApp(dictated)
                    } else if route == .clippy {
                        // Send the composer — transcript plus anything typed
                        // before it — rather than the bare transcript. Applied
                        // here rather than left to `onChange`, which SwiftUI
                        // has not necessarily delivered yet.
                        applyDictationToDraft(dictated)
                        viewModel.send()
                    }
                }
            },
            cancel: { _ in
                speech.cancelPushToTalk()
                dictationTargetsExternalApp = false
            }
        )
        monitor.startMonitoring()
        pushToTalk = monitor
    }

    /// Merges a transcript into the composer, preserving whatever the user had
    /// already typed before dictation started.
    ///
    /// Recomputed from `draftBeforeDictation` every time rather than appended,
    /// so calling it twice with the same transcript is a no-op — which is what
    /// lets the release handler apply the transcript itself instead of waiting
    /// for `onChange` to be delivered. That wait used to be free when the
    /// transcript arrived live; with a batch engine the whole transcript lands
    /// in one assignment right before `send()`, and SwiftUI would not have
    /// updated the draft yet.
    private func applyDictationToDraft(_ transcript: String) {
        // Dictation aimed at another app must not also accumulate in Clippy's
        // composer — that text is delivered on release instead.
        guard !dictationTargetsExternalApp else { return }
        guard speech.isListening || !transcript.isEmpty else { return }
        guard !draftBeforeDictation.isEmpty else {
            viewModel.draft = transcript
            return
        }
        let needsSpace = !draftBeforeDictation.hasSuffix(" ") && !transcript.isEmpty
        viewModel.draft = draftBeforeDictation + (needsSpace ? " " : "") + transcript
    }

    /// Types dictated text straight into whatever editable field the user had
    /// focused, falling back to the clipboard when there's nowhere safe to put
    /// it (no Accessibility permission, no editable target, or a password
    /// field — `insert` refuses those outright). The fallback is announced,
    /// since text silently vanishing is worse than text in the wrong place.
    private func deliverDictationToFocusedApp(_ text: String) async {
        do {
            // The text appearing in the field is its own confirmation, so
            // there's nothing to announce on the success path.
            _ = try await ScreenTypingService.shared.insert(text)
        } catch {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            viewModel.errorMessage = "Couldn't type that in (\(error.localizedDescription)) — copied it to your clipboard instead."
        }
    }

    private func setCompactBalloonVisible(_ visible: Bool) {
        // Restore normal hit testing before presenting the balloon, so its first
        // frame is already interactive. When hiding, leave it interactive until
        // the closing transition has cleared the screen.
        if visible {
            publishBalloonVisibility(true)
        }
        compactBalloonVisible = visible

        guard !visible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !compactBalloonVisible else { return }
            publishBalloonVisibility(false)
        }
    }

    private func publishBalloonVisibility(_ visible: Bool? = nil) {
        let resolvedVisibility = visible ?? compactBalloonVisible
        UserDefaults.standard.set(resolvedVisibility, forKey: "compactBalloonVisible")
        NotificationCenter.default.post(
            name: .clippyBalloonVisibilityChanged,
            object: resolvedVisibility
        )
    }

    private func publishBalloonContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        NotificationCenter.default.post(
            name: .clippyBalloonContentSizeChanged,
            object: size
        )
    }

    private func attachmentIcon(for url: URL) -> String {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
        return imageExtensions.contains(url.pathExtension.lowercased()) ? "photo" : "doc"
    }

    private var compactStatusMessage: String {
        // A finished session outranks the idle greeting: the balloon's text is
        // the one surface guaranteed to be visible at the balloon's size, so
        // the notification goes here rather than only into an extra banner
        // that the balloon's layout may not have room to show.
        if let handoff = viewModel.pendingSessionHandoff {
            return handoff.balloonText
        }
        if let error = viewModel.errorMessage {
            return "I couldn’t finish that: \(error)"
        }
        if viewModel.isLoading { return viewModel.activityMessage }
        if viewModel.activityMessage.hasPrefix("Stopped") { return viewModel.activityMessage }
        if !compactInputActive {
            switch compactPanel {
            case .home:
                return "It looks like you could use some help. What would you like to do?"
            case .sessions:
                return "Pick up where you left off. I’ll reopen the session in Terminal."
            case .open:
                return "What should I open for you?"
            }
        }
        if speech.isSpeaking, let last = viewModel.messages.last {
            return ResponsePresentation.compactText(last.content)
        }
        if let last = viewModel.messages.last, last.role == .assistant {
            return ResponsePresentation.compactText(last.content)
        }
        return "Hi! I am \(viewModel.character.title), your desktop assistant. Would you like some assistance today?"
    }

    /// Title bar plus toolbar, in that order — the arrangement every window of
    /// the era used. The close box collapses back to the floating paperclip
    /// rather than quitting, which is what the old expand/collapse button did.
    private var header: some View {
        VStack(spacing: 0) {
            RetroTitleBar(
                title: viewModel.character.title,
                // Minimising a chat window that lives as a desktop character
                // means going back to being the character — not vanishing into
                // the Dock, which is where the user would then have to hunt
                // for it.
                onMinimize: { viewModel.setExpanded(false) },
                onMaximize: toggleMaximized,
                isMaximized: isMaximized,
                // Close gets out of the way entirely: back to the paperclip
                // with its balloon dismissed. Reversible with a click on
                // Clippy, so nothing is lost.
                onClose: {
                    viewModel.setExpanded(false)
                    setCompactBalloonVisible(false)
                }
            )

            HStack(spacing: 9) {
                StaticClippyView()
                    .frame(width: 40, height: 40)
                    .scaleEffect(hoveringClippy ? 1.04 : 1)
                    .onHover { hoveringClippy = $0 }
                    .animation(.spring(response: 0.25), value: hoveringClippy)

                HStack(spacing: 6) {
                    Text(statusMessage)
                        .font(RetroPalette.font(11))
                        .foregroundStyle(RetroPalette.text)
                        .lineLimit(1)
                    if speech.isListening {
                        ListeningWaveform(level: speech.audioLevel, barCount: 4, color: .red)
                            .frame(width: 24, height: 14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 3) {
                    // Only in the expanded window: the compact balloon has no
                    // room to render a dashboard.
                    if viewModel.isExpanded {
                        headerButton(
                            showScheduleDashboard ? "bubble.left.and.bubble.right.fill" : "clock.badge.checkmark",
                            help: showScheduleDashboard ? "Back to conversation" : "Scheduled checks"
                        ) {
                            showScheduleDashboard.toggle()
                        }
                    }
                    headerButton("clock.arrow.circlepath", help: "Chat history") {
                        showHistory = true
                    }
                    headerButton("square.and.pencil", help: "New conversation") {
                        viewModel.clearConversation()
                    }
                    headerButton("gearshape.fill", help: "Settings") {
                        viewModel.showSettings = true
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        // Deliberately no background: the window's translucent face shows
        // through, so the toolbar and the conversation are one continuous
        // tone. An opaque fill here left a visible seam under the toolbar.
    }

    /// Grows the chat window to fill the screen it's on, and back again.
    ///
    /// Done by hand rather than with `NSWindow.zoom(_:)` because the window is
    /// borderless and transparent with its standard buttons hidden — `zoom`
    /// on that window does nothing. The pre-maximise frame is remembered here
    /// so Restore returns to the exact size the user had, not the default.
    private func toggleMaximized() {
        guard let window = NSApplication.shared.windows.first(where: { !$0.isSheet && $0.isVisible }),
              let screen = window.screen ?? NSScreen.main
        else { return }

        if let frameBeforeMaximize {
            window.setFrame(frameBeforeMaximize, display: true, animate: true)
            self.frameBeforeMaximize = nil
            isMaximized = false
        } else {
            frameBeforeMaximize = window.frame
            window.setFrame(screen.visibleFrame, display: true, animate: true)
            isMaximized = true
        }
    }

    private func headerButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(RetroPalette.text)
                .frame(width: 22, height: 20)
        }
        // A toolbar button is a small square bevel, not a circle. The glyphs
        // stay SF Symbols: hand-drawn 16px icons would read as a different
        // kind of pastiche, and these are legible at this size.
        .buttonStyle(RetroButtonStyle(minWidth: 22))
        .help(help)
    }

    private var statusMessage: String {
        if speech.isListening { return "I’m listening…" }
        if viewModel.isLoading { return viewModel.activityMessage }
        if speech.isSpeaking { return "Here’s what I found!" }
        if viewModel.errorMessage != nil { return "Oops—something went wrong." }
        if viewModel.activityMessage.hasPrefix("Stopped") { return viewModel.activityMessage }
        if viewModel.recentlyCompleted { return "Done — here’s what I found." }
        return "It looks like you’re trying to get something done."
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                conversationScroll(proxy)
                if scrollMetrics.needsScrollBar {
                    RetroScrollBar(
                        fraction: scrollMetrics.fraction,
                        visibleRatio: scrollMetrics.visibleRatio,
                        scrollTo: { fraction in scrollConversation(to: fraction, proxy: proxy) },
                        step: { direction in stepConversation(by: direction, proxy: proxy) }
                    )
                }
            }
        }
    }

    /// Maps a scrollbar position onto a message to scroll to.
    ///
    /// Approximate by construction: messages are wildly different heights, so
    /// a fraction of the *content* doesn't correspond to a fraction of the
    /// *list*. Landing on the right neighbourhood is what a scrollbar is for,
    /// and pre-macOS 15 there's no API to scroll a SwiftUI ScrollView to an
    /// arbitrary offset.
    private func scrollConversation(to fraction: Double, proxy: ScrollViewProxy) {
        let messages = viewModel.visibleMessages
        guard !messages.isEmpty else { return }
        let clamped = min(max(fraction, 0), 1)
        if clamped >= 0.999 {
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
            return
        }
        let index = Int((Double(messages.count - 1) * clamped).rounded())
        proxy.scrollTo(messages[index].id, anchor: .top)
    }

    private func stepConversation(by direction: Int, proxy: ScrollViewProxy) {
        let messages = viewModel.visibleMessages
        guard !messages.isEmpty else { return }
        let current = Int((Double(messages.count - 1) * scrollMetrics.fraction).rounded())
        let next = min(max(current + direction, 0), messages.count - 1)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            proxy.scrollTo(messages[next].id, anchor: .top)
        }
    }

    private func conversationScroll(_ proxy: ScrollViewProxy) -> some View {
        GeometryReader { viewport in
            ScrollView {
                LazyVStack(spacing: 11) {
                    ForEach(Array(viewModel.visibleMessages.enumerated()), id: \.element.id) { index, message in
                        MessageBubble(
                            message: message,
                            showsPortrait: index == 0
                                || viewModel.visibleMessages[index - 1].role != message.role
                        )
                        .id(message.id)
                    }

                    if viewModel.visibleMessages.count == 1 {
                        suggestionGrid
                    }

                    if viewModel.isLoading {
                        HStack {
                            ActivityBubble(
                                message: viewModel.activityMessage,
                                provider: viewModel.provider.shortTitle,
                                elapsed: elapsedText,
                                stop: viewModel.cancelRequest
                            )
                            Spacer(minLength: 70)
                        }
                        .id("loading")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("conversation-bottom")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    GeometryReader { content in
                        Color.clear.preference(
                            key: RetroScrollMetricsKey.self,
                            value: RetroScrollMetrics(
                                offset: -content.frame(in: .named("chatScroll")).minY,
                                contentHeight: content.size.height,
                                viewportHeight: viewport.size.height
                            )
                        )
                    }
                )
            }
            .coordinateSpace(name: "chatScroll")
            // The native indicator is replaced by RetroScrollBar, which is
            // drawn as part of the window rather than floating over it.
            .scrollIndicators(.hidden)
            .onPreferenceChange(RetroScrollMetricsKey.self) { scrollMetrics = $0 }
            .onAppear {
                // A full-chat open creates this view anew. Deferring one run-loop
                // lets LazyVStack lay out recent messages before the initial jump.
                DispatchQueue.main.async {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.messages.last?.id) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.isLoading) { _, loading in
                if loading {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var suggestionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    viewModel.send(suggestion)
                } label: {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.background.opacity(0.85))
                                .stroke(Color.secondary.opacity(0.18))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
            Button("Try again") {
                viewModel.retryLastRequest()
            }
            .buttonStyle(.borderless)
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .background(Color.orange.opacity(0.1))
        .padding(.horizontal, 14)
    }

    /// Shown when a Claude Code or Codex session ends: what happened, and a
    /// reply box that reopens the session in Terminal with that message
    /// already sent — so answering a finished session is one step, not a
    /// context switch back to a terminal to retype it.
    private func sessionHandoffBanner(_ handoff: SessionHandoff) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(handoff.provider.displayName) finished in \(handoff.projectName)")
                        .font(.caption.weight(.semibold))
                    Text(handoff.notificationText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Button {
                    viewModel.dismissSessionHandoff()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Dismiss")
            }
            HStack(spacing: 6) {
                TextField("Reply to continue in Terminal…", text: $viewModel.handoffReply)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { viewModel.resumeSessionHandoff() }
                Button("Continue") {
                    viewModel.resumeSessionHandoff()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Reopen this session in Terminal")
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func screenActionBanner(_ action: PendingScreenAction) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "cursorarrow.click.2")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.character.title) found “\(action.label)”")
                    .font(.caption.weight(.semibold))
                Text(action.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") {
                viewModel.cancelPendingScreenAction()
            }
            .buttonStyle(.borderless)
            Button("Click") {
                viewModel.confirmPendingScreenAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func stepMarker(index: Int, status: ScreenPlanStepStatus) -> some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .frame(width: 17, height: 17)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(width: 17, height: 17)
        case .running:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 17, height: 17)
        case .pending, .skipped:
            Text("\(index + 1)")
                .font(.caption2.bold().monospacedDigit())
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.blue.opacity(0.15)))
        }
    }

    private func screenPlanBanner(_ plan: PendingScreenPlan) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(plan.summary, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(plan.steps.count) steps")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                            let status = viewModel.screenPlanStatuses.indices.contains(index)
                                ? viewModel.screenPlanStatuses[index]
                                : .pending
                            HStack(alignment: .top, spacing: 7) {
                                stepMarker(index: index, status: status)
                                Text(step.displayText)
                                    .font(.caption)
                                    .foregroundStyle(status == .done ? .secondary : .primary)
                                    .strikethrough(status == .done)
                                    .textSelection(.enabled)
                            }
                            .id(index)
                        }
                    }
                }
                // A running task can easily produce more steps than fit —
                // scroll internally past this height instead of growing the
                // banner until it crowds out the Stop/Run controls below it.
                .frame(maxHeight: 160)
                .onChange(of: plan.steps.count) { _, _ in
                    withAnimation { scrollProxy.scrollTo(plan.steps.count - 1, anchor: .bottom) }
                }
            }

            HStack {
                Text("\(viewModel.character.title) will stop before Send, Submit, payment, deletion, or password controls.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(viewModel.isRunningScreenPlan ? "Stop" : "Cancel") {
                    viewModel.cancelPendingScreenPlan()
                }
                .buttonStyle(.borderless)
                Button(viewModel.isRunningScreenPlan ? "Running…" : "Run plan") {
                    viewModel.runPendingScreenPlan()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.isRunningScreenPlan)
            }
        }
        .padding(11)
        .background(Color.blue.opacity(0.07))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.blue.opacity(0.25)).frame(height: 1)
        }
        .padding(.horizontal, 14)
    }

    /// Commands matching what's been typed so far, shown above the composer so
    /// the feature is discoverable without having to remember `/help`.
    private var matchingCommands: [(command: String, detail: String)] {
        let trimmed = viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only while typing the command itself — once there's a space the user
        // has moved on to arguments and the list is just in the way.
        guard trimmed.hasPrefix("/"), !trimmed.contains(" ") else { return [] }
        let typed = trimmed.dropFirst().lowercased()

        var all: [(command: String, detail: String)] = [
            ("clear", "Clear the chat and start a new session"),
            ("help", "List every command")
        ]
        all += viewModel.customPrompts
            .filter(\.isValid)
            .sorted { $0.command < $1.command }
            .map {
                (
                    $0.command,
                    $0.prompt.replacingOccurrences(of: "\n", with: " ")
                )
            }
        return all.filter { typed.isEmpty || $0.command.hasPrefix(typed) }
    }

    private var commandPalette: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matchingCommands, id: \.command) { entry in
                Button {
                    viewModel.draft = "/\(entry.command)"
                } label: {
                    HStack(spacing: 8) {
                        Text("/\(entry.command)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .stroke(Color.secondary.opacity(0.22))
        )
    }

    private var composer: some View {
        VStack(spacing: 9) {
            if !matchingCommands.isEmpty {
                commandPalette
            }

            if !viewModel.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(viewModel.pendingAttachments, id: \.self) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachmentIcon(for: attachment))
                                    .foregroundStyle(Color.accentColor)
                                Text(attachment.lastPathComponent)
                                    .lineLimit(1)
                                Button {
                                    viewModel.removeAttachment(attachment)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.1))
                                    .stroke(Color.accentColor.opacity(0.22))
                            )
                        }
                    }
                }
                .accessibilityLabel("Attachments ready to send")
            }

            HStack(alignment: .bottom, spacing: 9) {
                Button {
                    chooseAttachments()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13))
                        .foregroundStyle(RetroPalette.text)
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(RetroButtonStyle(minWidth: 24))
                .disabled(viewModel.isLoading)
                .help("Attach a file")

                Button {
                    viewModel.pasteAttachmentsOrExplain()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13))
                        .foregroundStyle(RetroPalette.text)
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(RetroButtonStyle(minWidth: 24))
                .disabled(viewModel.isLoading)
                .help("Paste an image or file")

                TextField("Ask \(viewModel.character.title) anything…", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(RetroPalette.font(12))
                    .foregroundStyle(RetroPalette.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .background(RetroPalette.fieldBackground)
                    .retroBevel(.sunken)
                    .onSubmit {
                        if !NSEvent.modifierFlags.contains(.shift) {
                            viewModel.send()
                        }
                    }

                if speech.isListening {
                    ListeningWaveform(level: speech.audioLevel)
                        .frame(width: 30, height: 27)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                if speech.isPreparingModel || speech.isTranscribing {
                    // The one-time (or first-launch-of-a-session) local
                    // model load can take several seconds with nothing else
                    // on screen changing — without this the mic button just
                    // looks unresponsive the whole time. The same is true of
                    // the gap between releasing the keys and a batch engine
                    // producing its transcript.
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 27, height: 27)
                        .help(speech.isPreparingModel ? "Loading \(speech.engine.displayName)…" : "Transcribing…")
                } else {
                    Button {
                        Task { await speech.toggleListening() }
                    } label: {
                        Image(systemName: speech.isListening ? "waveform" : "mic")
                            .font(.system(size: 13))
                            .foregroundStyle(speech.isListening ? Color.red : RetroPalette.text)
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(RetroButtonStyle(minWidth: 24))
                    .listeningPulse(isActive: speech.isListening)
                    .help(speech.isListening ? "Stop dictation" : "Dictate — or hold ⌘⌥ to type into any app, ⌥⇧ to ask \(viewModel.character.title)")
                    .animation(.easeOut(duration: 0.16), value: speech.isListening)
                }

                Button {
                    if viewModel.isLoading || viewModel.isRunningScreenPlan {
                        viewModel.cancelRequest()
                    } else {
                        viewModel.send()
                    }
                } label: {
                    Text((viewModel.isLoading || viewModel.isRunningScreenPlan) ? "Stop" : "Send")
                        .font(RetroPalette.font(11))
                        .frame(height: 22)
                }
                .buttonStyle(RetroButtonStyle(minWidth: 46))
                .disabled(
                    (viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     && viewModel.pendingAttachments.isEmpty)
                    && !viewModel.isLoading && !viewModel.isRunningScreenPlan
                )
                .help((viewModel.isLoading || viewModel.isRunningScreenPlan) ? "Stop generating" : "Send")
                .keyboardShortcut(.return, modifiers: [])
            }

            HStack {
                Text(viewModel.isLoading
                     ? "\(viewModel.provider.shortTitle) is working · \(elapsedText)"
                     : viewModel.isRunningScreenPlan
                     ? "Running a screen plan…"
                     : (viewModel.providerReady ? "Connected via \(viewModel.provider.title)" : "Setup needed for \(viewModel.provider.title)"))
                    .foregroundStyle(viewModel.providerReady ? RetroPalette.text : RetroPalette.errorText)
                Spacer()
                if viewModel.speakReplies {
                    Text("Voice on")
                }
            }
            .font(RetroPalette.font(10))
            // The status line is a sunken strip along the bottom, the way
            // every window of the era ended.
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .retroBevel(.sunken)
        }
        .padding(8)
    }

    private var elapsedText: String {
        let minutes = viewModel.activityElapsed / 60
        let seconds = viewModel.activityElapsed % 60
        return minutes > 0
            ? String(format: "%d:%02d", minutes, seconds)
            : "\(seconds)s"
    }

    private var lastAssistantAnswer: String? {
        viewModel.messages.last(where: { $0.role == .assistant })?.content
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    /// False for a reply that follows another reply — one portrait per run of
    /// messages from the same side, rather than a column of identical
    /// paperclips down the transcript.
    var showsPortrait = true

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user { Spacer(minLength: 58) }

            if message.role == .assistant {
                // The slot is kept even when the portrait is hidden, so
                // messages in a run stay aligned with the one that has it.
                Group {
                    if showsPortrait {
                        ClippyPortrait()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 30)
            }

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if message.role == .assistant {
                        MarkdownMessageText(content: message.content)
                    } else {
                        Text(message.content)
                    }
                }
                if message.role == .assistant {
                    // Kept in the layout at all times and only faded in, so
                    // the transcript stays quiet without messages resizing
                    // under the pointer as you move across them.
                    AnswerActions(content: message.content)
                        .opacity(isHovered ? 1 : 0)
                }
            }
            .onHover { isHovered = $0 }
            .textSelection(.enabled)
                .font(RetroPalette.font(12))
                .lineSpacing(3)
                .padding(.horizontal, message.role == .user ? 9 : 2)
                .padding(.vertical, message.role == .user ? 7 : 2)
                // Inside the white well, Clippy's replies are just text on the
                // page — boxing them drew a border around white on white and
                // gave the log a boxes-inside-boxes look. Yours stay a grey
                // panel, which is what distinguishes the two sides now that
                // the well provides the outer frame.
                .background(message.role == .user ? RetroPalette.light : Color.clear)
                .retroBevel(message.role == .user ? .staticEdge : .none)
                .foregroundStyle(RetroPalette.text)

            if message.role == .assistant { Spacer(minLength: 58) }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AnswerActions: View {
    let content: String

    var body: some View {
        HStack(spacing: 11) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            } label: {
                buttonLabel("doc.on.doc", "Copy")
            }
            if let url = Self.firstLink(in: content) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    buttonLabel("arrow.up.right.square", "Open link")
                }
            }
        }
        // Small raised buttons rather than tinted links: a coloured text link
        // is a web idiom the era predates. Icon left of the label, which is
        // where every toolbar of the period put it, and compact so it reads as
        // an action on the message rather than a dialog button sitting in one.
        .buttonStyle(RetroButtonStyle(minWidth: 0, compact: true))
        .padding(.top, 4)
    }

    private func buttonLabel(_ systemName: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 9))
            Text(title)
                .font(RetroPalette.font(10))
        }
        .foregroundStyle(RetroPalette.text)
    }

    static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range)?.url
    }
}

private struct MarkdownMessageText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownBlock.parse(content)) { block in
                switch block.kind {
                case .heading(let level, let text):
                    inlineText(text)
                        .font(.system(size: level == 1 ? 17 : 15, weight: .bold))
                        .padding(.top, block.isFirst ? 0 : 3)
                case .paragraph(let text):
                    inlineText(text)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").fontWeight(.bold)
                        inlineText(text)
                    }
                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(number).")
                            .fontWeight(.semibold)
                            .frame(minWidth: 18, alignment: .trailing)
                        inlineText(text)
                    }
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(9)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.black.opacity(0.14))
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineText(_ markdown: String) -> Text {
        let attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
        return Text(attributed)
    }
}

struct MarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case numbered(Int, String)
        case code(String)
    }

    let id = UUID()
    let kind: Kind
    let isFirst: Bool

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var kinds: [Kind] = []
        var paragraph: [String] = []
        var code: [String] = []
        var insideCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            kinds.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        func flushCode() {
            guard !code.isEmpty else { return }
            kinds.append(.code(code.joined(separator: "\n")))
            code.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if insideCode {
                    flushCode()
                    insideCode = false
                } else {
                    flushParagraph()
                    insideCode = true
                }
                continue
            }
            if insideCode {
                code.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }

            let headingLevel = line.prefix(while: { $0 == "#" }).count
            if headingLevel > 0, line.dropFirst(headingLevel).first == " " {
                flushParagraph()
                kinds.append(.heading(
                    min(headingLevel, 3),
                    String(line.dropFirst(headingLevel)).trimmingCharacters(in: .whitespaces)
                ))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                kinds.append(.bullet(String(line.dropFirst(2))))
                continue
            }
            let numberedParts = line.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            if numberedParts.count == 2,
               let number = Int(numberedParts[0]),
               numberedParts[1].hasPrefix(" ") {
                flushParagraph()
                kinds.append(.numbered(
                    number,
                    String(numberedParts[1]).trimmingCharacters(in: .whitespaces)
                ))
                continue
            }
            paragraph.append(line)
        }

        flushParagraph()
        flushCode()
        if kinds.isEmpty {
            kinds = [.paragraph(markdown)]
        }
        return kinds.enumerated().map {
            MarkdownBlock(kind: $0.element, isFirst: $0.offset == 0)
        }
    }
}

private struct SpeechBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(
            roundedRect: CGRect(x: 12, y: 0, width: rect.width - 12, height: rect.height),
            cornerRadius: 14
        )
        path.move(to: CGPoint(x: 13, y: rect.midY - 7))
        path.addLine(to: CGPoint(x: 0, y: rect.midY + 2))
        path.addLine(to: CGPoint(x: 13, y: rect.midY + 9))
        path.closeSubpath()
        return path
    }
}

private struct ClassicBalloonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: 2, y: 2, width: rect.width - 4, height: rect.height - 25)
        var path = Path(roundedRect: body, cornerRadius: 8)
        let tailX = rect.width * 0.64
        path.move(to: CGPoint(x: tailX - 12, y: body.maxY - 1))
        path.addLine(to: CGPoint(x: tailX + 2, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: tailX + 6, y: body.maxY - 1))
        path.closeSubpath()
        return path
    }
}

private struct ClassicButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(configuration.isPressed ? Color.gray.opacity(0.18) : Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.gray.opacity(0.8), lineWidth: 1)
            )
    }
}

private struct ClassicOptionButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(Color(red: 0.05, green: 0.38, blue: 0.78))
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 0.6))
                    .padding(.top, 4)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.black)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MiniActivityIndicator: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color(red: 0.05, green: 0.38, blue: 0.78))
                    .frame(width: 4, height: 4)
                    .scaleEffect(pulse ? 1 : 0.65)
                    .animation(
                        .easeInOut(duration: 0.65)
                            .repeatForever()
                            .delay(Double(index) * 0.14),
                        value: pulse
                    )
            }
        }
        .onAppear { pulse = true }
    }
}

private struct ActivityBubble: View {
    let message: String
    let provider: String
    let elapsed: String
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MiniActivityIndicator()
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout)
                Text("\(provider) · \(elapsed)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button("Stop", action: stop)
                .font(.caption)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message), \(provider), elapsed time \(elapsed)")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    // See the matching comment in OnboardingView.swift: `SpeechService` is a
    // nested ObservableObject on ChatViewModel, not one of its `@Published`
    // properties, so it needs its own `@ObservedObject` here to reactively
    // reflect dictation-engine changes.
    @ObservedObject var speech: SpeechService
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var saveError: String?
    @State private var accessibilityEnabled = ScreenTypingService.shared.isAuthorized
    @State private var screenRecordingEnabled = ScreenAwarenessService.shared.canSeeScreen

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Scrollable: a fixed-height VStack silently overflows past the
            // sheet's frame instead of resizing it — the Dictation section
            // pushed total content past 680pt and clipped the header (title
            // + Done button) off-screen. Same root cause and fix as
            // OnboardingView's ScrollView.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
            GroupBox("AI provider") {
                VStack(alignment: .leading, spacing: 12) {
                    RetroRadioGroup(
                        options: AIProvider.allCases.map { ($0, $0.title) },
                        selection: $viewModel.provider
                    )
                    Text(viewModel.provider.detail)
                        .font(RetroPalette.font(10))
                        .foregroundStyle(RetroPalette.disabledText)
                }
                .padding(8)
            }

            if viewModel.provider.needsAPIKey {
                GroupBox("Credentials") {
                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("\(viewModel.provider.shortTitle) API key", text: $apiKey)
                        HStack {
                            Text("Stored only in your macOS Keychain.")
                                .font(RetroPalette.font(11))
                                .foregroundStyle(RetroPalette.text)
                            Spacer()
                            Button("Save key") {
                                do {
                                    try viewModel.saveAPIKey(apiKey)
                                    saveError = nil
                                } catch {
                                    saveError = error.localizedDescription
                                }
                            }
                        }
                        if let saveError {
                            Text(saveError).font(RetroPalette.font(11)).foregroundStyle(RetroPalette.errorText)
                        }
                    }
                    .padding(8)
                }
            }

            GroupBox("Character") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Any of the classic Office assistants — same balloon, same brains, different sprite.")
                        .font(RetroPalette.font(11))
                        .foregroundStyle(RetroPalette.text)
                    RetroRadioGroup(
                        options: ClippyCharacter.allCases.map { ($0, $0.title) },
                        selection: $viewModel.character
                    )
                }
                .padding(8)
            }

            GroupBox("Model and behavior") {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.provider.needsAPIKey {
                        TextField("Model", text: $viewModel.model)
                    } else {
                        Text("The CLI’s configured default model will be used.")
                            .font(RetroPalette.font(11))
                            .foregroundStyle(RetroPalette.text)
                    }
                    Toggle("Read replies aloud", isOn: $viewModel.speakReplies)
                    Toggle("Keep \(viewModel.character.title) above other windows", isOn: $viewModel.alwaysOnTop)
                    Toggle("Animate \(viewModel.character.title)", isOn: $viewModel.animateClippy)
                    Text("Off keeps the paperclip still and reduces visual motion.")
                        .font(RetroPalette.font(11))
                        .foregroundStyle(RetroPalette.text)
                    Toggle("Always run screen plans without confirming", isOn: $viewModel.alwaysAutoRunScreenPlans)
                    Text("Off (recommended) waits for you to tap Run plan on anything beyond a single app switch or address-bar navigation.")
                        .font(RetroPalette.font(11))
                        .foregroundStyle(RetroPalette.text)
                }
                .padding(8)
            }

            // Memory the user can't see is memory they can't correct, so
            // every stored fact is listed verbatim and individually
            // removable rather than hidden behind a single on/off switch.
            GroupBox("What \(viewModel.character.title) remembers") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Durable facts picked up from your conversations, kept across chats so you don’t have to repeat yourself. Delete anything that’s wrong or that you’d rather it didn’t know.")
                        .font(RetroPalette.font(11))
                        .foregroundStyle(RetroPalette.text)
                    if viewModel.memories.isEmpty {
                        Text("Nothing yet — it starts remembering once you tell it something about yourself.")
                            .font(RetroPalette.font(11))
                            .foregroundStyle(RetroPalette.text)
                    } else {
                        ForEach(viewModel.memories) { fact in
                            HStack(alignment: .top, spacing: 8) {
                                Text(fact.text)
                                    .font(RetroPalette.font(11))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button {
                                    viewModel.forget(fact)
                                } label: {
                                    Text("Delete")
                                }
                                .buttonStyle(RetroButtonStyle(minWidth: 54))
                                .help("Forget this")
                                .accessibilityLabel("Forget: \(fact.text)")
                            }
                        }
                        Button("Forget everything") { viewModel.forgetEverything() }
                            .font(RetroPalette.font(11))
                    }
                }
                .padding(8)
            }

            GroupBox("Balloon menu") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The options offered by the floating paperclip. Rename them, reorder them, or untick ones you never use. Each row keeps what it does — only the wording is yours.")
                        .font(RetroPalette.font(11))
                        .foregroundStyle(RetroPalette.text)

                    ForEach($viewModel.balloonActions) { $action in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $action.isVisible)
                                .labelsHidden()
                                .help(action.isVisible ? "Shown in the balloon" : "Hidden")
                            VStack(alignment: .leading, spacing: 2) {
                                TextField(action.kind.defaultTitle, text: $action.title)
                                        Text(action.kind.behaviourNote)
                                    .font(RetroPalette.font(10))
                                    .foregroundStyle(RetroPalette.text)
                            }
                            VStack(spacing: 2) {
                                Button {
                                    viewModel.moveBalloonAction(id: action.id, by: -1)
                                } label: {
                                    Text("▲")
                                }
                                .buttonStyle(RetroButtonStyle(minWidth: 20))
                                .disabled(viewModel.balloonActions.first?.id == action.id)
                                Button {
                                    viewModel.moveBalloonAction(id: action.id, by: 1)
                                } label: {
                                    Text("▼")
                                }
                                .buttonStyle(RetroButtonStyle(minWidth: 20))
                                .disabled(viewModel.balloonActions.last?.id == action.id)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Reset to defaults") { viewModel.resetBalloonActions() }
                            .font(RetroPalette.font(11))
                    }
                }
                .padding(8)
            }

            GroupBox("Custom prompts") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Save a prompt you use often as a slash command, then type it in the chat. Anything you add after the command is appended to the prompt, so `/review this function` works too.")
                        .font(RetroPalette.font(11))
                        .foregroundStyle(RetroPalette.text)
                    Text("Built in: `/clear` starts a new session, `/help` lists everything.")
                        .font(RetroPalette.font(10))
                        .foregroundStyle(RetroPalette.text)

                    ForEach($viewModel.customPrompts) { $prompt in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text("/").foregroundStyle(RetroPalette.text)
                                    TextField("command", text: Binding(
                                        get: { prompt.command },
                                        // Normalizing on every keystroke keeps
                                        // what's stored matchable — a command
                                        // saved with spaces or capitals could
                                        // never be typed successfully.
                                        set: { prompt.command = CustomPrompt.normalize($0) }
                                    ))
                                            .frame(width: 130)
                                }
                                TextField("What should \(viewModel.character.title) do?", text: $prompt.prompt, axis: .vertical)
                                            .lineLimit(1...4)
                                Toggle("Show in balloon menu", isOn: $prompt.showsInBalloon)
                                    .font(RetroPalette.font(11))
                            }
                            Button {
                                viewModel.customPrompts.removeAll { $0.id == prompt.id }
                            } label: {
                                Text("Delete")
                            }
                            .buttonStyle(RetroButtonStyle(minWidth: 54))
                            .help("Delete this prompt")
                        }

                        if !prompt.isValid {
                            Text(
                                CustomPrompt.reservedCommands.contains(prompt.command)
                                    ? "`/\(prompt.command)` is built in — pick another name."
                                    : "Needs both a command and a prompt to be usable."
                            )
                            .font(RetroPalette.font(10))
                            .foregroundStyle(RetroPalette.errorText)
                        }
                    }

                    Button {
                        viewModel.customPrompts.append(CustomPrompt(command: "", prompt: ""))
                    } label: {
                        Text("Add prompt")
                    }
                }
                .padding(8)
            }

            GroupBox("Dictation") {
                VStack(alignment: .leading, spacing: 10) {
                    RetroRadioGroup(
                        options: DictationEngine.allCases.map { ($0, $0.displayName) },
                        selection: Binding(
                            get: { speech.engine },
                            set: { newValue in
                                speech.engine = newValue
                                Task { await speech.prepareModel() }
                            }
                        )
                    )
                    Text(speech.engine.detail)
                        .font(RetroPalette.font(10))
                        .foregroundStyle(RetroPalette.disabledText)
                    Text("The local engines record the whole time you hold the keys and transcribe once you let go, so nothing gets clipped. Silence is dropped before the model ever sees it.")
                        .font(RetroPalette.font(10))
                        .foregroundStyle(RetroPalette.disabledText)
                    if speech.isPreparingModel {
                        RetroProgressBar(value: speech.modelDownloadProgress)
                        Text("Downloading model…")
                            .font(RetroPalette.font(10))
                            .foregroundStyle(RetroPalette.disabledText)
                    } else if speech.readyEngines.contains(speech.engine) {
                        Text("✓ Model ready")
                            .font(RetroPalette.font(10))
                            .foregroundStyle(RetroPalette.text)
                    }
                }
                .padding(8)
            }

            GroupBox("Write in other apps") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(viewModel.character.title) can insert generated text into the last editable field you focused. It never types into secure fields or presses Send.")
                        .font(RetroPalette.font(11))
                        .foregroundStyle(RetroPalette.text)
                    HStack {
                        Text(
                            accessibilityEnabled
                                ? "✓ Accessibility enabled"
                                : "! Accessibility permission required"
                        )
                        .font(RetroPalette.font(10))
                        .foregroundStyle(RetroPalette.text)
                        Spacer()
                        if accessibilityEnabled {
                            Button("Open System Settings") {
                                ScreenTypingService.shared.openAccessibilitySettings()
                            }
                        } else {
                            Button("Enable…") {
                                ScreenTypingService.shared.requestAccessibilityPermission()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    accessibilityEnabled = ScreenTypingService.shared.isAuthorized
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("See and guide on screen") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("With Screen Recording and Accessibility, \(viewModel.character.title) can inspect the current app, highlight controls, and prepare clicks. Every click still requires your confirmation.")
                        .font(RetroPalette.font(11))
                        .foregroundStyle(RetroPalette.text)
                    HStack {
                        Text(
                            screenRecordingEnabled
                                ? "✓ Screen awareness enabled"
                                : "! Screen Recording permission required"
                        )
                        .font(RetroPalette.font(10))
                        .foregroundStyle(RetroPalette.text)
                        Spacer()
                        if screenRecordingEnabled {
                            Button("Open System Settings") {
                                ScreenAwarenessService.shared.openScreenRecordingSettings()
                            }
                        } else {
                            Button("Enable…") {
                                ScreenAwarenessService.shared.requestPermissions()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    screenRecordingEnabled = ScreenAwarenessService.shared.canSeeScreen
                                    accessibilityEnabled = ScreenTypingService.shared.isAuthorized
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }

            Text("Subscription modes use the locally installed CLI and its existing login. API usage is billed by the selected provider.")
                .font(RetroPalette.font(10))
                .foregroundStyle(RetroPalette.disabledText)
                }
                .padding(.vertical, 2)
            }

            // Classic dialogs put their commit button bottom-right. Only OK,
            // no Cancel: every setting here applies the moment it changes, so
            // a Cancel would promise a rollback that doesn't exist.
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .retroDialog()
        .frame(width: 560, height: 680)
        .retroWindow(title: "\(viewModel.character.title) Settings") { dismiss() }
        .onAppear {
            apiKey = viewModel.currentAPIKey()
            accessibilityEnabled = ScreenTypingService.shared.isAuthorized
            screenRecordingEnabled = ScreenAwarenessService.shared.canSeeScreen
        }
        .onChange(of: viewModel.provider) { _, _ in
            apiKey = viewModel.currentAPIKey()
            saveError = nil
        }
    }
}

struct ChatHistoryView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClearAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Chat history")
                    .font(.title2.bold())
                Spacer()
                if !viewModel.chatHistory.isEmpty {
                    Button("Clear all", role: .destructive) {
                        confirmingClearAll = true
                    }
                    .confirmationDialog(
                        "Delete all saved conversations?",
                        isPresented: $confirmingClearAll,
                        titleVisibility: .visible
                    ) {
                        Button("Delete All", role: .destructive) {
                            viewModel.clearAllHistory()
                        }
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if viewModel.chatHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Past conversations will show up here once you start a new one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.chatHistory) { session in
                        Button {
                            viewModel.restoreHistorySession(session)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.preview)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(session.endedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                viewModel.deleteHistorySession(session)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(22)
        .frame(width: 460, height: 520)
    }
}
