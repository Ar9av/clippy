import AppKit
import ClippyCore

/// End-to-end check that a multi-step plan really drives another app.
/// Unit tests cover the sequencing rules with a mock; this exercises the same
/// runner against live accessibility APIs, which nothing else can fake.
///
/// Run it with `CLIPPY_SELFTEST=1 /path/to/Clippy.app/Contents/MacOS/Clippy`.
/// It uses TextEdit and a scratch file, and exits when finished.
@MainActor
enum ScreenPlanSelfTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["CLIPPY_SELFTEST"] == "1"
    }

    private static var failures: [String] = []
    private static var transcript: [String] = []

    /// Launched from a terminal, the shell is the responsible process for TCC
    /// and the app reads as untrusted. The real run therefore goes through
    /// `open`, which detaches stdout — so everything is mirrored to a file.
    private static var reportURL: URL {
        if let path = ProcessInfo.processInfo.environment["CLIPPY_SELFTEST_LOG"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clippy-selftest-report.txt")
    }

    private static func log(_ line: String) {
        print(line)
        transcript.append(line)
        try? transcript.joined(separator: "\n").appending("\n")
            .write(to: reportURL, atomically: true, encoding: .utf8)
    }

    static func run() async -> Never {
        log("── Clippy screen-plan self test ──")

        guard AXIsProcessTrusted() else {
            log("SKIP: this binary is not trusted for Accessibility.")
            log("      Approve it in System Settings → Privacy & Security → Accessibility, then rerun.")
            exit(2)
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clippy-selftest.txt")
        try? "Clippy self test document\n".write(to: scratch, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(scratch)
        try? await Task.sleep(for: .seconds(2.5))

        let marker = "sequence-ok-\(Int(Date().timeIntervalSince1970))"
        await checkHappyPath(marker: marker)
        await checkHighlightGeometry()
        await checkStopsOnMissingTarget()
        await checkRefusesUnsafePlan()
        await checkAllowsTerminalActivation()

        log("──")
        if failures.isEmpty {
            log("PASS: all live checks succeeded.")
            exit(0)
        }
        for failure in failures { log("FAIL: \(failure)") }
        exit(1)
    }

    /// A five-step sequence: switch app, wait, type, wait, press a key —
    /// then read the field back to prove the text actually landed.
    private static func checkHappyPath(marker: String) async {
        let plan = PendingScreenPlan(
            summary: "Type a marker into TextEdit",
            steps: [
                ScreenPlanStep(action: .open, app: "TextEdit"),
                ScreenPlanStep(action: .wait, seconds: 1.0),
                ScreenPlanStep(action: .type, target: "text area", text: marker),
                ScreenPlanStep(action: .wait, seconds: 0.5),
                ScreenPlanStep(action: .key, key: .escape)
            ]
        )
        let runner = ScreenPlanRunner(performer: ScreenAwarenessService.shared)
        do {
            let completed = try await runner.run(plan) { progress in
                if progress.status == .running { log("  → \(progress.message)") }
            }
            guard completed == plan.steps.count else {
                failures.append("happy path ran \(completed) of \(plan.steps.count) steps")
                return
            }
            let value = (try? ScreenAwarenessService.shared.readValue(matching: "text area")) ?? ""
            if value.contains(marker) {
                log("  ✓ five-step sequence ran and the marker is in the document")
            } else {
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
                log("  · frontmost app after the plan: \(front)")
                log("  · resolver report: \(ScreenAwarenessService.shared.debugTargetReport(for: "text area"))")
                failures.append("marker not found in TextEdit after the plan (read back: \(value.prefix(80)))")
            }
        } catch {
            failures.append("happy path threw: \(error.localizedDescription)")
        }
    }

    /// The yellow callout has to sit on the control it names. Accessibility
    /// frames are top-left origin and global; the panel is bottom-left origin,
    /// so a wrong flip lands the ring somewhere else entirely.
    private static func checkHighlightGeometry() async {
        let report = await ScreenAwarenessService.shared.debugHighlightGeometry(for: "text area")
        log("  · highlight geometry: \(report)")
        guard let ax = ScreenAwarenessService.shared.debugLastProbeAXFrame,
              let panel = ScreenAwarenessService.shared.debugLastProbePanelFrame,
              let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.main else {
            failures.append("highlight geometry could not be measured (\(report))")
            return
        }
        // Expected Cocoa rect for the element, padded, with the caption strip
        // stacked above it.
        let padding: CGFloat = 7
        let labelHeight: CGFloat = 28
        let expected = CGRect(
            x: ax.minX - padding,
            y: screen.frame.maxY - ax.maxY - padding,
            width: ax.width + padding * 2,
            height: ax.height + padding * 2 + labelHeight
        )
        let drift = max(
            abs(expected.minX - panel.minX),
            max(abs(expected.minY - panel.minY),
                max(abs(expected.width - panel.width), abs(expected.height - panel.height)))
        )
        if drift <= 1 {
            log("  ✓ highlight lands on the control (drift \(Int(drift))pt)")
        } else {
            failures.append("highlight is off by \(Int(drift))pt — expected \(expected), got \(panel)")
        }
    }

    /// A control that does not exist must stop the sequence at that step and
    /// leave the following steps unrun.
    private static func checkStopsOnMissingTarget() async {
        let sentinel = "must-not-be-typed"
        let plan = PendingScreenPlan(
            summary: "Click something that isn't there",
            steps: [
                ScreenPlanStep(action: .click, target: "Nonexistent Control 12345"),
                ScreenPlanStep(action: .type, target: "text area", text: sentinel)
            ]
        )
        let runner = ScreenPlanRunner(performer: ScreenAwarenessService.shared)
        do {
            _ = try await runner.run(plan)
            failures.append("a missing target did not stop the plan")
        } catch let error as ScreenPlanError {
            guard case .stepFailed(let index, _, _) = error, index == 0 else {
                failures.append("expected stepFailed at step 1, got \(error)")
                return
            }
            let value = (try? ScreenAwarenessService.shared.readValue(matching: "text area")) ?? ""
            if value.contains(sentinel) {
                failures.append("the step after the failure still ran")
            } else {
                log("  ✓ stopped at the missing control and skipped the rest")
            }
        } catch {
            failures.append("unexpected error type: \(error)")
        }
    }

    private static func checkRefusesUnsafePlan() async {
        let plan = PendingScreenPlan(
            summary: "Send it",
            steps: [
                ScreenPlanStep(action: .type, target: "text area", text: "hello"),
                ScreenPlanStep(action: .click, target: "Send")
            ]
        )
        let runner = ScreenPlanRunner(performer: ScreenAwarenessService.shared)
        do {
            _ = try await runner.run(plan)
            failures.append("a plan ending in Send was allowed to run")
        } catch let error as ScreenPlanError {
            guard case .unsafeStep = error else {
                failures.append("expected unsafeStep, got \(error)")
                return
            }
            log("  ✓ refused the plan containing a Send step")
        } catch {
            failures.append("unexpected error type: \(error)")
        }
    }

    /// `AutomationSafety.blockedNameFragments`/`blockedBundleIdentifiers` are
    /// intentionally empty (see that file's doc comment) — Clippy is allowed
    /// to switch to and type into a terminal, with the no-Return rule as the
    /// residual guard against it running commands unattended. This check
    /// previously expected the opposite (asserting activation is refused),
    /// which directly contradicted
    /// `ScreenPlanRunnerTests.testAllowsTerminalsAsOpenTargetsSinceRestrictionWasIntentionallyDisabled`
    /// — the two test suites were asserting opposite contracts for the same
    /// behavior.
    private static func checkAllowsTerminalActivation() async {
        do {
            try await ScreenAwarenessService.shared.activateApp(named: "Terminal")
            log("  ✓ activated Terminal (typing is allowed; Return to it is not)")
        } catch {
            failures.append("Terminal activation was refused: \(error.localizedDescription)")
        }
    }
}
