import XCTest
@testable import ClippyCore

/// What a control's line in "Visible actionable controls" tells the model, and
/// which controls survive the cut when there are more of them than fit.
final class ScreenElementSummaryTests: XCTestCase {
    private func element(
        label: String,
        role: String = "Button",
        frame: CGRect = CGRect(x: 0, y: 0, width: 60, height: 20),
        enabled: Bool = true,
        value: String? = nil,
        checked: Bool? = nil,
        focused: Bool = false
    ) -> ScreenElementSummary {
        ScreenElementSummary(
            id: UUID(),
            label: label,
            role: role,
            frame: frame,
            enabled: enabled,
            value: value,
            checked: checked,
            focused: focused
        )
    }

    // MARK: - Context lines

    func testReportsAFieldsCurrentContents() {
        let line = element(label: "Search", role: "TextField", value: "swift concurrency").contextLine
        XCTAssertTrue(line.contains("= \"swift concurrency\""), line)
    }

    /// The distinction that matters: a field with no readable value at all
    /// versus one that is genuinely empty. Only the latter is safe to type
    /// into without clearing it first.
    func testDistinguishesAnEmptyFieldFromOneWithNoReadableValue() {
        XCTAssertTrue(element(label: "Search", role: "TextField", value: "").contextLine.contains("(empty)"))
        XCTAssertFalse(element(label: "Search", role: "TextField").contextLine.contains("="))
    }

    func testTruncatesLongFieldContents() {
        let long = String(repeating: "a", count: 500)
        let line = element(label: "Note", role: "TextArea", value: long).contextLine
        XCTAssertTrue(line.contains("…"))
        XCTAssertLessThan(line.count, 200)
    }

    func testCollapsesNewlinesInFieldContents() {
        let line = element(label: "Note", role: "TextArea", value: "one\ntwo").contextLine
        XCTAssertTrue(line.contains("= \"one two\""), line)
        XCTAssertFalse(line.contains("\n"))
    }

    func testReportsToggleState() {
        XCTAssertTrue(element(label: "Dark Mode", role: "CheckBox", checked: true).contextLine.contains("[checked]"))
        XCTAssertTrue(element(label: "Dark Mode", role: "CheckBox", checked: false).contextLine.contains("[unchecked]"))
        // A button has no checked state and must not claim one either way.
        let button = element(label: "Save").contextLine
        XCTAssertFalse(button.contains("checked"))
    }

    func testReportsFocusAndDisabledState() {
        let line = element(label: "Send", enabled: false, focused: true).contextLine
        XCTAssertTrue(line.contains("[focused]"), line)
        XCTAssertTrue(line.contains("[disabled]"), line)
    }

    // MARK: - Prompt ordering

    func testKeepsEverythingWhenItFitsAndSortsIntoReadingOrder() {
        let bottom = element(label: "Bottom", frame: CGRect(x: 10, y: 300, width: 50, height: 20))
        let topRight = element(label: "Top right", frame: CGRect(x: 400, y: 10, width: 50, height: 20))
        let topLeft = element(label: "Top left", frame: CGRect(x: 10, y: 10, width: 50, height: 20))

        let ordered = ScreenElementSummary.promptOrdered([bottom, topRight, topLeft], limit: 10)
        XCTAssertEqual(ordered.map(\.label), ["Top left", "Top right", "Bottom"])
    }

    /// Controls a few points apart vertically are on the same visual row and
    /// must be read left-to-right, not split by the jitter.
    func testBandsNearlyAlignedControlsIntoOneRow() {
        let right = element(label: "Right", frame: CGRect(x: 400, y: 102, width: 50, height: 20))
        let left = element(label: "Left", frame: CGRect(x: 10, y: 100, width: 50, height: 20))

        let ordered = ScreenElementSummary.promptOrdered([right, left], limit: 10)
        XCTAssertEqual(ordered.map(\.label), ["Left", "Right"])
    }

    /// The whole point of ranking before truncating: an unnamed control can't
    /// be matched by label anyway, so it must never crowd out a named one.
    func testDropsUnnamedControlsBeforeNamedOnes() {
        let unnamed = (0..<20).map { index in
            element(label: "Button", frame: CGRect(x: 0, y: Double(index) * 30, width: 50, height: 20))
        }
        let named = element(label: "Continue", frame: CGRect(x: 0, y: 900, width: 50, height: 20))

        let ordered = ScreenElementSummary.promptOrdered(unnamed + [named], limit: 5)
        XCTAssertEqual(ordered.count, 5)
        XCTAssertTrue(ordered.contains { $0.label == "Continue" })
    }

    func testKeepsTheFocusedAndEditableControlsUnderPressure() {
        let filler = (0..<40).map { index in
            element(label: "Item \(index)", frame: CGRect(x: 0, y: Double(index) * 30, width: 50, height: 20))
        }
        let field = element(
            label: "Message",
            role: "TextArea",
            frame: CGRect(x: 0, y: 2000, width: 200, height: 40),
            focused: true
        )

        let ordered = ScreenElementSummary.promptOrdered(filler + [field], limit: 6)
        XCTAssertTrue(ordered.contains { $0.label == "Message" })
    }

    func testDisabledControlsAreDroppedFirst() {
        let disabled = (0..<10).map { index in
            element(label: "Disabled \(index)", frame: CGRect(x: 0, y: Double(index) * 30, width: 50, height: 20), enabled: false)
        }
        let enabled = (0..<3).map { index in
            element(label: "Enabled \(index)", frame: CGRect(x: 0, y: Double(index) * 30 + 500, width: 50, height: 20))
        }

        let ordered = ScreenElementSummary.promptOrdered(disabled + enabled, limit: 3)
        XCTAssertEqual(Set(ordered.map(\.label)), Set(enabled.map(\.label)))
    }
}
