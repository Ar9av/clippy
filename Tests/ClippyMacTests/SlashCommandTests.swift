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
}
