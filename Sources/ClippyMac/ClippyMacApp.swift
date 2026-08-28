import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isExpanded = false
    private var isCompactBalloonVisible = true
    private var pointerPassthroughTimer: Timer?
    /// The balloon's actual rendered size, relayed live from SwiftUI via
    /// `clippyBalloonContentSizeChanged`. Falls back to the full compact
    /// window size until the first measurement arrives, so nothing regresses
    /// for the one frame before that notification fires.
    private var balloonContentSize = CGSize(width: 250, height: 340)
    /// In-flight poll for the newly-activated app's display, cancelled when a
    /// later activation supersedes it.
    private var followTask: Task<Void, Never>?
    /// Mirrors ContentView's `.padding(.bottom, 3)` on the compact layout. Kept
    /// here so the pointer hit region and the drawn content stay in agreement.
    private static let compactBottomInset: CGFloat = 3

    /// macOS only prevents a second launch of the *same* bundle, so an updated
    /// copy in /Applications and an older one elsewhere both run happily under
    /// one bundle identifier — two paperclips, two balloons, each acting on
    /// the same screen and each writing the same files in Application Support.
    /// Hand off to whichever got here first and leave.
    ///
    /// The self test is exempt: it drives a scratch document to completion and
    /// exits, and it has to be runnable while an ordinary Clippy is up.
    @MainActor
    private func yieldToRunningInstance() -> Bool {
        guard !ScreenPlanSelfTest.isRequested,
              let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return false }
        existing.activate(options: [.activateAllWindows])
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A shortcut capture can never survive an app launch. This is also a
        // belt-and-braces reset for builds from before capture state became
        // in-memory-only.
        DictationShortcutCapture.isActive = false
        UserDefaults.standard.removeObject(forKey: "isRecordingDictationShortcut")
        if yieldToRunningInstance() {
            NSApp.terminate(nil)
            return
        }
        if ScreenPlanSelfTest.isRequested {
            Task { await ScreenPlanSelfTest.run() }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.configureWindows(expanded: false)
            self?.startPointerPassthroughMonitoring()
        }
        NotificationCenter.default.addObserver(
            forName: .clippyWindowLevelChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.configureWindows()
        }
        NotificationCenter.default.addObserver(
            forName: .clippyExpansionChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let expanded = notification.object as? Bool ?? false
            self?.isExpanded = expanded
            self?.configureWindows(expanded: expanded)
        }
        NotificationCenter.default.addObserver(
            forName: .clippyBalloonVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let visible = notification.object as? Bool ?? true
            self?.isCompactBalloonVisible = visible
            UserDefaults.standard.set(visible, forKey: "compactBalloonVisible")
            self?.updatePointerPassthrough()
        }
        NotificationCenter.default.addObserver(
            forName: .clippyBalloonContentSizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let size = notification.object as? CGSize else { return }
            self?.balloonContentSize = size
            self?.updatePointerPassthrough()
        }
        // Follow the display you're actually working on. `.canJoinAllSpaces`
        // above only spans Spaces — an NSWindow still lives on exactly one
        // screen, so on a multi-monitor setup Clippy would otherwise stay
        // stranded on whichever display it started on.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification
                .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.followActiveScreen(of: application)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reclaimOffscreenWindows()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pointerPassthroughTimer?.invalidate()
    }

    private func configureWindows(expanded: Bool? = nil) {
        let floating = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        for window in NSApplication.shared.windows {
            // Settings/History present as `.sheet(isPresented:)`, which are
            // real NSWindows in `NSApplication.shared.windows` — without this
            // guard they got the same transparent-background, no-shadow,
            // hidden-titlebar-buttons, forced-floating-level, forced-resize
            // treatment as the main balloon/chat window, which is why the
            // Settings sheet used to render with broken chrome.
            guard !window.isSheet else { continue }
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            window.level = (!isExpanded || floating) ? .floating : .normal
            window.isMovableByWindowBackground = true
            // The app supplies its own complete title bar. `.fullSizeContentView`
            // lets the hosting view extend under the native title region so the
            // custom blue caption isn't pushed below an empty strip. Keep
            // `.titled` — a borderless window can't become key, which silently
            // kills all keyboard input in the chat text field.
            window.styleMask = [.titled, .fullSizeContentView, .resizable, .miniaturizable]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            if let expanded {
                resize(window, expanded: expanded)
            }
        }
        updatePointerPassthrough()
    }

    private func resize(_ window: NSWindow, expanded: Bool) {
        let size = expanded
            ? NSSize(width: 360, height: 500)
            : NSSize(width: 250, height: 340)
        let oldFrame = window.frame
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? oldFrame
        let origin = NSPoint(
            x: min(max(oldFrame.maxX - size.width, screenFrame.minX), screenFrame.maxX - size.width),
            y: min(max(oldFrame.minY, screenFrame.minY), screenFrame.maxY - size.height)
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
    }

    /// Moves Clippy onto the display holding the app the user just switched
    /// to. Driven by app activation rather than raw cursor position, so the
    /// character doesn't chase the pointer around while you work.
    private func followActiveScreen(of application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        // Supersede any in-flight poll so rapid app switching resolves against
        // the app the user actually landed on.
        followTask?.cancel()
        followTask = Task { @MainActor [weak self] in
            // The activated app's window is routinely absent from
            // CGWindowList at the instant the notification fires — the window
            // server hasn't published it yet — and it's absent for longer when
            // the app is launching or restoring a window. Resolving once and
            // giving up silently did nothing at all; poll briefly instead.
            for attempt in 0..<8 {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(120))
                }
                guard !Task.isCancelled, let self else { return }
                guard let target = self.screenForFrontmostWindow(of: application) else { continue }
                self.moveClippyWindows(onto: target)
                return
            }
        }
    }

    private func moveClippyWindows(onto target: NSScreen) {
        for window in NSApplication.shared.windows {
            guard !window.isSheet, window.identifier != clippyOverlayWindowIdentifier else { continue }
            // Comparing against the window's live screen rather than a cached
            // "current display" keeps this correct when the window was dragged
            // to another monitor by hand.
            guard window.screen != target else { continue }
            reposition(window, onto: target)
        }
        updatePointerPassthrough()
    }

    /// Unplugging a display leaves `window.screen` nil and the window parked in
    /// coordinates nothing owns any more, which reads as Clippy vanishing.
    private func reclaimOffscreenWindows() {
        guard let fallback = NSScreen.main else { return }
        for window in NSApplication.shared.windows {
            guard !window.isSheet, window.identifier != clippyOverlayWindowIdentifier else { continue }
            guard window.screen == nil else { continue }
            reposition(window, onto: fallback)
        }
        updatePointerPassthrough()
    }

    /// Keeps the window's position *proportional* to the display it came from,
    /// so a Clippy parked bottom-right stays bottom-right on a monitor of a
    /// different size instead of landing somewhere arbitrary.
    private func reposition(_ window: NSWindow, onto screen: NSScreen) {
        let destination = screen.visibleFrame
        let size = window.frame.size
        let slackX = max(destination.width - size.width, 0)
        let slackY = max(destination.height - size.height, 0)

        var fractionX = 1.0
        var fractionY = 0.0
        if let origin = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
           origin.width > size.width, origin.height > size.height {
            fractionX = (window.frame.minX - origin.minX) / (origin.width - size.width)
            fractionY = (window.frame.minY - origin.minY) / (origin.height - size.height)
        }

        window.setFrameOrigin(
            NSPoint(
                x: destination.minX + min(max(fractionX, 0), 1) * slackX,
                y: destination.minY + min(max(fractionY, 0), 1) * slackY
            )
        )
    }

    /// The screen showing `application`'s frontmost window. `CGWindowList`
    /// bounds are top-left origin measured from the primary display, whereas
    /// `NSScreen.frame` is bottom-left origin — hence the flip before testing
    /// containment.
    private func screenForFrontmostWindow(of application: NSRunningApplication) -> NSScreen? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let frames = windows.compactMap { window -> CGRect? in
            guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
                  pid.int32Value == application.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 80, rect.height > 80 else { return nil }
            return rect
        }
        // `optionOnScreenOnly` returns windows front-to-back, so the first
        // match is the one the user is looking at.
        guard let frontmost = frames.first else { return nil }

        let primaryHeight = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        let center = CGPoint(
            x: frontmost.midX,
            y: primaryHeight - frontmost.midY
        )
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
    }

    private func startPointerPassthroughMonitoring() {
        guard pointerPassthroughTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updatePointerPassthrough()
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerPassthroughTimer = timer
    }

    private func updatePointerPassthrough() {
        let pointer = NSEvent.mouseLocation
        let defaults = UserDefaults.standard
        let balloonVisible = defaults.object(forKey: "compactBalloonVisible") == nil
            ? isCompactBalloonVisible
            : defaults.bool(forKey: "compactBalloonVisible")

        for window in NSApplication.shared.windows {
            // The screen-highlight overlays are ours but are not chat windows:
            // they can cover a whole display, and making them catch the pointer
            // swallows every click meant for the app underneath.
            guard window.identifier != clippyOverlayWindowIdentifier else { continue }

            // Expanded chat and sheets fill their window for real, so the whole
            // frame is legitimately interactive there.
            guard !isExpanded,
                  window.sheetParent == nil,
                  window.attachedSheet == nil else {
                window.ignoresMouseEvents = false
                continue
            }

            // Only the actually-drawn artwork should catch the pointer — the
            // rest of this otherwise-transparent window belongs to whatever
            // app is underneath. The window itself is a fixed 250x340, but a
            // short balloon (or none at all, tucked away) only occupies part
            // of that, and used to leave dead space on top that still ate
            // clicks meant for the app behind it.
            let hitSize: CGSize = balloonVisible
                ? CGSize(
                    width: min(balloonContentSize.width, window.frame.width),
                    // The measured content sits `compactBottomInset` above the
                    // window's bottom edge (ContentView's `.padding(.bottom,)`),
                    // but the region is anchored at the bottom — so without
                    // adding it back the region's top lands that far below the
                    // content's real top. That dead strip is exactly where the
                    // balloon's top row, and its expand button, live.
                    height: min(
                        balloonContentSize.height + Self.compactBottomInset,
                        window.frame.height
                    )
                  )
                : CGSize(width: 150, height: 132)
            // The compact frame centers its content horizontally and anchors
            // it to the bottom (`.frame(..., alignment: .bottom)` in
            // ContentView) — mirror that here so the hit region tracks where
            // the content actually lands, not the window's raw corner.
            let clippyHitRegion = balloonVisible
                ? NSRect(
                    x: window.frame.minX + (window.frame.width - hitSize.width) / 2,
                    y: window.frame.minY,
                    width: hitSize.width,
                    height: hitSize.height
                  )
                : NSRect(
                    x: window.frame.maxX - 158,
                    y: window.frame.minY,
                    width: hitSize.width,
                    height: hitSize.height
                  )
            window.ignoresMouseEvents = !clippyHitRegion.contains(pointer)
        }
    }
}

@main
struct ClippyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(speech: viewModel.speech)
                .environmentObject(viewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 250, height: 340)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    viewModel.clearConversation()
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .appSettings) {
                Button("\(viewModel.character.title) Settings…") {
                    viewModel.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // Dictation's primary gesture is hold-⌘⌥ push-to-talk (see
            // PushToTalkMonitor), which can't be expressed as a
            // `.keyboardShortcut`. This menu item stays as the click-to-toggle
            // alternative — useful when holding a chord through a long
            // dictation isn't practical.
            CommandGroup(after: .textEditing) {
                Button("Toggle Dictation") {
                    Task { await viewModel.speech.toggleListening() }
                }
            }
        }
    }
}
