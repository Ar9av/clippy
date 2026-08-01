import XCTest
@testable import ClippyCore

final class WorkflowStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func store() -> WorkflowStore { WorkflowStore(directory: directory) }

    private func monitorFlow(name: String = "portfolio") -> Workflow {
        Workflow(
            name: name,
            summary: "check the portfolio page",
            steps: [
                ScreenPlanStep(action: .open, app: "Safari"),
                ScreenPlanStep(action: .scroll, direction: .down, amount: 4)
            ],
            mode: .monitor
        )
    }

    private func interactiveFlow(name: String = "standup") -> Workflow {
        Workflow(
            name: name,
            summary: "post the standup",
            steps: [ScreenPlanStep(action: .click, target: "Compose")],
            mode: .interactive
        )
    }

    // MARK: - Saving

    func testSavedWorkflowIsFoundByNameAndSurvivesAReload() throws {
        try store().save(monitorFlow())
        // A fresh store reads from disk rather than memory.
        XCTAssertEqual(store().workflow(named: "portfolio")?.summary, "check the portfolio page")
        XCTAssertEqual(store().workflow(named: "/Portfolio")?.name, "portfolio")
    }

    /// Re-saving after a tweak should mean "the latest version", not two
    /// entries competing for one command word.
    func testSavingTheSameNameReplacesRatherThanDuplicates() throws {
        let store = self.store()
        try store.save(monitorFlow())
        var updated = monitorFlow()
        updated.summary = "revised"
        try store.save(updated)

        XCTAssertEqual(store.workflows.filter { $0.name == "portfolio" }.count, 1)
        XCTAssertEqual(store.workflow(named: "portfolio")?.summary, "revised")
    }

    func testAnInvalidWorkflowIsRejected() {
        let store = self.store()
        XCTAssertThrowsError(try store.save(Workflow(name: "", summary: "", steps: []))) { error in
            XCTAssertEqual(error as? WorkflowError, .invalidName)
        }
    }

    // MARK: - Scheduling

    func testOnlyAMonitorWorkflowCanBeScheduled() throws {
        let store = self.store()
        let interactive = try store.save(interactiveFlow())
        XCTAssertThrowsError(try store.schedule(interactive, every: 300)) { error in
            XCTAssertEqual(
                error as? WorkflowError,
                .actionNotAllowedWhileMonitoring(.click),
                "a check that fires unattended must not be able to click"
            )
        }
        XCTAssertTrue(store.schedules.isEmpty)
    }

    func testAMonitorWorkflowSchedulesAndPersists() throws {
        let flow = try store().save(monitorFlow())
        try store().schedule(flow, every: 900)
        XCTAssertEqual(store().schedules.count, 1)
        XCTAssertEqual(store().schedules.first?.interval, 900)
    }

    /// A monitor that fires every second is a busy-loop against someone's
    /// screen, not a check.
    func testIntervalIsFloored() throws {
        let flow = try store().save(monitorFlow())
        let schedule = try store().schedule(flow, every: 1)
        XCTAssertEqual(schedule.interval, WorkflowSchedule.minimumInterval)
    }

    func testReschedulingReplacesRatherThanStacking() throws {
        let store = self.store()
        let flow = try store.save(monitorFlow())
        try store.schedule(flow, every: 300)
        try store.schedule(flow, every: 600)
        XCTAssertEqual(store.schedules.count, 1)
        XCTAssertEqual(store.schedules.first?.interval, 600)
    }

    // MARK: - Due-ness

    func testANewScheduleIsDueImmediately() {
        let schedule = WorkflowSchedule(workflowID: UUID(), interval: 600)
        XCTAssertTrue(schedule.isDue(), "a new check answers now, not after a full interval of silence")
    }

    func testNotDueUntilTheIntervalElapses() {
        let now = Date()
        let schedule = WorkflowSchedule(workflowID: UUID(), interval: 600, lastRunAt: now)
        XCTAssertFalse(schedule.isDue(at: now.addingTimeInterval(599)))
        XCTAssertTrue(schedule.isDue(at: now.addingTimeInterval(600)))
    }

    func testADisabledScheduleIsNeverDue() {
        let schedule = WorkflowSchedule(
            workflowID: UUID(), interval: 60, lastRunAt: nil, isEnabled: false
        )
        XCTAssertFalse(schedule.isDue(at: Date().addingTimeInterval(10_000)))
    }

    func testDueListsTheWorkflowToRunAndMarkingClearsIt() throws {
        let store = self.store()
        let flow = try store.save(monitorFlow())
        let schedule = try store.schedule(flow, every: 600)

        let now = Date()
        XCTAssertEqual(store.due(at: now).count, 1)
        XCTAssertEqual(store.due(at: now).first?.workflow.name, "portfolio")

        try store.markRun(scheduleID: schedule.id, at: now)
        XCTAssertTrue(store.due(at: now).isEmpty, "just ran, so no longer due")
        XCTAssertEqual(store.due(at: now.addingTimeInterval(600)).count, 1)
    }

    // MARK: - Deletion

    func testDeletingAWorkflowTakesItsScheduleWithIt() throws {
        let store = self.store()
        let flow = try store.save(monitorFlow())
        try store.schedule(flow, every: 300)
        XCTAssertEqual(store.schedules.count, 1)

        try store.delete(named: "portfolio")
        XCTAssertNil(store.workflow(named: "portfolio"))
        XCTAssertTrue(store.schedules.isEmpty, "an orphaned schedule would fire against nothing")
    }

    /// A hand-edited or partially restored file could leave a schedule with no
    /// workflow; loading must drop it rather than fire forever against nothing.
    func testOrphanedSchedulesAreDroppedOnLoad() throws {
        let store = self.store()
        let flow = try store.save(monitorFlow())
        try store.schedule(flow, every: 300)

        // Remove the workflows file, leaving the schedule behind.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Workflows.json"))

        let reloaded = WorkflowStore(directory: directory)
        XCTAssertTrue(reloaded.workflows.isEmpty)
        XCTAssertTrue(reloaded.schedules.isEmpty)
    }
}

/// The dashboard's rows are computed in the store rather than the view, so the
/// cadence text, countdown, and status are testable without building UI.
final class ScheduleDashboardTests: XCTestCase {
    private var directory: URL!
    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardTests-\(UUID().uuidString)")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func storeWithCheck(every interval: TimeInterval) throws -> (WorkflowStore, UUID) {
        let store = WorkflowStore(directory: directory)
        let flow = try store.save(Workflow(
            name: "portfolio",
            summary: "check the portfolio page",
            steps: [ScreenPlanStep(action: .scroll, direction: .down, amount: 3)],
            mode: .monitor
        ))
        let schedule = try store.schedule(flow, every: interval)
        return (store, schedule.id)
    }

    func testARowIsProducedPerScheduledCheck() throws {
        let (store, _) = try storeWithCheck(every: 900)
        let rows = store.dashboardRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "portfolio")
        XCTAssertEqual(rows[0].summary, "check the portfolio page")
    }

    func testCadenceReadsInWholeUnits() throws {
        XCTAssertEqual(try storeWithCheck(every: 30).0.dashboardRows()[0].cadence, "every 30s")
        directory = directory.appendingPathComponent("b")
        XCTAssertEqual(try storeWithCheck(every: 900).0.dashboardRows()[0].cadence, "every 15 min")
        directory = directory.appendingPathComponent("c")
        XCTAssertEqual(try storeWithCheck(every: 7200).0.dashboardRows()[0].cadence, "every 2h")
    }

    /// 30 seconds is the floor, so a faster request is raised rather than
    /// refused — and the dashboard shows what will actually happen.
    func testAFasterThanAllowedCheckShowsTheFlooredCadence() throws {
        let (store, _) = try storeWithCheck(every: 5)
        XCTAssertEqual(store.dashboardRows()[0].cadence, "every 30s")
        XCTAssertEqual(store.dashboardRows()[0].interval, 30)
    }

    func testStatusReflectsDuePausedAndWaiting() throws {
        let (store, id) = try storeWithCheck(every: 600)
        let now = Date()
        XCTAssertEqual(store.dashboardRows(at: now)[0].status, .due, "never run, so due now")

        try store.markRun(scheduleID: id, at: now)
        XCTAssertEqual(store.dashboardRows(at: now)[0].status, .waiting)
        XCTAssertEqual(store.dashboardRows(at: now)[0].nextRunDescription(at: now), "in 10 min")

        try store.setEnabled(false, scheduleID: id)
        XCTAssertEqual(store.dashboardRows(at: now)[0].status, .paused)
        XCTAssertEqual(store.dashboardRows(at: now)[0].nextRunDescription(at: now), "paused")
    }

    func testPausingStopsItBeingDueButKeepsTheCheck() throws {
        let (store, id) = try storeWithCheck(every: 60)
        try store.setEnabled(false, scheduleID: id)
        XCTAssertTrue(store.due().isEmpty)
        XCTAssertEqual(store.dashboardRows().count, 1, "paused is not deleted")

        try store.setEnabled(true, scheduleID: id)
        XCTAssertEqual(store.due().count, 1)
    }

    func testRemovingFromTheDashboardDropsTheCheckButKeepsTheWorkflow() throws {
        let (store, id) = try storeWithCheck(every: 60)
        try store.removeSchedule(id: id)
        XCTAssertTrue(store.dashboardRows().isEmpty)
        XCTAssertNotNil(store.workflow(named: "portfolio"), "the workflow is still runnable by hand")
    }
}
