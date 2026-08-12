import XCTest
@testable import ClippyMac

final class SlashCommandTests: XCTestCase {
    private let prompts = [
        CustomPrompt(command: "review", prompt: "Review this code for bugs."),
        CustomPrompt(command: "tighten", prompt: "Rewrite this more concisely.")
    ]

    // MARK: - Non-commands fall through

    func testPlainTextIsNotACommand() {
        XCTAssertNil(SlashCommand.parse("what is a monad?", prompts: prompts))
    }

    func testBareSlashIsNotACommand() {
        XCTAssertNil(SlashCommand.parse("/", prompts: prompts))
    }

    /// A path pasted into the composer must not be mistaken for a command.
    func testSlashMidSentenceIsNotACommand() {
        XCTAssertNil(SlashCommand.parse("look at src/main.swift", prompts: prompts))
    }

    // MARK: - Built-ins

    func testClearIsRecognized() {
        XCTAssertEqual(SlashCommand.parse("/clear", prompts: prompts), .clear)
    }

    func testCommandsAreCaseInsensitive() {
        XCTAssertEqual(SlashCommand.parse("/CLEAR", prompts: prompts), .clear)
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(SlashCommand.parse("  /clear  ", prompts: prompts), .clear)
    }

    func testHelpIsRecognized() {
        XCTAssertEqual(SlashCommand.parse("/help", prompts: prompts), .help)
    }

    // MARK: - Custom prompts

    func testCustomCommandExpandsToItsPrompt() {
        XCTAssertEqual(
            SlashCommand.parse("/review", prompts: prompts),
            .expanded(text: "Review this code for bugs.")
        )
    }

    /// Trailing text is kept, so a saved prompt can still be pointed at
    /// something specific instead of only working bare.
    func testTrailingArgumentsAreAppended() {
        XCTAssertEqual(
            SlashCommand.parse("/review the parser", prompts: prompts),
            .expanded(text: "Review this code for bugs.\n\nthe parser")
        )
    }

    func testUnknownCommandIsReported() {
        XCTAssertEqual(SlashCommand.parse("/nope", prompts: prompts), .unknown(command: "nope"))
    }

    func testUnknownCommandReportsLowercasedName() {
        XCTAssertEqual(SlashCommand.parse("/NOPE", prompts: prompts), .unknown(command: "nope"))
    }

    // MARK: - Help text

    func testHelpTextListsCustomPrompts() {
        let text = SlashCommand.helpText(prompts: prompts)
        XCTAssertTrue(text.contains("/review"))
        XCTAssertTrue(text.contains("/tighten"))
        XCTAssertTrue(text.contains("/clear"))
    }

    func testHelpTextPointsAtSettingsWhenThereAreNoCustomPrompts() {
        XCTAssertTrue(SlashCommand.helpText(prompts: []).contains("Settings"))
    }

    // MARK: - Normalization

    /// A command stored with spaces or capitals could never be typed and
    /// matched, so both are normalized away at the point of entry.
    func testNormalizeLowercasesAndHyphenatesSpaces() {
        XCTAssertEqual(CustomPrompt.normalize("Deep Review"), "deep-review")
    }

    func testNormalizeStripsLeadingSlash() {
        XCTAssertEqual(CustomPrompt.normalize("/review"), "review")
    }

    func testNormalizeTrimsWhitespace() {
        XCTAssertEqual(CustomPrompt.normalize("  review  "), "review")
    }

    func testNormalizedCommandMatchesWhatTheUserTyped() {
        let saved = CustomPrompt(command: " /Deep Review ", prompt: "Go deep.")
        XCTAssertEqual(saved.command, "deep-review")
        XCTAssertEqual(
            SlashCommand.parse("/deep-review", prompts: [saved]),
            .expanded(text: "Go deep.")
        )
    }

    // MARK: - Validation

    func testPromptNeedingBothFieldsIsInvalid() {
        XCTAssertFalse(CustomPrompt(command: "x", prompt: "   ").isValid)
        XCTAssertFalse(CustomPrompt(command: "", prompt: "something").isValid)
        XCTAssertTrue(CustomPrompt(command: "x", prompt: "something").isValid)
    }

    /// Shadowing a built-in would silently break it, which is worse than
    /// refusing to save the prompt.
    func testBuiltInCommandsCannotBeShadowed() {
        XCTAssertFalse(CustomPrompt(command: "clear", prompt: "something").isValid)
        XCTAssertFalse(CustomPrompt(command: "help", prompt: "something").isValid)
    }

    func testBuiltInWinsEvenIfACustomPromptClaimsIt() {
        let shadowing = [CustomPrompt(command: "clear", prompt: "should never run")]
        XCTAssertEqual(SlashCommand.parse("/clear", prompts: shadowing), .clear)
    }

    // MARK: - Voice actions

    func testVoiceActionExtractsNamedJSONField() throws {
        XCTAssertEqual(
            try CustomPrompt.extractedVoiceValue(
                from: "```json\n{\"command\":\"git status --short\"}\n```",
                key: "command"
            ),
            "git status --short"
        )
    }

    func testVoiceActionAcceptsPlainTextWithoutJSON() throws {
        XCTAssertEqual(
            try CustomPrompt.extractedVoiceValue(from: "git status --short", key: "command"),
            "git status --short"
        )
    }

    func testVoiceActionAcceptsSoleLegacyJSONField() throws {
        XCTAssertEqual(
            try CustomPrompt.extractedVoiceValue(from: "{\"result\":\"git status\"}", key: "command"),
            "git status"
        )
    }

    func testTerminalPromptIsRecognizedAsShellVoiceAction() {
        let prompt = CustomPrompt(command: "command", prompt: "write me the commands for terminal")
        XCTAssertTrue(prompt.isShellCommandVoiceAction)
        XCTAssertFalse(CustomPrompt(command: "reply", prompt: "Draft a friendly reply").isShellCommandVoiceAction)
    }

    func testShellVoiceActionExtractsCommandFromReportedVerboseFailure() throws {
        let response = """
        “Take a good pull” is idiomatic slang and isn't asking for terminal commands.

        If you meant something git-related (like `git pull`), let me know.
        """
        XCTAssertEqual(
            try CustomPrompt.extractedShellCommand(from: response, key: "result"),
            "git pull"
        )
    }

    func testShellVoiceActionRejectsProseInsteadOfTypingItIntoTerminal() {
        XCTAssertThrowsError(
            try CustomPrompt.extractedShellCommand(
                from: "I could not determine which command you wanted.",
                key: "result"
            )
        )
    }

    func testCommonGitPullHomophonesResolveWithoutAModelCall() {
        XCTAssertEqual(CustomPrompt.obviousShellCommand(from: "can you take a git pull"), "git pull")
        XCTAssertEqual(CustomPrompt.obviousShellCommand(from: "please take a good pull"), "git pull")
        XCTAssertEqual(CustomPrompt.obviousShellCommand(from: "run get pull"), "git pull")
    }

    func testGitPullWithArgumentsStillUsesTheConfiguredPrompt() {
        XCTAssertNil(CustomPrompt.obviousShellCommand(from: "git pull origin main"))
    }

    func testDefaultTerminalVoiceActionIsReadyToUse() {
        let action = CustomPrompt.defaultTerminalAction
        XCTAssertEqual(action.command, "command")
        XCTAssertEqual(action.voiceShortcut?.displayName, "⌥⌃Space")
        XCTAssertEqual(action.voiceOutputKey, "command")
        XCTAssertTrue(action.isShellCommandVoiceAction)
        XCTAssertTrue(action.hasVoiceAction)
    }

    func testTerminalVoiceActionIsSeededOnlyWhenMissing() {
        let unrelated = CustomPrompt(command: "reply", prompt: "Draft a reply")
        let seeded = ChatViewModel.promptsBySeedingTerminalAction(into: [unrelated])
        XCTAssertEqual(seeded.count, 2)
        XCTAssertEqual(seeded.last?.id, CustomPrompt.defaultTerminalActionID)

        let existing = CustomPrompt(command: "term", prompt: "Write commands for terminal")
        XCTAssertEqual(ChatViewModel.promptsBySeedingTerminalAction(into: [existing]), [existing])
    }

    func testDefaultTerminalShortcutDoesNotDuplicateAnExistingShortcut() {
        let defaultShortcut = CustomPrompt.defaultTerminalAction.voiceShortcut
        let existing = CustomPrompt(
            command: "reply",
            prompt: "Draft a reply",
            voiceShortcut: defaultShortcut
        )
        let seeded = ChatViewModel.promptsBySeedingTerminalAction(into: [existing])
        XCTAssertNil(seeded.last?.voiceShortcut)
    }

    func testVoiceActionRemovesMarkdownFenceFromPlainOutput() throws {
        XCTAssertEqual(
            try CustomPrompt.extractedVoiceValue(from: "```bash\ngit status --short\n```", key: "command"),
            "git status --short"
        )
    }

    func testVoiceOutputKeyNormalizationKeepsJSONSafeCharacters() {
        XCTAssertEqual(CustomPrompt.normalizeVoiceOutputKey("shell command!"), "shellcommand")
        XCTAssertEqual(CustomPrompt.normalizeVoiceOutputKey("command_2"), "command_2")
    }

    func testLegacyCustomPromptDecodesWithoutVoiceConfiguration() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","command":"terminal","prompt":"Write a command","showsInBalloon":false}
        """
        let decoded = try JSONDecoder().decode(CustomPrompt.self, from: Data(json.utf8))
        XCTAssertNil(decoded.voiceShortcut)
        XCTAssertEqual(decoded.voiceOutputKey, "result")
    }
}
