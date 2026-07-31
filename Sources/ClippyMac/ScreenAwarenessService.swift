import AppKit
import ApplicationServices
import ClippyCore
import ScreenCaptureKit

@MainActor
final class ScreenAwarenessService {
    static let shared = ScreenAwarenessService()

    private struct ResolvedElement {
        let summary: ScreenElementSummary
        let element: AXUIElement
        let processIdentifier: pid_t
    }

    private var activationMonitor: Any?
    private var deactivationMonitor: Any?
    private var mouseMonitor: Any?
    private var lastExternalApplication: NSRunningApplication?
    private var resolvedElements: [UUID: ResolvedElement] = [:]
    private var highlightedElementID: UUID?
    private let highlightController = ScreenHighlightController()
    /// The window frame and screenshot scale from the most recent
    /// `captureContext()` — used to validate and, if needed, correct
    /// model-supplied x/y coordinates before a click is ever dispatched.
    private var lastWindowFrame: CGRect?
    private var lastScreenshotScale: CGFloat?

    private init() {}

    func startTracking() {
        guard activationMonitor == nil else { return }
        activationMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard application.bundleIdentifier != Bundle.main.bundleIdentifier,
                      application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      application.bundleIdentifier != "com.apple.systempreferences",
                      !AutomationSafety.isRestricted(application) else {
                    return
                }
                self?.lastExternalApplication = application
            }
        }
        deactivationMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard application.bundleIdentifier != Bundle.main.bundleIdentifier,
                      application.processIdentifier
                        != ProcessInfo.processInfo.processIdentifier,
                      application.bundleIdentifier != "com.apple.systempreferences",
                      !AutomationSafety.isRestricted(application) else {
                    return
                }
                self?.lastExternalApplication = application
            }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] _ in
            let point = CGEvent(source: nil)?.location ?? .zero
            let systemWide = AXUIElementCreateSystemWide()
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                systemWide,
                Float(point.x),
                Float(point.y),
                &element
            ) == .success,
                  let element else { return }
            var processIdentifier: pid_t = 0
            guard AXUIElementGetPid(element, &processIdentifier) == .success,
                  processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let application = NSRunningApplication(
                    processIdentifier: processIdentifier
                  ),
                  application.bundleIdentifier != Bundle.main.bundleIdentifier,
                  !AutomationSafety.isRestricted(application) else {
                return
            }
            Task { @MainActor in
                self?.lastExternalApplication = application
            }
        }
        if let application = NSWorkspace.shared.frontmostApplication,
           application.bundleIdentifier != Bundle.main.bundleIdentifier,
           !AutomationSafety.isRestricted(application) {
            lastExternalApplication = application
        }
    }

    var canSeeScreen: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestPermissions() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        _ = CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func captureContext() async throws -> ScreenContext {
        guard AXIsProcessTrusted() else {
            requestPermissions()
            throw ScreenAwarenessError.accessibilityPermission
        }
        guard CGPreflightScreenCaptureAccess() else {
            requestPermissions()
            throw ScreenAwarenessError.screenRecordingPermission
        }
        guard let application = topmostExternalApplication(includeRestricted: true)
                ?? lastExternalApplication else {
            throw ScreenAwarenessError.noExternalApp
        }
        // Only remember this as the action-resolution fallback when it's a
        // legitimate target. `lastExternalApplication` also backs
        // `refreshSpatialMap()`'s fallback for click/type resolution, and
        // that path must never end up pointed at a terminal even when it's
        // the only other window on screen.
        if !AutomationSafety.isRestricted(application) {
            lastExternalApplication = application
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows
            .filter({ $0.owningApplication?.processID == application.processIdentifier })
            .filter({ $0.frame.width > 80 && $0.frame.height > 80 })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else {
            throw ScreenAwarenessError.noWindow
        }

        // Capture every attached display in full, not just the active window.
        // The window alone left anything on a second monitor invisible — a
        // request about "the other screen" had nothing to look at.
        let anchorDisplay = content.displays.first { $0.frame.intersects(window.frame) }
            ?? content.displays.first
        guard let anchorDisplay else { throw ScreenAwarenessError.noWindow }

        let elements = scan(application: application, limitedTo: window.frame)
        let directory = try contextDirectory()
        let identifier = UUID().uuidString

        var displayShots: [DisplayShot] = []
        for display in content.displays {
            let isAnchor = display.displayID == anchorDisplay.displayID
            let url = directory.appendingPathComponent(
                "Screen-\(identifier)-\(display.displayID).png"
            )
            do {
                let shot = try await captureDisplay(display, to: url, isAnchor: isAnchor)
                // Anchor first, so a consumer taking one image gets the one
                // being acted on.
                if isAnchor { displayShots.insert(shot, at: 0) } else { displayShots.append(shot) }
            } catch {
                // One unreadable display (just unplugged, mid-mode-change)
                // must not cost the user the rest of the observation.
                if isAnchor { throw error }
            }
        }
        guard let anchorShot = displayShots.first else {
            throw ScreenAwarenessError.noWindow
        }
        // Actions are bounded to the display holding the active window, and
        // model-supplied x/y are read in that display's point space.
        let actionBounds = anchorShot.frame
        let scale = anchorShot.scale

        let windowTitle = window.title?.isEmpty == false ? window.title! : "Untitled"
        let otherApps = Self.otherRunningApplications(excluding: application)
        let promptLimit = 140
        let shown = ScreenElementSummary.promptOrdered(elements, limit: promptLimit)
        let truncationNote = elements.count > shown.count
            ? "\n…and \(elements.count - shown.count) more controls not listed. Anything you need that isn't here may simply be off screen — scroll and look again."
            : ""
        let displayLines = displayShots.enumerated().map { index, shot in
            "- Image \(index + 1): \(shot.name)\(shot.isAnchor ? " (active — the one you can act on)" : "")"
                + " covering x \(Int(shot.frame.minX)) to \(Int(shot.frame.maxX)),"
                + " y \(Int(shot.frame.minY)) to \(Int(shot.frame.maxY))"
        }.joined(separator: "\n")
        let spatialText = """
        Current app: \(application.localizedName ?? "Unknown")
        Current window: \(windowTitle)
        Window frame: x \(Int(window.frame.minX)), y \(Int(window.frame.minY)), width \(Int(window.frame.width)), height \(Int(window.frame.height))

        Attached screenshots — one per display, in this order. All coordinates \
        below (and every x/y you give back) are in one shared point space that \
        spans every display, so a control on a second monitor simply has a \
        larger x than one on the first:
        \(displayLines)
        The active display's image is \(String(format: "%.2f", scale))x its point size (e.g. a point at x=10 on it is at pixel x=\(String(format: "%.0f", 10 * scale)) in that image) — any x/y you give must be in the shared point space above, never raw image pixels.
        You can see every display, but you can only act on the active one: a click or type must land inside x \(Int(actionBounds.minX)) to \(Int(actionBounds.maxX)), y \(Int(actionBounds.minY)) to \(Int(actionBounds.maxY)). To act on something you can see on another display, first switch to the app that owns it.

        Other open apps (already running — prefer switching to one of these over launching a new instance, and reuse an already-open tab/document when the task fits it): \
        \(otherApps.isEmpty ? "none" : otherApps.joined(separator: ", "))

        Visible actionable controls (screen coordinates, in reading order). A control's current \
        contents appear after "=", and toggles show [checked]/[unchecked] — check these before \
        acting, so you don't retype a field that already holds the right text or click a switch \
        that is already on:
        \(shown.map(\.contextLine).joined(separator: "\n"))\(truncationNote)

        Use the screenshots for appearance and this list for precise labels and positions.
        """
        let contextURL = directory.appendingPathComponent("Screen-Context-\(identifier).txt")
        try spatialText.write(to: contextURL, atomically: true, encoding: .utf8)

        lastWindowFrame = actionBounds
        lastScreenshotScale = scale

        return ScreenContext(
            appName: application.localizedName ?? "the current app",
            windowTitle: windowTitle,
            contextURL: contextURL,
            elements: elements,
            displayShots: displayShots,
            windowFrame: actionBounds,
            screenshotScale: scale
        )
    }

    /// Captures one display whole, downscales it, and writes it out.
    private func captureDisplay(
        _ display: SCDisplay,
        to url: URL,
        isAnchor: Bool
    ) async throws -> DisplayShot {
        let screen = NSScreen.screens.first { $0.frame.intersects(display.frame) }
        let backingScale = screen?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(display.frame.width * backingScale))
        configuration.height = max(1, Int(display.frame.height * backingScale))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let image = try await SCScreenshotManager.captureImage(
            // Exclude nothing: the point of a full-display shot is to show
            // what is actually there, including windows of other apps.
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
        // See `downscaledForModel` — encoding a full 4K display at native
        // resolution would cost far more than the detail is worth, and the
        // API downsamples past this bound on arrival anyway.
        let modelImage = Self.downscaledForModel(image)
        try writePNG(modelImage, to: url)

        // Derive the ratio from the image actually written, not the display's
        // backing scale — every coordinate correction downstream keys off it.
        let scale = display.frame.width > 0
            ? CGFloat(modelImage.width) / CGFloat(display.frame.width)
            : backingScale
        return DisplayShot(
            name: screen?.localizedName ?? "Display \(display.displayID)",
            url: url,
            frame: display.frame,
            scale: scale,
            isAnchor: isAnchor
        )
    }

    @discardableResult
    func highlight(matching query: String, instruction: String? = nil) throws -> String {
        let resolved = try resolve(query)
        highlightedElementID = resolved.summary.id
        highlightController.show(
            around: resolved.summary.frame,
            label: instruction ?? "Here — \(resolved.summary.label)"
        )
        return resolved.summary.label
    }

    func clickHighlighted() throws {
        guard let highlightedElementID,
              let resolved = resolvedElements[highlightedElementID] else {
            throw ScreenAwarenessError.targetUnavailable
        }
        guard resolved.summary.enabled else {
            throw ScreenAwarenessError.targetUnavailable
        }
        guard !AutomationSafety.isFinalAction(resolved.summary.label) else {
            throw ScreenAwarenessError.unsafeAction(resolved.summary.label)
        }
        let result = AXUIElementPerformAction(
            resolved.element,
            kAXPressAction as CFString
        )
        if result != .success {
            let center = CGPoint(
                x: resolved.summary.frame.midX,
                y: resolved.summary.frame.midY
            )
            guard let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: center,
                mouseButton: .left
            ), let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: center,
                mouseButton: .left
            ) else {
                throw ScreenAwarenessError.targetUnavailable
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        highlightController.dismiss()
        self.highlightedElementID = nil
    }

    func runClick(matching query: String) async throws {
        guard !AutomationSafety.isFinalAction(query) else {
            throw ScreenAwarenessError.unsafeAction(query)
        }
        try await waitForTarget(query)
        _ = try highlight(matching: query, instruction: "Clippy is clicking \(query)")
        try clickHighlighted()
        try await Task.sleep(for: .milliseconds(750))
    }

    /// Clicks a raw screen point instead of resolving a label through the
    /// accessibility tree. Custom-drawn controls (browser toolbars, canvas
    /// UIs, some Electron apps) often expose no usable AX label at all, or
    /// one that doesn't match what a model would guess from the screenshot —
    /// this is the fallback for exactly that case, the same way a person
    /// would just click where they can see the control.
    func clickAtPoint(_ point: CGPoint, label: String) async throws {
        try await guardedRawClick(at: point, label: label, highlightLabel: "Clippy is clicking \(label)")
        try await Task.sleep(for: .milliseconds(750))
    }

    /// Types by clicking a raw screen point first, then handing off to
    /// `ScreenTypingService` — completely bypassing accessibility-label
    /// resolution for the destination. AX labels are frequently wrong for
    /// this: they vary across app/browser versions, and some pages put a
    /// decoy control with an identical-looking label right next to the real
    /// one (e.g. a page's own embedded search box next to a browser's actual
    /// address bar, both reading "Search Google or type a URL"). A literal
    /// click can't be fooled by either problem — `ScreenTypingService`'s
    /// global mouse-down monitor resolves whatever is really at that pixel
    /// via `AXUIElementCopyElementAtPosition`, the same way a person clicking
    /// there would land on it, then reuses its already-robust multi-strategy
    /// insertion (AX value write, then paste, with the read-back-unavailable
    /// tolerance already in place) to actually type the text.
    func putAtPoint(
        _ text: String,
        at point: CGPoint,
        label: String,
        pressReturnAfter: Bool
    ) async throws {
        try await guardedRawClick(at: point, label: label, highlightLabel: "Clippy is typing into \(label)")
        // Give ScreenTypingService's global mouse-down monitor a moment to
        // resolve and capture the element actually at this point before
        // acting on it — that capture is dispatched asynchronously.
        try await Task.sleep(for: .milliseconds(220))
        // The click was posted at a model-supplied coordinate with no
        // confirmation it actually landed on an editable field — if the
        // coordinate space was off, the click could have hit anything.
        // Verify an editable, non-secure element was really captured before
        // ever touching its contents; a miss throws instead of blindly
        // clearing whatever happens to be frontmost.
        do {
            try ScreenTypingService.shared.verifiedNonSecureTarget()
        } catch ScreenTypingError.secureField {
            throw ScreenAwarenessError.unsafeAction(label)
        } catch {
            throw ScreenAwarenessError.notEditable(label)
        }
        // ScreenTypingService.insert replaces the current selection (or
        // inserts at the cursor if nothing's selected) — it never clears the
        // field itself. A real click on a browser's address bar auto-selects
        // its whole contents, but a synthetic click isn't guaranteed to
        // trigger that app-specific behavior, so leftover text from an
        // earlier attempt at this same field would otherwise get appended to
        // instead of replaced (e.g. a retry producing "ar9avar9av").
        try await clearField()
        _ = try await ScreenTypingService.shared.insert(text)
        if pressReturnAfter, AutomationSafety.isSafeAddressBarSubmit(target: label, text: text) {
            try await pressReturnKey()
        }
    }

    /// Shared by `clickAtPoint` and `putAtPoint`: the restricted-app refusal,
    /// app activation, and the actual move/down/up click posted at the HID
    /// tap (indistinguishable from a real click to any global event monitor,
    /// which is what lets `ScreenTypingService` pick it up).
    private func guardedRawClick(at point: CGPoint, label: String, highlightLabel: String) async throws {
        guard !AutomationSafety.isFinalAction(label) else {
            throw ScreenAwarenessError.unsafeAction(label)
        }
        let point = CoordinateSpace.resolvedPoint(point, windowFrame: lastWindowFrame, scale: lastScreenshotScale)
        guard CoordinateSpace.isWithinBounds(point, windowFrame: lastWindowFrame) else {
            throw ScreenAwarenessError.targetUnavailable
        }
        // This bypasses `refreshSpatialMap`'s label resolution entirely, so
        // it needs its own copy of the same check: refuse outright rather
        // than activating and clicking into whatever app was last legitimately
        // remembered while a restricted terminal is actually frontmost.
        if let restrictedFrontmost = topmostExternalApplication(includeRestricted: true),
           AutomationSafety.isRestricted(restrictedFrontmost) {
            throw ScreenAwarenessError.restrictedApp(
                restrictedFrontmost.localizedName ?? "this app"
            )
        }
        if let application = topmostExternalApplication() ?? lastExternalApplication {
            NSRunningApplication(processIdentifier: application.processIdentifier)?
                .activate(options: [.activateAllWindows])
            try await Task.sleep(for: .milliseconds(180))
        }
        highlightController.show(around: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2), label: highlightLabel)
        guard let moved = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            highlightController.dismiss()
            throw ScreenAwarenessError.targetUnavailable
        }
        moved.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(60))
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        highlightController.dismiss()
    }

    /// Mid-sequence, a target usually doesn't exist yet: the previous click is
    /// still opening a menu, a sheet, or a new pane. Re-scan on a short cycle
    /// instead of failing the whole plan on the first miss.
    func waitForTarget(_ query: String, timeout: Double = 6.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = ScreenAwarenessError.targetNotFound(query)
        repeat {
            do {
                try refreshSpatialMap()
                _ = try resolve(query)
                return
            } catch let error as ScreenAwarenessError {
                lastError = error
                switch error {
                case .accessibilityPermission, .screenRecordingPermission, .restrictedApp:
                    // Waiting won't grant a permission, and it won't make the
                    // frontmost app stop being a terminal either.
                    throw error
                default:
                    // Everything else is ordinary mid-sequence churn: an app
                    // still launching, a window not yet on screen, a pane still
                    // being built. Keep re-scanning until the deadline.
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
        } while Date() < deadline
        throw lastError
    }

    /// Brings an app to the front (launching it if needed) so the following
    /// steps resolve against its windows.
    func activateApp(named name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !AutomationSafety.isRestrictedName(trimmed) else {
            throw ScreenAwarenessError.restrictedApp(trimmed)
        }
        let normalized = trimmed.lowercased()
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular
                && ($0.localizedName ?? "").lowercased() == normalized
        }) ?? NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular
                && ($0.localizedName ?? "").lowercased().contains(normalized)
        }) {
            guard !AutomationSafety.isRestricted(running) else {
                throw ScreenAwarenessError.restrictedApp(trimmed)
            }
            running.activate(options: [.activateAllWindows])
            // `NSRunningApplication.activate` is unreliable when the caller
            // isn't frontmost: recent macOS refuses focus transfers requested
            // by a background app, and refuses them *silently*. That is how a
            // "switch to <app>" step reported success while nothing moved —
            // waitUntilReady's fallback only checks that a window exists, not
            // that the app actually came forward. Re-opening the bundle is the
            // supported way to raise an already-running app, so fall back to
            // it whenever the direct activation didn't take.
            try? await Task.sleep(for: .milliseconds(150))
            if !running.isActive, let bundleURL = running.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try? await NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: configuration
                )
            }
            lastExternalApplication = running
            try await waitUntilReady(running)
            return
        }

        let candidates = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("\(trimmed).app") }
        guard let bundleURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw ScreenAwarenessError.appNotFound(trimmed)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let application = try await NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration
        )
        lastExternalApplication = application
        try await waitUntilReady(application)
    }

    /// A freshly launched app answers accessibility queries before its window
    /// is really usable. Wait for it to be frontmost with a focused window
    /// rather than guessing with a fixed sleep — that guess is what makes a
    /// cold-start sequence type into the wrong place.
    private func waitUntilReady(_ application: NSRunningApplication, timeout: Double = 6.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if application.isActive,
               focusedWindowFrame(for: application.processIdentifier) != nil {
                // One more beat so the window finishes laying out its content.
                try await Task.sleep(for: .milliseconds(250))
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard focusedWindowFrame(for: application.processIdentifier) != nil
                || largestVisibleWindowFrame(for: application.processIdentifier) != nil else {
            throw ScreenAwarenessError.noWindow
        }
    }

    /// Posts one navigation keystroke. `ScreenPlanKey` has no Return case, so
    /// this can move focus or dismiss a sheet but never commit a form.
    func press(_ key: ScreenPlanKey) async throws {
        guard AXIsProcessTrusted() else {
            throw ScreenAwarenessError.accessibilityPermission
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: false) else {
            throw ScreenAwarenessError.targetUnavailable
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(140))
    }

    /// Scrolls the content under `point`, defaulting to the centre of the
    /// captured window. Nothing here can commit, send, or destroy anything —
    /// it only changes what is visible — so unlike click and type this has no
    /// final-action gate. It keeps the restricted-app refusal, because
    /// scrolling a terminal still means synthesising input into one.
    func scrollContent(
        _ direction: ScreenScrollDirection,
        ticks: Int,
        at point: CGPoint?
    ) async throws {
        guard AXIsProcessTrusted() else {
            throw ScreenAwarenessError.accessibilityPermission
        }
        if let restrictedFrontmost = topmostExternalApplication(includeRestricted: true),
           AutomationSafety.isRestricted(restrictedFrontmost) {
            throw ScreenAwarenessError.restrictedApp(
                restrictedFrontmost.localizedName ?? "this app"
            )
        }
        // A scroll wheel event goes to whatever sits under the pointer, not
        // to the focused app — so the pointer has to be over the target
        // window first, or the scroll silently lands somewhere else.
        let resolved = point.map {
            CoordinateSpace.resolvedPoint($0, windowFrame: lastWindowFrame, scale: lastScreenshotScale)
        } ?? lastWindowFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        guard let target = resolved else {
            throw ScreenAwarenessError.noWindow
        }
        guard CoordinateSpace.isWithinBounds(target, windowFrame: lastWindowFrame) else {
            throw ScreenAwarenessError.targetUnavailable
        }
        if let application = topmostExternalApplication() ?? lastExternalApplication {
            NSRunningApplication(processIdentifier: application.processIdentifier)?
                .activate(options: [.activateAllWindows])
            try await Task.sleep(for: .milliseconds(120))
        }
        if let moved = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left
        ) {
            moved.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(60))
        }

        let delta = direction.unitDelta
        // One event per tick rather than a single large delta: apps with
        // momentum or snap-to-item scrolling (Finder icon views, many web
        // views) treat one big jump very differently from a real flick, and
        // some ignore an oversized delta outright.
        for _ in 0..<max(1, ticks) {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 2,
                wheel1: delta.vertical,
                wheel2: delta.horizontal,
                wheel3: 0
            ) else {
                throw ScreenAwarenessError.targetUnavailable
            }
            event.location = target
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(40))
        }
        // Let the view settle — and any lazily-rendered content load — before
        // the agent loop takes its next screenshot, or it observes the scroll
        // mid-flight and re-scrolls past what it was looking for.
        try await Task.sleep(for: .milliseconds(400))
    }

    func put(_ text: String, into query: String) async throws {
        try await put(text, into: query, pressReturnAfter: false)
    }

    /// `pressReturnAfter` must only ever arrive here already validated by
    /// `AutomationSafety.isSafeAddressBarSubmit` — this function does not
    /// re-check the target/text shape itself, since by the time a
    /// `ScreenPlanStep` reaches the performer, `ScreenPlanRunner.validate`
    /// and the safety re-check right before dispatch have already refused
    /// anything that isn't a URL going into an address/search field.
    func put(_ text: String, into query: String, pressReturnAfter: Bool) async throws {
        try await waitForTarget(query)
        let resolved = try resolve(query, preferEditable: true)
        let role = stringAttribute(kAXRoleAttribute, from: resolved.element) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute, from: resolved.element) ?? ""
        guard !AutomationSafety.isSecureField(role: role, subrole: subrole) else {
            throw ScreenAwarenessError.unsafeAction(query)
        }
        let editableRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        guard editableRoles.contains(role)
                || isSettable(kAXValueAttribute as CFString, on: resolved.element) else {
            throw ScreenAwarenessError.notEditable(query)
        }

        NSRunningApplication(processIdentifier: resolved.processIdentifier)?
            .activate(options: [.activateAllWindows])
        try await Task.sleep(for: .milliseconds(180))
        AXUIElementSetAttributeValue(
            resolved.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        try await Task.sleep(for: .milliseconds(80))

        let result = AXUIElementSetAttributeValue(
            resolved.element,
            kAXValueAttribute as CFString,
            text as CFString
        )
        if result == .success {
            try await Task.sleep(for: .milliseconds(160))
            if stringAttribute(kAXValueAttribute, from: resolved.element) == text {
                if pressReturnAfter {
                    try await pressReturnKey()
                    highlightController.show(around: resolved.summary.frame, label: "Navigating to \(text)")
                } else {
                    highlightController.show(
                        around: resolved.summary.frame,
                        label: "Text added — Clippy did not submit it"
                    )
                }
                return
            }
        }

        // Chromium content-editable composers often ignore AX focus/value writes.
        // Clicking the already-resolved field gives the browser a real caret
        // before the controlled paste below. This never targets Send.
        try clickForTextEntry(resolved)
        try await Task.sleep(for: .milliseconds(90))
        try await paste(text, into: resolved)

        // Confirm the text is really there. Silently "succeeding" is worse than
        // failing inside a sequence: later steps would keep clicking through an
        // interface that never received the input. A field that exposes no
        // readable value at all (some web composers) is accepted as before.
        try await Task.sleep(for: .milliseconds(160))
        if let written = stringAttribute(kAXValueAttribute, from: resolved.element),
           !written.contains(text) {
            throw ScreenAwarenessError.textNotAccepted(query)
        }
        if pressReturnAfter {
            try await pressReturnKey()
            highlightController.show(around: resolved.summary.frame, label: "Navigating to \(text)")
        } else {
            highlightController.show(
                around: resolved.summary.frame,
                label: "Text added — Clippy did not submit it"
            )
        }
    }

    /// Posted only after `AutomationSafety.isSafeAddressBarSubmit` has already
    /// confirmed the field and text are going into an address/search bar —
    /// see the doc comment on `put(_:into:pressReturnAfter:)`.
    private func pressReturnKey() async throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else {
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Cmd+A then Delete. Used before a coordinate-driven type so the
    /// field's existing content is actually gone before typing, rather than
    /// relying on `ScreenTypingService.insert` correctly reading back a
    /// "selection" this just posted — reading `kAXSelectedTextRangeAttribute`
    /// immediately after a synthetic Cmd+A is its own race (the app may not
    /// have updated it yet), and a select-without-delete that loses that
    /// race silently degrades back to an append at the cursor instead of a
    /// replace — exactly what produced "ar9avar9av". Actually emptying the
    /// field removes the dependency on that race entirely: insert() then has
    /// nothing to append to.
    private func clearField() async throws {
        guard let selectDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let selectUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false),
              let deleteDown = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true),
              let deleteUp = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false) else {
            return
        }
        selectDown.flags = .maskCommand
        selectUp.flags = .maskCommand
        selectDown.post(tap: .cghidEventTap)
        selectUp.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(150))
        deleteDown.post(tap: .cghidEventTap)
        deleteUp.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(150))
    }

    /// Re-scan immediately before writing a drafted reply. Web apps frequently
    /// rebuild their composer while a model is generating, so a stale snapshot
    /// can point at a search field instead of the message box.
    ///
    /// `near` is the model's own [[CLIPPY_REPLY_AT:x,y]] hint (already
    /// resolved into window-space by the caller) — accessibility-label
    /// matching goes first because it's more precise when it works, but a
    /// web app's composer (a `contenteditable` div, e.g. LinkedIn's message
    /// box) frequently exposes an inconsistent or empty AX role/label that
    /// `preferredReplyTarget` can't match at all. Reusing the same
    /// point-based dispatch `ScreenPlanRunner` already relies on for exactly
    /// this case (see `ScreenPlanStep.x`/`.y`) means a screenshot-only click
    /// still lands correctly instead of silently only ever answering in
    /// Clippy's own chat.
    @discardableResult
    func putReplyDraft(_ text: String, near point: CGPoint? = nil) async throws -> String {
        let elements = try refreshSpatialMap()
        if let target = preferredReplyTarget(in: elements) {
            try await put(text, into: target)
            return target
        }
        if let point {
            try await putAtPoint(text, at: point, label: "reply box", pressReturnAfter: false)
            return "reply box"
        }
        throw ScreenAwarenessError.targetNotFound("message box")
    }

    @discardableResult
    func refreshSpatialMap() throws -> [ScreenElementSummary] {
        guard AXIsProcessTrusted() else {
            throw ScreenAwarenessError.accessibilityPermission
        }
        // Distinguish "nothing else is on screen" from "the frontmost window
        // belongs to a restricted app" — the latter must refuse outright,
        // not silently fall back to whatever legitimate app was last
        // remembered. Resolving a click/type target against some unrelated
        // app the user isn't even looking at is worse than a clear refusal.
        if let restrictedFrontmost = topmostExternalApplication(includeRestricted: true),
           AutomationSafety.isRestricted(restrictedFrontmost) {
            throw ScreenAwarenessError.restrictedApp(
                restrictedFrontmost.localizedName ?? "this app"
            )
        }
        guard let application = topmostExternalApplication()
                ?? lastExternalApplication else {
            throw ScreenAwarenessError.noExternalApp
        }
        lastExternalApplication = application
        // Scan the focused window's own subtree. Walking the whole application
        // instead pulls in controls from background windows that merely overlap
        // this one — with cascaded documents that means several identical
        // "TextArea" candidates and an arbitrary winner.
        let focusedWindow = focusedWindowElement(for: application.processIdentifier)
        let focusedFrame = focusedWindowFrame(for: application.processIdentifier)
        let largestFrame = largestVisibleWindowFrame(for: application.processIdentifier)

        // Clicking a browser's address bar (or similar) can hand AX focus to
        // its own autocomplete/suggestions dropdown — a real, on-screen
        // window, just not the one the actual target lives in. A "focused"
        // window far smaller than the app's largest one is much more likely
        // to be exactly that kind of transient popup than the surface the
        // task is actually working in, so fall back to scanning the whole
        // app rather than just that popup's subtree.
        if let focusedFrame, let largestFrame,
           focusedFrame.width * focusedFrame.height < 0.5 * largestFrame.width * largestFrame.height {
            return scan(application: application, root: nil, limitedTo: largestFrame)
        }

        guard let frame = focusedFrame ?? largestFrame else {
            throw ScreenAwarenessError.noWindow
        }
        return scan(application: application, root: focusedWindow, limitedTo: frame)
    }

    /// Diagnostics for the self test: the accessibility frame of a target, the
    /// frame the highlight panel actually took, and the screen it flipped
    /// against — enough to tell a mis-resolved element from a bad conversion.
    private(set) var debugLastProbeAXFrame: CGRect?
    private(set) var debugLastProbePanelFrame: CGRect?

    func debugHighlightGeometry(for query: String) async -> String {
        debugLastProbeAXFrame = nil
        debugLastProbePanelFrame = nil
        do {
            try refreshSpatialMap()
            let resolved = try resolve(query)
            let ax = resolved.summary.frame
            debugLastProbeAXFrame = ax
            highlightController.show(around: ax, label: "geometry probe")
            // The callout appears only after the marker finishes flying to it.
            try? await Task.sleep(for: .milliseconds(900))
            let panel = highlightController.debugPanelFrame
            debugLastProbePanelFrame = panel
            let screens = NSScreen.screens.map {
                "screen(origin=\(Int($0.frame.minX)),\(Int($0.frame.minY)) size=\(Int($0.frame.width))x\(Int($0.frame.height)))"
            }.joined(separator: " ")
            return "ax=\(rectString(ax)) panel=\(panel.map(rectString) ?? "nil") \(screens)"
        } catch {
            return "unresolved: \(error.localizedDescription)"
        }
    }

    private func rectString(_ rect: CGRect) -> String {
        "(x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height)))"
    }

    /// Diagnostics for the self test: which element a query resolves to, and
    /// whether its value can be written directly.
    func debugTargetReport(for query: String) -> String {
        do {
            try refreshSpatialMap()
            let resolved = try resolve(query)
            let role = stringAttribute(kAXRoleAttribute, from: resolved.element) ?? "?"
            let settable = isSettable(kAXValueAttribute as CFString, on: resolved.element)
            let app = NSRunningApplication(processIdentifier: resolved.processIdentifier)?
                .localizedName ?? "?"
            return "app=\(app) role=\(role) label=\(resolved.summary.label) valueSettable=\(settable)"
        } catch {
            return "unresolved: \(error.localizedDescription)"
        }
    }

    /// Reads a control's current value. Used to verify that a plan actually
    /// changed what it claimed to change.
    func readValue(matching query: String) throws -> String {
        try refreshSpatialMap()
        let resolved = try resolve(query)
        return stringAttribute(kAXValueAttribute, from: resolved.element) ?? ""
    }

    func dismissHighlight() {
        highlightController.dismiss()
        highlightedElementID = nil
    }

    /// Returns the most likely writable field from the current accessibility snapshot.
    /// This avoids relying on an AI provider to guess a label from a screenshot.
    func preferredEditableTarget(in elements: [ScreenElementSummary]) -> String? {
        elements
            .filter { $0.enabled && Self.isEditableRole($0.role) }
            .sorted { left, right in
                let leftScore = Self.editableScore(left)
                let rightScore = Self.editableScore(right)
                if leftScore != rightScore { return leftScore > rightScore }
                return left.frame.maxY > right.frame.maxY
            }
            .first?
            .label
    }

    /// A reply may only go into a conversation composer. Browser address bars,
    /// page search, and application search fields are intentionally excluded.
    func preferredReplyTarget(in elements: [ScreenElementSummary]) -> String? {
        elements
            .filter { element in
                guard element.enabled && Self.isEditableRole(element.role) else { return false }
                let label = Self.normalized(element.label)
                let isBrowserOrSearch = ["address", "search", "find"].contains(where: label.contains)
                let isComposer = element.role == "TextArea"
                    || ["message", "reply", "compose", "comment", "write"].contains(where: label.contains)
                return isComposer && !isBrowserOrSearch
            }
            .sorted { left, right in
                let leftScore = Self.replyScore(left)
                let rightScore = Self.replyScore(right)
                if leftScore != rightScore { return leftScore > rightScore }
                return left.frame.maxY > right.frame.maxY
            }
            .first?
            .label
    }

    private func resolve(_ query: String, preferEditable: Bool = false) throws -> ResolvedElement {
        let normalizedQuery = Self.normalized(query)
        // `preferEditable` is set by callers that already know this is a typing
        // action (`put`), so a phrase like "address bar" that doesn't literally
        // say "field"/"box" still gets biased toward the real editable control
        // instead of a same-named toolbar label or group.
        let isFieldIntent = preferEditable || Self.isFieldIntent(normalizedQuery)
        let candidates = resolvedElements.values.filter(\.summary.enabled)
        let ranked = candidates.map { candidate -> (ResolvedElement, Int) in
            let score = Self.matchScore(
                query: normalizedQuery,
                label: candidate.summary.label,
                role: candidate.summary.role,
                isFieldIntent: isFieldIntent
            )
            return (candidate, score)
        }
        guard let best = ranked.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
            throw ScreenAwarenessError.targetNotFound(query)
        }
        return best.0
    }

    /// The word-overlap + role-bias scoring `resolve()` ranks candidates by,
    /// pulled out as a pure function of plain values (no `ResolvedElement`/
    /// `AXUIElement`) so it's testable without accessibility permission.
    /// `query` is expected already-normalized (see `normalized(_:)`); `label`
    /// and `role` are raw as read off the accessibility tree.
    nonisolated static func matchScore(query normalizedQuery: String, label: String, role: String, isFieldIntent: Bool) -> Int {
        let queryWords = Set(normalizedQuery.split(separator: " ").map(String.init))
        let normalizedLabel = Self.normalized(label)
        let labelWords = Set(normalizedLabel.split(separator: " ").map(String.init))
        var score = queryWords.intersection(labelWords).count * 10
        if normalizedLabel == normalizedQuery { score += 100 }
        if normalizedLabel.contains(normalizedQuery) || normalizedQuery.contains(normalizedLabel) { score += 35 }
        if isFieldIntent, Self.isEditableRole(role) {
            // macOS often calls a chat composer “TextArea” or exposes only
            // its placeholder, so use the real editable control.
            score += 80
            if role == "TextArea" { score += 20 }
        }
        // Break ties toward a purpose-built control. The scan also keeps
        // structural roles that merely answer to a press (a pressable label
        // or table cell), which is what makes custom web and Electron UI
        // reachable — but when a real Button and a same-named StaticText both
        // match, the Button is what the user means, and without this the
        // winner between two equal scores is whichever the tree happened to
        // yield first.
        if score > 0, Self.primaryInteractiveRoles.contains(role) { score += 5 }
        return score
    }

    /// Roles that exist to be interacted with, as opposed to the structural
    /// ones the scan's press probe can also turn up. See `matchScore`.
    nonisolated static let primaryInteractiveRoles: Set<String> = [
        "Button", "CheckBox", "RadioButton", "PopUpButton", "ComboBox",
        "TextField", "TextArea", "Link", "MenuItem", "MenuBarItem",
        "DisclosureTriangle", "Slider", "Incrementor", "MenuButton",
        "Switch", "SearchField"
    ]

    /// `includeRestricted: false` (the default) is for anything that will
    /// act on the result — click, type, or resolve targets — so a terminal
    /// or agent CLI is never a valid destination. `includeRestricted: true`
    /// is only for read-only screen capture: silently substituting a
    /// different, unrelated app in its place would be more confusing than
    /// just showing the user what's actually on their screen. See
    /// `AutomationSafety`'s doc comment — the risk it guards against is
    /// writing into a terminal, not looking at one.
    private func topmostExternalApplication(includeRestricted: Bool = false) -> NSRunningApplication? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0,
                  let rawPID = window[kCGWindowOwnerPID as String] as? NSNumber else {
                continue
            }
            let processIdentifier = pid_t(rawPID.int32Value)
            guard processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let application = NSRunningApplication(
                    processIdentifier: processIdentifier
                  ),
                  application.activationPolicy == .regular,
                  includeRestricted || !AutomationSafety.isRestricted(application) else {
                continue
            }
            return application
        }
        return nil
    }

    /// The window the app itself considers focused. With several documents
    /// open, the largest window is often not the one in front — acting on it
    /// means typing into a document the user isn't looking at.
    private func focusedWindowElement(for processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &window
        ) == .success, let window else { return nil }
        return unsafeBitCast(window, to: AXUIElement.self)
    }

    private func focusedWindowFrame(for processIdentifier: pid_t) -> CGRect? {
        guard let element = focusedWindowElement(for: processIdentifier),
              let rect = frame(of: element),
              rect.width > 80, rect.height > 80 else {
            return nil
        }
        return rect
    }

    private func largestVisibleWindowFrame(for processIdentifier: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return windows.compactMap { window -> CGRect? in
            guard let rawPID = window[kCGWindowOwnerPID as String] as? NSNumber,
                  rawPID.int32Value == processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? NSNumber,
                  let y = bounds["Y"] as? NSNumber,
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber else {
                return nil
            }
            return CGRect(
                x: x.doubleValue,
                y: y.doubleValue,
                width: width.doubleValue,
                height: height.doubleValue
            )
        }
        .filter { $0.width > 80 && $0.height > 80 }
        .max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    private func paste(_ text: String, into resolved: ResolvedElement) async throws {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            throw ScreenAwarenessError.accessibilityPermission
        }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        defer {
            pasteboard.clearContents()
            let restored = previous.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !restored.isEmpty {
                pasteboard.writeObjects(restored)
            }
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: false
        ) else {
            throw ScreenAwarenessError.targetUnavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(220))
        let value = stringAttribute(kAXValueAttribute, from: resolved.element)
        guard value?.contains(text) == true else {
            throw ScreenAwarenessError.targetUnavailable
        }
    }

    private func clickForTextEntry(_ resolved: ResolvedElement) throws {
        let center = CGPoint(
            x: resolved.summary.frame.midX,
            y: resolved.summary.frame.midY
        )
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: center,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: center,
            mouseButton: .left
        ) else {
            throw ScreenAwarenessError.targetUnavailable
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func isSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }

    nonisolated private static func isEditableRole(_ role: String) -> Bool {
        ["TextField", "TextArea", "ComboBox"].contains(role)
    }

    private static func isFieldIntent(_ query: String) -> Bool {
        ["field", "text box", "textbox", "text area", "textarea", "prompt", "composer", "input", "message box"].contains {
            query.contains($0)
        }
    }

    private static func editableScore(_ element: ScreenElementSummary) -> Int {
        var score = element.role == "TextArea" ? 30 : 20
        let label = normalized(element.label)
        if ["prompt", "message", "ask", "type", "reply", "do anything"].contains(where: label.contains) {
            score += 40
        }
        return score
    }

    private static func replyScore(_ element: ScreenElementSummary) -> Int {
        let label = normalized(element.label)
        var score = element.role == "TextArea" ? 80 : 0
        if label.contains("message") { score += 50 }
        if label.contains("reply") { score += 50 }
        if label.contains("compose") || label.contains("write") { score += 35 }
        return score
    }

    private func scan(
        application: NSRunningApplication,
        root: AXUIElement? = nil,
        limitedTo windowFrame: CGRect
    ) -> [ScreenElementSummary] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        // Accessibility calls block on the target app answering, and the
        // default timeout is measured in seconds. One busy app — a browser
        // mid-layout, an Electron app doing work on its main thread — could
        // therefore hang a whole scan, and with it the user's request. Cap
        // how long any single read may wait: a control that can't answer
        // promptly is treated as absent, which is far better than a request
        // that appears to have frozen.
        AXUIElementSetMessagingTimeout(appElement, Self.axMessagingTimeout)
        var roots: [AXUIElement] = []
        if let root {
            roots.append(root)
            // Menus sit outside the window subtree, and an open menu is a
            // legitimate click target mid-sequence. Add that branch only —
            // not the whole app, which is what pulled in sibling windows.
            var menuBar: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                appElement,
                kAXMenuBarAttribute as CFString,
                &menuBar
            ) == .success, let menuBar {
                roots.append(unsafeBitCast(menuBar, to: AXUIElement.self))
            }
        } else {
            roots.append(appElement)
        }
        var queue: [(AXUIElement, Int)] = roots.map { ($0, 0) }
        var head = 0
        var results: [ResolvedElement] = []
        var visited = Set<CFHashCode>()
        var pressProbes = 0

        while head < queue.count && results.count < Self.maxScannedElements {
            // Nothing worth finding is behind a tree this large, and an
            // unbounded walk of a big web view would stall every request.
            guard visited.count < Self.maxVisitedNodes else { break }
            let (element, depth) = queue[head]
            head += 1
            let hash = CFHash(element)
            guard visited.insert(hash).inserted else { continue }
            let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
            // Decide from the role alone whether this node is even worth
            // reading further. Every attribute below costs an accessibility
            // round trip, and the overwhelming majority of nodes in a web or
            // Electron tree are structural groups — reading frames and labels
            // for those would make the scan cost several times what it does
            // for the handful of nodes that can actually be acted on.
            let isKnownActionable = Self.actionableRoles.contains(role)
            // Roles that are usually structural but that some frameworks make
            // clickable. Worth the extra reads only while the probe budget
            // holds out.
            let isProbeCandidate = !isKnownActionable
                && Self.pressProbeRoles.contains(role)
                && pressProbes < Self.maxPressProbes
            if isKnownActionable || isProbeCandidate {
                // Menus and menu-bar items live outside the window's own frame
                // by definition, so they're exempt from the intersection test
                // that keeps everything else clipped to the window being
                // worked in.
                let isMenuRole = Self.menuRoles.contains(role)
                // One round trip for everything this node needs, rather than
                // one per attribute. Each accessibility read is IPC into the
                // target app, so a scan that touched nine attributes across
                // nine calls spent almost all of its time waiting.
                let details = nodeDetails(of: element)
                if let frame = details.frame,
                   frame.width >= 4,
                   frame.height >= 4,
                   frame.intersects(windowFrame) || isMenuRole {
                    let label = details.label

                    // A probe candidate only counts if it both carries a name
                    // and actually answers to a press — that's how a
                    // custom-drawn control in an Electron or web view gets
                    // found, since those routinely render a real button as a
                    // named image or cell that no role list would ever match.
                    var isActionable = isKnownActionable
                    if !isActionable, label != nil {
                        pressProbes += 1
                        isActionable = supportsPress(element)
                    }

                    if isActionable {
                        let summary = ScreenElementSummary(
                            id: UUID(),
                            label: label ?? role.replacingOccurrences(of: "AX", with: ""),
                            role: role.replacingOccurrences(of: "AX", with: ""),
                            frame: frame,
                            enabled: details.enabled ?? true,
                            value: Self.readableValue(details.value, role: role),
                            checked: Self.checkedState(details.value, role: role),
                            focused: details.focused ?? false
                        )
                        results.append(ResolvedElement(
                            summary: summary,
                            element: element,
                            processIdentifier: application.processIdentifier
                        ))
                    }
                }
            }
            guard depth < Self.maxScanDepth else { continue }
            queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
        }

        resolvedElements = Dictionary(uniqueKeysWithValues: results.map { ($0.summary.id, $0) })
        return results.map(\.summary)
    }

    /// Web and Electron content sits far deeper than a native window's own
    /// controls: an AXWebArea's buttons are routinely 15-plus levels below the
    /// window. The old limit of 9 stopped short of nearly all of it, which is
    /// why page content so often looked "not on screen" to the agent and every
    /// browser interaction had to fall back to raw coordinates.
    private static let maxScanDepth = 26
    private static let maxScannedElements = 300
    private static let maxVisitedNodes = 9000
    /// The press probe costs one extra accessibility round trip per candidate,
    /// so it gets its own budget rather than riding the node budget.
    private static let maxPressProbes = 400
    /// Long enough that a healthy app always answers, short enough that a
    /// stalled one can't hold up the request. Applies per accessibility read.
    private static let axMessagingTimeout: Float = 0.25

    private static let actionableRoles: Set<String> = [
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXComboBoxRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXLink",
        kAXMenuItemRole as String,
        // Without this the top-level menu titles (File, Edit, View) are
        // invisible, so a menu can never be opened in the first place — only
        // the items inside one that already happens to be open.
        kAXMenuBarItemRole as String,
        kAXTabGroupRole as String,
        kAXDisclosureTriangleRole as String,
        kAXSliderRole as String,
        kAXIncrementorRole as String,
        kAXMenuButtonRole as String,
        "AXSwitch",
        "AXSearchField"
    ]

    /// Roles that are usually structural but that web and app frameworks
    /// sometimes make clickable. Candidates here are only kept if they carry a
    /// name *and* answer to a press.
    private static let pressProbeRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXImageRole as String,
        kAXCellRole as String,
        kAXRowRole as String,
        "AXHeading"
    ]

    private func supportsPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    /// Everything the scan needs about one node, fetched together.
    private struct NodeDetails {
        var frame: CGRect?
        var label: String?
        var enabled: Bool?
        var focused: Bool?
        /// Raw `AXValue` — a string for a text field, a 0/1 number for a
        /// toggle. Interpreted by role, since the attribute is shared.
        var value: CFTypeRef?
    }

    private static let nodeAttributes: [String] = [
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXHelpAttribute as String,
        kAXPlaceholderValueAttribute as String,
        kAXEnabledAttribute as String,
        kAXFocusedAttribute as String,
        kAXValueAttribute as String
    ]

    /// Reads every attribute the scan cares about in a single accessibility
    /// call. `AXUIElementCopyMultipleAttributeValues` returns one entry per
    /// requested name, substituting an error placeholder for any the element
    /// doesn't implement — those simply fail their casts below and stay nil,
    /// which is the same outcome the one-at-a-time reads produced.
    private func nodeDetails(of element: AXUIElement) -> NodeDetails {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            Self.nodeAttributes as CFArray,
            AXCopyMultipleAttributeOptions(),
            &raw
        ) == .success,
            let values = raw as? [CFTypeRef],
            values.count == Self.nodeAttributes.count else {
            // Some elements refuse the batch call; fall back rather than
            // silently dropping a control that is really there.
            return NodeDetails(
                frame: frame(of: element),
                label: label(of: element),
                enabled: boolAttribute(kAXEnabledAttribute, from: element),
                focused: boolAttribute(kAXFocusedAttribute, from: element),
                value: copyAttribute(kAXValueAttribute, from: element)
            )
        }

        var details = NodeDetails()
        if let position = Self.point(from: values[0]), let size = Self.size(from: values[1]) {
            details.frame = CGRect(origin: position, size: size)
        }
        details.label = values[2...5]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        details.enabled = values[6] as? Bool
        details.focused = values[7] as? Bool
        details.value = values[8]
        return details
    }

    nonisolated private static func point(from value: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    nonisolated private static func size(from value: CFTypeRef) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    /// A control's current contents, when reading them is meaningful. Toggles
    /// are excluded because their value is the 0/1 that `checkedState`
    /// already reports in a readable form.
    nonisolated private static func readableValue(_ value: CFTypeRef?, role: String) -> String? {
        let valueRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            kAXPopUpButtonRole as String,
            "AXSearchField"
        ]
        guard valueRoles.contains(role), let value else { return nil }
        return value as? String
    }

    nonisolated private static func checkedState(_ value: CFTypeRef?, role: String) -> Bool? {
        let toggleRoles: Set<String> = [
            kAXCheckBoxRole as String,
            kAXRadioButtonRole as String,
            "AXSwitch"
        ]
        guard toggleRoles.contains(role), let value, let number = value as? NSNumber else {
            return nil
        }
        return number.intValue != 0
    }

    private func label(of element: AXUIElement) -> String? {
        [
            stringAttribute(kAXTitleAttribute, from: element),
            stringAttribute(kAXDescriptionAttribute, from: element),
            stringAttribute(kAXHelpAttribute, from: element),
            stringAttribute(kAXPlaceholderValueAttribute, from: element)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return value
    }

    private static let menuRoles: Set<String> = [
        kAXMenuItemRole as String,
        kAXMenuBarItemRole as String
    ]

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeValue
              ) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(
            unsafeBitCast(positionValue, to: AXValue.self),
            .cgPoint,
            &position
        ), AXValueGetValue(
            unsafeBitCast(sizeValue, to: AXValue.self),
            .cgSize,
            &size
        ) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func contextDirectory() throws -> URL {
        let directory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Clippy/ScreenContext", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// The longest edge a screenshot is worth encoding at. Matches the bound
    /// the API downsamples to on arrival, so going above it costs encode time,
    /// disk, upload, and tokens while adding no detail the model can use.
    nonisolated static let maxScreenshotDimension = 1568

    /// Shrinks an oversized capture, preserving aspect ratio exactly (one
    /// scale factor for both axes) so screen points map onto image pixels by a
    /// single multiplier. A capture already within the bound is returned
    /// untouched and stays pixel-exact.
    nonisolated static func downscaledForModel(_ image: CGImage) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxScreenshotDimension else { return image }
        let ratio = Double(maxScreenshotDimension) / Double(longest)
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            // Better a slow correct screenshot than none at all.
            return image
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ScreenAwarenessError.noWindow
        }
        try data.write(to: url, options: .atomic)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? Bool
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lets the model choose to switch to an already-running app instead of
    /// defaulting to "open a new instance" for every plan step.
    private static func otherRunningApplications(excluding current: NSRunningApplication) -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.processIdentifier != current.processIdentifier }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !AutomationSafety.isRestricted($0) }
            .compactMap(\.localizedName)
            .reduce(into: [String]()) { result, name in
                if !result.contains(name) { result.append(name) }
            }
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

    func scroll(_ direction: ScreenScrollDirection, ticks: Int, at point: CGPoint?) async throws {
        try await scrollContent(direction, ticks: ticks, at: point)
    }

    func idle(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    func highlight(_ label: String) async throws -> String {
        try highlight(matching: label)
    }
}

/// Sits just below macOS's drag-image layer instead of `.screenSaver`. A
/// `.screenSaver`-level overlay renders above active drag previews too, which
/// makes SwiftUI/AppKit drop targets elsewhere on the system fail to see
/// themselves as the drop destination while Clippy's highlight is visible.
private func clippyOverlayWindowLevel() -> NSWindow.Level {
    NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) - 1)
}

/// Marks the screen-highlight windows so `AppDelegate`'s pointer-passthrough
/// pass leaves them alone. They live in `NSApplication.shared.windows` like any
/// other window, and re-enabling mouse events on a screen-sized overlay makes
/// every click land on the highlight instead of the app underneath.
let clippyOverlayWindowIdentifier = NSUserInterfaceItemIdentifier("clippy.screen-overlay")

/// A small triangle marker used only to show, in flight, which element
/// Clippy is about to highlight. Purely decorative — never intercepts events.
private final class TriangleMarkerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let shape = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: frameRect.width / 2, y: frameRect.height))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: frameRect.width, y: 0))
        path.closeSubpath()
        shape.path = path
        shape.fillColor = NSColor.systemYellow.cgColor
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0.35
        shape.shadowRadius = 3
        shape.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class ScreenHighlightController {
    private var panel: NSPanel?
    private var flightWindow: NSWindow?
    private var flightTimer: Timer?
    private var autoDismissTimer: Timer?

    var debugPanelFrame: CGRect? { panel?.frame }

    func show(around frame: CGRect, label: String) {
        dismiss()
        let screenForTarget = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
        let destination = CGPoint(
            x: frame.midX,
            y: screenForTarget.map { $0.frame.maxY - frame.midY } ?? frame.midY
        )
        animateFlight(to: destination) { [weak self] in
            self?.showCallout(around: frame, label: label)
        }
    }

    /// Flies a small marker from wherever the real cursor currently is to the
    /// target element, so it's obvious at a glance which screen/window Clippy
    /// is about to act on — especially useful with more than one display.
    private func animateFlight(to destination: CGPoint, onComplete: @escaping () -> Void) {
        let unionFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !unionFrame.isNull, !unionFrame.isEmpty else {
            onComplete()
            return
        }

        let start = NSEvent.mouseLocation
        let startLocal = CGPoint(x: start.x - unionFrame.minX, y: start.y - unionFrame.minY)
        let endLocal = CGPoint(x: destination.x - unionFrame.minX, y: destination.y - unionFrame.minY)
        let distance = hypot(endLocal.x - startLocal.x, endLocal.y - startLocal.y)

        guard distance > 12 else {
            onComplete()
            return
        }

        let window = NSWindow(
            contentRect: unionFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.identifier = clippyOverlayWindowIdentifier
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.level = clippyOverlayWindowLevel()
        window.setFrame(unionFrame, display: true)

        let markerSize: CGFloat = 22
        let marker = TriangleMarkerView(frame: CGRect(x: 0, y: 0, width: markerSize, height: markerSize))
        let root = NSView(frame: CGRect(origin: .zero, size: unionFrame.size))
        root.wantsLayer = true
        root.addSubview(marker)
        marker.setFrameOrigin(CGPoint(x: startLocal.x - markerSize / 2, y: startLocal.y - markerSize / 2))
        window.contentView = root
        window.orderFrontRegardless()
        flightWindow = window

        let duration = min(max(distance / 2200.0, 0.16), 0.5)
        let frameInterval = 1.0 / 60.0
        let totalFrames = max(1, Int(duration / frameInterval))
        var currentFrame = 0
        let midX = (startLocal.x + endLocal.x) / 2
        let midY = (startLocal.y + endLocal.y) / 2
        let arcHeight = min(distance * 0.18, 60)
        let controlPoint = CGPoint(x: midX, y: midY + arcHeight)

        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                currentFrame += 1
                guard currentFrame <= totalFrames else {
                    timer.invalidate()
                    self?.flightTimer = nil
                    self?.dismissFlight()
                    onComplete()
                    return
                }
                let linear = Double(currentFrame) / Double(totalFrames)
                let eased = linear * linear * (3.0 - 2.0 * linear)
                let oneMinusT = 1.0 - eased
                let x = oneMinusT * oneMinusT * startLocal.x
                    + 2 * oneMinusT * eased * controlPoint.x
                    + eased * eased * endLocal.x
                let y = oneMinusT * oneMinusT * startLocal.y
                    + 2 * oneMinusT * eased * controlPoint.y
                    + eased * eased * endLocal.y
                marker.setFrameOrigin(CGPoint(x: x - markerSize / 2, y: y - markerSize / 2))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flightTimer = timer
    }

    private func dismissFlight() {
        flightTimer?.invalidate()
        flightTimer = nil
        flightWindow?.orderOut(nil)
        flightWindow = nil
    }

    private func showCallout(around frame: CGRect, label: String) {
        // A match that spans most of a display is a container (a whole window,
        // a web view, a scroll area), not a control. Ringing it paints the
        // entire screen yellow and tells the user nothing, so show a compact
        // banner near the top of that region instead.
        let screenForTarget = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
            ?? NSScreen.main
        if let screenFrame = screenForTarget?.frame,
           frame.width > screenFrame.width * 0.8,
           frame.height > screenFrame.height * 0.8 {
            showBanner(over: frame, on: screenFrame, label: label)
            return
        }

        let padding: CGFloat = 7
        let labelHeight: CGFloat = 28
        let panelFrame = CGRect(
            x: frame.minX - padding,
            y: NSScreen.screens.first(where: { $0.frame.intersects(frame) })
                .map { $0.frame.maxY - frame.maxY - padding } ?? frame.minY - padding,
            width: frame.width + padding * 2,
            height: frame.height + padding * 2 + labelHeight
        )
        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = clippyOverlayWindowIdentifier
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = clippyOverlayWindowLevel()
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let root = NSView(frame: CGRect(origin: .zero, size: panelFrame.size))
        root.wantsLayer = true
        let box = NSView(frame: CGRect(
            x: 1,
            y: 1,
            width: panelFrame.width - 2,
            height: panelFrame.height - labelHeight - 2
        ))
        box.wantsLayer = true
        box.layer?.borderColor = NSColor.systemYellow.cgColor
        box.layer?.borderWidth = 4
        box.layer?.cornerRadius = 9
        box.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.09).cgColor
        root.addSubview(box)

        let caption = NSTextField(labelWithString: label)
        caption.frame = CGRect(
            x: 4,
            y: panelFrame.height - labelHeight,
            width: panelFrame.width - 8,
            height: labelHeight
        )
        caption.alignment = .center
        caption.textColor = .black
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        caption.backgroundColor = .systemYellow
        caption.isBezeled = false
        caption.drawsBackground = true
        caption.lineBreakMode = .byTruncatingTail
        root.addSubview(caption)

        panel.contentView = root
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleAutoDismiss()
    }

    /// Compact stand-in for the full ring when the resolved element is the size
    /// of the whole window. Sized to the caption, never wider than the screen.
    private func showBanner(over frame: CGRect, on screenFrame: CGRect, label: String) {
        let height: CGFloat = 28
        let width = min(max(CGFloat(label.count) * 7.5 + 32, 180), screenFrame.width - 40)
        let bannerFrame = CGRect(
            x: frame.midX - width / 2,
            y: screenFrame.maxY - frame.minY - height - 12,
            width: width,
            height: height
        )
        let panel = NSPanel(
            contentRect: bannerFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = clippyOverlayWindowIdentifier
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = clippyOverlayWindowLevel()
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let root = NSView(frame: CGRect(origin: .zero, size: bannerFrame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.systemYellow.cgColor
        root.layer?.cornerRadius = 7

        let caption = NSTextField(labelWithString: label)
        caption.frame = CGRect(x: 8, y: 4, width: bannerFrame.width - 16, height: height - 8)
        caption.alignment = .center
        caption.textColor = .black
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        caption.isBezeled = false
        caption.drawsBackground = false
        caption.lineBreakMode = .byTruncatingTail
        root.addSubview(caption)

        panel.contentView = root
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleAutoDismiss()
    }

    /// Safety net: a highlight left behind by a failed or abandoned action would
    /// otherwise sit on top of every app until the next explicit dismiss.
    private func scheduleAutoDismiss() {
        autoDismissTimer?.invalidate()
        let timer = Timer(timeInterval: 12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoDismissTimer = timer
    }

    func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        dismissFlight()
        panel?.orderOut(nil)
        panel = nil
    }
}
