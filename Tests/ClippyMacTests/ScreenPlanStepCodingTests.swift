import XCTest
@testable import ClippyCore

/// The CLI providers return free-text JSON with no schema enforcing the enum
/// cases, so decoding has to survive a plausible near-miss without taking the
/// rest of the plan down with it.
final class ScreenPlanStepCodingTests: XCTestCase {
    private func decodePlan(_ json: String) throws -> PendingScreenPlan {
        try JSONDecoder().decode(PendingScreenPlan.self, from: Data(json.utf8))
    }

    func testDecodesAScrollStep() throws {
        let plan = try decodePlan("""
        {"summary":"look further down","steps":[
          {"action":"scroll","direction":"down","amount":4,"x":500,"y":400}
        ]}
        """)
        XCTAssertEqual(plan.steps.first?.action, .scroll)
        XCTAssertEqual(plan.steps.first?.direction, .down)
        XCTAssertEqual(plan.steps.first?.amount, 4)
        XCTAssertEqual(plan.steps.first?.x, 500)
        try ScreenPlanRunner.validate(plan)
    }

    /// The regression this guards: an unrecognised direction used to throw out
    /// of the whole container, so one bad step silently discarded every good
    /// step alongside it — at parse time, where nothing reports the failure.
    func testAnUnknownDirectionDoesNotDiscardTheRestOfThePlan() throws {
        let plan = try decodePlan("""
        {"summary":"mixed","steps":[
          {"action":"click","target":"Appearance"},
          {"action":"scroll","direction":"downward"},
          {"action":"click","target":"Dark"}
        ]}
        """)
        XCTAssertEqual(plan.steps.count, 3)
        XCTAssertEqual(plan.steps[0].target, "Appearance")
        XCTAssertEqual(plan.steps[2].target, "Dark")
        XCTAssertNil(plan.steps[1].direction)
    }

    /// Lenient decoding must not become lenient execution — the bad step is
    /// still refused, just by validation, which names it.
    func testAScrollWithAnUnknownDirectionIsStillRejectedByValidation() throws {
        let plan = try decodePlan("""
        {"summary":"s","steps":[{"action":"scroll","direction":"sideways"}]}
        """)
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan)) { error in
            XCTAssertEqual(error as? ScreenPlanError, .malformedStep(0))
        }
    }

    func testAnUnknownKeyDecodesToNilAndIsRejectedByValidation() throws {
        let plan = try decodePlan("""
        {"summary":"s","steps":[{"action":"key","key":"return"}]}
        """)
        XCTAssertNil(plan.steps.first?.key)
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan)) { error in
            XCTAssertEqual(error as? ScreenPlanError, .malformedStep(0))
        }
    }

    /// A "return" key must never sneak through as a valid keystroke, however
    /// it is spelled — the no-Return rule is structural, not a filter.
    func testReturnIsNotDecodableAsAKey() {
        for spelling in ["return", "enter", "Return", "\r"] {
            XCTAssertNil(ScreenPlanKey(rawValue: spelling), spelling)
        }
    }

    func testEveryFieldSurvivesARoundTrip() throws {
        let original = ScreenPlanStep(
            action: .type,
            target: "Address bar",
            text: "https://example.com",
            seconds: 1.5,
            app: "Safari",
            key: .tab,
            x: 420,
            y: 38,
            pressReturnAfter: true,
            direction: .right,
            amount: 7
        )
        let decoded = try JSONDecoder().decode(
            ScreenPlanStep.self,
            from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded.action, original.action)
        XCTAssertEqual(decoded.target, original.target)
        XCTAssertEqual(decoded.text, original.text)
        XCTAssertEqual(decoded.seconds, original.seconds)
        XCTAssertEqual(decoded.app, original.app)
        XCTAssertEqual(decoded.key, original.key)
        XCTAssertEqual(decoded.x, original.x)
        XCTAssertEqual(decoded.y, original.y)
        XCTAssertEqual(decoded.pressReturnAfter, original.pressReturnAfter)
        XCTAssertEqual(decoded.direction, original.direction)
        XCTAssertEqual(decoded.amount, original.amount)
    }

    /// A step with nothing but an action must not gain values from decoding.
    func testAbsentFieldsDecodeToNil() throws {
        let step = try JSONDecoder().decode(
            ScreenPlanStep.self,
            from: Data(#"{"action":"wait"}"#.utf8)
        )
        XCTAssertEqual(step.action, .wait)
        XCTAssertNil(step.target)
        XCTAssertNil(step.text)
        XCTAssertNil(step.seconds)
        XCTAssertNil(step.app)
        XCTAssertNil(step.key)
        XCTAssertNil(step.x)
        XCTAssertNil(step.y)
        XCTAssertNil(step.pressReturnAfter)
        XCTAssertNil(step.direction)
        XCTAssertNil(step.amount)
    }

    /// An unknown action is still fatal to the parse, and should be: there is
    /// no safe default for "what should this step do".
    func testAnUnknownActionStillFailsTheDecode() {
        XCTAssertThrowsError(try decodePlan(
            #"{"summary":"s","steps":[{"action":"drag","target":"x"}]}"#
        ))
    }
}
