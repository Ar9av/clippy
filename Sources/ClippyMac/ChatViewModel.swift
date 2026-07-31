import AppKit
import ClippyCore
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published var showOnboarding: Bool
    @Published var isExpanded = false
    @Published var pendingAttachments: [URL] = []
    @Published private(set) var activityMessage = ""
    @Published private(set) var activityElapsed = 0
    @Published private(set) var recentlyCompleted = false
    @Published private(set) var recentSessions: [CodingSession] = []
    @Published private(set) var chatHistory: [ArchivedChatSession] = []
    @Published var pendingScreenAction: PendingScreenAction?
    @Published var pendingScreenPlan: PendingScreenPlan? {
        didSet { ChatStore.savePendingPlan(pendingScreenPlan) }
    }
    @Published private(set) var isRunningScreenPlan = false
    /// One status per step of `pendingScreenPlan`, so the banner shows the
    /// sequence advancing and where it stopped if something failed.
    @Published private(set) var screenPlanStatuses: [ScreenPlanStepStatus] = []
    @Published private(set) var screenStatus: String?
    /// User-defined slash commands, editable in Settings. Stored as JSON
    /// rather than a plist array so the shape can grow without a migration.
    @Published var customPrompts: [CustomPrompt] = [] {
        didSet {
            guard let data = try? JSONEncoder().encode(customPrompts) else { return }
            UserDefaults.standard.set(data, forKey: "customPrompts")
        }
    }
    /// The floating balloon's home menu, seeded with the built-in rows so
    /// Settings has something to show on a fresh install.
    @Published var balloonActions: [BalloonAction] = BalloonAction.defaults {
        didSet {
            guard let data = try? JSONEncoder().encode(balloonActions) else { return }
            UserDefaults.standard.set(data, forKey: "balloonActions")
        }
    }

    /// Balloon rows the user has kept, plus any custom prompts they've asked to
    /// surface there. Drives the compact menu.
    var visibleBalloonActions: [BalloonAction] {
        balloonActions.filter(\.isVisible)
    }

    var balloonPrompts: [CustomPrompt] {
        customPrompts.filter { $0.showsInBalloon && $0.isValid }
    }

    func resetBalloonActions() {
        balloonActions = BalloonAction.defaults
    }

    func moveBalloonAction(id: UUID, by offset: Int) {
        guard let index = balloonActions.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard balloonActions.indices.contains(target) else { return }
        balloonActions.swapAt(index, target)
    }
    @Published var provider: AIProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "provider")
            model = UserDefaults.standard.string(forKey: "model.\(provider.rawValue)")
                ?? provider.defaultModel
        }
    }
    @Published var model: String {
        didSet {
            UserDefaults.standard.set(model, forKey: "model.\(provider.rawValue)")
        }
    }
    @Published var speakReplies: Bool {
        didSet { UserDefaults.standard.set(speakReplies, forKey: "speakReplies") }
    }
    @Published var alwaysOnTop: Bool {
        didSet {
            UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop")
            NotificationCenter.default.post(name: .clippyWindowLevelChanged, object: nil)
        }
    }
    @Published var animateClippy: Bool {
        didSet { UserDefaults.standard.set(animateClippy, forKey: "animateClippy") }
    }
    /// Off by default: a multi-step plan waits for the user to tap "Run
    /// plan" in the banner (or reply with an affirmative) instead of running
    /// unattended the moment it's parsed. A single-step open/navigate is
    /// always auto-run regardless of this setting — there's nothing to
    /// meaningfully review before switching to an app or loading a URL.
    @Published var alwaysAutoRunScreenPlans: Bool {
        didSet { UserDefaults.standard.set(alwaysAutoRunScreenPlans, forKey: "alwaysAutoRunScreenPlans") }
    }

    let speech = SpeechService()
    let permissions = PermissionsModel()
    private var currentRequestTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var lastRequestAttachments: [URL] = []
    private var lastRequestUsesScreenPlan = false
    private var lastUserRequestText: String?
    /// How long a plan waiting for confirmation stays valid — after this, an
    /// affirmative message is treated as unrelated rather than silently
    /// re-triggering a plan the user may have forgotten about.
    private static let pendingPlanConfirmationWindow: TimeInterval = 120

    init() {
        let rawProvider = UserDefaults.standard.string(forKey: "provider") ?? ""
        let selected = AIProvider(rawValue: rawProvider) ?? .claudeCLI
        provider = selected
        model = UserDefaults.standard.string(forKey: "model.\(selected.rawValue)")
            ?? selected.defaultModel
        speakReplies = UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true
        alwaysOnTop = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? false
        // The sprite sheet is charming, but a resting paperclip is smoother by default.
        animateClippy = UserDefaults.standard.object(forKey: "animateClippy") as? Bool ?? false
        alwaysAutoRunScreenPlans = UserDefaults.standard.object(forKey: "alwaysAutoRunScreenPlans") as? Bool ?? false
        showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if let data = UserDefaults.standard.data(forKey: "customPrompts"),
           let decoded = try? JSONDecoder().decode([CustomPrompt].self, from: data) {
            customPrompts = decoded
        }
        if let data = UserDefaults.standard.data(forKey: "balloonActions"),
           let decoded = try? JSONDecoder().decode([BalloonAction].self, from: data) {
            balloonActions = BalloonAction.merged(stored: decoded)
        }
        ScreenTypingService.shared.startTracking()
        ScreenAwarenessService.shared.startTracking()
        refreshSessions()
        Task.detached(priority: .background) { CacheJanitor.clean() }
        loadMessages()
        loadChatHistory()
        loadPendingScreenPlan()
        if messages.isEmpty {
            messages = [
                ChatMessage(
                    role: .assistant,
                    content: "Hi! I’m Clippy, now with a useful amount of intelligence. What can I help you with?"
                )
            ]
        }
    }

    var providerReady: Bool {
        if provider.needsAPIKey {
            return !(KeychainStore.read(account: provider.rawValue) ?? "").isEmpty
        }
        return AIService.cliAvailable(for: provider)
    }

    /// Keep full chat light and immediately useful. Older history remains stored
    /// for context, but the visual transcript opens on recent work only.
    var visibleMessages: [ChatMessage] {
        Array(messages.suffix(40))
    }

    func send(_ suggestedText: String? = nil) {
        var text = (suggestedText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)

        // Handled ahead of the in-flight guards below so `/clear` still works
        // as an escape hatch while a request or screen plan is running — which
        // is exactly when you're most likely to want to start over.
        if let command = SlashCommand.parse(text, prompts: customPrompts) {
            switch command {
            case .clear:
                draft = ""
                clearConversation()
                return
            case .help:
                draft = ""
                postAssistantNote(SlashCommand.helpText(prompts: customPrompts))
                return
            case .unknown(let name):
                draft = ""
                postAssistantNote(
                    "I don't have a `/\(name)` command.\n\n"
                        + SlashCommand.helpText(prompts: customPrompts)
                )
                return
            case .expanded(let expansion):
                text = expansion
            }
        }
        // A running plan holds currentRequestTask just like a chat request
        // does — without also checking isRunningScreenPlan here, a message
        // typed while a plan is mid-flight would start a second request that
        // overwrites currentRequestTask, orphaning the running plan so
        // neither cancelRequest() nor cancelPendingScreenPlan() can stop it.
        guard (!text.isEmpty || !pendingAttachments.isEmpty), !isLoading, !isRunningScreenPlan else { return }
        if let plan = pendingScreenPlan {
            let isStale = Date().timeIntervalSince(plan.createdAt) > Self.pendingPlanConfirmationWindow
            if Self.isAffirmativeConfirmation(text), !plan.hasExecuted, !isStale {
                draft = ""
                runPendingScreenPlan()
                return
            }
            // Either this message isn't a confirmation, or the plan it would
            // confirm has already run or gone stale — either way it must not
            // sit around to be re-triggered by some later unrelated "ok".
            pendingScreenPlan = nil
            screenPlanStatuses = []
        }
        if text.isEmpty {
            text = "Please look at the attached file and tell me what you notice."
        }
        var requestsScreenPlan = Self.requestsScreenPlan(text)
        if Self.requestsScreenTyping(text), !requestsScreenPlan {
            do {
                try ScreenTypingService.shared.prepareForInsertion()
            } catch ScreenTypingError.noEditableTarget,
                    ScreenTypingError.unsupportedField {
                requestsScreenPlan = true
            } catch {
                errorMessage = error.localizedDescription
                announce(error.localizedDescription)
                return
            }
        }

        draft = ""
        errorMessage = nil
        speech.stopSpeaking()
        let attachments = pendingAttachments
        pendingAttachments = []
        submitUserMessage(text: text, attachments: attachments, requestsScreenPlan: requestsScreenPlan)
    }

    /// Appends the user's message to the transcript and starts the request —
    /// shared by `send()` and `retryLastRequest()` so a retry always resends
    /// through the exact same path a fresh message would, rather than
    /// replaying `startRequest` against whatever now happens to be at the
    /// end of `messages`.
    private func submitUserMessage(text: String, attachments: [URL], requestsScreenPlan: Bool) {
        let attachmentLabel = attachments.isEmpty
            ? ""
            : "\n\nAttached: " + attachments.map(\.lastPathComponent).joined(separator: ", ")
        messages.append(ChatMessage(role: .user, content: text + attachmentLabel))
        persistMessages()
        lastRequestAttachments = attachments
        lastRequestUsesScreenPlan = requestsScreenPlan
        lastUserRequestText = text
        startRequest(
            attachments: attachments,
            forceScreenPlan: requestsScreenPlan
        )
    }

    /// Retries the last message the user actually sent, tracked explicitly
    /// rather than inferred from `messages.last?.role`. A screen plan posts
    /// its own assistant-authored step history to the transcript on
    /// completion or failure (`postStepHistory`), so after any plan the last
    /// message is never the user's — the old `messages.last?.role == .user`
    /// guard made "Try again" a silent no-op in exactly the case it matters
    /// most: right after a plan failed. Re-submits the same text as a fresh
    /// message rather than replaying stale history.
    func retryLastRequest() {
        guard !isLoading, !isRunningScreenPlan, let text = lastUserRequestText else { return }
        errorMessage = nil
        speech.stopSpeaking()
        submitUserMessage(text: text, attachments: lastRequestAttachments, requestsScreenPlan: lastRequestUsesScreenPlan)
    }

    /// Also cancels a running screen plan, not just an ordinary chat
    /// request — previously guarded on `isLoading` alone, which is already
    /// false by the time a plan is executing (see `startRequest`), making
    /// this a silent no-op for the entire duration of any plan.
    func cancelRequest() {
        guard isLoading || isRunningScreenPlan else { return }
        if isRunningScreenPlan {
            cancelPendingScreenPlan()
            return
        }
        currentRequestTask?.cancel()
        currentRequestTask = nil
        activityTask?.cancel()
        isLoading = false
        activityMessage = "Stopped. Your message is still here."
        announce("Clippy stopped working on the request.")
    }

    private func startRequest(
        attachments: [URL],
        forceScreenPlan: Bool = false
    ) {
        isLoading = true
        recentlyCompleted = false
        errorMessage = nil
        activityElapsed = 0
        activityMessage = attachments.isEmpty
            ? "Sending to \(provider.shortTitle)…"
            : "Opening \(attachmentSummary(attachments.count))…"
        announce(activityMessage)
        startActivityClock(hasAttachments: !attachments.isEmpty)

        let history = messages
        let selectedProvider = provider
        let selectedModel = model
        let key = KeychainStore.read(account: selectedProvider.rawValue)
        let shouldWriteToScreen = Self.requestsScreenTyping(history.last?.content ?? "")
            && !Self.requestsScreenPlan(history.last?.content ?? "")
            && !forceScreenPlan
        let shouldBuildScreenPlan = forceScreenPlan
            || Self.requestsScreenPlan(history.last?.content ?? "")
        let shouldDraftScreenReply = Self.requestsScreenReply(history.last?.content ?? "")
        // Always capture the screen + running-app list rather than gating it
        // behind a hand-written phrase list. The model decides from that
        // context whether the request needs a click, a multi-app workflow,
        // or no screen action at all — matching phrases like "open", "do it",
        // or something we never thought to enumerate would otherwise leave
        // it answering blind. The presentation-specific flags below still
        // shape formatting strictness once we know context is available.
        let shouldInspectScreen = ScreenAwarenessService.shared.canSeeScreen
        // Without Screen Recording, every request previously still went out
        // with screen-action instructions in the prompt while no screenshot
        // was ever attached — the model had no way to know why, and the user
        // saw no indication their screen simply wasn't visible. Say so once,
        // up front, whenever the request actually wanted a screen action.
        if !shouldInspectScreen, shouldWriteToScreen || shouldBuildScreenPlan || shouldDraftScreenReply {
            screenStatus = "I can't see your screen — grant Screen Recording in Settings, or I'll just answer in words."
        }
        let presentation: ResponsePresentation
        if shouldWriteToScreen {
            presentation = .screenInsert
        } else if shouldBuildScreenPlan {
            presentation = .screenPlan
        } else if shouldDraftScreenReply {
            presentation = .screenReply
        } else {
            presentation = isExpanded ? .expanded : .compact
        }

        currentRequestTask = Task {
            // Declared outside the `do` block so the `catch` below can also
            // see it — a stream that errors out partway through must not
            // leave an empty placeholder bubble behind.
            var streamedMessageID: UUID?
            do {
                var effectiveAttachments = attachments
                var capturedScreen: ScreenContext?
                if shouldInspectScreen {
                    activityMessage = "Looking at the current screen…"
                    let context = try await ScreenAwarenessService.shared.captureContext()
                    // Every display, not just the active one — a request about
                    // "the other screen" needs the other screen attached.
                    effectiveAttachments.append(contentsOf: context.screenshotURLs)
                    effectiveAttachments.append(context.contextURL)
                    capturedScreen = context
                    screenStatus = "Looking at \(context.appName) · \(context.windowTitle)"
                    activityMessage = "Understanding \(context.appName)…"
                }

                // When the user supplied the literal text, build the one safe
                // typing step from macOS's actual accessibility labels instead
                // of asking a model to guess a target name.
                if shouldBuildScreenPlan,
                   let capturedScreen,
                   let textToInsert = Self.explicitTextToInsert(from: history.last?.content ?? ""),
                   let target = ScreenAwarenessService.shared.preferredEditableTarget(
                    in: capturedScreen.elements
                   ) {
                    let plan = PendingScreenPlan(
                        summary: "Put the requested text into \(target)",
                        steps: [ScreenPlanStep(action: .type, target: target, text: textToInsert)]
                    )
                    messages.append(ChatMessage(
                        role: .assistant,
                        content: "Putting that into \(target)."
                    ))
                    persistMessages()
                    activityTask?.cancel()
                    isLoading = false
                    await autoRunScreenPlan(plan)
                    currentRequestTask = nil
                    return
                }
                var response: String
                // Streaming only covers the plain-answer path: Anthropic,
                // no attachments (screenshots/pasted files still go through
                // the existing non-streaming AIService.reply, which already
                // knows how to encode them), and a presentation the user
                // will actually watch fill in live. Screen-action
                // presentations need the complete response before any
                // marker/plan parsing can happen, so there's nothing
                // meaningful to stream there.
                if selectedProvider == .anthropic,
                   let key, !key.isEmpty,
                   effectiveAttachments.isEmpty,
                   presentation == .compact || presentation == .expanded {
                    let streamed = try await streamAnthropicReply(
                        history: history,
                        model: selectedModel,
                        apiKey: key,
                        presentation: presentation
                    )
                    response = streamed.text
                    streamedMessageID = streamed.messageID
                } else {
                    response = try await AIService.reply(
                        provider: selectedProvider,
                        messages: history,
                        model: selectedModel,
                        apiKey: key,
                        attachments: effectiveAttachments,
                        presentation: presentation
                    )
                }
                if shouldDraftScreenReply, AIService.asksForScreenAttachment(response) {
                    // Some CLI providers occasionally ignore image attachments on
                    // their first pass. Retry once with an unambiguous instruction
                    // while retaining the same live screenshot and AX context.
                    let retryMessage = ChatMessage(
                        role: .user,
                        content: "Use the live Screen Context already provided. Draft the reply from the visible conversation now. Do not ask for an attachment, screenshot, or pasted message."
                    )
                    response = try await AIService.reply(
                        provider: selectedProvider,
                        messages: history + [retryMessage],
                        model: selectedModel,
                        apiKey: key,
                        attachments: effectiveAttachments,
                        presentation: .screenReply
                    )
                    if AIService.asksForScreenAttachment(response) {
                        response = "I can’t find an open conversation on screen."
                    }
                }
                try Task.checkCancellation()
                var screenReplyPoint: CGPoint?
                if shouldDraftScreenReply, let target = AIService.screenReplyTarget(from: response) {
                    response = target.response
                    screenReplyPoint = CoordinateSpace.resolvedPoint(
                        target.point,
                        windowFrame: capturedScreen?.windowFrame,
                        scale: capturedScreen?.screenshotScale
                    )
                }
                let signaledInsertion = AIService.screenInsertionText(from: response)
                let parsedScreenPlan = AIService.screenPlan(
                    from: response,
                    bounds: capturedScreen?.windowFrame,
                    scale: capturedScreen?.screenshotScale
                )
                let screenDirective = AIService.screenDirective(from: response)
                let responseWithoutDirective: String
                if let parsedScreenPlan {
                    responseWithoutDirective = parsedScreenPlan.response
                } else if let screenDirective {
                    // A directive with no trailing sentence must never fall through
                    // to the raw, marker-included response — that's how a literal
                    // "[[CLIPPY_CLICK:...]]" string ends up displayed or typed.
                    responseWithoutDirective = screenDirective.response.isEmpty
                        ? Self.defaultDirectiveMessage(
                            for: screenDirective.kind,
                            target: screenDirective.target
                        )
                        : screenDirective.response
                } else if let fallback = AIService.screenPlanFallbackResponse(from: response) {
                    responseWithoutDirective = fallback
                } else if let noTarget = AIService.screenPlanNoTargetResponse(from: response) {
                    responseWithoutDirective = noTarget
                } else if shouldBuildScreenPlan {
                    responseWithoutDirective = "I couldn’t map a safe destination from this screen. Open the target field, then ask me to look again."
                } else {
                    responseWithoutDirective = response
                }
                let preparedResponse = signaledInsertion
                    ?? presentation.prepare(responseWithoutDirective)
                let willWriteToScreen = shouldWriteToScreen || signaledInsertion != nil
                // A streamed reply already exists in `messages` as a
                // live-updating placeholder — finalize its content (which
                // may differ slightly from the raw streamed text once
                // `presentation.prepare` trims/compacts it) rather than
                // appending a second copy of the same answer.
                if let streamedMessageID, let index = messages.firstIndex(where: { $0.id == streamedMessageID }) {
                    messages[index].content = preparedResponse
                } else {
                    messages.append(ChatMessage(role: .assistant, content: preparedResponse))
                }
                persistMessages()
                // An explicit [[CLIPPY_GUIDE]]/[[CLIPPY_CLICK]] directive always wins
                // over the generic "type into screen" heuristic — otherwise a
                // click directive with no trailing text could get typed verbatim
                // into the focused field instead of ever asking for confirmation.
                if let screenDirective {
                    switch screenDirective.kind {
                    case .guide:
                        do {
                            let target = try ScreenAwarenessService.shared.highlight(
                                matching: screenDirective.target,
                                instruction: preparedResponse
                            )
                            screenStatus = "Highlighted \(target)."
                            finishActivity(message: "I highlighted \(target).")
                        } catch {
                            screenStatus = "Visual guidance ready."
                            finishActivity(message: "I found the next step.")
                        }
                    case .click:
                        let target = try ScreenAwarenessService.shared.highlight(
                            matching: screenDirective.target,
                            instruction: preparedResponse
                        )
                        guard !AutomationSafety.isFinalAction(target) else {
                            ScreenAwarenessService.shared.dismissHighlight()
                            screenStatus = "I won't click \"\(target)\" — that looks like a final action, so I'll leave it for you to click."
                            finishActivity(message: screenStatus ?? "I won't click that for you.")
                            return
                        }
                        pendingScreenAction = PendingScreenAction(
                            label: target,
                            detail: preparedResponse.isEmpty
                                ? "Click \(target)?"
                                : preparedResponse
                        )
                        screenStatus = "Waiting for your confirmation."
                        finishActivity(message: "Ready when you are.")
                    }
                    if speakReplies { speech.speak(Self.spokenText(from: preparedResponse)) }
                } else if willWriteToScreen {
                    // Prefer the field the screen capture above already found —
                    // it doesn't require the destination to have been clicked
                    // or polled into focus, unlike ScreenTypingService's live
                    // tracker. Fall back to that tracker only when no screen
                    // was captured (e.g. screen-recording permission denied).
                    if let capturedScreen,
                       let target = ScreenAwarenessService.shared.preferredEditableTarget(
                        in: capturedScreen.elements
                       ) {
                        try await ScreenAwarenessService.shared.put(preparedResponse, into: target)
                        finishActivity(message: "Typed into \(target).")
                    } else {
                        let appName = try await ScreenTypingService.shared.insert(preparedResponse)
                        finishActivity(message: "Typed into \(appName).")
                    }
                    // preparedResponse here is the exact text just typed into
                    // another app, not commentary — speaking it back would
                    // read the other app's own field content aloud.
                } else if shouldDraftScreenReply {
                    do {
                        let target = try await ScreenAwarenessService.shared
                            .putReplyDraft(preparedResponse, near: screenReplyPoint)
                        screenStatus = "Draft placed in \(target). It was not sent."
                        finishActivity(message: "I drafted it in the reply box — not sent.")
                    } catch {
                        // Keep the draft visible even if the page changed while
                        // the provider was thinking; the user can still copy it.
                        screenStatus = "Reply ready — I couldn’t reach the message box."
                        finishActivity(message: "Your reply is ready to copy.")
                    }
                    // Same reasoning as willWriteToScreen: this is the drafted
                    // reply's own text, not something to read aloud.
                } else {
                    if let parsedScreenPlan {
                        activityTask?.cancel()
                        isLoading = false
                        await presentOrAutoRun(parsedScreenPlan.plan)
                    } else {
                        finishActivity()
                    }
                    if speakReplies { speech.speak(Self.spokenText(from: preparedResponse)) }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A stream that errors before any text arrived left an empty
                // placeholder bubble in the transcript — remove it rather
                // than showing a blank assistant message next to the error.
                if let streamedMessageID,
                   let index = messages.firstIndex(where: { $0.id == streamedMessageID }),
                   messages[index].content.isEmpty {
                    messages.remove(at: index)
                }
                errorMessage = error.localizedDescription
                activityMessage = "I hit a snag."
                announce("Clippy could not complete the request. \(error.localizedDescription)")
            }
            activityTask?.cancel()
            isLoading = false
            currentRequestTask = nil
        }
    }

    /// Appends a live-updating placeholder assistant message and fills it in
    /// as text deltas arrive from `AnthropicClient.stream`, instead of the
    /// single blocking round-trip every provider used before. Only ever
    /// called for plain-answer presentations with no attachments (see the
    /// call site) — screen-action presentations still need the complete
    /// response before any marker/plan parsing can happen.
    private func streamAnthropicReply(
        history: [ChatMessage],
        model: String,
        apiKey: String,
        presentation: ResponsePresentation
    ) async throws -> (text: String, messageID: UUID) {
        let recent = Array(history.suffix(24))
        let trimmed = recent.firstIndex(where: { $0.role == .user }).map { Array(recent[$0...]) } ?? recent
        let completionMessages = trimmed.map {
            CompletionMessage(role: $0.role == .user ? .user : .assistant, content: [.text($0.content)])
        }
        let request = CompletionRequest(
            system: AIService.systemPrompt + "\n\n" + presentation.instructions,
            messages: completionMessages,
            model: model
        )

        let placeholder = ChatMessage(role: .assistant, content: "")
        messages.append(placeholder)
        let index = messages.count - 1

        let client = AnthropicClient(apiKey: apiKey)
        var accumulated = ""
        for try await event in client.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
                accumulated += delta
                if messages.indices.contains(index) {
                    messages[index].content = accumulated
                }
            case .completed(let response):
                if !response.text.isEmpty { accumulated = response.text }
            }
        }
        return (accumulated, placeholder.id)
    }

    private func startActivityClock(hasAttachments: Bool) {
        activityTask?.cancel()
        activityTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, isLoading else { return }
                activityElapsed += 1
                switch activityElapsed {
                case 1 where hasAttachments:
                    activityMessage = "Reading the attachments…"
                case 2:
                    activityMessage = "Thinking through your request…"
                case 7:
                    activityMessage = "Still working — this one needs a little more thought."
                case 18:
                    activityMessage = "Taking longer than usual, but I’m still on it."
                default:
                    break
                }
            }
        }
    }

    private func finishActivity(message: String = "Done — here’s what I found.") {
        activityMessage = message
        recentlyCompleted = true
        announce(message)
        completionTask?.cancel()
        completionTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            recentlyCompleted = false
        }
    }

    private func attachmentSummary(_ count: Int) -> String {
        count == 1 ? "your attachment" : "\(count) attachments"
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private static func isAffirmativeConfirmation(_ request: String) -> Bool {
        let normalized = request
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        let phrases: Set<String> = [
            "yes", "yep", "yeah", "yup", "sure", "ok", "okay",
            "do it", "go ahead", "run it", "run the plan", "confirm",
            "sounds good", "yes please", "yeah do it", "go for it",
            "looks good", "lgtm"
        ]
        return phrases.contains(normalized)
    }

    private static func requestsScreenTyping(_ request: String) -> Bool {
        let normalized = request
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let writingVerb = [
            "write ", "type ", "insert ", "put ", "fill ", "paste ",
            "enter ", "place "
        ].contains { normalized.hasPrefix($0) || normalized.contains(" \($0)") }
        let destinationHint = [
            "for me", "here", "in this", "into this", "text box",
            "textbox", "field", "on screen", "in the app", "on the app",
            "in this app", "on this app", "in chatgpt", "on chatgpt",
            "into chatgpt", "in the prompt", "into the prompt", "on the prompt",
            "type it", "put it", "paste it", "enter it", "there"
        ].contains { normalized.contains($0) }
        return writingVerb && destinationHint
    }

    private static func requestsScreenContext(_ request: String) -> Bool {
        let normalized = request.lowercased()
        let visualHints = [
            "look at my screen", "look at the screen", "look at the current screen",
            "see my screen",
            "what's on my screen", "what is on my screen", "this screen",
            "this page", "this window", "what should i click",
            "where do i click", "show me where", "highlight",
            "click for me", "click it", "click the"
        ]
        return visualHints.contains { normalized.contains($0) }
    }

    private static func requestsScreenPlan(_ request: String) -> Bool {
        let normalized = request
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        let navigation = [
            "navigate", "go to", "open the", "find the", "find and",
            "click through", "take me to"
        ].contains { normalized.contains($0) }
        let placement = [
            " put ", "put ", " type ", "type ", " fill ", "fill ",
            " write ", "write ", " enter ", "enter "
        ].contains { normalized.contains($0) }
        if navigation && placement { return true }

        let changeVerb = [
            "change", "update", "edit", "modify", "enable", "disable",
            "turn on", "turn off", "switch", "select", "choose", "set "
        ].contains { normalized.contains($0) }
        let onScreenDestination = [
            "in the app", "on the app", "on screen", "on the screen",
            "in settings", "the setting", "the settings", "the menu",
            "the option", "dark mode", "light mode"
        ].contains { normalized.contains($0) }
        if changeVerb && onScreenDestination { return true }

        // A short imperative with no other content ("open", "do it for me")
        // almost always means "act on what you just told me about" — usually
        // a link Clippy itself just suggested. These never satisfy the more
        // specific phrase pairs above, so they need their own direct check.
        let actionConfirmations: Set<String> = [
            "open", "open it", "open that", "open this", "open it for me",
            "open that for me", "open for me", "do it", "do it for me",
            "go there", "go for it", "take me there", "visit it", "visit that"
        ]
        return actionConfirmations.contains(normalized)
    }

    private static func defaultDirectiveMessage(
        for kind: AIService.ScreenDirectiveKind,
        target: String
    ) -> String {
        switch kind {
        case .guide:
            return "Here's \(target)."
        case .click:
            return "Click \(target)?"
        }
    }

    /// Strips Markdown before handing text to `AVSpeechSynthesizer` — it was
    /// previously fed the raw expanded-presentation reply verbatim, so
    /// headings, bold/italic markers, links, and fenced code all got read
    /// aloud character-for-character (e.g. "pound pound Setup" for "## Setup").
    /// Code blocks are dropped entirely rather than read character-by-character.
    nonisolated static func spokenText(from markdown: String) -> String {
        var text = markdown
        text = text.replacingOccurrences(of: #"```[a-zA-Z0-9]*\n[\s\S]*?```"#, with: " Code omitted. ", options: .regularExpression)
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: [.regularExpression, .anchored])
        text = text.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: #"(?m)^[-*]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Internal rather than private so the routing it drives is testable
    /// directly, the same way `ScreenAwarenessService.matchScore` is.
    static func requestsScreenReply(_ request: String) -> Bool {
        let normalized = request.lowercased()
        let replyVerb = ["reply", "respond", "answer", "write back"].contains {
            normalized.contains($0)
        }
        let directDraftRequest = [
            "write a reply", "draft a reply", "help me reply", "compose a reply"
        ].contains { normalized.contains($0) }
        let visibleReference = [
            "this guy", "this person", "this message", "this chat", "this conversation",
            "him", "her", "them", "the last message", "on screen"
        ].contains { normalized.contains($0) }
        // Reply requests are most useful when Clippy reads the active thread.
        // If no message is actually visible, the provider can still ask a
        // focused follow-up instead of forcing the user to re-describe a page.
        return replyVerb || directDraftRequest || visibleReference && normalized.contains("draft")
    }

    private static func explicitTextToInsert(from request: String) -> String? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?is)\b(?:put|type|paste|enter|insert)\s+[“\"]?(.+?)[”\"]?\s+(?:into|in|on|to)\s+(?:the\s+)?(?:app|screen|prompt|field|text box|textbox|chat|codex(?:\s+prompt(?:\s+field)?)?)\s*[.!?]?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              let range = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        let text = String(trimmed[range])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard !text.isEmpty, text.count <= 2_000 else { return nil }
        return text
    }

    func inspectCurrentScreen() {
        send("Look at the current screen, tell me the best next step, and highlight the relevant control.")
    }

    func confirmPendingScreenAction() {
        guard pendingScreenAction != nil else { return }
        do {
            try ScreenAwarenessService.shared.clickHighlighted()
            screenStatus = "Clicked."
            pendingScreenAction = nil
            finishActivity(message: "Clicked — I left submission to you.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelPendingScreenAction() {
        pendingScreenAction = nil
        screenStatus = nil
        ScreenAwarenessService.shared.dismissHighlight()
    }

    func runPendingScreenPlan() {
        guard let plan = pendingScreenPlan, !isRunningScreenPlan, !plan.hasExecuted else { return }
        currentRequestTask = Task {
            await executeScreenPlan(plan)
            currentRequestTask = nil
        }
    }

    /// Runs a plan immediately, with no approval step. Used for plans Clippy
    /// builds itself in direct response to an explicit user request (e.g.
    /// "open X for me") — `ScreenPlanRunner`/`AutomationSafety` still refuse
    /// any step that touches Send, Submit, payment, deletion, or password
    /// controls, so this only auto-runs the steps already judged safe.
    /// Callers that are already inside `currentRequestTask` should await this
    /// directly rather than going through `runPendingScreenPlan()`, which
    /// would spawn a second task and stomp on the first's task reference.
    func autoRunScreenPlan(_ plan: PendingScreenPlan) async {
        guard !isRunningScreenPlan else { return }
        await executeScreenPlan(plan)
    }

    /// A single `open` (switch app) or a single address/search-bar navigate
    /// has nothing meaningful to review before running — the earlier
    /// "I couldn't map a destination" branches already cover the case where
    /// there's no safe target at all. Anything else (multi-step, or any
    /// step that clicks/types into the current app) waits for the user to
    /// tap "Run plan" in the banner, unless they've opted into always
    /// auto-running via Settings.
    private static func qualifiesForAutoRun(_ plan: PendingScreenPlan) -> Bool {
        guard plan.steps.count == 1, let step = plan.steps.first else { return false }
        switch step.action {
        case .open:
            return true
        case .type:
            return step.pressReturnAfter == true
        case .scroll:
            // Scrolling changes nothing but the viewport, and asking the user
            // to confirm "scroll down a bit" defeats the point of the agent
            // being able to look further down a page on its own.
            return true
        case .click, .wait, .key:
            return false
        }
    }

    /// Decides whether a freshly parsed plan runs immediately or waits for
    /// explicit confirmation — the system prompt tells the model the app
    /// "will show the complete plan and require confirmation before running
    /// it," but until this every plan auto-ran regardless of size or risk.
    private func presentOrAutoRun(_ plan: PendingScreenPlan) async {
        if alwaysAutoRunScreenPlans || Self.qualifiesForAutoRun(plan) {
            await autoRunScreenPlan(plan)
            return
        }
        pendingScreenPlan = plan
        screenPlanStatuses = plan.steps.map { _ in .pending }
        screenStatus = "Ready to run \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s") — tap Run plan to confirm."
        finishActivity(message: "I've got a plan ready — tap Run plan when you want me to go ahead.")
    }

    /// Runs one step, then re-observes the screen and asks the model to
    /// decide the next one from what actually happened — rather than
    /// trusting every step a plan predicted up front. The screen rarely
    /// matches a prediction exactly (a menu opens somewhere unexpected, a
    /// dialog appears, a page is still loading), and running blind through a
    /// stale plan is exactly what leaves Clippy clicking into a state it
    /// never actually observed. `plan.steps` beyond the first are only ever
    /// used as the very first action; every action after that comes from a
    /// fresh decide-from-screenshot round.
    /// A step failing (wrong label, moved control, a menu that opened
    /// differently) isn't grounds to stop and wait for the user to click
    /// Try Again — it's exactly what re-observing is for. A fresh screenshot
    /// after the failure usually shows the model why its guess was wrong, so
    /// it can propose a different approach on its own. `maxConsecutiveFailures`
    /// bounds that so a genuinely stuck task still stops instead of retrying
    /// forever.
    private static let maxConsecutiveFailures = 3
    /// A model proposing the same action it just took — even one it
    /// succeeded at — twice in a row means re-observing isn't changing its
    /// mind, usually because it's judging from a screenshot taken before the
    /// previous action's effect (a page load, an animation) actually
    /// finished. Screenshotting and asking a third time won't fix that;
    /// stopping and surfacing it beats silently looping to the step cap.
    private static let maxConsecutiveRepeats = 2

    /// Scrolling is the exception: reaching something far down a page takes
    /// several identical scrolls in a row, and each one genuinely changes
    /// what the next observation sees. Under the ordinary limit the loop
    /// would stop two scrolls in — barely past the fold — and report a stall
    /// that never happened. Still bounded, so scrolling forever at the end of
    /// a document stops.
    private static let maxConsecutiveScrolls = 5

    private func executeScreenPlan(_ plan: PendingScreenPlan) async {
        isRunningScreenPlan = true
        errorMessage = nil

        var executedSteps: [ScreenPlanStep] = []
        var executedStatuses: [ScreenPlanStepStatus] = []
        var nextStep = plan.steps.first
        let summary = plan.summary
        var stoppedEarly = false
        var consecutiveFailures = 0
        var consecutiveRepeats = 0
        var lastFailureReason: String?
        var stalledOnRepeat = false
        // Set when the model explicitly says the goal is done (or can't
        // safely continue) via an empty-steps [[CLIPPY_PLAN]] — a real
        // success/stop signal, never conflated with a request failure.
        var modelStopReason: String?
        // Set when re-planning itself failed (provider error, unreadable
        // response) — this must never be reported as success just because
        // `nextStep` ended up nil.
        var loopError: String?

        stepLoop: while let step = nextStep, executedSteps.count < ScreenPlanRunner.stepLimit {
            guard !Task.isCancelled else {
                stoppedEarly = true
                break
            }
            executedSteps.append(step)
            executedStatuses.append(.running)
            pendingScreenPlan = PendingScreenPlan(summary: summary, steps: executedSteps)
            screenPlanStatuses = executedStatuses

            let runner = ScreenPlanRunner(performer: ScreenAwarenessService.shared)
            var failureReason: String?
            do {
                try await runner.run(PendingScreenPlan(summary: summary, steps: [step])) { [weak self] progress in
                    guard let self else { return }
                    self.activityMessage = progress.message
                    self.announce(progress.message)
                }
                executedStatuses[executedStatuses.count - 1] = .done
                screenPlanStatuses = executedStatuses
                consecutiveFailures = 0
            } catch is CancellationError {
                executedStatuses[executedStatuses.count - 1] = .failed
                screenPlanStatuses = executedStatuses
                stoppedEarly = true
                break
            } catch {
                executedStatuses[executedStatuses.count - 1] = .failed
                screenPlanStatuses = executedStatuses
                consecutiveFailures += 1
                failureReason = error.localizedDescription
                lastFailureReason = failureReason
                announce("That didn't work — \(failureReason ?? "trying a different way.")")
            }

            guard !Task.isCancelled else {
                stoppedEarly = true
                break
            }

            if consecutiveFailures >= Self.maxConsecutiveFailures {
                errorMessage = lastFailureReason
                screenStatus = "Stopped after \(consecutiveFailures) failed attempts in a row."
                ScreenAwarenessService.shared.dismissHighlight()
                announce("Clippy stopped after retrying \(consecutiveFailures) times. \(lastFailureReason ?? "")")
                finishActivity(message: "I tried a few approaches and got stuck — check the step I flagged.")
                postStepHistory(executedSteps, statuses: executedStatuses, goal: summary, outcomeNote: "stuck after repeated failures")
                pendingScreenPlan?.hasExecuted = true
                isRunningScreenPlan = false
                return
            }

            // Give the action's effect time to actually land before judging
            // it from a screenshot — a page navigation especially. Without
            // this, the very next capture can catch a still-loading page and
            // the model concludes nothing happened, retyping the same thing.
            let settleMillis = (step.action == .type && step.pressReturnAfter == true) ? 1400 : 500
            try? await Task.sleep(for: .milliseconds(settleMillis))

            let decision = await decideNextStep(afterAttempting: step, goal: summary, failureReason: failureReason)
            guard !Task.isCancelled else {
                stoppedEarly = true
                break
            }
            switch decision {
            case .step(let proposed):
                if Self.isEquivalentAction(proposed, step) {
                    consecutiveRepeats += 1
                } else {
                    consecutiveRepeats = 0
                }
                let repeatLimit = proposed.action == .scroll
                    ? Self.maxConsecutiveScrolls
                    : Self.maxConsecutiveRepeats
                if consecutiveRepeats >= repeatLimit {
                    stalledOnRepeat = true
                    break stepLoop
                }
                nextStep = proposed
            case .stop(let reason):
                modelStopReason = reason
                nextStep = nil
            case .error(let message):
                loopError = message
                nextStep = nil
            }
        }

        ScreenAwarenessService.shared.dismissHighlight()
        // Whatever a plan is left visible for below (stopped, stalled,
        // errored, or gave up), it has already run and must never be
        // re-triggered by "Run plan" or a later affirmative message — the
        // success branches null pendingScreenPlan out entirely anyway.
        pendingScreenPlan?.hasExecuted = true
        if stoppedEarly {
            screenStatus = "Plan stopped."
        } else if let loopError {
            // The re-planning round itself failed (provider error, unreadable
            // response, or a failed re-capture) — this must read as an error,
            // not as "the model decided to stop," even though the plan itself
            // is now paused with no next step.
            errorMessage = loopError
            screenStatus = "Stopped — I couldn't check what happened next."
            announce("Clippy stopped. \(loopError)")
            finishActivity(message: "Something interrupted me while checking the next step — check what ran so far.")
            postStepHistory(executedSteps, statuses: executedStatuses, goal: summary, outcomeNote: "stopped — couldn't confirm the next step (\(loopError))")
        } else if stalledOnRepeat {
            screenStatus = "Stopped — kept proposing the same step without progress."
            announce("Clippy stopped. It kept proposing the same step without anything changing.")
            finishActivity(message: "I got stuck repeating the same step — check what happened and try again.")
            postStepHistory(executedSteps, statuses: executedStatuses, goal: summary, outcomeNote: "stopped — repeated the same step without progress")
        } else if executedStatuses.last == .failed {
            // The loop exited because the model, after seeing the failure and
            // a fresh screenshot, couldn't find another way forward — not
            // because the task succeeded. Leave the plan and its statuses
            // visible so the user can see exactly where it gave up.
            errorMessage = lastFailureReason
            screenStatus = "Stopped — couldn't find a safe way to continue."
            announce("Clippy stopped. \(lastFailureReason ?? "It couldn't find a safe way to continue.")")
            finishActivity(message: "I got stuck and couldn't finish — check the step I flagged.")
            postStepHistory(executedSteps, statuses: executedStatuses, goal: summary, outcomeNote: "stopped — couldn't find a safe way to continue")
        } else if let modelStopReason {
            // The only real success path: the model itself, looking at a
            // fresh screenshot, said the goal is done (or can't safely
            // continue) and gave a reason — surface that reason verbatim
            // rather than a generic "done" that discards it.
            pendingScreenPlan = nil
            screenPlanStatuses = []
            screenStatus = modelStopReason
            finishActivity(message: modelStopReason)
            postStepHistory(executedSteps, statuses: executedStatuses, goal: summary, outcomeNote: modelStopReason)
        } else if executedSteps.count >= ScreenPlanRunner.stepLimit {
            // Hit the step cap with a next step still queued — the task was
            // truncated, not completed. Never claim success here.
            screenStatus = "Reached the \(ScreenPlanRunner.stepLimit)-step limit before finishing."
            announce("Clippy reached its step limit before finishing.")
            finishActivity(message: "I hit my \(ScreenPlanRunner.stepLimit)-step limit before finishing — here's where I got to.")
            postStepHistory(executedSteps, statuses: executedStatuses, goal: summary, outcomeNote: "stopped — reached the step limit before finishing")
        } else {
            pendingScreenPlan = nil
            screenPlanStatuses = []
            screenStatus = "Ran \(executedSteps.count) step\(executedSteps.count == 1 ? "" : "s")."
            finishActivity(message: "Done — I ran the whole sequence.")
            postStepHistory(executedSteps, statuses: executedStatuses, goal: summary, outcomeNote: nil)
        }
        isRunningScreenPlan = false
    }

    /// Ignores `id` (regenerated fresh on every decode, so it can never
    /// match across separately-parsed steps) and pixel-level x/y jitter —
    /// what matters for loop detection is "is this the same action again,"
    /// not exact coordinates.
    private static func isEquivalentAction(_ a: ScreenPlanStep, _ b: ScreenPlanStep) -> Bool {
        a.action == b.action && a.target == b.target && a.text == b.text
            && a.app == b.app && a.key == b.key && a.direction == b.direction
    }

    /// Posts a permanent, readable record of what actually ran to the chat
    /// transcript — the live banner is transient UI (cleared or replaced by
    /// the next plan), and the compact balloon in particular has no room to
    /// show a long step list without cutting it off.
    private func postStepHistory(
        _ steps: [ScreenPlanStep],
        statuses: [ScreenPlanStepStatus],
        goal: String,
        outcomeNote: String?
    ) {
        guard !steps.isEmpty else { return }
        var lines = ["**\(goal)**"]
        for (index, step) in steps.enumerated() {
            let status = statuses.indices.contains(index) ? statuses[index] : .pending
            let mark = status == .done ? "✓" : (status == .failed ? "✗" : "•")
            lines.append("\(mark) \(index + 1). \(step.displayText)")
        }
        if let outcomeNote {
            lines.append("\n_\(outcomeNote.prefix(1).capitalized + outcomeNote.dropFirst())._")
        }
        messages.append(ChatMessage(role: .assistant, content: lines.joined(separator: "\n")))
        persistMessages()
    }

    /// What the re-plan round decided. Distinguishing these three keeps a
    /// provider error or a failed re-capture from ever being reported as
    /// success — previously all three collapsed into a single `nil`, so a
    /// mid-plan network error read exactly like the model saying "I'm done."
    private enum NextStepDecision {
        case step(ScreenPlanStep)
        case stop(reason: String?)
        case error(String)
    }

    /// A standalone, unpersisted follow-up call — it isn't appended to
    /// `messages`, so an N-step task doesn't spam the visible chat with N
    /// intermediate exchanges.
    private func decideNextStep(
        afterAttempting step: ScreenPlanStep,
        goal: String,
        failureReason: String?
    ) async -> NextStepDecision {
        let context: ScreenContext
        do {
            context = try await ScreenAwarenessService.shared.captureContext()
        } catch {
            return .error(error.localizedDescription)
        }
        let content: String
        if let failureReason {
            content = "You just tried: \(step.displayText) — but it failed: \(failureReason). Using the attached current screenshot and Screen Context (taken after the failed attempt), find a different way to reach the goal \"\(goal)\": a different label, coordinates instead of a label, or a different route entirely. If nothing on screen looks like a safe way forward, say so and return no further step."
        } else {
            content = "You just completed: \(step.displayText). Toward the goal \"\(goal)\", using the attached current screenshot and Screen Context, decide the single next step — or say the goal already looks complete."
        }
        let followUp = ChatMessage(role: .user, content: content)
        let response: String
        do {
            response = try await AIService.reply(
                provider: provider,
                messages: messages + [followUp],
                model: model,
                apiKey: KeychainStore.read(account: provider.rawValue),
                attachments: context.screenshotURLs + [context.contextURL],
                presentation: .screenPlanStep
            )
        } catch {
            return .error(error.localizedDescription)
        }
        if let next = AIService.screenPlan(from: response, bounds: context.windowFrame, scale: context.screenshotScale)?.plan.steps.first {
            return .step(next)
        }
        if let reason = AIService.screenPlanStop(from: response) {
            return .stop(reason: reason)
        }
        return .error("I couldn't understand the model's next step.")
    }

    func cancelPendingScreenPlan() {
        currentRequestTask?.cancel()
        pendingScreenPlan = nil
        screenPlanStatuses = []
        isRunningScreenPlan = false
        screenStatus = nil
        ScreenAwarenessService.shared.dismissHighlight()
    }

    func finishOnboarding() {
        showOnboarding = false
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }

    func addAttachments(_ urls: [URL]) {
        let existing = Set(pendingAttachments)
        pendingAttachments.append(contentsOf: urls.filter { !existing.contains($0) })
    }

    @discardableResult
    func importPasteboardAttachments() -> Bool {
        let pasteboard = NSPasteboard.general

        let pastedURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL])?.map { $0 as URL } ?? []
        if !pastedURLs.isEmpty {
            addAttachments(pastedURLs)
            announce(pastedURLs.count == 1 ? "File attached." : "\(pastedURLs.count) files attached.")
            return true
        }

        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("org.webmproject.webp")
        ]
        let image = NSImage(pasteboard: pasteboard) ?? imageTypes.compactMap {
            pasteboard.data(forType: $0).flatMap(NSImage.init(data:))
        }.first

        guard let image,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }

        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Clippy", isDirectory: true)
                .appendingPathComponent("PastedAttachments", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = directory.appendingPathComponent(
                "Pasted Image \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).png"
            )
            try pngData.write(to: url, options: .atomic)
            addAttachments([url])
            errorMessage = nil
            announce("Image pasted and attached.")
            return true
        } catch {
            errorMessage = "I couldn’t save that pasted image. \(error.localizedDescription)"
            return false
        }
    }

    func pasteAttachmentsOrExplain() {
        if !importPasteboardAttachments() {
            errorMessage = "There isn’t an image or file on the clipboard yet. Copy one, then paste again."
        }
    }

    func removeAttachment(_ url: URL) {
        pendingAttachments.removeAll { $0 == url }
    }

    /// Recursively enumerates `~/.codex/sessions` and `~/.claude/projects`
    /// and reads a chunk of each session file — potentially dozens of files
    /// for a heavy CLI user. Runs off the main actor so a cold launch (this
    /// is called from `init()`) doesn't stall the UI on disk I/O before the
    /// window ever appears.
    func refreshSessions() {
        Task.detached(priority: .utility) {
            let sessions = LocalActionService.recentSessions()
            await MainActor.run { self.recentSessions = sessions }
        }
    }

    func resume(_ session: CodingSession) {
        do {
            try LocalActionService.resume(session)
            activityMessage = "Opening \(session.provider.rawValue) in Terminal…"
            announce(activityMessage)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        NotificationCenter.default.post(name: .clippyExpansionChanged, object: expanded)
    }

    /// Adds an assistant message that came from Clippy itself rather than a
    /// model response — command help and unknown-command replies — so they
    /// read in the transcript like any other answer.
    private func postAssistantNote(_ text: String) {
        errorMessage = nil
        messages.append(ChatMessage(role: .assistant, content: text))
        persistMessages()
    }

    func clearConversation() {
        cancelRequest()
        speech.stopSpeaking()
        cancelPendingScreenAction()
        cancelPendingScreenPlan()
        archiveCurrentSession()
        messages = [
            ChatMessage(role: .assistant, content: "Fresh sheet of paper. What are we working on?")
        ]
        persistMessages()
    }

    /// Only conversations with a real user message are worth keeping —
    /// an untouched greeting-only chat is not history.
    private func archiveCurrentSession() {
        guard messages.contains(where: { $0.role == .user }) else { return }
        let archived = ArchivedChatSession(messages: messages)
        chatHistory.insert(archived, at: 0)
        chatHistory = Array(chatHistory.prefix(30))
        persistChatHistory()
    }

    func restoreHistorySession(_ session: ArchivedChatSession) {
        archiveCurrentSession()
        chatHistory.removeAll { $0.id == session.id }
        persistChatHistory()
        messages = session.messages
        persistMessages()
    }

    func deleteHistorySession(_ session: ArchivedChatSession) {
        chatHistory.removeAll { $0.id == session.id }
        persistChatHistory()
    }

    func clearAllHistory() {
        chatHistory = []
        persistChatHistory()
    }

    func saveAPIKey(_ key: String) throws {
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainStore.delete(account: provider.rawValue)
        } else {
            try KeychainStore.save(key, account: provider.rawValue)
        }
        objectWillChange.send()
    }

    func currentAPIKey() -> String {
        KeychainStore.read(account: provider.rawValue) ?? ""
    }

    private func persistMessages() {
        ChatStore.saveMessages(messages)
    }

    private func loadMessages() {
        let decoded = ChatStore.loadMessages()
        guard !decoded.isEmpty else { return }
        messages = decoded
    }

    /// A plan left over from before the app quit is only worth restoring if
    /// it's still within the same confirmation window `send()` enforces for
    /// a live plan — otherwise this would resurrect a stale "Run plan" days
    /// later. `didSet` on `pendingScreenPlan` re-persists it here, which is a
    /// harmless no-op write.
    private func loadPendingScreenPlan() {
        guard let plan = ChatStore.loadPendingPlan(), !plan.hasExecuted else { return }
        let isStale = Date().timeIntervalSince(plan.createdAt) > Self.pendingPlanConfirmationWindow
        guard !isStale else {
            ChatStore.savePendingPlan(nil)
            return
        }
        pendingScreenPlan = plan
        screenPlanStatuses = plan.steps.map { _ in .pending }
    }

    private func persistChatHistory() {
        ChatStore.saveHistory(chatHistory)
    }

    private func loadChatHistory() {
        chatHistory = ChatStore.loadHistory()
    }
}

extension Notification.Name {
    static let clippyWindowLevelChanged = Notification.Name("clippyWindowLevelChanged")
    static let clippyExpansionChanged = Notification.Name("clippyExpansionChanged")
    static let clippyBalloonVisibilityChanged = Notification.Name("clippyBalloonVisibilityChanged")
    static let clippyBalloonContentSizeChanged = Notification.Name("clippyBalloonContentSizeChanged")
}
