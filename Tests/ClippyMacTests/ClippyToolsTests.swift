import XCTest
@testable import ClippyCore

final class ClippyToolsTests: XCTestCase {
    private func response(name: String, input: JSONValue) -> CompletionResponse {
        CompletionResponse(
            content: [.toolUse(id: "toolu_1", name: name, input: input)],
            stopReason: .toolUse,
            usage: nil
        )
    }

    func testDecodesScreenActionIntoAPendingScreenPlan() {
        let input = JSONValue.object([
            "summary": .string("Turn on dark mode"),
            "steps": .array([
                .object(["action": .string("click"), "target": .string("Appearance")]),
                .object(["action": .string("wait"), "seconds": .number(0.8)]),
                .object(["action": .string("click"), "target": .string("Dark")])
            ])
        ])
        guard case .screenAction(let plan)? = ClippyTools.call(from: response(name: "screen_action", input: input)) else {
            return XCTFail("expected .screenAction")
        }
        XCTAssertEqual(plan.summary, "Turn on dark mode")
        XCTAssertEqual(plan.steps.count, 3)
        XCTAssertEqual(plan.steps[0].action, .click)
        XCTAssertEqual(plan.steps[0].target, "Appearance")
        XCTAssertEqual(plan.steps[1].seconds, 0.8)
    }

    func testDecodesAScrollStep() {
        let input = JSONValue.object([
            "summary": .string("Look further down the page"),
            "steps": .array([
                .object([
                    "action": .string("scroll"),
                    "direction": .string("down"),
                    "amount": .number(4),
                    "x": .number(500),
                    "y": .number(400)
                ])
            ])
        ])
        guard case .screenAction(let plan)? = ClippyTools.call(from: response(name: "screen_action", input: input)) else {
            return XCTFail("expected .screenAction")
        }
        XCTAssertEqual(plan.steps.first?.action, .scroll)
        XCTAssertEqual(plan.steps.first?.direction, .down)
        XCTAssertEqual(plan.steps.first?.amount, 4)
        XCTAssertEqual(plan.steps.first?.x, 500)
    }

    /// An unrecognised direction must not silently become a default one — the
    /// step is rejected by validation instead of scrolling some other way.
    func testDropsAnUnknownScrollDirection() {
        let input = JSONValue.object([
            "summary": .string("s"),
            "steps": .array([
                .object(["action": .string("scroll"), "direction": .string("sideways")])
            ])
        ])
        guard case .screenAction(let plan)? = ClippyTools.call(from: response(name: "screen_action", input: input)) else {
            return XCTFail("expected .screenAction")
        }
        XCTAssertNil(plan.steps.first?.direction)
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan))
    }

    func testDecodesScreenActionStepWithCoordinatesAndKey() {
        let input = JSONValue.object([
            "summary": .string("s"),
            "steps": .array([
                .object([
                    "action": .string("type"), "target": .string("Address bar"), "text": .string("hi"),
                    "x": .number(420), "y": .number(38), "pressReturnAfter": .bool(true)
                ]),
                .object(["action": .string("key"), "key": .string("tab")])
            ])
        ])
        guard case .screenAction(let plan)? = ClippyTools.call(from: response(name: "screen_action", input: input)) else {
            return XCTFail("expected .screenAction")
        }
        XCTAssertEqual(plan.steps[0].x, 420)
        XCTAssertEqual(plan.steps[0].y, 38)
        XCTAssertEqual(plan.steps[0].pressReturnAfter, true)
        XCTAssertEqual(plan.steps[1].key, .tab)
    }

    func testSkipsMalformedStepsRatherThanFailingTheWholePlan() {
        let input = JSONValue.object([
            "summary": .string("s"),
            "steps": .array([
                .object(["action": .string("not-a-real-action")]),
                .object(["action": .string("click"), "target": .string("OK")])
            ])
        ])
        guard case .screenAction(let plan)? = ClippyTools.call(from: response(name: "screen_action", input: input)) else {
            return XCTFail("expected .screenAction")
        }
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps[0].target, "OK")
    }

    func testDecodesTypeText() {
        let input = JSONValue.object(["target": .string("Search"), "text": .string("hello")])
        guard case .typeText(let target, let text)? = ClippyTools.call(from: response(name: "type_text", input: input)) else {
            return XCTFail("expected .typeText")
        }
        XCTAssertEqual(target, "Search")
        XCTAssertEqual(text, "hello")
    }

    func testDecodesHighlightControl() {
        let input = JSONValue.object(["label": .string("Save")])
        guard case .highlightControl(let label)? = ClippyTools.call(from: response(name: "highlight_control", input: input)) else {
            return XCTFail("expected .highlightControl")
        }
        XCTAssertEqual(label, "Save")
    }

    func testDecodesTaskComplete() {
        let input = JSONValue.object(["summary": .string("Dark mode is on.")])
        guard case .taskComplete(let summary)? = ClippyTools.call(from: response(name: "task_complete", input: input)) else {
            return XCTFail("expected .taskComplete")
        }
        XCTAssertEqual(summary, "Dark mode is on.")
    }

    func testDecodesCannotProceed() {
        let input = JSONValue.object(["reason": .string("The next step would submit a purchase.")])
        guard case .cannotProceed(let reason)? = ClippyTools.call(from: response(name: "cannot_proceed", input: input)) else {
            return XCTFail("expected .cannotProceed")
        }
        XCTAssertEqual(reason, "The next step would submit a purchase.")
    }

    func testReturnsNilForAPlainTextResponse() {
        let response = CompletionResponse(content: [.text("just an answer")], stopReason: .endTurn, usage: nil)
        XCTAssertNil(ClippyTools.call(from: response))
    }

    func testReturnsNilForUnrecognizedToolName() {
        let response = response(name: "not_a_real_tool", input: .object([:]))
        XCTAssertNil(ClippyTools.call(from: response))
    }

    func testReturnsNilWhenRequiredFieldMissing() {
        let response = response(name: "task_complete", input: .object([:]))
        XCTAssertNil(ClippyTools.call(from: response))
    }

    func testAllToolsHaveUniqueNames() {
        let names = Set(ClippyTools.all.map(\.name))
        XCTAssertEqual(names.count, ClippyTools.all.count)
    }
}
