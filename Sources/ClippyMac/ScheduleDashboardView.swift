import ClippyCore
import SwiftUI

/// Backs the scheduled-checks dashboard. Owns the store and republishes rows on
/// a slow tick, so "next run in 4 min" counts down while the panel is open
/// without the view reaching into persistence itself.
@MainActor
final class ScheduleDashboardModel: ObservableObject {
    @Published private(set) var rows: [ScheduledCheckRow] = []
    @Published var errorMessage: String?

    private let store: WorkflowStore
    private var ticker: Timer?

    init(store: WorkflowStore = WorkflowStore(directory: WorkflowStore.defaultDirectory())) {
        self.store = store
        refresh()
    }

    func startTicking() {
        guard ticker == nil else { return }
        // One second is enough for a countdown that is only ever shown to the
        // nearest second or minute, and cheap next to what it displays.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    func refresh() {
        rows = store.dashboardRows()
    }

    func setEnabled(_ isEnabled: Bool, id: UUID) {
        perform { try store.setEnabled(isEnabled, scheduleID: id) }
    }

    func remove(id: UUID) {
        perform { try store.removeSchedule(id: id) }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The scheduled-checks dashboard, shown inside the expanded window in place
/// of the conversation rather than as a separate sheet — a check that is
/// running in the background is something you glance at next to the chat, not
/// something worth losing the chat to look at.
struct ScheduleDashboardView: View {
    @StateObject private var model = ScheduleDashboardModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.rows) { row in
                            ScheduleRowView(
                                row: row,
                                onToggle: { model.setEnabled(!row.isEnabled, id: row.id) },
                                onDelete: { model.remove(id: row.id) }
                            )
                        }
                    }
                    .padding(14)
                }
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.startTicking() }
        .onDisappear { model.stopTicking() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("No scheduled checks")
                .font(.headline)
            Text("A check runs a saved monitor workflow on a timer and tells you what changed. It can look and scroll, but never click or type.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct ScheduleRowView: View {
    let row: ScheduledCheckRow
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("/\(row.name)").font(.system(.body, design: .monospaced)).bold()
                    Text(row.cadence).font(.caption).foregroundStyle(.secondary)
                }
                if !row.summary.isEmpty {
                    Text(row.summary).font(.caption).foregroundStyle(.secondary)
                }
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Button(row.isEnabled ? "Pause" : "Resume", action: onToggle)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Delete this check")
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusColor: Color {
        switch row.status {
        case .paused: .secondary
        case .due: .green
        case .waiting: .accentColor
        }
    }

    private var detail: String {
        var parts = ["next \(row.nextRunDescription())"]
        if let lastRunAt = row.lastRunAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            parts.append("last ran \(formatter.localizedString(for: lastRunAt, relativeTo: Date()))")
        } else {
            parts.append("never run")
        }
        return parts.joined(separator: " · ")
    }
}
