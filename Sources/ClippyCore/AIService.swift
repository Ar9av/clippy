import CoreGraphics
import Foundation

public enum ResponsePresentation: Equatable {
    case compact
    case expanded
    case screenInsert
    case screenPlan
    case screenPlanStep
    case screenReply

    public var instructions: String {
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
        case .screenPlanStep:
            """
            Clippy just performed one screen action and is now showing you a fresh screenshot and Screen Context taken after it, not before. \
            The real screen rarely matches a prediction exactly — a menu may have opened somewhere unexpected, a dialog may have appeared, a page may still be loading — so judge only from what is actually visible now, not from what the previous step assumed would happen. \
            Decide the single next step toward the stated goal and return [[CLIPPY_PLAN]] with exactly one step in "steps" (ignore the multi-step format otherwise allowed elsewhere — here only the first step will ever be used, so including more just wastes output). \
            If the goal already looks accomplished, or the screen shows it's not possible to continue safely, return [[CLIPPY_PLAN]] with an empty "steps" array and a one-sentence summary explaining why you stopped. \
            Every target must exactly match a label in “Visible actionable controls”, or supply "x"/"y" coordinates in that same space (not raw screenshot pixels — see the coordinate note below) when a label match would be unreliable. \
            Do not use [[CLIPPY_TYPE]], Markdown, commentary, or any text outside the JSON. \
            Never return a step that sends, submits, publishes, purchases, deletes, accepts terms, or enters a password — that means a real-world consequential action (messaging someone, spending money, destroying data, handing over a credential), not a self-contained, reversible one like pressing “=” on a calculator or clicking “Calculate”/“Apply”. If the task is otherwise done, finish it with that kind of step rather than stopping one step early.
            """
        case .screenReply:
            """
            The user asked for a reply to a conversation visible on their screen. A live screenshot and Screen Context are supplied with this request; use them directly. \
            Return only a polished, ready-to-send reply to the most relevant visible message. \
            Match the other person's language and tone, keep it concise, and do not mention screenshots, Clippy, or uncertainty. \
            Never ask the user to attach, paste, share, or describe the message. If no readable conversation is visible, say only: “I can’t find an open conversation on screen.” \
            Do not use Markdown or a speaker label. Never send the reply or claim it was sent. \
            [[CLIPPY_REPLY_AT:x,y]] on its own line at the very end is the one exception to "no action markers": \
            if you can see the actual reply/message box to type into (not just the conversation), end with it, giving \
            that box's exact pixel position read off the screenshot, in the same coordinate space as the frames in \
            Screen Context — this box's accessibility label is often unreliable in web apps, so Clippy will click this \
            exact point as a fallback if it can't otherwise locate the box. Omit the marker entirely if no distinct \
            reply box is visible (e.g. the conversation is read-only, or this is plain text with nowhere to type it).
            """
        }
    }

    public func prepare(_ response: String) -> String {
        guard self == .compact || self == .screenReply else {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Self.compactText(response, limit: self == .screenReply ? 340 : 120)
    }

    public static func compactText(_ response: String, limit: Int = 120) -> String {
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

public enum AIService {
    public enum ScreenDirectiveKind {
        case guide
        case click
    }

    public struct ScreenDirective {
        public let kind: ScreenDirectiveKind
        public let target: String
        public let response: String
    }

    public struct ParsedScreenPlan {
        public let plan: PendingScreenPlan
        public let response: String
    }

    /// Exposed (not just internal to `reply`) so the streaming path can
    /// build the exact same system prompt for a live-updating request
    /// instead of duplicating it.
    public static let systemPrompt = """
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
    When the user asks you to get something done — even a short "open it", "do it for me", or "handle this", not just an explicit "navigate to X and type Y" — break it into whatever steps the task actually needs and return a multi-step plan. \
    A task may span more than one app (e.g. copy something from one window, switch apps, paste it into another). Sequence every app switch, click, and type step the task requires, in order. \
    Before adding an "open" step, check "Other open apps" and the current window in Screen Context: if the destination app is already running, switch to it instead of launching a second instance, and prefer an already-open tab, document, or window over starting fresh when the task fits it. \
    Begin with [[CLIPPY_PLAN]] followed by one compact JSON object matching \
    {"summary":"what the plan will do","steps":[{"action":"open","app":"System Settings"},{"action":"click","target":"exact label"},{"action":"wait","seconds":0.8},{"action":"key","key":"tab"},{"action":"type","target":"exact field label","text":"exact text"}]}. \
    Use at most 10 steps. Allowed actions are open, click, wait, key, scroll, and type. \
    Every click and type step still needs a short "target" label for the confirmation UI and safety checks, even when you also give coordinates. \
    A click OR type step may additionally include "x" and "y": the exact pixel position of the control read directly off the screenshot, e.g. {"action":"type","target":"Address bar","text":"https://example.com","x":420,"y":38}. \
    Use x/y whenever the control's accessibility label is generic, unclear, or likely to not exactly match anything in "Visible actionable controls" — browser address/search bars, toolbar icons, and custom-drawn or canvas UI are the common cases. Clippy will click that exact point directly instead of searching for the label, then type into whatever is actually there. \
    A browser's own address/search bar is the single most common case where this matters: its exact accessibility label varies across browsers and versions, and some pages (like a browser's own new-tab page) show an on-page search box with the exact same placeholder text right underneath it — a label match can silently land on the wrong one. Always give x/y for the address bar rather than relying on its label alone. \
    Coordinates are in the same space as the frames already given in "Visible actionable controls" and the "Window frame" line, not raw image pixels. \
    A type step whose target is a browser's own address/search bar may add "pressReturnAfter":true to actually submit it — the text can be a full http:// or https:// URL to navigate, or a plain search query to search with the default engine, e.g. {"action":"type","target":"Address and Search","text":"https://example.com","pressReturnAfter":true} or {"action":"type","target":"Address and Search","text":"ar9av","x":420,"y":38,"pressReturnAfter":true}. \
    This is the one exception: submitting a browser's own address/search field is not a final action, whether it's a URL or a search term. Never set pressReturnAfter on any other field — it is silently ignored, and dropped as unsafe, everywhere except an address/search bar. \
    Use open to bring another app to the front before acting on it, and key only for tab, escape, up, down, left, or right — there is no Return key outside that one exception, because the user always performs the final submit. \
    "Visible actionable controls" lists only what is on screen at this moment. When the control you need isn't there, it is usually below the fold rather than absent: add a scroll step and look again before deciding it doesn't exist. A scroll step takes "direction" (up, down, left, or right — "down" reveals what is below), an optional "amount" of 1 to 15 wheel ticks (default 5), and optional x/y to scroll a specific pane rather than the window's centre, e.g. {"action":"scroll","direction":"down","amount":5}. Prefer a few small scrolls over one large jump, and remember scrolling only changes what is visible, so it is always safe. \
    Each control also reports its current state: text contents after "=", and [checked]/[unchecked] on toggles. Use that instead of guessing — skip typing into a field that already holds the right text, and don't click a checkbox that is already in the state the user asked for. \
    Waits may be 0.1 to 8 seconds; prefer a short wait after any click that opens a menu, sheet, or new pane. \
    Sequence as many steps as the task genuinely needs rather than stopping after the first one. \
    Never include a step that sends, submits, publishes, purchases, deletes, accepts terms, or enters a password — this means real-world consequential actions with an effect outside the app itself: messaging someone, spending money, agreeing to a contract, permanently destroying data, or handing over a credential. \
    It does not mean a self-contained, reversible completion with no outside effect: pressing “=” on a calculator, submitting a search box, finishing a game move, or clicking “Calculate”/“Apply”/“Preview” are not final actions — include them so the task actually finishes instead of leaving it half-done. \
    After the JSON, add one short plain-language sentence describing what the plan will attempt, not what already happened — never state a result as fact before the plan has run. \
    When a Screen Context attachment is present and the user asks to change, update, enable, disable, switch, or select something in the current app, return the same multi-step plan format. \
    Use only exact labels from “Visible actionable controls”, include every necessary navigation step, and stop only before a real-world consequential action as defined above. \
    You are running as a local desktop client. Never claim you changed files or performed an action unless the user explicitly saw that happen. \
    Use plain language and light humor when it fits.
    """

    private static let screenTypingMarker = "[[CLIPPY_TYPE]]"

    public static func screenInsertionText(from response: String) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(screenTypingMarker) else { return nil }
        let text = trimmed.dropFirst(screenTypingMarker.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public static func screenDirective(from response: String) -> ScreenDirective? {
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

    /// A `.screenReply` response's optional trailing `[[CLIPPY_REPLY_AT:x,y]]` —
    /// see the coordinate note on that case's `instructions`. Unlike
    /// `screenDirective`, this marker is a suffix (it comes after the reply
    /// text, not before it), and its absence is the common case: most reply
    /// boxes resolve fine by accessibility label alone, so this is read only
    /// as a fallback hint, never required.
    public static func screenReplyTarget(from response: String) -> (point: CGPoint, response: String)? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\[\[CLIPPY_REPLY_AT:\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\]\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              let xRange = Range(match.range(at: 1), in: trimmed),
              let yRange = Range(match.range(at: 2), in: trimmed),
              let markerRange = Range(match.range(at: 0), in: trimmed),
              let x = Double(trimmed[xRange]),
              let y = Double(trimmed[yRange]) else {
            return nil
        }
        let cleaned = String(trimmed[..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return (CGPoint(x: x, y: y), cleaned)
    }

    /// Locates the `[[CLIPPY_PLAN]]` JSON object in a response via brace
    /// matching (tolerating braces inside quoted strings) and returns it
    /// alongside whatever plain-language text follows it. Shared by
    /// `screenPlan(from:)` and `screenPlanStop(from:)` so both parse exactly
    /// the same JSON shape rather than drifting apart.
    private static func extractPlanJSON(from response: String) -> (json: String, trailingText: String)? {
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
        guard let end else { return nil }
        let json = String(remainder[start...end])
        var trailingText = String(remainder[remainder.index(after: end)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trailingText.hasPrefix("```") {
            trailingText.removeFirst(3)
            trailingText = trailingText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (json, trailingText)
    }

    public static func screenPlan(from response: String, bounds: CGRect? = nil, scale: CGFloat? = nil) -> ParsedScreenPlan? {
        guard let extracted = extractPlanJSON(from: response),
              let data = extracted.json.data(using: .utf8),
              let plan = try? JSONDecoder().decode(PendingScreenPlan.self, from: data),
              (try? ScreenPlanRunner.validate(plan, bounds: bounds, scale: scale)) != nil else {
            return nil
        }
        return ParsedScreenPlan(
            plan: plan,
            response: extracted.trailingText.isEmpty ? plan.summary : extracted.trailingText
        )
    }

    /// Parses the model's explicit "I'm done" shape: a `[[CLIPPY_PLAN]]` with
    /// an empty `steps` array and a one-sentence `summary` explaining why it
    /// stopped. `screenPlan(from:)` rejects this shape via `validate` (a plan
    /// must have at least one step to be runnable), which is correct for
    /// execution but previously meant the model's stop reason was silently
    /// discarded — this sibling recovers it instead.
    public static func screenPlanStop(from response: String) -> String? {
        guard let extracted = extractPlanJSON(from: response),
              let data = extracted.json.data(using: .utf8),
              let plan = try? JSONDecoder().decode(PendingScreenPlan.self, from: data),
              plan.steps.isEmpty else {
            return nil
        }
        let summary = plan.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    public static func screenPlanFallbackResponse(from response: String) -> String? {
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

    public static func screenPlanNoTargetResponse(from response: String) -> String? {
        let marker = "[[CLIPPY_NO_TARGET]]"
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker) else { return nil }
        let message = String(trimmed.dropFirst(marker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty
            ? "I can’t see an editable field yet. Open the destination and ask me to look again."
            : message
    }

    public static func asksForScreenAttachment(_ response: String) -> Bool {
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

    public static func reply(
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

    public static func cliAvailable(for provider: AIProvider) -> Bool {
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

    /// Internal rather than private so what the CLI providers are actually
    /// told about attachments is testable.
    static func attachmentPrompt(_ attachments: [URL]) -> String {
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
