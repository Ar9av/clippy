import XCTest
@testable import ClippyCore

/// The fixed delays scattered through the action path were guesses at how long
/// an app might take to react. They are now polled conditions whose timeout is
/// the old delay, so the worst case is unchanged and the common case is much
/// shorter. These pin the sequencing that change depends on.
@MainActor
final class SettleTests: XCTestCase {
    /// Records how long each settle was *allowed*, and can answer instantly to
    /// stand in for an interface that goes quiet immediately.
    final class SettleRecordingPerformer: ScreenStepPerforming {
        private(set) var settleBudgets: [Double] = []
        private(set) var idleCalls: [Double] = []
        private(set) var order: [String] = []

        func openApp(named name: String) async throws { order.append("open") }
        func click(_ target: String) async throws { order.append("click") }
        func type(_ text: String, into target: String) async throws { order.append("type") }
        func press(_ key: ScreenPlanKey) async throws { order.append("key") }
        func scroll(_ direction: ScreenScrollDirection, ticks: Int, at point: CGPoint?) async throws {
            order.append("scroll")
        }
        func settle(within seconds: Double) async {
            settleBudgets.append(seconds)
            order.append("settle")
        }
        func idle(_ seconds: Double) async throws {
            idleCalls.append(seconds)
            order.append("idle")
        }
    }

    private func plan(_ steps: [ScreenPlanStep]) -> PendingScreenPlan {
        PendingScreenPlan(summary: "test", steps: steps)
    }

    // MARK: - The runner settles rather than sleeping

    func testInterStepPauseIsASettleNotABlindSleep() async throws {
        let performer = SettleRecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0.45)
        try await runner.run(plan([
            ScreenPlanStep(action: .click, target: "One"),
            ScreenPlanStep(action: .click, target: "Two")
        ]))

        XCTAssertEqual(performer.settleBudgets, [0.45], "one settle between two steps")
        XCTAssertTrue(performer.idleCalls.isEmpty, "the pause is no longer a blind sleep")
    }

    /// The budget handed to the performer is the delay this replaced, so an
    /// interface that never goes quiet costs exactly what it always did.
    func testSettleBudgetMatchesTheDelayItReplaced() async throws {
        let performer = SettleRecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0.45)
        try await runner.run(plan([
            ScreenPlanStep(action: .click, target: "One"),
            ScreenPlanStep(action: .click, target: "Two"),
            ScreenPlanStep(action: .click, target: "Three")
        ]))

        XCTAssertEqual(performer.settleBudgets, [0.45, 0.45])
    }

    /// An explicit `wait` step is a real pause the plan asked for, not a guess
    /// about repaint timing — it must stay a sleep.
    func testAnExplicitWaitStepStaysASleep() async throws {
        let performer = SettleRecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0)
        try await runner.run(plan([ScreenPlanStep(action: .wait, seconds: 0.5)]))

        XCTAssertEqual(performer.idleCalls, [0.5])
        XCTAssertTrue(performer.settleBudgets.isEmpty)
    }

    func testNoSettleAfterTheFinalStep() async throws {
        let performer = SettleRecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0.45)
        try await runner.run(plan([ScreenPlanStep(action: .click, target: "Only")]))

        XCTAssertTrue(performer.settleBudgets.isEmpty)
        XCTAssertEqual(performer.order, ["click"])
    }

    /// Settling happens between steps, never before the first one.
    func testSettleIsInterleavedBetweenActions() async throws {
        let performer = SettleRecordingPerformer()
        let runner = ScreenPlanRunner(performer: performer, settleSeconds: 0.2)
        try await runner.run(plan([
            ScreenPlanStep(action: .click, target: "One"),
            ScreenPlanStep(action: .type, target: "Field", text: "hi")
        ]))

        XCTAssertEqual(performer.order, ["click", "settle", "type"])
    }

    // MARK: - The default conformance

    /// A performer that cannot observe the screen keeps the old behaviour, so
    /// nothing silently stops waiting.
    func testDefaultConformanceStillWaits() async {
        final class Bare: ScreenStepPerforming {
            func openApp(named name: String) async throws {}
            func click(_ target: String) async throws {}
            func type(_ text: String, into target: String) async throws {}
            func press(_ key: ScreenPlanKey) async throws {}
            func idle(_ seconds: Double) async throws {}
        }
        let start = ContinuousClock.now
        await Bare().settle(within: 0.05)
        XCTAssertGreaterThanOrEqual((ContinuousClock.now - start), .milliseconds(40))
    }
}
