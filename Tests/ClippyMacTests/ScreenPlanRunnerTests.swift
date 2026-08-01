import XCTest
@testable import ClippyCore

/// Records what a plan asked the screen to do, without touching the screen.
@MainActor
final class RecordingPerformer: ScreenStepPerforming {
    enum Call: Equatable {
        case open(String)
        case click(String)
        case type(text: String, target: String)
        case press(ScreenPlanKey)
        case scroll(ScreenScrollDirection, ticks: Int, point: CGPoint?)
        case settle(Double)
        case idle(Double)
    }

    private(set) var calls: [Call] = []
    /// Fail the nth click (0-based) to simulate a control that never appeared.
    var failClickAtIndex: Int?
    private var clickCount = 0

    func openApp(named name: String) async throws { calls.append(.open(name)) }

    func click(_ target: String) async throws {
        defer { clickCount += 1 }
        if let failClickAtIndex, failClickAtIndex == clickCount {
            calls.append(.click(target))
            throw ScreenAwarenessError.targetNotFound(target)
        }
        calls.append(.click(target))
    }

    func type(_ text: String, into target: String) async throws {
        calls.append(.type(text: text, target: target))
    }

    func press(_ key: ScreenPlanKey) async throws { calls.append(.press(key)) }

    func scroll(_ direction: ScreenScrollDirection, ticks: Int, at point: CGPoint?) async throws {
        calls.append(.scroll(direction, ticks: ticks, point: point))
    }

    func settle(within seconds: Double) async { calls.append(.settle(seconds)) }

    func idle(_ seconds: Double) async throws { calls.append(.idle(seconds)) }

    /// Everything except the settle pauses the runner inserts between steps.
    var actions: [Call] {
        calls.filter {
            switch $0 {
            case .idle, .settle: return false
            default: return true
            }
        }
    }
}

@MainActor
final class ScreenPlanRunnerTests: XCTestCase {
    private func plan(_ steps: [ScreenPlanStep], summary: String = "test") -> PendingScreenPlan {
        PendingScreenPlan(summary: summary, steps: steps)
    }

    // MARK: - Sequencing

    func testRunsEveryStepInOrder() async throws {
        let performer = RecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0)
        let completed = try await runner.run(plan([
            ScreenPlanStep(action: .open, app: "TextEdit"),
            ScreenPlanStep(action: .click, target: "Format"),
            ScreenPlanStep(action: .wait, seconds: 0.5),
            ScreenPlanStep(action: .key, key: .down),
            ScreenPlanStep(action: .type, target: "Document", text: "hello")
        ]))

        XCTAssertEqual(completed, 5)
        XCTAssertEqual(performer.actions, [
            .open("TextEdit"),
            .click("Format"),
            .press(.down),
            .type(text: "hello", target: "Document")
        ])
        // The wait step is the only idle in a zero-settle run.
        XCTAssertEqual(performer.calls.filter { $0 == .idle(0.5) }.count, 1)
    }

    func testSettlesBetweenStepsButNotAfterTheLast() async throws {
        let performer = RecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0.25)
        try await runner.run(plan([
            ScreenPlanStep(action: .click, target: "One"),
            ScreenPlanStep(action: .click, target: "Two"),
            ScreenPlanStep(action: .click, target: "Three")
        ]))

        XCTAssertEqual(performer.calls.filter { $0 == .settle(0.25) }.count, 2)
        XCTAssertEqual(performer.calls.last, .click("Three"))
    }

    func testReportsProgressForEveryStep() async throws {
        let performer = RecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0)
        var statuses: [(Int, ScreenPlanStepStatus)] = []
        try await runner.run(plan([
            ScreenPlanStep(action: .click, target: "One"),
            ScreenPlanStep(action: .click, target: "Two")
        ])) { statuses.append(($0.index, $0.status)) }

        XCTAssertEqual(statuses.map(\.0), [0, 0, 1, 1])
        XCTAssertEqual(statuses.map(\.1), [.running, .done, .running, .done])
    }

    // MARK: - Stop on failure

    func testStopsAtFailedStepAndSkipsTheRest() async throws {
        let performer = RecordingPerformer()
        performer.failClickAtIndex = 1
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0)
        var reported: [(Int, ScreenPlanStepStatus)] = []

        do {
            try await runner.run(plan([
                ScreenPlanStep(action: .click, target: "One"),
                ScreenPlanStep(action: .click, target: "Two"),
                ScreenPlanStep(action: .type, target: "Field", text: "never runs")
            ])) { reported.append(($0.index, $0.status)) }
            XCTFail("Expected the plan to stop at step 2")
        } catch let error as ScreenPlanError {
            guard case .stepFailed(let index, _, let reason) = error else {
                return XCTFail("Expected stepFailed, got \(error)")
            }
            XCTAssertEqual(index, 1)
            XCTAssertTrue(reason.contains("Two"), "Failure should name the missing target: \(reason)")
        }

        // The third step never ran — no half-navigated screen gets typed into.
        XCTAssertFalse(performer.actions.contains(.type(text: "never runs", target: "Field")))
        XCTAssertEqual(reported.last?.1, .failed)
        XCTAssertEqual(reported.last?.0, 1)
    }

    func testCancellationStopsTheSequence() async throws {
        let performer = RecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0)
        let steps = (0..<6).map { ScreenPlanStep(action: .click, target: "Step \($0)") }

        let task = Task { @MainActor in
            try await runner.run(self.plan(steps))
        }
        task.cancel()

        do {
            _ = try await task.value
        } catch is CancellationError {
            // Expected.
        } catch let error as ScreenPlanError {
            XCTFail("Cancellation should surface as CancellationError, got \(error)")
        }
        XCTAssertLessThan(performer.actions.count, steps.count)
    }

    // MARK: - Validation and safety

    func testRejectsFinalActionTargets() {
        for target in ["Send", "Submit order", "Delete account", "Confirm payment", "Password"] {
            XCTAssertThrowsError(
                try ScreenPlanRunner.validate(plan([ScreenPlanStep(action: .click, target: target)])),
                "“\(target)” must be refused"
            ) { error in
                guard case ScreenPlanError.unsafeStep = error else {
                    return XCTFail("Expected unsafeStep for \(target), got \(error)")
                }
            }
        }
    }

    /// `AutomationSafety`'s terminal/agent-CLI blocklist was emptied at the
    /// user's explicit request (local machine, full access). Return is still
    /// refused everywhere except a URL into a browser address bar, so a plan
    /// naming a terminal is now accepted rather than refused outright.
    func testAllowsTerminalsAsOpenTargetsSinceRestrictionWasIntentionallyDisabled() throws {
        for app in ["Warp", "Terminal", "iTerm", "Ghostty"] {
            XCTAssertNoThrow(
                try ScreenPlanRunner.validate(plan([ScreenPlanStep(action: .open, app: app)])),
                "\(app) should be allowed now that the blocklist is empty"
            )
        }
    }

    func testRejectsMalformedAndOversizedPlans() {
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan([])))
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .click, target: "  ")
        ])))
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .type, target: "Field", text: "")
        ])))
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .wait, seconds: 60)
        ])))
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan(
            (0...ScreenPlanRunner.stepLimit).map { ScreenPlanStep(action: .click, target: "Step \($0)") }
        )))
    }

    func testUnsafePlanNeverTouchesTheScreen() async {
        let performer = RecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0)
        _ = try? await runner.run(plan([
            ScreenPlanStep(action: .click, target: "Compose"),
            ScreenPlanStep(action: .click, target: "Send")
        ]))
        XCTAssertTrue(performer.calls.isEmpty, "Validation must run before the first step")
    }

    func testAcceptsAFullLengthMultiStepPlan() throws {
        try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .open, app: "System Settings"),
            ScreenPlanStep(action: .wait, seconds: 1.2),
            ScreenPlanStep(action: .click, target: "Appearance"),
            ScreenPlanStep(action: .wait, seconds: 0.8),
            ScreenPlanStep(action: .click, target: "Dark"),
            ScreenPlanStep(action: .key, key: .tab),
            ScreenPlanStep(action: .type, target: "Search", text: "display")
        ]))
    }

    // MARK: - Coordinate bounds

    private let windowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)

    func testAcceptsPointsInsideTheWindowFrame() throws {
        try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .click, target: "Field", x: 200, y: 200)
        ]), bounds: windowFrame)
    }

    func testRejectsPointsOutsideTheWindowFrame() {
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .click, target: "Field", x: 5000, y: 5000)
        ]), bounds: windowFrame)) { error in
            XCTAssertEqual(error as? ScreenPlanError, .outOfBounds(0, "Field"))
        }
    }

    func testRejectsNonFinitePoints() {
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .click, target: "Field", x: .nan, y: 200)
        ])))
    }

    func testCorrectsScreenshotPixelCoordinatesBackIntoWindowSpace() throws {
        // A point that's out of bounds raw, but lands inside the window once
        // divided by a 2x screenshot scale, is accepted rather than rejected —
        // this is the "model read pixels off the image" recovery path.
        let pixelPoint = CGPoint(x: (windowFrame.midX) * 2, y: (windowFrame.midY) * 2)
        try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .type, target: "Field", text: "hello", x: pixelPoint.x, y: pixelPoint.y)
        ]), bounds: windowFrame, scale: 2)
    }

    func testDoesNotValidatePointsWhenNoBoundsGiven() throws {
        try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .click, target: "Field", x: 99999, y: 99999)
        ]))
    }

    // MARK: - Scroll

    func testScrollDispatchesDirectionTicksAndPoint() async throws {
        let performer = RecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0)
        try await runner.run(plan([
            ScreenPlanStep(action: .scroll, direction: .down, amount: 3),
            ScreenPlanStep(action: .scroll, x: 300, y: 400, direction: .right, amount: 2)
        ]))

        XCTAssertEqual(performer.actions, [
            .scroll(.down, ticks: 3, point: nil),
            .scroll(.right, ticks: 2, point: CGPoint(x: 300, y: 400))
        ])
    }

    func testScrollWithoutAnAmountUsesTheDefault() async throws {
        let performer = RecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0)
        try await runner.run(plan([ScreenPlanStep(action: .scroll, direction: .down)]))

        XCTAssertEqual(
            performer.actions,
            [.scroll(.down, ticks: Int(ScreenPlanRunner.defaultScrollTicks), point: nil)]
        )
    }

    /// A single step must not be able to fling a document to its end — the
    /// agent loop needs to observe between scrolls to find anything.
    func testClampsAnOversizedScrollToTheAllowedRange() async throws {
        let performer = RecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0)
        try await runner.run(plan([ScreenPlanStep(action: .scroll, direction: .down, amount: 900)]))

        XCTAssertEqual(
            performer.actions,
            [.scroll(.down, ticks: Int(ScreenPlanRunner.scrollTickRange.upperBound), point: nil)]
        )
    }

    func testRejectsAScrollWithNoDirection() {
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .scroll, amount: 3)
        ]))) { error in
            XCTAssertEqual(error as? ScreenPlanError, .malformedStep(0))
        }
    }

    func testRejectsAScrollWithANonPositiveAmount() {
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .scroll, direction: .down, amount: 0)
        ]))) { error in
            XCTAssertEqual(error as? ScreenPlanError, .malformedStep(0))
        }
    }

    /// A scroll point outside the window would send wheel events to whatever
    /// else is under it, so it gets the same bounds check a click does.
    func testRejectsAScrollPointOutsideTheWindowFrame() {
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .scroll, x: 5000, y: 5000, direction: .down)
        ]), bounds: windowFrame)) { error in
            XCTAssertEqual(error as? ScreenPlanError, .outOfBounds(0, "the content"))
        }
    }

    /// Scrolling only changes what is visible. It must never be caught by the
    /// final-action refusal, even when the surrounding view is named for one.
    func testScrollIsNotTreatedAsAFinalAction() throws {
        try ScreenPlanRunner.validate(plan([
            ScreenPlanStep(action: .scroll, target: "Send message list", direction: .down)
        ]))
    }
}

// MARK: - Plan parsing

final class ScreenPlanParsingTests: XCTestCase {
    func testParsesMultiStepPlanFromModelOutput() throws {
        let response = """
        [[CLIPPY_PLAN]]{"summary":"Turn on dark mode","steps":[\
        {"action":"open","app":"System Settings"},\
        {"action":"wait","seconds":1.5},\
        {"action":"click","target":"Appearance"},\
        {"action":"key","key":"tab"},\
        {"action":"type","target":"Search","text":"display"}]}
        I'll walk through Settings for you.
        """
        let parsed = try XCTUnwrap(AIService.screenPlan(from: response))

        XCTAssertEqual(parsed.plan.steps.count, 5)
        XCTAssertEqual(parsed.plan.steps[0].action, .open)
        XCTAssertEqual(parsed.plan.steps[0].app, "System Settings")
        XCTAssertEqual(parsed.plan.steps[1].seconds, 1.5)
        XCTAssertEqual(parsed.plan.steps[3].key, .tab)
        XCTAssertEqual(parsed.plan.steps[4].text, "display")
        XCTAssertEqual(parsed.response, "I'll walk through Settings for you.")
    }

    func testParsesPlanWrappedInACodeFence() throws {
        let response = """
        [[CLIPPY_PLAN]]```json
        {"summary":"Open the note","steps":[{"action":"click","target":"Notes"}]}
        ```
        """
        let parsed = try XCTUnwrap(AIService.screenPlan(from: response))
        XCTAssertEqual(parsed.plan.steps.count, 1)
        XCTAssertEqual(parsed.response, "Open the note")
    }

    func testRejectsPlanContainingAFinalAction() {
        let response = """
        [[CLIPPY_PLAN]]{"summary":"Send it","steps":[\
        {"action":"type","target":"Message","text":"hi"},\
        {"action":"click","target":"Send"}]}
        """
        XCTAssertNil(AIService.screenPlan(from: response))
    }

    func testRejectsWaitLongerThanTheAllowedRange() {
        let response = """
        [[CLIPPY_PLAN]]{"summary":"Stall","steps":[{"action":"wait","seconds":90}]}
        """
        XCTAssertNil(AIService.screenPlan(from: response))
    }

    func testIgnoresResponsesWithoutTheMarker() {
        XCTAssertNil(AIService.screenPlan(from: "Sure, click Appearance and then Dark."))
    }

    // MARK: - Stop-reason parsing

    func testScreenPlanStopRecoversTheModelsSummary() {
        let response = """
        [[CLIPPY_PLAN]]{"summary":"Dark mode is already on — nothing left to do.","steps":[]}
        """
        XCTAssertEqual(AIService.screenPlanStop(from: response), "Dark mode is already on — nothing left to do.")
    }

    func testScreenPlanRejectsTheEmptyStepsShapeThatScreenPlanStopAccepts() {
        // `validate` requires at least one step to be runnable, so the same
        // response must be nil from screenPlan(from:) even though
        // screenPlanStop(from:) recovers its reason above.
        let response = """
        [[CLIPPY_PLAN]]{"summary":"Dark mode is already on — nothing left to do.","steps":[]}
        """
        XCTAssertNil(AIService.screenPlan(from: response))
    }

    func testScreenPlanStopIgnoresNonEmptyPlans() {
        let response = """
        [[CLIPPY_PLAN]]{"summary":"Turn on dark mode","steps":[{"action":"click","target":"Dark"}]}
        """
        XCTAssertNil(AIService.screenPlanStop(from: response))
    }

    func testScreenPlanStopIgnoresBlankSummary() {
        let response = """
        [[CLIPPY_PLAN]]{"summary":"   ","steps":[]}
        """
        XCTAssertNil(AIService.screenPlanStop(from: response))
    }

    func testScreenPlanStopIgnoresResponsesWithoutTheMarker() {
        XCTAssertNil(AIService.screenPlanStop(from: "Looks like that's already done."))
    }
}
