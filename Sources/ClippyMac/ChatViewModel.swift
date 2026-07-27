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

    let speech = SpeechService()
    private var currentRequestTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var lastRequestAttachments: [URL] = []

    init() {
        let rawProvider = UserDefaults.standard.string(forKey: "provider") ?? ""
        let selected = AIProvider(rawValue: rawProvider) ?? .claudeCLI
        provider = selected
        model = UserDefaults.standard.string(forKey: "model.\(selected.rawValue)")
            ?? selected.defaultModel
        speakReplies = UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true
        alwaysOnTop = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? false
        refreshSessions()
        loadMessages()
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

    func send(_ suggestedText: String? = nil) {
        var text = (suggestedText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !pendingAttachments.isEmpty), !isLoading else { return }
        if text.isEmpty {
            text = "Please look at the attached file and tell me what you notice."
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
        startRequest(attachments: attachments)
    }

    func retryLastRequest() {
        guard !isLoading, messages.last?.role == .user else { return }
        errorMessage = nil
        speech.stopSpeaking()
        startRequest(attachments: lastRequestAttachments)
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

    private func startRequest(attachments: [URL]) {
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
        let presentation: ResponsePresentation = isExpanded ? .expanded : .compact

        currentRequestTask = Task {
            do {
                let response = try await AIService.reply(
                    provider: selectedProvider,
                    messages: history,
                    model: selectedModel,
                    apiKey: key,
                    attachments: attachments,
                    presentation: presentation
                )
                try Task.checkCancellation()
                messages.append(
                    ChatMessage(role: .assistant, content: presentation.prepare(response))
                )
                persistMessages()
                finishActivity()
                if speakReplies { speech.speak(presentation.prepare(response)) }
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

    private func finishActivity() {
        activityMessage = "Done — here’s what I found."
        recentlyCompleted = true
        announce("Clippy finished the request.")
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
        messages = [
            ChatMessage(role: .assistant, content: "Fresh sheet of paper. What are we working on?")
        ]
        persistMessages()
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
}

extension Notification.Name {
    static let clippyWindowLevelChanged = Notification.Name("clippyWindowLevelChanged")
    static let clippyExpansionChanged = Notification.Name("clippyExpansionChanged")
    static let clippyBalloonVisibilityChanged = Notification.Name("clippyBalloonVisibilityChanged")
}
