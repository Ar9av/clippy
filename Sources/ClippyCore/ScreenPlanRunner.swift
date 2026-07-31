import Foundation
import CoreGraphics

/// The five things a plan step can ask of the screen. Splitting this out from
/// `ScreenAwarenessService` keeps the sequencing rules — ordering, validation,
/// stop-on-failure, cancellation — testable without accessibility permission.
@MainActor
public protocol ScreenStepPerforming: AnyObject {
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
    /// Scrolls the content under `point` (the captured window's centre when
    /// `nil`) by `ticks` wheel notches. Purely a viewport change — it commits
    /// nothing and destroys nothing, which is why it carries none of the
    /// final-action gating the click and type paths do. Conformers that don't
    /// need it get a default that does nothing, so a test double or a
    /// non-scrolling performer stays source-compatible.
    func scroll(_ direction: ScreenScrollDirection, ticks: Int, at point: CGPoint?) async throws
    func idle(_ seconds: Double) async throws
    /// Visually points out a control without clicking it — used by
    /// `ScreenAgent`'s `highlight_control` tool. Returns the resolved
    /// label (which may differ slightly from `label` once matched against
    /// the accessibility tree). Conformers that don't need this get a
    /// default that just echoes `label` back with no visible effect.
    func highlight(_ label: String) async throws -> String
}

extension ScreenStepPerforming {
    public func click(_ target: String, at point: CGPoint) async throws {
        try await click(target)
    }

    public func type(_ text: String, into target: String, pressReturnAfter: Bool) async throws {
        try await type(text, into: target)
    }

    public func type(_ text: String, into target: String, at point: CGPoint, pressReturnAfter: Bool) async throws {
        try await type(text, into: target, pressReturnAfter: pressReturnAfter)
    }

    public func highlight(_ label: String) async throws -> String {
        label
    }

    public func scroll(_ direction: ScreenScrollDirection, ticks: Int, at point: CGPoint?) async throws {}
}

public enum ScreenPlanError: LocalizedError, Equatable {
    case empty
    case tooManySteps(Int)
    case malformedStep(Int)
    case unsafeStep(Int, String)
    case restrictedApp(String)
    case outOfBounds(Int, String)
    case stepFailed(index: Int, description: String, reason: String)

    public var errorDescription: String? {
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
        case .outOfBounds(let index, let target):
            "Step \(index + 1) gave a position for “\(target)” outside the visible window."
        case .stepFailed(let index, let description, let reason):
            "Stopped at step \(index + 1) (\(description)): \(reason)"
        }
    }
}

/// Runs the steps of an approved plan in order, one at a time, and reports
/// progress as it goes. Any failure stops the sequence: a half-navigated
/// interface is not a safe place to keep clicking.
@MainActor
public final class ScreenPlanRunner {
    nonisolated public static let stepLimit = 10
    nonisolated public static let waitRange: ClosedRange<Double> = 0.1...8.0
    /// Bounded so a single step can't scroll a document to its end and lose
    /// the user's place. Several small scrolls with a fresh screenshot
    /// between them is also what makes the agent loop able to *find* things:
    /// one giant jump skips past the target without ever observing it.
    nonisolated public static let scrollTickRange: ClosedRange<Double> = 1...15
    nonisolated public static let defaultScrollTicks: Double = 5

    public struct Progress: Equatable {
        public let index: Int
        public let total: Int
        public let step: ScreenPlanStep
        public let status: ScreenPlanStepStatus

        public var message: String {
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

    public init(performer: ScreenStepPerforming, settleSeconds: Double = 0.45) {
        self.performer = performer
        self.settleSeconds = settleSeconds
    }

    /// Checked before the plan is ever shown for approval, and again before it
    /// runs, so an unsafe step can't slip in between the two. `bounds`, when
    /// given, is the captured window's frame — any step-supplied x/y outside
    /// it (with a small margin) is rejected rather than dispatched blind.
    nonisolated public static func validate(_ plan: PendingScreenPlan, bounds: CGRect? = nil, scale: CGFloat? = nil) throws {
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
                try Self.validatePoint(step, target: target, index: index, bounds: bounds, scale: scale)
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
                try Self.validatePoint(step, target: target, index: index, bounds: bounds, scale: scale)
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
            case .scroll:
                guard step.direction != nil else { throw ScreenPlanError.malformedStep(index) }
                if let amount = step.amount, !amount.isFinite || amount <= 0 {
                    throw ScreenPlanError.malformedStep(index)
                }
                // An out-of-window scroll point would send the wheel event to
                // whatever else happens to be under it, so it gets the same
                // bounds check a click does.
                try Self.validatePoint(
                    step,
                    target: step.target ?? "the content",
                    index: index,
                    bounds: bounds,
                    scale: scale
                )
            case .wait:
                guard waitRange.contains(step.seconds ?? 0.8) else {
                    throw ScreenPlanError.malformedStep(index)
                }
            }
        }
    }

    /// A step's x/y is optional, but when present it must be a finite point,
    /// and — when the caller has a window frame to check against — either
    /// inside that frame or resolvable to a point inside it by dividing out
    /// the screenshot scale (the same correction applied at dispatch time in
    /// `ScreenAwarenessService.resolvedPoint`).
    nonisolated private static func validatePoint(
        _ step: ScreenPlanStep,
        target: String,
        index: Int,
        bounds: CGRect?,
        scale: CGFloat?
    ) throws {
        guard let x = step.x, let y = step.y else { return }
        guard x.isFinite, y.isFinite else {
            throw ScreenPlanError.outOfBounds(index, target)
        }
        guard let bounds else { return }
        let point = CGPoint(x: x, y: y)
        let resolved = CoordinateSpace.resolvedPoint(point, windowFrame: bounds, scale: scale)
        guard CoordinateSpace.isWithinBounds(resolved, windowFrame: bounds) else {
            throw ScreenPlanError.outOfBounds(index, target)
        }
    }

    @discardableResult
    public func run(
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
        case .scroll:
            guard let direction = step.direction else { throw ScreenPlanError.malformedStep(0) }
            let requested = step.amount ?? Self.defaultScrollTicks
            let ticks = min(max(requested, Self.scrollTickRange.lowerBound), Self.scrollTickRange.upperBound)
            let point = (step.x.flatMap { x in step.y.map { CGPoint(x: x, y: $0) } })
            try await performer.scroll(direction, ticks: Int(ticks.rounded()), at: point)
        case .wait:
            // validate() already rejects any step whose seconds falls
            // outside waitRange, and run() always validates before this is
            // ever reached — the clamp here is pure defense-in-depth for a
            // future caller of perform() that skips validate, not a second,
            // looser policy. There is exactly one allowed range.
            try await performer.idle(min(max(step.seconds ?? 0.8, Self.waitRange.lowerBound), Self.waitRange.upperBound))
        }
    }
}
