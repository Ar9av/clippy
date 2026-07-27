import Foundation

enum ResponsePresentation: Equatable {
    case compact
    case expanded

    var instructions: String {
        switch self {
        case .compact:
            """
            This answer will appear inside a very small floating speech balloon. \
            Give only the most useful conclusion in one or two short sentences, using at most 110 characters. \
            Use plain text only: no Markdown, headings, bullets, code fences, or preamble. \
            If the request genuinely needs detail, give the key answer and end with “Open full chat for details.”
            """
        case .expanded:
            """
            This answer will appear in the full chat window. Give a complete, useful answer. \
            Use clear Markdown structure when it improves readability: short headings, bullets, numbered steps, emphasis, links, and fenced code blocks. \
            Stay concise relative to the task, but do not omit important explanation merely to keep the answer short.
            """
        }
    }

    func prepare(_ response: String) -> String {
        guard self == .compact else {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Self.compactText(response)
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
    private static let systemPrompt = """
    You are Clippy, a friendly desktop AI assistant for macOS. Be genuinely helpful, warm, concise, and practical. \
    You can help with writing, brainstorming, explaining, planning, debugging, and everyday questions. \
    You are running as a local desktop client. Never claim you changed files or performed an action unless the user explicitly saw that happen. \
    Use plain language and light humor when it fits.
    """

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
