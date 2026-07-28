import AppKit
import ClippyCore
import SwiftUI

private enum CompactPanel {
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
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveringClippy = false
    @State private var compactInputActive = false
    @State private var compactBalloonVisible = true
    @State private var pasteMonitor: Any?
    @State private var compactInputFocused = false
    @State private var compactPanel: CompactPanel = .home
    @State private var showHistory = false
    /// Snapshot of the draft the moment dictation starts, so live transcript
    /// updates append to whatever the user already typed instead of
    /// replacing it outright — `SpeechService.transcript` resets to "" at
    /// the start of every dictation session.
    @State private var draftBeforeDictation = ""

    private let suggestions = [
        "Help me think through an idea",
        "Rewrite something for me",
        "Explain a hard concept",
        "Plan my day"
    ]

    private var clippyMood: ClippyMood {
        if viewModel.speech.isListening { return .listening }
        // isLoading only covers the initial chat request — a running or
        // retrying screen plan (including the decide-next-step follow-up
        // calls between actions) is a separate flag, and without this check
        // the sprite falls through to idle for the entire time Clippy is
        // actually working through a task.
        if viewModel.isLoading || viewModel.isRunningScreenPlan { return .thinking }
        if viewModel.speech.isSpeaking { return .talking }
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
            SettingsView()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showHistory) {
            ChatHistoryView()
                .environmentObject(viewModel)
        }
        .onChange(of: viewModel.speech.isListening) { _, isListening in
            if isListening { draftBeforeDictation = viewModel.draft }
        }
        .onChange(of: viewModel.speech.transcript) { _, newValue in
            guard viewModel.speech.isListening || !newValue.isEmpty else { return }
            guard !draftBeforeDictation.isEmpty else {
                viewModel.draft = newValue
                return
            }
            let needsSpace = !draftBeforeDictation.hasSuffix(" ") && !newValue.isEmpty
            viewModel.draft = draftBeforeDictation + (needsSpace ? " " : "") + newValue
        }
        .onAppear {
            installPasteMonitor()
            publishBalloonVisibility()
        }
        .onDisappear {
            if let pasteMonitor {
                NSEvent.removeMonitor(pasteMonitor)
                self.pasteMonitor = nil
            }
        }
        .alert(
            "Clippy needs permission",
            isPresented: Binding(
                get: { viewModel.speech.authorizationError != nil },
                set: { if !$0 { viewModel.speech.authorizationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.speech.authorizationError ?? "")
        }
    }

    private var expandedAssistant: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            conversation
            if let plan = viewModel.pendingScreenPlan {
                screenPlanBanner(plan)
            }
            if let action = viewModel.pendingScreenAction {
                screenActionBanner(action)
            }
            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
            composer
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.045)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(minWidth: 420, minHeight: 560)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.28))
        )
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
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
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
        .frame(width: 250, height: 340, alignment: .bottom)
    }

    private var classicBalloon: some View {
        VStack(alignment: .leading, spacing: 11) {
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
    private var compactMenu: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch compactPanel {
            case .home:
                ClassicOptionButton("Ask Clippy here") {
                    compactInputActive = true
                    compactInputFocused = true
                }
                ClassicOptionButton("Look at this screen") {
                    compactInputActive = true
                    viewModel.inspectCurrentScreen()
                }
                ClassicOptionButton("Continue a coding session") {
                    viewModel.refreshSessions()
                    compactPanel = .sessions
                }
                ClassicOptionButton("Open something") {
                    compactPanel = .open
                }
                ClassicOptionButton("Open the full chat window") {
                    viewModel.setExpanded(true)
                }
                Button {
                    setCompactBalloonVisible(false)
                } label: {
                    Label("Don’t show me this right now", systemImage: "square")
                        .font(.system(size: 11))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

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
        panel.title = "Attach to Clippy"
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

    private func attachmentIcon(for url: URL) -> String {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
        return imageExtensions.contains(url.pathExtension.lowercased()) ? "photo" : "doc"
    }

    private var compactStatusMessage: String {
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
        if viewModel.speech.isSpeaking, let last = viewModel.messages.last {
            return ResponsePresentation.compactText(last.content)
        }
        if let last = viewModel.messages.last, last.role == .assistant {
            return ResponsePresentation.compactText(last.content)
        }
        return "Hi! I am Clippy, your desktop assistant. Would you like some assistance today?"
    }

    private var header: some View {
        HStack(spacing: 11) {
            StaticClippyView()
                .frame(width: 62, height: 62)
                .scaleEffect(hoveringClippy ? 1.04 : 1)
                .onHover { hoveringClippy = $0 }
                .animation(.spring(response: 0.25), value: hoveringClippy)

            VStack(alignment: .leading, spacing: 5) {
                Text("Clippy")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(Color.black.opacity(0.64))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Circle()
                        .fill(viewModel.providerReady ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(viewModel.provider.shortTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.7))
                        .stroke(Color.black.opacity(0.1))
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                headerButton(
                    "arrow.down.right.and.arrow.up.left",
                    help: "Return to floating Clippy"
                ) {
                    viewModel.setExpanded(false)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.99, blue: 0.84),
                    Color(red: 1.0, green: 0.98, blue: 0.72)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.1))
                .frame(height: 1)
        }
    }

    private func headerButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 29, height: 29)
                .background(Circle().fill(Color.white.opacity(0.65)))
                .overlay(Circle().stroke(Color.black.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var statusMessage: String {
        if viewModel.speech.isListening { return "I’m listening…" }
        if viewModel.isLoading { return viewModel.activityMessage }
        if viewModel.speech.isSpeaking { return "Here’s what I found!" }
        if viewModel.errorMessage != nil { return "Oops—something went wrong." }
        if viewModel.activityMessage.hasPrefix("Stopped") { return viewModel.activityMessage }
        if viewModel.recentlyCompleted { return "Done — here’s what I found." }
        return "It looks like you’re trying to get something done."
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(viewModel.visibleMessages) { message in
                        MessageBubble(message: message)
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
                .padding(18)
            }
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

    private func screenActionBanner(_ action: PendingScreenAction) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "cursorarrow.click.2")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clippy found “\(action.label)”")
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
                Text("Clippy will stop before Send, Submit, payment, deletion, or password controls.")
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

    private var composer: some View {
        VStack(spacing: 9) {
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
                    Image(systemName: "paperclip.circle.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
                .help("Attach a file")

                Button {
                    viewModel.pasteAttachmentsOrExplain()
                } label: {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
                .help("Paste an image or file")

                TextField("Ask Clippy anything…", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(.body)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .stroke(Color.secondary.opacity(0.22))
                    )
                    .onSubmit {
                        if !NSEvent.modifierFlags.contains(.shift) {
                            viewModel.send()
                        }
                    }

                Button {
                    Task { await viewModel.speech.toggleListening() }
                } label: {
                    Image(systemName: viewModel.speech.isListening ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(viewModel.speech.isListening ? .red : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(viewModel.speech.isListening ? "Stop dictation" : "Dictate")

                Button {
                    if viewModel.isLoading || viewModel.isRunningScreenPlan {
                        viewModel.cancelRequest()
                    } else {
                        viewModel.send()
                    }
                } label: {
                    Image(systemName: (viewModel.isLoading || viewModel.isRunningScreenPlan) ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 29))
                }
                .buttonStyle(.plain)
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
                    .foregroundStyle(viewModel.providerReady ? Color.secondary : Color.orange)
                Spacer()
                if viewModel.speakReplies {
                    Label("Voice on", systemImage: "speaker.wave.2.fill")
                }
            }
            .font(.caption2)
        }
        .padding(14)
        .background(.ultraThinMaterial)
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

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user { Spacer(minLength: 58) }

            if message.role == .assistant {
                ClippyPortrait()
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
                    AnswerActions(content: message.content)
                }
            }
            .textSelection(.enabled)
                .font(.system(size: 14))
                .lineSpacing(3)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 15)
                        .fill(message.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                )
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)

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
                Label("Copy", systemImage: "doc.on.doc")
            }
            if let url = Self.firstLink(in: content) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open link", systemImage: "arrow.up.right.square")
                }
            }
        }
        .font(.system(size: 10, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .padding(.top, 2)
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

private struct MarkdownBlock: Identifiable {
    enum Kind {
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
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var saveError: String?
    @State private var accessibilityEnabled = ScreenTypingService.shared.isAuthorized
    @State private var screenRecordingEnabled = ScreenAwarenessService.shared.canSeeScreen

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Clippy Settings")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            GroupBox("AI provider") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Provider", selection: $viewModel.provider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(viewModel.provider.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            if viewModel.provider.needsAPIKey {
                GroupBox("Credentials") {
                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("\(viewModel.provider.shortTitle) API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Text("Stored only in your macOS Keychain.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                            Text(saveError).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(8)
                }
            }

            GroupBox("Model and behavior") {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.provider.needsAPIKey {
                        TextField("Model", text: $viewModel.model)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Text("The CLI’s configured default model will be used.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Read replies aloud", isOn: $viewModel.speakReplies)
                    Toggle("Keep Clippy above other windows", isOn: $viewModel.alwaysOnTop)
                    Toggle("Animate Clippy", isOn: $viewModel.animateClippy)
                    Text("Off keeps the paperclip still and reduces visual motion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Always run screen plans without confirming", isOn: $viewModel.alwaysAutoRunScreenPlans)
                    Text("Off (recommended) waits for you to tap Run plan on anything beyond a single app switch or address-bar navigation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("Write in other apps") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Clippy can insert generated text into the last editable field you focused. It never types into secure fields or presses Send.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Label(
                            accessibilityEnabled ? "Accessibility enabled" : "Accessibility permission required",
                            systemImage: accessibilityEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(accessibilityEnabled ? Color.green : Color.orange)
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
                    Text("With Screen Recording and Accessibility, Clippy can inspect the current app, highlight controls, and prepare clicks. Every click still requires your confirmation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Label(
                            screenRecordingEnabled
                                ? "Screen awareness enabled"
                                : "Screen Recording permission required",
                            systemImage: screenRecordingEnabled
                                ? "eye.circle.fill"
                                : "eye.slash.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(screenRecordingEnabled ? Color.green : Color.orange)
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
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 560, height: 680)
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
