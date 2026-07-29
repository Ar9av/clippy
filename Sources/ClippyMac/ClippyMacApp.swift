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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            window.titlebarAppearsTransparent = true
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
            ? NSSize(width: 480, height: 680)
            : NSSize(width: 250, height: 340)
        let oldFrame = window.frame
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? oldFrame
        let origin = NSPoint(
            x: min(max(oldFrame.maxX - size.width, screenFrame.minX), screenFrame.maxX - size.width),
            y: min(max(oldFrame.minY, screenFrame.minY), screenFrame.maxY - size.height)
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
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
                ? CGSize(width: min(balloonContentSize.width, window.frame.width),
                         height: min(balloonContentSize.height, window.frame.height))
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
                Button("Clippy Settings…") {
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
