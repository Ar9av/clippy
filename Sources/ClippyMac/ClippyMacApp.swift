import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isExpanded = false
    private var isCompactBalloonVisible = true
    private var pointerPassthroughTimer: Timer?

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        pointerPassthroughTimer?.invalidate()
    }

    private func configureWindows(expanded: Bool? = nil) {
        let floating = UserDefaults.standard.bool(forKey: "alwaysOnTop")
        for window in NSApplication.shared.windows {
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

            // Expanded chat, visible balloons, and sheets remain conventionally interactive.
            guard !isExpanded,
                  !balloonVisible,
                  window.sheetParent == nil,
                  window.attachedSheet == nil else {
                window.ignoresMouseEvents = false
                continue
            }

            // In the tucked-away state only the artwork at the lower-right of the
            // otherwise transparent window should catch the pointer. Everything
            // above and beside it belongs to the application underneath.
            let clippyHitRegion = NSRect(
                x: window.frame.maxX - 158,
                y: window.frame.minY,
                width: 150,
                height: 132
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
            ContentView()
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
        }
    }
}
