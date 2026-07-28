import XCTest
@testable import ClippyCore

final class PendingScreenPlanTests: XCTestCase {
    func testNewPlanDefaultsToUnexecutedAndFreshlyCreated() {
        let plan = PendingScreenPlan(summary: "test", steps: [ScreenPlanStep(action: .click, target: "A")])
        XCTAssertFalse(plan.hasExecuted)
        XCTAssertLessThan(abs(plan.createdAt.timeIntervalSinceNow), 1)
    }

    func testHasExecutedIsMutable() {
        var plan = PendingScreenPlan(summary: "test", steps: [ScreenPlanStep(action: .click, target: "A")])
        plan.hasExecuted = true
        XCTAssertTrue(plan.hasExecuted)
    }

    func testDecodingFromModelJSONDefaultsMetadataFields() throws {
        // A model's [[CLIPPY_PLAN]] response never includes createdAt/
        // hasExecuted — decoding must still succeed and produce sane defaults.
        let json = """
        {"summary":"Turn on dark mode","steps":[{"action":"click","target":"Dark"}]}
        """
        let plan = try JSONDecoder().decode(PendingScreenPlan.self, from: Data(json.utf8))
        XCTAssertFalse(plan.hasExecuted)
        XCTAssertLessThan(abs(plan.createdAt.timeIntervalSinceNow), 1)
    }
}
