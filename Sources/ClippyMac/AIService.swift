import Foundation

enum ResponsePresentation: Equatable {
    case compact
    case expanded
    case screenInsert
    case screenPlan
    case screenReply

    var instructions: String {
        switch self {
        case .compact:
            """
            This answer will appear inside a very small floating speech balloon. \
            Give only the most useful conclusion in one or two short sentences, using at most 110 characters. \
            Use plain text only: no Markdown, headings, bullets, code fences, or preamble. \
            If the request genuinely needs detail, give the key answer and end with “Open full chat for details.” \
            The [[CLIPPY_TYPE]] screen-action format is an exception to these length and formatting limits.
            """
        case .expanded:
            """
            This answer will appear in the full chat window. Give a complete, useful answer. \
            Use clear Markdown structure when it improves readability: short headings, bullets, numbered steps, emphasis, links, and fenced code blocks. \
            Stay concise relative to the task, but do not omit important explanation merely to keep the answer short.
            """
        case .screenInsert:
            """
            The answer will be inserted directly into another app’s text field. \
            Return only the exact finished text the user asked you to write. \
            Do not add an introduction, explanation, quotation marks, Markdown fences, or a speaker label.
            """
        case .screenPlan:
            """
            Clippy could not retain a previously focused field, so use the attached screenshot and Screen Context to locate the intended destination. \
            Return only a [[CLIPPY_PLAN]] JSON plan that navigates if needed and types the requested text into a clearly labeled editable field. \
            Every target must exactly match a label in “Visible actionable controls”; never invent a label such as “prompt field.” \
            Do not use [[CLIPPY_TYPE]], Markdown, commentary, or any text outside the JSON. \
            If there is no visible editable destination, return [[CLIPPY_NO_TARGET]] followed by one short sentence. \
            Never include Send, Submit, payment, deletion, agreement, password, or other final-action steps.
            """
        case .screenReply:
            """
            The user asked for a reply to a conversation visible on their screen. A live screenshot and Screen Context are supplied with this request; use them directly. \
            Return only a polished, ready-to-send reply to the most relevant visible message. \
            Match the other person's language and tone, keep it concise, and do not mention screenshots, Clippy, or uncertainty. \
            Never ask the user to attach, paste, share, or describe the message. If no readable conversation is visible, say only: “I can’t find an open conversation on screen.” \
            Do not use Markdown, a speaker label, or action markers. Never send the reply or claim it was sent.
            """
        }
    }

    func prepare(_ response: String) -> String {
        guard self == .compact || self == .screenReply else {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Self.compactText(response, limit: self == .screenReply ? 340 : 120)
    }

    static func compactText(_ response: String, limit: Int = 120) -> String {
        var text = response
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit - 1))
        if let sentenceEnd = prefix.lastIndex(where: { ".!?".contains($0) }),
           prefix.distance(from: prefix.startIndex, to: sentenceEnd) > limit / 2 {
            return String(prefix[...sentenceEnd])
        }
        let trimmed = prefix.split(separator: " ").dropLast().joined(separator: " ")
        return (trimmed.isEmpty ? prefix : trimmed) + "…"
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func install(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let activeProcess = process
        lock.unlock()
        if activeProcess?.isRunning == true {
            activeProcess?.terminate()
        }
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum AIService {
    enum ScreenDirectiveKind {
        case guide
        case click
    }

    struct ScreenDirective {
        let kind: ScreenDirectiveKind
        let target: String
        let response: String
    }

    struct ParsedScreenPlan {
        let plan: PendingScreenPlan
        let response: String
    }

    private static let systemPrompt = """
    You are Clippy, a friendly desktop AI assistant for macOS. Be genuinely helpful, warm, concise, and practical. \
    You can help with writing, brainstorming, explaining, planning, debugging, and everyday questions. \
    Clippy can insert text into the last editable field the user focused. When the user asks you to type, enter, paste, \
    put, place, fill, or write finished text in another app, in a prompt, in a text box, “here,” or “on the app,” \
    respond with [[CLIPPY_TYPE]] as the first characters, followed only by the exact text to insert. \
    Resolve follow-ups such as “put that on the app” from the conversation. Never say you cannot type into the app. \
    Do not use the marker for ordinary writing requests that the user only wants answered inside Clippy. \
    When a Screen Context attachment is present, use its accessibility labels and coordinates together with the screenshot. \
    If pointing to one visible control would help, begin with [[CLIPPY_GUIDE:exact control label]]. \
    If and only if the user explicitly asks Clippy to click a control, begin with [[CLIPPY_CLICK:exact control label]]. \
    Only emit either marker when that exact label appears in the “Visible actionable controls” list; otherwise give visual instructions without a marker. \
    The app always asks the user to confirm before a click, so never claim the click already happened. \
    When the user explicitly asks you to navigate, find a control, and put text somewhere, you may return a multi-step plan. \
    Begin with [[CLIPPY_PLAN]] followed by one compact JSON object matching \
    {"summary":"what the plan will do","steps":[{"action":"open","app":"System Settings"},{"action":"click","target":"exact label"},{"action":"wait","seconds":0.8},{"action":"key","key":"tab"},{"action":"type","target":"exact field label","text":"exact text"}]}. \
    Use at most 10 steps. Allowed actions are open, click, wait, key, and type. \
    Use open to bring another app to the front before acting on it, and key only for tab, escape, up, down, left, or right — there is no Return key, because the user always performs the final submit. \
    Waits may be 0.1 to 8 seconds; prefer a short wait after any click that opens a menu, sheet, or new pane. \
    Sequence as many steps as the task genuinely needs rather than stopping after the first one. \
    Never include a step that sends, submits, publishes, purchases, deletes, accepts terms, or enters a password. \
    After the JSON, add one short plain-language sentence. The app will show the complete plan and require confirmation before running it. \
    When a Screen Context attachment is present and the user asks to change, update, enable, disable, switch, or select something in the current app, return the same multi-step plan format. \
    Use only exact labels from “Visible actionable controls”, include every necessary navigation step, and stop before any final or irreversible action. \
    You are running as a local desktop client. Never claim you changed files or performed an action unless the user explicitly saw that happen. \
    Use plain language and light humor when it fits.
    """

    private static let screenTypingMarker = "[[CLIPPY_TYPE]]"

    static func screenInsertionText(from response: String) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(screenTypingMarker) else { return nil }
        let text = trimmed.dropFirst(screenTypingMarker.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func screenDirective(from response: String) -> ScreenDirective? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns: [(ScreenDirectiveKind, String)] = [
            (.guide, #"^\[\[CLIPPY_GUIDE:([^\]]+)\]\]"#),
            (.click, #"^\[\[CLIPPY_CLICK:([^\]]+)\]\]"#)
        ]
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: trimmed,
                    range: NSRange(trimmed.startIndex..., in: trimmed)
                  ),
                  let targetRange = Range(match.range(at: 1), in: trimmed),
                  let markerRange = Range(match.range(at: 0), in: trimmed) else {
                continue
            }
            let target = String(trimmed[targetRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = String(trimmed[markerRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return nil }
            return ScreenDirective(kind: kind, target: target, response: cleaned)
        }
        return nil
    }

    static func screenPlan(from response: String) -> ParsedScreenPlan? {
        let marker = "[[CLIPPY_PLAN]]"
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker) else { return nil }
        var remainder = String(trimmed.dropFirst(marker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.hasPrefix("```json") {
            remainder.removeFirst(7)
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if remainder.hasPrefix("```") {
            remainder.removeFirst(3)
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = remainder.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?
        for index in remainder.indices[start...] {
            let character = remainder[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && inString {
                escaped = true
                continue
            }
            if character == "\"" {
                inString.toggle()
                continue
            }
            guard !inString else { continue }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    end = index
                    break
                }
            }
        }
        guard let end,
              let data = String(remainder[start...end]).data(using: .utf8),
              let plan = try? JSONDecoder().decode(PendingScreenPlan.self, from: data),
              (try? ScreenPlanRunner.validate(plan)) != nil else {
            return nil
        }
        var responseText = String(remainder[remainder.index(after: end)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if responseText.hasPrefix("```") {
            responseText.removeFirst(3)
            responseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ParsedScreenPlan(
            plan: plan,
            response: responseText.isEmpty ? plan.summary : responseText
        )
    }

    static func screenPlanFallbackResponse(from response: String) -> String? {
        let marker = "[[CLIPPY_PLAN]]"
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker) else { return nil }
        let remainder = String(trimmed.dropFirst(marker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let closingBrace = remainder.lastIndex(of: "}") {
            let trailing = String(remainder[remainder.index(after: closingBrace)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                return trailing
            }
            let jsonText = String(remainder[...closingBrace])
            if let data = jsonText.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let summary = object["summary"] as? String,
               !summary.isEmpty {
                return summary
            }
        }
        return "Open the target app so the destination field is visible, then ask me again."
    }

    static func screenPlanNoTargetResponse(from response: String) -> String? {
        let marker = "[[CLIPPY_NO_TARGET]]"
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker) else { return nil }
        let message = String(trimmed.dropFirst(marker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty
            ? "I can’t see an editable field yet. Open the destination and ask me to look again."
            : message
    }

    static func asksForScreenAttachment(_ response: String) -> Bool {
        let normalized = response.lowercased()
        let attachmentAsk = [
            "attach a screenshot", "attach the screenshot", "attach a screen context",
            "attach screen context", "share the message", "paste the message",
            "i don't see a screenshot", "i can’t see a screenshot", "i can't see a screenshot",
            "screenshot attached", "only see what's shared", "only see what’s shared",
            "not your live screen", "can only see what"
        ]
        return attachmentAsk.contains { normalized.contains($0) }
    }

    static func reply(
        provider: AIProvider,
        messages: [ChatMessage],
        model: String,
        apiKey: String?,
        attachments: [URL] = [],
        presentation: ResponsePresentation
    ) async throws -> String {
        let prompt = transcript(
            messages,
            attachments: attachments,
            presentation: presentation
        )
        switch provider {
        case .claudeCLI:
            return try await runClaude(prompt: prompt)
        case .codexCLI:
            return try await runCodex(
                prompt: prompt,
                attachments: attachments
            )
        case .openAI:
            guard let apiKey, !apiKey.isEmpty else { throw ClippyError.missingAPIKey("OpenAI") }
            return try await callOpenAI(
                messages: messages,
                model: model,
                apiKey: apiKey,
                attachments: attachments,
                instructions: systemPrompt + "\n\n" + presentation.instructions
            )
        case .anthropic:
            guard let apiKey, !apiKey.isEmpty else { throw ClippyError.missingAPIKey("Anthropic") }
            return try await callAnthropic(
                messages: messages,
                model: model,
                apiKey: apiKey,
                attachments: attachments,
                instructions: systemPrompt + "\n\n" + presentation.instructions
            )
        }
    }

    static func cliAvailable(for provider: AIProvider) -> Bool {
        switch provider {
        case .claudeCLI: findExecutable(named: "claude") != nil
        case .codexCLI: findExecutable(named: "codex") != nil
        case .openAI, .anthropic: true
        }
    }

    private static func transcript(
        _ messages: [ChatMessage],
        attachments: [URL],
        presentation: ResponsePresentation
    ) -> String {
        let recent = messages.suffix(16).map {
            "\($0.role == .user ? "User" : "Clippy"): \($0.content)"
        }.joined(separator: "\n\n")
        let files = attachmentPrompt(attachments)

        return """
        \(systemPrompt)

        \(presentation.instructions)

        Continue this conversation. Answer only as Clippy, without a speaker label.

        \(recent)
        \(files)
        """
    }

    private static func runClaude(prompt: String) async throws -> String {
        guard let executable = findExecutable(named: "claude") else {
            throw ClippyError.missingCLI("Claude Code")
        }
        let result = try await runProcess(
            executable: executable,
            arguments: ["-p", prompt, "--output-format", "text"],
            currentDirectory: FileManager.default.temporaryDirectory
        )
        return try checkedOutput(result)
    }

    private static func runCodex(prompt: String, attachments: [URL]) async throws -> String {
        guard let executable = findExecutable(named: "codex") else {
            throw ClippyError.missingCLI("Codex")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        var arguments = [
            "exec",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--color", "never",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "-o", outputURL.path
        ]
        for attachment in attachments where isImage(attachment) {
            arguments.append(contentsOf: ["-i", attachment.path])
        }
        arguments.append("-")

        let result = try await runProcess(
            executable: executable,
            arguments: arguments,
            currentDirectory: FileManager.default.temporaryDirectory,
            standardInput: Data(prompt.utf8)
        )

        if result.status != 0 {
            throw ClippyError.processFailed(cleanProcessError(result))
        }
        guard let data = try? Data(contentsOf: outputURL),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try checkedOutput(result)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func callOpenAI(
        messages: [ChatMessage],
        model: String,
        apiKey: String,
        attachments: [URL],
        instructions: String
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let apiMessages = APIServiceMessages.from(messages)
        let input: [[String: Any]] = apiMessages.enumerated().map { index, message in
            let isLatestUser = index == apiMessages.count - 1 && message.role == .user
            if isLatestUser && !attachments.isEmpty {
                var content: [[String: Any]] = [
                    ["type": "input_text", "text": message.content + textAttachmentContents(attachments)]
                ]
                for attachment in attachments where isImage(attachment) {
                    if let dataURL = imageDataURL(attachment) {
                        content.append(["type": "input_image", "image_url": dataURL])
                    }
                }
                for attachment in attachments where isPDF(attachment) {
                    if let data = boundedData(attachment) {
                        content.append([
                            "type": "input_file",
                            "filename": attachment.lastPathComponent,
                            "file_data": "data:application/pdf;base64,\(data.base64EncodedString())"
                        ])
                    }
                }
                return ["role": "user", "content": content]
            }
            return [
                "role": message.role == .user ? "user" : "assistant",
                "content": message.content
            ]
        }
        let body: [String: Any] = [
            "model": model.isEmpty ? AIProvider.openAI.defaultModel : model,
            "instructions": instructions,
            "input": input
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, provider: "OpenAI")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [[String: Any]] else {
            throw ClippyError.invalidResponse("OpenAI returned an unfamiliar response.")
        }

        let text = output.compactMap { item -> String? in
            guard let content = item["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { $0["text"] as? String }.joined()
        }.joined()
        guard !text.isEmpty else { throw ClippyError.emptyResponse }
        return text
    }

    private static func callAnthropic(
        messages: [ChatMessage],
        model: String,
        apiKey: String,
        attachments: [URL],
        instructions: String
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let apiMessages = APIServiceMessages.from(messages)
        let bodyMessages: [[String: Any]] = apiMessages.enumerated().map { index, message in
            let isLatestUser = index == apiMessages.count - 1 && message.role == .user
            if isLatestUser && !attachments.isEmpty {
                var content: [[String: Any]] = [
                    ["type": "text", "text": message.content + textAttachmentContents(attachments)]
                ]
                for attachment in attachments where isImage(attachment) {
                    guard let data = boundedData(attachment) else { continue }
                    content.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mimeType(for: attachment),
                            "data": data.base64EncodedString()
                        ]
                    ])
                }
                for attachment in attachments where isPDF(attachment) {
                    guard let data = boundedData(attachment) else { continue }
                    content.append([
                        "type": "document",
                        "source": [
                            "type": "base64",
                            "media_type": "application/pdf",
                            "data": data.base64EncodedString()
                        ]
                    ])
                }
                return ["role": "user", "content": content]
            }
            return [
                "role": message.role == .user ? "user" : "assistant",
                "content": message.content
            ]
        }
        let body: [String: Any] = [
            "model": model.isEmpty ? AIProvider.anthropic.defaultModel : model,
            "max_tokens": 2048,
            "system": instructions,
            "messages": bodyMessages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, provider: "Anthropic")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw ClippyError.invalidResponse("Anthropic returned an unfamiliar response.")
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ClippyError.emptyResponse }
        return text
    }

    private static func validate(response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ClippyError.invalidResponse("\(provider) did not return an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            let message = error?["message"] as? String
            throw ClippyError.processFailed(message ?? "\(provider) request failed (HTTP \(http.statusCode)).")
        }
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
        let error: String
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        standardInput: Data? = nil
    ) async throws -> ProcessResult {
        let runningProcess = RunningProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    let stdoutURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("clippy-stdout-\(UUID().uuidString)")
                    let stderrURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("clippy-stderr-\(UUID().uuidString)")
                    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

                    guard let stdout = try? FileHandle(forWritingTo: stdoutURL),
                          let stderr = try? FileHandle(forWritingTo: stderrURL) else {
                        continuation.resume(throwing: ClippyError.processFailed("Could not create provider output files."))
                        return
                    }

                    func cleanUp() {
                        try? stdout.close()
                        try? stderr.close()
                        try? FileManager.default.removeItem(at: stdoutURL)
                        try? FileManager.default.removeItem(at: stderrURL)
                        runningProcess.clear()
                    }

                    guard runningProcess.install(process) else {
                        cleanUp()
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    process.executableURL = executable
                    process.arguments = arguments
                    process.standardOutput = stdout
                    process.standardError = stderr
                    process.currentDirectoryURL = currentDirectory
                    let inputPipe = standardInput == nil ? nil : Pipe()
                    process.standardInput = inputPipe

                    var environment = ProcessInfo.processInfo.environment
                    environment["PATH"] = searchPaths().joined(separator: ":")
                    environment["TERM"] = "dumb"
                    process.environment = environment

                    do {
                        try process.run()
                        if let standardInput, let inputPipe {
                            try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                            try inputPipe.fileHandleForWriting.close()
                        }
                        if runningProcess.isCancelled {
                            process.terminate()
                        }
                        process.waitUntilExit()
                        let outData = (try? Data(contentsOf: stdoutURL)) ?? Data()
                        let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
                        cleanUp()
                        continuation.resume(returning: ProcessResult(
                            status: process.terminationStatus,
                            output: String(data: outData, encoding: .utf8) ?? "",
                            error: String(data: errorData, encoding: .utf8) ?? ""
                        ))
                    } catch {
                        cleanUp()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            runningProcess.cancel()
        }
    }

    private static func checkedOutput(_ result: ProcessResult) throws -> String {
        guard result.status == 0 else {
            throw ClippyError.processFailed(cleanProcessError(result))
        }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ClippyError.emptyResponse }
        return text
    }

    private static func cleanProcessError(_ result: ProcessResult) -> String {
        let detail = result.error.isEmpty ? result.output : result.error
        let cleaned = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return "The provider process exited with status \(result.status)."
        }
        if cleaned.count > 800 || cleaned.contains("Continue this conversation.") {
            return "The provider stopped unexpectedly. Please try again."
        }
        return cleaned
    }

    private static func searchPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? []
        return Array(Set([
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ] + inherited))
    }

    private static func findExecutable(named name: String) -> URL? {
        for directory in searchPaths() {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func attachmentPrompt(_ attachments: [URL]) -> String {
        guard !attachments.isEmpty else { return "" }
        let paths = attachments.map { "- \($0.path)" }.joined(separator: "\n")
        return """

        The user attached these local files. Inspect them when relevant to the request:
        \(paths)
        \(textAttachmentContents(attachments))
        """
    }

    private static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(url.pathExtension.lowercased())
    }

    private static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        default: "image/png"
        }
    }

    private static func boundedData(_ url: URL) -> Data? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize,
            size <= 20 * 1_024 * 1_024
        else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func imageDataURL(_ url: URL) -> String? {
        guard let data = boundedData(url) else { return nil }
        return "data:\(mimeType(for: url));base64,\(data.base64EncodedString())"
    }

    private static func textAttachmentContents(_ attachments: [URL]) -> String {
        attachments
            .filter { !isImage($0) }
            .compactMap { url -> String? in
                guard
                    let data = boundedData(url),
                    data.count <= 100_000,
                    let text = String(data: data, encoding: .utf8)
                else { return nil }
                return "\n\nAttached file \(url.lastPathComponent):\n\(text)"
            }
            .joined()
    }
}

private enum APIServiceMessages {
    static func from(_ messages: [ChatMessage]) -> [ChatMessage] {
        let recent = Array(messages.suffix(24))
        guard let firstUser = recent.firstIndex(where: { $0.role == .user }) else {
            return recent
        }
        return Array(recent[firstUser...])
    }
}
