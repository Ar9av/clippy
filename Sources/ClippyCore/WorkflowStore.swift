import Foundation

/// Saved workflows and their schedules, persisted as JSON.
///
/// Takes its directory rather than choosing one, so the scheduling and
/// name-collision rules are testable against a temporary directory instead of
/// the real Application Support folder.
public final class WorkflowStore {
    private let directory: URL
    private let workflowsURL: URL
    private let schedulesURL: URL

    public private(set) var workflows: [Workflow] = []
    public private(set) var schedules: [WorkflowSchedule] = []

    public init(directory: URL) {
        self.directory = directory
        self.workflowsURL = directory.appendingPathComponent("Workflows.json")
        self.schedulesURL = directory.appendingPathComponent("WorkflowSchedules.json")
        load()
    }

    /// The default location, alongside the rest of Clippy's saved state.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clippy", isDirectory: true)
    }

    // MARK: Workflows

    public func workflow(named name: String) -> Workflow? {
        let normalized = Workflow.normalize(name)
        return workflows.first { $0.name == normalized }
    }

    /// Saves a workflow, replacing any existing one with the same name.
    ///
    /// Replacing by name rather than appending is what makes re-saving after a
    /// tweak do the obvious thing: `/standup` should mean the latest version,
    /// not silently become ambiguous between two entries.
    @discardableResult
    public func save(_ workflow: Workflow) throws -> Workflow {
        guard workflow.isValid else { throw WorkflowError.invalidName }
        workflows.removeAll { $0.name == workflow.name }
        workflows.append(workflow)
        workflows.sort { $0.name < $1.name }
        try persistWorkflows()
        return workflow
    }

    public func delete(named name: String) throws {
        let normalized = Workflow.normalize(name)
        guard let removed = workflows.first(where: { $0.name == normalized }) else { return }
        workflows.removeAll { $0.name == normalized }
        // A schedule pointing at a deleted workflow would fire forever with
        // nothing to run, so it goes with it.
        schedules.removeAll { $0.workflowID == removed.id }
        try persistWorkflows()
        try persistSchedules()
    }

    // MARK: Schedules

    /// Schedules a workflow to run unattended.
    ///
    /// Refused unless the workflow is in `monitor` mode: a check that fires
    /// while nobody is at the machine must not be able to click or type.
    @discardableResult
    public func schedule(
        _ workflow: Workflow,
        every interval: TimeInterval
    ) throws -> WorkflowSchedule {
        guard workflow.mode == .monitor else {
            throw WorkflowError.actionNotAllowedWhileMonitoring(
                workflow.steps.first(where: { !WorkflowMode.monitor.allows($0.action) })?.action
                    ?? .click
            )
        }
        schedules.removeAll { $0.workflowID == workflow.id }
        let schedule = WorkflowSchedule(workflowID: workflow.id, interval: interval)
        schedules.append(schedule)
        try persistSchedules()
        return schedule
    }

    public func unschedule(workflowID: UUID) throws {
        schedules.removeAll { $0.workflowID == workflowID }
        try persistSchedules()
    }

    /// Every workflow whose schedule is due, paired with that schedule.
    /// Callers run these and then call `markRun` for each.
    public func due(at now: Date = Date()) -> [(workflow: Workflow, schedule: WorkflowSchedule)] {
        schedules.filter { $0.isDue(at: now) }.compactMap { schedule in
            workflows.first { $0.id == schedule.workflowID }.map { ($0, schedule) }
        }
    }

    public func markRun(scheduleID: UUID, at now: Date = Date()) throws {
        guard let index = schedules.firstIndex(where: { $0.id == scheduleID }) else { return }
        schedules[index] = schedules[index].markingRun(at: now)
        try persistSchedules()
    }

    // MARK: Dashboard

    /// One row per scheduled check, ready to render. Computed here rather than
    /// in the view so "is this due", "when next", and the human-readable
    /// cadence are testable without building UI.
    public func dashboardRows(at now: Date = Date()) -> [ScheduledCheckRow] {
        schedules.compactMap { schedule in
            guard let workflow = workflows.first(where: { $0.id == schedule.workflowID }) else {
                return nil
            }
            return ScheduledCheckRow(
                id: schedule.id,
                name: workflow.name,
                summary: workflow.summary,
                interval: schedule.interval,
                lastRunAt: schedule.lastRunAt,
                nextRunAt: schedule.nextRun(after: now),
                isEnabled: schedule.isEnabled,
                isDue: schedule.isDue(at: now)
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// Pausing keeps the check and its history; deleting throws them away.
    /// Both are on the dashboard because "stop for now" and "I'm done with
    /// this" are different intentions.
    public func setEnabled(_ isEnabled: Bool, scheduleID: UUID) throws {
        guard let index = schedules.firstIndex(where: { $0.id == scheduleID }) else { return }
        schedules[index].isEnabled = isEnabled
        try persistSchedules()
    }

    public func removeSchedule(id: UUID) throws {
        schedules.removeAll { $0.id == id }
        try persistSchedules()
    }

    // MARK: Persistence

    private func load() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: workflowsURL) {
            workflows = (try? decoder.decode([Workflow].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: schedulesURL) {
            schedules = (try? decoder.decode([WorkflowSchedule].self, from: data)) ?? []
        }
        // A schedule whose workflow is gone (hand-edited file, partial restore)
        // would otherwise fire forever against nothing.
        let ids = Set(workflows.map(\.id))
        schedules.removeAll { !ids.contains($0.workflowID) }
    }

    private func persistWorkflows() throws {
        try write(workflows, to: workflowsURL)
    }

    private func persistSchedules() throws {
        try write(schedules, to: schedulesURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}


/// A scheduled check as the dashboard shows it.
public struct ScheduledCheckRow: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let summary: String
    public let interval: TimeInterval
    public let lastRunAt: Date?
    public let nextRunAt: Date
    public let isEnabled: Bool
    public let isDue: Bool

    public enum Status: Equatable { case paused, due, waiting }

    public var status: Status {
        if !isEnabled { return .paused }
        return isDue ? .due : .waiting
    }

    /// "every 30s" / "every 15 min" / "every 2h" — whole units only, since a
    /// cadence someone chose is never worth showing to the second.
    public var cadence: String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "every \(seconds)s" }
        if seconds < 3600 {
            let minutes = seconds / 60
            return "every \(minutes) min"
        }
        let hours = Double(seconds) / 3600
        return hours == hours.rounded()
            ? "every \(Int(hours))h"
            : String(format: "every %.1fh", hours)
    }

    public func nextRunDescription(at now: Date = Date()) -> String {
        guard isEnabled else { return "paused" }
        let remaining = nextRunAt.timeIntervalSince(now)
        if remaining <= 0 { return "now" }
        if remaining < 60 { return "in \(Int(remaining.rounded()))s" }
        if remaining < 3600 { return "in \(Int((remaining / 60).rounded())) min" }
        return String(format: "in %.1fh", remaining / 3600)
    }
}
