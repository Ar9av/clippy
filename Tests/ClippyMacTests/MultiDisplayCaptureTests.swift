import XCTest
import CoreGraphics
@testable import ClippyCore

/// Clippy captures every attached display, not just the active window, so a
/// request about "the other screen" has something to look at.
final class MultiDisplayCaptureTests: XCTestCase {
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    private func shot(
        _ name: String,
        _ frame: CGRect,
        anchor: Bool,
        file: String = "/tmp/shot.png"
    ) -> DisplayShot {
        DisplayShot(
            name: name,
            url: URL(fileURLWithPath: file),
            frame: frame,
            scale: 1.04,
            isAnchor: anchor
        )
    }

    private func context(_ shots: [DisplayShot], bounds: CGRect) -> ScreenContext {
        ScreenContext(
            appName: "Safari",
            windowTitle: "Test",
            contextURL: URL(fileURLWithPath: "/tmp/ctx.txt"),
            elements: [],
            displayShots: shots,
            windowFrame: bounds,
            screenshotScale: 1.04
        )
    }

    func testEveryDisplayIsAttached() {
        let ctx = context([
            shot("Built-in", builtIn, anchor: true, file: "/tmp/a.png"),
            shot("DELL S2725QC", external, anchor: false, file: "/tmp/b.png")
        ], bounds: builtIn)

        XCTAssertEqual(ctx.screenshotURLs.count, 2)
        XCTAssertEqual(ctx.screenshotURLs.map(\.lastPathComponent), ["a.png", "b.png"])
    }

    /// Single-image consumers must get the display being acted on, not
    /// whichever display the system happened to enumerate first.
    func testSingleImageConsumersGetTheAnchorDisplay() {
        let ctx = context([
            shot("Built-in", builtIn, anchor: true, file: "/tmp/anchor.png"),
            shot("DELL S2725QC", external, anchor: false, file: "/tmp/other.png")
        ], bounds: builtIn)

        XCTAssertEqual(ctx.screenshotURL.lastPathComponent, "anchor.png")
        XCTAssertEqual(ctx.screenshotURLs.first, ctx.screenshotURL, "anchor comes first")
    }

    func testWorksWithASingleDisplay() {
        let ctx = context([shot("Built-in", builtIn, anchor: true)], bounds: builtIn)
        XCTAssertEqual(ctx.screenshotURLs.count, 1)
        XCTAssertEqual(ctx.screenshotURL, ctx.displayShots[0].url)
    }

    /// Displays tile in one shared point space, so a point on the external
    /// monitor is simply a larger x — not a second origin.
    func testDisplaysTileIntoOneSharedCoordinateSpace() {
        XCTAssertEqual(builtIn.maxX, external.minX, "second display begins where the first ends")
        XCTAssertFalse(builtIn.intersects(external))
    }

    // MARK: - Action bounds

    /// Seeing every screen must not mean clicking on every screen: actions stay
    /// bounded to the display holding the active window.
    func testActionsAreBoundedToTheActiveDisplay() {
        let ctx = context([
            shot("Built-in", builtIn, anchor: true),
            shot("DELL S2725QC", external, anchor: false)
        ], bounds: builtIn)

        // A point on the active display is dispatchable.
        XCTAssertTrue(CoordinateSpace.isWithinBounds(
            CGPoint(x: 700, y: 400), windowFrame: ctx.windowFrame
        ))
        // The same-looking point on the other monitor is not.
        XCTAssertFalse(CoordinateSpace.isWithinBounds(
            CGPoint(x: 2400, y: 400), windowFrame: ctx.windowFrame
        ))
    }

    /// When the user is working on the external monitor, that becomes the
    /// anchor and the bounds follow — the rule is "the active display", not
    /// "the built-in display".
    func testBoundsFollowWhicheverDisplayIsActive() {
        let ctx = context([
            shot("DELL S2725QC", external, anchor: true),
            shot("Built-in", builtIn, anchor: false)
        ], bounds: external)

        XCTAssertTrue(CoordinateSpace.isWithinBounds(
            CGPoint(x: 2400, y: 400), windowFrame: ctx.windowFrame
        ))
        XCTAssertFalse(CoordinateSpace.isWithinBounds(
            CGPoint(x: 700, y: 400), windowFrame: ctx.windowFrame
        ))
    }

    /// A plan step aimed at the other monitor is refused at validation, before
    /// anything is dispatched.
    func testAPlanStepOnTheOtherDisplayIsRejected() {
        let plan = PendingScreenPlan(
            summary: "click something on the other screen",
            steps: [ScreenPlanStep(action: .click, target: "Appearance", x: 2400, y: 400)]
        )
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan, bounds: builtIn)) { error in
            XCTAssertEqual(error as? ScreenPlanError, .outOfBounds(0, "Appearance"))
        }
    }

    func testTheSameStepIsAcceptedOnTheActiveDisplay() throws {
        try ScreenPlanRunner.validate(
            PendingScreenPlan(
                summary: "click on the active screen",
                steps: [ScreenPlanStep(action: .click, target: "Appearance", x: 700, y: 400)]
            ),
            bounds: builtIn
        )
    }

    /// The final-action refusal is checked before the bounds are, so a step
    /// that is both unsafe and off-display is reported as unsafe — widening
    /// what Clippy can see never reorders that gate.
    func testTheFinalActionRefusalStillTakesPrecedenceOverBounds() {
        let plan = PendingScreenPlan(
            summary: "send on the other screen",
            steps: [ScreenPlanStep(action: .click, target: "Send", x: 2400, y: 400)]
        )
        XCTAssertThrowsError(try ScreenPlanRunner.validate(plan, bounds: builtIn)) { error in
            XCTAssertEqual(error as? ScreenPlanError, .unsafeStep(0, "Send"))
        }
    }
}
