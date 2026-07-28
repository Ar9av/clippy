import Foundation
import CoreGraphics

/// The five things a plan step can ask of the screen. Splitting this out from
/// `ScreenAwarenessService` keeps the sequencing rules — ordering, validation,
/// stop-on-failure, cancellation — testable without accessibility permission.
@MainActor
protocol ScreenStepPerforming: AnyObject {
    func openApp(named name: String) async throws
    func click(_ target: String) async throws
    /// Click at an exact screen point instead of resolving `target` through
    /// the accessibility tree — used when the model already knows where the
    /// control is from the screenshot, which is more reliable than a label
    /// match for generic/custom-drawn controls (e.g. a browser's address bar).
    /// Conformers that don't need this get a default that falls back to the
    /// label-only `click(_:)`.
    func click(_ target: String, at point: CGPoint) async throws
    func type(_ text: String, into target: String) async throws
    /// Same as `type(_:into:)`, but presses Return afterward. Only ever
    /// called when `AutomationSafety.isSafeAddressBarSubmit` has already
    /// confirmed this is a URL going into an address/search field — see
    /// `ScreenPlanRunner.validate`. Conformers that don't care about the
    /// distinction get a default that just types without submitting.
    func type(_ text: String, into target: String, pressReturnAfter: Bool) async throws
    /// Types by clicking an exact screen point first, bypassing accessibility
    /// label resolution for the destination entirely — see `click(_:at:)`
    /// for why that matters, and `ScreenAwarenessService.putAtPoint` for how
    /// this actually resolves the field once clicked. Conformers that don't
    /// need this get a default that falls back to the label-based type.
    func type(_ text: String, into target: String, at point: CGPoint, pressReturnAfter: Bool) async throws
    func press(_ key: ScreenPlanKey) async throws
    func idle(_ seconds: Double) async throws
}

extension ScreenStepPerforming {
    func click(_ target: String, at point: CGPoint) async throws {
        try await click(target)
    }

    func type(_ text: String, into target: String, pressReturnAfter: Bool) async throws {
        try await type(text, into: target)
    }

    func type(_ text: String, into target: String, at point: CGPoint, pressReturnAfter: Bool) async throws {
        try await type(text, into: target, pressReturnAfter: pressReturnAfter)
    }
}

/// The live implementation: every step goes through the same accessibility
/// service the single-step paths use, including its safety checks.
extension ScreenAwarenessService: ScreenStepPerforming {
    func openApp(named name: String) async throws {
        try await activateApp(named: name)
    }

    func click(_ target: String) async throws {
        try await runClick(matching: target)
    }

    func click(_ target: String, at point: CGPoint) async throws {
        try await clickAtPoint(point, label: target)
    }

    func type(_ text: String, into target: String) async throws {
        try await put(text, into: target)
    }

    func type(_ text: String, into target: String, pressReturnAfter: Bool) async throws {
        try await put(text, into: target, pressReturnAfter: pressReturnAfter)
    }

    func type(_ text: String, into target: String, at point: CGPoint, pressReturnAfter: Bool) async throws {
        try await putAtPoint(text, at: point, label: target, pressReturnAfter: pressReturnAfter)
    }

    func idle(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

enum ScreenPlanError: LocalizedError, Equatable {
    case empty
    case tooManySteps(Int)
    case malformedStep(Int)
    case unsafeStep(Int, String)
    case restrictedApp(String)
    case stepFailed(index: Int, description: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .empty:
            "That plan has no steps."
        case .tooManySteps(let limit):
            "A plan can run at most \(limit) steps."
        case .malformedStep(let index):
            "Step \(index + 1) is missing something it needs."
        case .unsafeStep(let index, let target):
            "Step \(index + 1) targets “\(target)”. Clippy stops before send, submit, payment, deletion, and password controls."
        case .restrictedApp(let name):
            "Clippy won't drive \(name) — terminals and agent CLIs run real commands."
        case .stepFailed(let index, let description, let reason):
            "Stopped at step \(index + 1) (\(description)): \(reason)"
        }
    }
}

/// Runs the steps of an approved plan in order, one at a time, and reports
/// progress as it goes. Any failure stops the sequence: a half-navigated
/// interface is not a safe place to keep clicking.
@MainActor
final class ScreenPlanRunner {
    nonisolated static let stepLimit = 10
    nonisolated static let waitRange: ClosedRange<Double> = 0.1...8.0

    struct Progress: Equatable {
        let index: Int
        let total: Int
        let step: ScreenPlanStep
        let status: ScreenPlanStepStatus

        var message: String {
            switch status {
            case .running: "Step \(index + 1) of \(total): \(step.displayText)"
            case .done: "Step \(index + 1) of \(total) done"
            case .failed: "Step \(index + 1) of \(total) failed"
            case .pending, .skipped: step.displayText
            }
        }
    }

    private let performer: ScreenStepPerforming
    /// Pause between steps so the app under automation can repaint and settle
    /// before the next target is resolved.
    private let settleSeconds: Double

    init(performer: ScreenStepPerforming, settleSeconds: Double = 0.45) {
        self.performer = performer
        self.settleSeconds = settleSeconds
    }

    /// Checked before the plan is ever shown for approval, and again before it
    /// runs, so an unsafe step can't slip in between the two.
    nonisolated static func validate(_ plan: PendingScreenPlan) throws {
        guard !plan.steps.isEmpty else { throw ScreenPlanError.empty }
        guard plan.steps.count <= stepLimit else {
            throw ScreenPlanError.tooManySteps(stepLimit)
        }
        for (index, step) in plan.steps.enumerated() {
            switch step.action {
            case .click:
                guard let target = step.target?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !target.isEmpty else {
                    throw ScreenPlanError.malformedStep(index)
                }
                guard !AutomationSafety.isFinalAction(target) else {
                    throw ScreenPlanError.unsafeStep(index, target)
                }
            case .type:
                guard let target = step.target?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !target.isEmpty,
                      let text = step.text, !text.isEmpty else {
                    throw ScreenPlanError.malformedStep(index)
                }
                guard !AutomationSafety.isFinalAction(target) else {
                    throw ScreenPlanError.unsafeStep(index, target)
                }
                // pressReturnAfter is the one narrow exception to "never send
                // Return" — only for text submitted into an address/search
                // field. Refuse silently downgrading it to a submit key
                // anywhere else in the plan.
                if step.pressReturnAfter == true,
                   !AutomationSafety.isSafeAddressBarSubmit(target: target, text: text) {
                    throw ScreenPlanError.unsafeStep(index, target)
                }
            case .open:
                guard let app = step.app?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !app.isEmpty else {
                    throw ScreenPlanError.malformedStep(index)
                }
                guard !AutomationSafety.isRestrictedName(app) else {
                    throw ScreenPlanError.restrictedApp(app)
                }
            case .key:
                guard step.key != nil else { throw ScreenPlanError.malformedStep(index) }
            case .wait:
                guard waitRange.contains(step.seconds ?? 0.8) else {
                    throw ScreenPlanError.malformedStep(index)
                }
            }
        }
    }

    @discardableResult
    func run(
        _ plan: PendingScreenPlan,
        onProgress: (Progress) -> Void = { _ in }
    ) async throws -> Int {
        try Self.validate(plan)
        let total = plan.steps.count
        var completed = 0

        for (index, step) in plan.steps.enumerated() {
            try Task.checkCancellation()
            onProgress(Progress(index: index, total: total, step: step, status: .running))
            do {
                try await perform(step)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onProgress(Progress(index: index, total: total, step: step, status: .failed))
                throw ScreenPlanError.stepFailed(
                    index: index,
                    description: step.displayText,
                    reason: error.localizedDescription
                )
            }
            completed += 1
            onProgress(Progress(index: index, total: total, step: step, status: .done))

            // No settle after the last step, and none after an explicit wait —
            // the plan already said how long to pause there.
            if index < total - 1, step.action != .wait, settleSeconds > 0 {
                try await performer.idle(settleSeconds)
            }
        }
        return completed
    }

    private func perform(_ step: ScreenPlanStep) async throws {
        switch step.action {
        case .click:
            if let x = step.x, let y = step.y {
                try await performer.click(step.target ?? "the control", at: CGPoint(x: x, y: y))
            } else {
                try await performer.click(step.target ?? "")
            }
        case .type:
            let shouldPressReturn = step.pressReturnAfter == true
                && AutomationSafety.isSafeAddressBarSubmit(
                    target: step.target ?? "",
                    text: step.text ?? ""
                )
            if let x = step.x, let y = step.y {
                try await performer.type(
                    step.text ?? "",
                    into: step.target ?? "the field",
                    at: CGPoint(x: x, y: y),
                    pressReturnAfter: shouldPressReturn
                )
            } else {
                try await performer.type(
                    step.text ?? "",
                    into: step.target ?? "",
                    pressReturnAfter: shouldPressReturn
                )
            }
        case .open:
            try await performer.openApp(named: step.app ?? "")
        case .key:
            guard let key = step.key else { throw ScreenPlanError.malformedStep(0) }
            try await performer.press(key)
        case .wait:
            try await performer.idle(min(max(step.seconds ?? 0.8, Self.waitRange.lowerBound), Self.waitRange.upperBound))
        }
    }
}
