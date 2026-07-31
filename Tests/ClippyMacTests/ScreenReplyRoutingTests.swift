import XCTest
@testable import ClippyCore
@testable import ClippyMac

/// Reproduces the reported failure: a user pastes an image, asks Clippy to
/// "tell me and write a reply", and gets back "I can't find an open
/// conversation on screen" — an answer about the live desktop rather than the
/// file they attached.
@MainActor
final class ScreenReplyRoutingTests: XCTestCase {
    private let pastedImage = URL(fileURLWithPath: "/tmp/Pasted Image 2026-07-30 at 15.04.44-FDEDD7.png")
    private let liveScreenshot = URL(fileURLWithPath: "/tmp/Caches/Clippy/ScreenContext/Screen-ABC.png")
    private let liveContext = URL(fileURLWithPath: "/tmp/Caches/Clippy/ScreenContext/Screen-Context-ABC.txt")

    // MARK: - Step 1: the request is routed to the live-screen reply path

    func testTheReportedMessageRoutesToTheScreenReplyPath() {
        XCTAssertTrue(ChatViewModel.requestsScreenReply("tell me and write a reply"))
    }

    /// The routing decision is made from the message text alone. Nothing in
    /// this predicate can see that the user attached a file, so an explicit
    /// attachment cannot take precedence over the live screen.
    func testRoutingIgnoresWhetherTheUserAttachedAnything() {
        // Identical text is all the router gets; there is no attachment-aware
        // overload to call.
        let text = "tell me and write a reply"
        XCTAssertTrue(ChatViewModel.requestsScreenReply(text))
        XCTAssertEqual(
            ChatViewModel.requestsScreenReply(text),
            ChatViewModel.requestsScreenReply(text),
            "routing is a pure function of the text — attachments are invisible to it"
        )
    }

    /// A bare substring is enough, so requests that merely contain the word
    /// get pulled onto the screen-reply path too.
    func testBareSubstringIsEnoughToTrigger() {
        for text in [
            "reply",
            "what does this say, and answer it",
            "can you respond to that",
            "no reply needed, just summarise this file",
        ] {
            XCTAssertTrue(ChatViewModel.requestsScreenReply(text), text)
        }
    }

    func testUnrelatedRequestsDoNotTrigger() {
        for text in [
            "Please look at the attached file and tell me what you notice.",
            "summarise this image",
            "what is in this screenshot",
        ] {
            XCTAssertFalse(ChatViewModel.requestsScreenReply(text), text)
        }
    }

    // MARK: - Step 2: the prompt on that path forbids using attachments

    func testScreenReplyPromptForbidsAttachmentsAndSuppliesTheCannedLine() {
        let instructions = ResponsePresentation.screenReply.instructions
        XCTAssertTrue(
            instructions.contains("Never ask the user to attach, paste, share, or describe"),
            instructions
        )
        XCTAssertTrue(
            instructions.contains("I can’t find an open conversation on screen."),
            "the exact sentence the user saw is dictated by this prompt"
        )
    }

    // MARK: - Step 3: the live capture is mislabelled as a user attachment

    /// The CLI providers get attachments as a flat list of paths under one
    /// header. Clippy's own screen capture is appended to the user's list
    /// before this runs, so it is described to the model as something *the
    /// user attached* — indistinguishable from the file they actually pasted.
    func testLiveScreenCaptureIsPresentedAsAUserAttachment() {
        let merged = [pastedImage, liveScreenshot, liveContext]
        let prompt = AIService.attachmentPrompt(merged)

        XCTAssertTrue(prompt.contains("The user attached these local files"), prompt)
        XCTAssertTrue(prompt.contains("Screen-ABC.png"), "the live capture is in the list")
        XCTAssertTrue(prompt.contains("Pasted Image"), "so is the user's own file")

        // Nothing separates them — no marker distinguishes the ambient screen
        // grab from the file the user chose to hand over.
        XCTAssertFalse(prompt.lowercased().contains("current screen"), prompt)
        XCTAssertFalse(prompt.lowercased().contains("live screen"), prompt)
        XCTAssertFalse(prompt.lowercased().contains("screen context"), prompt)
    }

    /// The header is identical whether or not Clippy added its own capture —
    /// the model has no way to tell one situation from the other.
    func testHeaderIsIdenticalWithAndWithoutTheInjectedCapture() {
        func header(_ urls: [URL]) -> String {
            AIService.attachmentPrompt(urls)
                .split(separator: "\n")
                .first(where: { $0.contains("attached") })
                .map(String.init) ?? ""
        }
        XCTAssertEqual(header([pastedImage]), header([pastedImage, liveScreenshot, liveContext]))
        XCTAssertFalse(header([pastedImage]).isEmpty)
    }
}

/// Which of the two possible sources produced the sentence the user saw.
@MainActor
final class ScreenReplyFallbackTests: XCTestCase {
    /// The canned fallback at the end of the retry branch only fires when the
    /// response looks like a request for an attachment. The sentence the user
    /// saw is not one of those, so it came straight from the model following
    /// the screenReply prompt — the retry never ran.
    func testTheSentenceTheUserSawDoesNotTriggerTheRetry() {
        XCTAssertFalse(AIService.asksForScreenAttachment("I can’t find an open conversation on screen."))
        XCTAssertFalse(AIService.asksForScreenAttachment("I can't find an open conversation on screen."))
    }

    func testRetryStillFiresForActualAttachmentRequests() {
        for response in [
            "Could you attach a screenshot of the conversation?",
            "I can't see a screenshot in this conversation.",
            "Please paste the message you want me to reply to.",
        ] {
            XCTAssertTrue(AIService.asksForScreenAttachment(response), response)
        }
    }
}
