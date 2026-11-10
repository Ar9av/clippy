import XCTest
import ClippyCore
@testable import ClippyMac

/// Pointing ids, the POINT markers, and where the character parks.
final class PointingTests: XCTestCase {
    private func control(_ label: String, _ frame: CGRect) -> ScreenElementSummary {
        ScreenElementSummary(id: UUID(), label: label, role: "Button", frame: frame, enabled: true)
    }

    private var sample: ScreenTargets {
        ScreenTargets(
            controls: [control("Share", CGRect(x: 500, y: 30, width: 40, height: 20))],
            lines: [
                .init(text: "Quarterly revenue", rect: CGRect(x: 100, y: 130, width: 200, height: 20), words: [
                    ("Quarterly", CGRect(x: 100, y: 130, width: 90, height: 20)),
                    ("revenue", CGRect(x: 200, y: 130, width: 100, height: 20))
                ]),
                .init(text: "Done", rect: CGRect(x: 100, y: 300, width: 40, height: 20), words: [
                    ("Done", CGRect(x: 100, y: 300, width: 40, height: 20))
                ])
            ],
            mouse: CGPoint(x: 250, y: 140)
        )
    }

    func testAssignsIdsByKind() {
        let t = sample
        XCTAssertEqual(t["C1"]?.text, "Share")
        XCTAssertEqual(t["l1"]?.text, "Quarterly revenue")
        XCTAssertEqual(t["W2"]?.text, "revenue")
        XCTAssertEqual(t["L2"]?.text, "Done")
        // A one-word line gets no separate word id.
        XCTAssertNil(t["W3"])
    }

    func testMouseSnapsToTheSmallestBoxUnderIt() {
        XCTAssertEqual(sample.target(near: CGPoint(x: 250, y: 140))?.id, "W2")
        // Nothing contains it, but a box centre is within 60 pt.
        XCTAssertEqual(sample.target(near: CGPoint(x: 120, y: 350))?.id, "L2")
        XCTAssertNil(sample.target(near: CGPoint(x: 900, y: 900)))
    }

    func testRenderListsIdsStateAndMouse() {
        let text = sample.render()
        XCTAssertTrue(text.contains("- C1 Button: \"Share\" at (520, 40)"), text)
        XCTAssertTrue(text.contains("L1 @200,140 \"Quarterly revenue\" | W1=Quarterly W2=revenue"), text)
        XCTAssertTrue(text.contains("Mouse is at @250,140, on W2 \"revenue\""), text)
    }

    func testPlanClickSnapsToTheBoxWithItsLabel() {
        // Aimed a row low at "Done": snaps back to it.
        XCTAssertEqual(sample.point(forLabel: "“Done”", near: CGPoint(x: 110, y: 340)), CGPoint(x: 120, y: 310))
        // Too far away, or no such text: keep the model's point.
        XCTAssertNil(sample.point(forLabel: "Done", near: CGPoint(x: 900, y: 900)))
        XCTAssertNil(sample.point(forLabel: "Nope", near: CGPoint(x: 110, y: 310)))
        // Label-only step: any box with exactly that text.
        XCTAssertEqual(sample.point(forLabel: "share"), CGPoint(x: 520, y: 40))
    }

    func testVisionBoxConvertsToGlobalTopLeftPoints() {
        // Second display to the right of a 1440-wide primary, 900 tall.
        let display = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let rect = ScreenTargets.rect(fromVision: CGRect(x: 0.5, y: 0.9, width: 0.1, height: 0.05), displayFrame: display)
        XCTAssertEqual(rect.minX, 1440 + 960, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 1080 * 0.05, accuracy: 0.01) // 1 - maxY(0.95)
        XCTAssertEqual(rect.width, 192, accuracy: 0.01)
        XCTAssertEqual(rect.height, 54, accuracy: 0.01)
    }

    func testParsesASinglePoint() throws {
        let parsed = try XCTUnwrap(AIService.pointDirectives(from: "[[CLIPPY_POINT:w12|The word]] It's right there."))
        XCTAssertEqual(parsed.points, [.init(target: .id("W12"), caption: "The word")])
        XCTAssertEqual(parsed.response, "It's right there.")
    }

    func testParsesASequenceInOrderCappedAtFour() throws {
        let reply = (1...5).map { "[[CLIPPY_POINT:C\($0)|Step \($0)]]" }.joined() + " Follow these."
        let parsed = try XCTUnwrap(AIService.pointDirectives(from: reply))
        XCTAssertEqual(parsed.points.map(\.caption), ["Step 1", "Step 2", "Step 3", "Step 4"])
        XCTAssertEqual(parsed.response, "Follow these.")
    }

    func testParsesACoordinateFallbackWithoutCaption() throws {
        let parsed = try XCTUnwrap(AIService.pointDirectives(from: "[[CLIPPY_POINT_AT: 512 , 380.5]]"))
        XCTAssertEqual(parsed.points, [.init(target: .point(CGPoint(x: 512, y: 380.5)), caption: "")])
        XCTAssertEqual(parsed.response, "")
    }

    func testNoMarkerAndLegacyGuideAreNotPoints() {
        XCTAssertNil(AIService.pointDirectives(from: "Just an answer."))
        XCTAssertNil(AIService.pointDirectives(from: "[[CLIPPY_GUIDE:Share]] There."))
        XCTAssertEqual(AIService.screenDirective(from: "[[CLIPPY_GUIDE:Share]] There.")?.target, "Share")
    }

    func testStepsResolveIdsAndDropUnknownOnes() {
        let screen = ScreenContext(
            appName: "Test", windowTitle: "Test",
            contextURL: URL(fileURLWithPath: "/dev/null"), elements: [],
            displayShots: [DisplayShot(name: "Main", url: URL(fileURLWithPath: "/dev/null"), frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 1, isAnchor: true)],
            windowFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), screenshotScale: 1
        )
        let steps = ChatViewModel.pointingSteps(
            [.init(target: .id("W2"), caption: ""), .init(target: .id("C99"), caption: "x"),
             .init(target: .point(CGPoint(x: 50, y: 60)), caption: "Icon")],
            screen: screen,
            targets: sample
        )
        XCTAssertEqual(steps.map(\.caption), ["revenue", "Icon"])
        XCTAssertEqual(steps.last?.rect.midX, 50)
        // No capture this turn means nothing to point at.
        XCTAssertTrue(ChatViewModel.pointingSteps([.init(target: .id("W2"), caption: "")], screen: nil, targets: sample).isEmpty)
    }

    func testCharacterParksBesideTheTargetWithoutCoveringIt() {
        let screen = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let right = PointingChoreographer.characterSpot(beside: CGRect(x: 100, y: 400, width: 80, height: 20), size: 110, screens: screen)
        XCTAssertEqual(right?.direction, .left)
        XCTAssertEqual(right?.center.x, 180 + 6 + 55)
        // No room on the right: park on the left and point right.
        let left = PointingChoreographer.characterSpot(beside: CGRect(x: 1360, y: 400, width: 70, height: 20), size: 110, screens: screen)
        XCTAssertEqual(left?.direction, .right)
        // A toolbar item near the top keeps the character on screen.
        let top = PointingChoreographer.characterSpot(beside: CGRect(x: 100, y: 10, width: 40, height: 20), size: 110, screens: screen)
        XCTAssertEqual(top?.center.y, 55)
    }

    func testFlightTimingAndEasing() {
        XCTAssertEqual(PointingChoreographer.flightDuration(distance: 0), 0.45)
        XCTAssertEqual(PointingChoreographer.flightDuration(distance: 100_000), 1.2)
        XCTAssertEqual(PointingChoreographer.ease(0), 0, accuracy: 1e-6)
        XCTAssertEqual(PointingChoreographer.ease(1), 1, accuracy: 1e-6)
        XCTAssertGreaterThan(PointingChoreographer.ease(0.5), 0.5)
    }

    func testPointingQuestionsTakeAScreenshot() {
        for request in ["where's the Appearance option?", "point at the word revenue", "which icon is Wi-Fi", "show me how to turn on dark mode"] {
            XCTAssertTrue(ChatViewModel.mightNeedScreen(request), request)
        }
    }

    func testShowMeRequestsAreToursNotPlans() {
        for request in ["show me how to turn on dark mode", "how do i change the wallpaper", "where's wi-fi"] {
            XCTAssertTrue(ChatViewModel.asksToBeShown(request), request)
        }
        XCTAssertFalse(ChatViewModel.asksToBeShown("turn on dark mode"))
    }

    /// Seen live with gpt-5.6-luna: the next step came back as bare JSON and
    /// every multi-step plan stopped after step 1.
    func testBareJSONNextStepStillParses() {
        let bare = #"{"summary":"Select Bluetooth.","steps":[{"action":"click","target":"Bluetooth","x":443,"y":313}]}"#
        let plan = AIService.screenPlan(from: ChatViewModel.withPlanMarker(bare), bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        XCTAssertEqual(plan?.plan.steps.first?.target, "Bluetooth")
        XCTAssertEqual(ChatViewModel.withPlanMarker("[[CLIPPY_PLAN]]{}"), "[[CLIPPY_PLAN]]{}")
    }

    func testAskingForAFreshScreenTriggersTheRetry() {
        XCTAssertTrue(AIService.asksForScreenAttachment("Send the current Screen Context and I'll point to it."))
        XCTAssertTrue(AIService.asksForScreenAttachment("I need a fresh screen update first."))
    }
}
