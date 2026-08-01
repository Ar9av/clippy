import XCTest
@testable import ClippyCore

/// A saved plan is checked when it is saved, but its arguments arrive later and
/// go straight into the fields the safety rules read. These pin the parts of
/// that gap that matter.
final class WorkflowTests: XCTestCase {
    private func workflow(
        _ steps: [ScreenPlanStep],
        name: String = "prices",
        mode: WorkflowMode = .interactive
    ) -> Workflow {
        Workflow(name: name, summary: "test", steps: steps, mode: mode)
    }

    // MARK: - Placeholders

    func testFindsPlaceholdersAcrossEveryTextField() {
        let flow = workflow([
            ScreenPlanStep(action: .open, app: "$2"),
            ScreenPlanStep(action: .type, target: "Search $1", text: "$3")
        ])
        XCTAssertEqual(flow.placeholders, ["$1", "$2", "$3"])
        XCTAssertEqual(flow.requiredArgumentCount, 3)
    }

    func testSubstitutesPositionalArguments() throws {
        let flow = workflow([
            ScreenPlanStep(action: .open, app: "$1"),
            ScreenPlanStep(action: .type, target: "Search", text: "$2")
        ])
        let plan = try flow.instantiate(arguments: ["Safari", "AAPL"])
        XCTAssertEqual(plan.steps[0].app, "Safari")
        XCTAssertEqual(plan.steps[1].text, "AAPL")
    }

    func testDollarStarTakesEverythingTyped() throws {
        let flow = workflow([ScreenPlanStep(action: .type, target: "Search", text: "$*")])
        let plan = try flow.instantiate(arguments: ["quarterly", "revenue", "report"])
        XCTAssertEqual(plan.steps[0].text, "quarterly revenue report")
    }

    func testTheSamePlaceholderCanRepeat() throws {
        let flow = workflow([
            ScreenPlanStep(action: .type, target: "Search $1", text: "$1")
        ])
        let plan = try flow.instantiate(arguments: ["AAPL"])
        XCTAssertEqual(plan.steps[0].target, "Search AAPL")
        XCTAssertEqual(plan.steps[0].text, "AAPL")
    }

    /// Running with a literal "$1" still in the text would type the placeholder
    /// into someone's document, so a missing argument is an error.
    func testAMissingArgumentIsRefusedRatherThanTypedLiterally() {
        let flow = workflow([ScreenPlanStep(action: .type, target: "Search", text: "$2")])
        XCTAssertThrowsError(try flow.instantiate(arguments: ["only-one"])) { error in
            XCTAssertEqual(error as? WorkflowError, .missingArgument(placeholder: "$2"))
        }
    }

    func testABlankArgumentIsRefused() {
        let flow = workflow([ScreenPlanStep(action: .type, target: "Search", text: "$1")])
        XCTAssertThrowsError(try flow.instantiate(arguments: ["   "])) { error in
            XCTAssertEqual(error as? WorkflowError, .emptyArgument(placeholder: "$1"))
        }
    }

    /// Coordinates and scroll amounts are not substitutable, so an argument can
    /// never move where a click lands.
    func testArgumentsCannotAlterCoordinatesOrScrollAmount() throws {
        let flow = workflow([
            ScreenPlanStep(action: .click, target: "$1", x: 100, y: 200),
            ScreenPlanStep(action: .scroll, direction: .down, amount: 3)
        ])
        let plan = try flow.instantiate(arguments: ["Appearance"])
        XCTAssertEqual(plan.steps[0].x, 100)
        XCTAssertEqual(plan.steps[0].y, 200)
        XCTAssertEqual(plan.steps[1].amount, 3)
    }

    // MARK: - Substitution is an injection vector into the safety check

    /// The workflow itself is harmless and passes validation when saved. The
    /// argument is what makes it a final action, and that is only visible after
    /// substitution — so the check has to run again there.
    func testAnArgumentCannotSmuggleInAFinalAction() throws {
        let flow = workflow([ScreenPlanStep(action: .click, target: "$1")])

        // Saved form is fine.
        try ScreenPlanRunner.validate(
            PendingScreenPlan(summary: "s", steps: flow.steps)
        )

        // Instantiated with a hostile argument, it is refused.
        XCTAssertThrowsError(try flow.instantiate(arguments: ["Send"])) { error in
            XCTAssertEqual(error as? WorkflowError, .unsafeAfterSubstitution("Send"))
        }
        for argument in ["Confirm payment", "Delete account", "Place order", "Buy"] {
            XCTAssertThrowsError(try flow.instantiate(arguments: [argument]), argument)
        }
    }

    func testAHarmlessArgumentStillRuns() throws {
        let flow = workflow([ScreenPlanStep(action: .click, target: "$1")])
        let plan = try flow.instantiate(arguments: ["Appearance"])
        XCTAssertEqual(plan.steps[0].target, "Appearance")
    }

    // MARK: - Monitor mode

    func testMonitorModePermitsOnlyLookingAround() {
        let monitor = WorkflowMode.monitor
        XCTAssertTrue(monitor.allows(.open))
        XCTAssertTrue(monitor.allows(.scroll))
        XCTAssertTrue(monitor.allows(.wait))
        XCTAssertTrue(monitor.allows(.key))
        XCTAssertFalse(monitor.allows(.click))
        XCTAssertFalse(monitor.allows(.type))
    }

    func testInteractiveModePermitsEverything() {
        for action in [ScreenPlanAction.open, .scroll, .wait, .key, .click, .type] {
            XCTAssertTrue(WorkflowMode.interactive.allows(action))
        }
    }

    func testAMonitorWorkflowRefusesToClick() {
        let flow = workflow(
            [ScreenPlanStep(action: .click, target: "Refresh")],
            mode: .monitor
        )
        XCTAssertThrowsError(try flow.instantiate(arguments: [])) { error in
            XCTAssertEqual(error as? WorkflowError, .actionNotAllowedWhileMonitoring(.click))
        }
    }

    func testAMonitorWorkflowCanNavigateAndScroll() throws {
        let flow = workflow([
            ScreenPlanStep(action: .open, app: "Safari"),
            ScreenPlanStep(action: .scroll, direction: .down, amount: 4),
            ScreenPlanStep(action: .wait, seconds: 0.5)
        ], mode: .monitor)
        let plan = try flow.instantiate(arguments: [])
        XCTAssertEqual(plan.steps.count, 3)
    }

    // MARK: - Naming

    func testNameIsNormalisedLikeASlashCommand() {
        XCTAssertEqual(Workflow.normalize("/Check Prices"), "check-prices")
        XCTAssertEqual(Workflow.normalize("  Standup  "), "standup")
    }

    func testAWorkflowNeedsANameAndAtLeastOneStep() {
        XCTAssertFalse(workflow([], name: "empty").isValid)
        XCTAssertFalse(workflow([ScreenPlanStep(action: .wait, seconds: 1)], name: "").isValid)
        XCTAssertTrue(workflow([ScreenPlanStep(action: .wait, seconds: 1)]).isValid)
    }

    // MARK: - Persistence round trip

    func testSurvivesAnEncodeDecodeRoundTrip() throws {
        let original = workflow([
            ScreenPlanStep(action: .open, app: "$1"),
            ScreenPlanStep(action: .scroll, direction: .down, amount: 4)
        ], mode: .monitor)
        let decoded = try JSONDecoder().decode(
            Workflow.self,
            from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.mode, .monitor)
        XCTAssertEqual(decoded.steps.count, 2)
        XCTAssertEqual(decoded.placeholders, ["$1"])
    }

    /// A workflow saved before `mode` existed must not vanish or silently
    /// become able to click.
    func testAWorkflowSavedBeforeModeExistedDecodesAsInteractive() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"legacy","summary":"s",
         "steps":[{"action":"click","target":"Appearance"}]}
        """
        let decoded = try JSONDecoder().decode(Workflow.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.mode, .interactive)
        XCTAssertEqual(decoded.name, "legacy")
    }
}
