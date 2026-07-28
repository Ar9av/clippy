import AppKit
import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published var isExpanded = false
    @Published var pendingAttachments: [URL] = []
    @Published private(set) var activityMessage = ""
    @Published private(set) var activityElapsed = 0
    @Published private(set) var recentlyCompleted = false
    @Published private(set) var recentSessions: [CodingSession] = []
    @Published private(set) var chatHistory: [ArchivedChatSession] = []
    @Published var pendingScreenAction: PendingScreenAction?
    @Published var pendingScreenPlan: PendingScreenPlan?
    @Published private(set) var isRunningScreenPlan = false
    /// One status per step of `pendingScreenPlan`, so the banner shows the
    /// sequence advancing and where it stopped if something failed.
    @Published private(set) var screenPlanStatuses: [ScreenPlanStepStatus] = []
    @Published private(set) var screenStatus: String?
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

    let speech = SpeechService()
    private var currentRequestTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var lastRequestAttachments: [URL] = []
    private var lastRequestUsesScreenPlan = false

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
        ScreenTypingService.shared.startTracking()
        ScreenAwarenessService.shared.startTracking()
        refreshSessions()
        loadMessages()
        loadChatHistory()
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
        guard (!text.isEmpty || !pendingAttachments.isEmpty), !isLoading else { return }
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
        let attachmentLabel = attachments.isEmpty
            ? ""
            : "\n\nAttached: " + attachments.map(\.lastPathComponent).joined(separator: ", ")
        messages.append(ChatMessage(role: .user, content: text + attachmentLabel))
        pendingAttachments = []
        persistMessages()
        lastRequestAttachments = attachments
        lastRequestUsesScreenPlan = requestsScreenPlan
        startRequest(
            attachments: attachments,
            forceScreenPlan: requestsScreenPlan
        )
    }

    func retryLastRequest() {
        guard !isLoading, messages.last?.role == .user else { return }
        errorMessage = nil
        speech.stopSpeaking()
        startRequest(
            attachments: lastRequestAttachments,
            forceScreenPlan: lastRequestUsesScreenPlan
        )
    }

    func cancelRequest() {
        guard isLoading else { return }
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
        let shouldInspectScreen = Self.requestsScreenContext(history.last?.content ?? "")
            || shouldBuildScreenPlan
            || shouldDraftScreenReply
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
            do {
                var effectiveAttachments = attachments
                var capturedScreen: ScreenContext?
                if shouldInspectScreen {
                    activityMessage = "Looking at the current screen…"
                    let context = try await ScreenAwarenessService.shared.captureContext()
                    effectiveAttachments.append(context.screenshotURL)
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
                        content: "I found \(target). Review the one safe step below."
                    ))
                    persistMessages()
                    pendingScreenPlan = plan
                    screenStatus = "Waiting for approval to run 1 step."
                    finishActivity(message: "I found the destination. Check the step.")
                    if speakReplies { speech.speak("I found the destination. Check the step.") }
                    activityTask?.cancel()
                    isLoading = false
                    currentRequestTask = nil
                    return
                }
                var response = try await AIService.reply(
                    provider: selectedProvider,
                    messages: history,
                    model: selectedModel,
                    apiKey: key,
                    attachments: effectiveAttachments,
                    presentation: presentation
                )
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
                let signaledInsertion = AIService.screenInsertionText(from: response)
                let parsedScreenPlan = AIService.screenPlan(from: response)
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
                messages.append(ChatMessage(role: .assistant, content: preparedResponse))
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
                        pendingScreenAction = PendingScreenAction(
                            label: target,
                            detail: preparedResponse.isEmpty
                                ? "Click \(target)?"
                                : preparedResponse
                        )
                        screenStatus = "Waiting for your confirmation."
                        finishActivity(message: "Ready when you are.")
                    }
                } else if willWriteToScreen {
                    let appName = try await ScreenTypingService.shared.insert(preparedResponse)
                    finishActivity(message: "Typed into \(appName).")
                } else if shouldDraftScreenReply {
                    do {
                        let target = try await ScreenAwarenessService.shared
                            .putReplyDraft(preparedResponse)
                        screenStatus = "Draft placed in \(target). It was not sent."
                        finishActivity(message: "I drafted it in the reply box — not sent.")
                    } catch {
                        // Keep the draft visible even if the page changed while
                        // the provider was thinking; the user can still copy it.
                        screenStatus = "Reply ready — I couldn’t reach the message box."
                        finishActivity(message: "Your reply is ready to copy.")
                    }
                } else if let parsedScreenPlan {
                    pendingScreenPlan = parsedScreenPlan.plan
                    screenStatus = "Waiting for approval to run \(parsedScreenPlan.plan.steps.count) steps."
                    finishActivity(message: "I mapped the route. Check the steps.")
                } else {
                    finishActivity()
                }
                if speakReplies { speech.speak(preparedResponse) }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                activityMessage = "I hit a snag."
                announce("Clippy could not complete the request. \(error.localizedDescription)")
            }
            activityTask?.cancel()
            isLoading = false
            currentRequestTask = nil
        }
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
        let normalized = request.lowercased()
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
        return changeVerb && onScreenDestination
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

    private static func requestsScreenReply(_ request: String) -> Bool {
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
        guard let plan = pendingScreenPlan, !isRunningScreenPlan else { return }
        isRunningScreenPlan = true
        errorMessage = nil
        screenPlanStatuses = Array(repeating: .pending, count: plan.steps.count)
        let runner = ScreenPlanRunner(performer: ScreenAwarenessService.shared)
        currentRequestTask = Task {
            do {
                try await runner.run(plan) { [weak self] progress in
                    guard let self else { return }
                    if self.screenPlanStatuses.indices.contains(progress.index) {
                        self.screenPlanStatuses[progress.index] = progress.status
                    }
                    if progress.status == .running {
                        self.activityMessage = progress.message
                        self.announce(progress.message)
                    }
                }
                pendingScreenPlan = nil
                screenPlanStatuses = []
                ScreenAwarenessService.shared.dismissHighlight()
                screenStatus = "Ran \(plan.steps.count) steps without submitting."
                finishActivity(message: "Done — I ran the whole sequence and stopped before submitting.")
            } catch is CancellationError {
                screenStatus = "Plan stopped."
                ScreenAwarenessService.shared.dismissHighlight()
            } catch {
                errorMessage = error.localizedDescription
                // The plan stays on screen with its statuses intact so the
                // user can see which step failed and retry from there.
                screenStatus = "Stopped before the remaining steps."
                ScreenAwarenessService.shared.dismissHighlight()
                announce("Clippy stopped the plan. \(error.localizedDescription)")
                finishActivity(message: "I stopped partway — check the step I flagged.")
            }
            isRunningScreenPlan = false
            currentRequestTask = nil
        }
    }

    func cancelPendingScreenPlan() {
        currentRequestTask?.cancel()
        pendingScreenPlan = nil
        screenPlanStatuses = []
        isRunningScreenPlan = false
        screenStatus = nil
        ScreenAwarenessService.shared.dismissHighlight()
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

    func refreshSessions() {
        recentSessions = LocalActionService.recentSessions()
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
        if let data = try? JSONEncoder().encode(Array(messages.suffix(100))) {
            UserDefaults.standard.set(data, forKey: "messages")
        }
    }

    private func loadMessages() {
        guard let data = UserDefaults.standard.data(forKey: "messages"),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return
        }
        messages = decoded
    }

    private func persistChatHistory() {
        if let data = try? JSONEncoder().encode(chatHistory) {
            UserDefaults.standard.set(data, forKey: "chatHistory")
        }
    }

    private func loadChatHistory() {
        guard let data = UserDefaults.standard.data(forKey: "chatHistory"),
              let decoded = try? JSONDecoder().decode([ArchivedChatSession].self, from: data) else {
            return
        }
        chatHistory = decoded
    }
}

extension Notification.Name {
    static let clippyWindowLevelChanged = Notification.Name("clippyWindowLevelChanged")
    static let clippyExpansionChanged = Notification.Name("clippyExpansionChanged")
    static let clippyBalloonVisibilityChanged = Notification.Name("clippyBalloonVisibilityChanged")
}
