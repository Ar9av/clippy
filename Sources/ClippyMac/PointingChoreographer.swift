import AppKit
import ClippyCore
import SwiftUI

/// Flies the character next to each target in turn, has it gesture at it,
/// rings it, holds, then moves on; returns home when the queue ends.
///
/// Timing, easing and "several points in order, each held a couple of
/// seconds" come from rbrown101010/bluey-by-riley (public domain).
@MainActor
final class PointingChoreographer {
    static let shared = PointingChoreographer()

    struct Step {
        /// Global top-left points, like every other rect in Clippy.
        let rect: CGRect
        let caption: String
    }

    static let hold: Duration = .milliseconds(2200)

    private var task: Task<Void, Never>?
    /// The real window, faded out while a stand-in sprite tours the screen.
    /// The real one can't do it: it is a titled 340pt-tall window with the
    /// character at its bottom, and AppKit won't move a titled window above
    /// the menu bar, so for anything near the top the character stopped
    /// ~250pt short of its target.
    private weak var hiddenWindow: NSWindow?
    private var sprite: NSPanel?
    private let spriteModel = PointerSpriteModel()

    var isPointing: Bool { task != nil }

    func run(_ steps: [Step]) {
        cancel()
        guard !steps.isEmpty else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let sprite = self.showSprite()
            for (index, step) in steps.enumerated() {
                guard !Task.isCancelled else { break }
                let caption = steps.count > 1 ? "\(index + 1) of \(steps.count): \(step.caption)" : step.caption
                if let sprite, let spot = Self.characterSpot(
                    beside: step.rect,
                    size: Self.characterSize,
                    screens: NSScreen.screens.map(Self.topLeftFrame)
                ) {
                    self.spriteModel.mood = .idle
                    await self.fly(sprite, to: Self.appKitPoint(spot.center))
                    guard !Task.isCancelled else { break }
                    self.spriteModel.mood = .pointing(spot.direction)
                }
                guard !Task.isCancelled else { break }
                ScreenAwarenessService.shared.showPointer(around: step.rect, label: caption, flyMarker: sprite == nil)
                try? await Task.sleep(for: Self.hold)
            }
            ScreenAwarenessService.shared.dismissHighlight()
            if !Task.isCancelled { await self.returnHome() }
            self.task = nil
        }
    }

    /// A new message or Stop ends the tour where it is.
    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        ScreenAwarenessService.shared.dismissHighlight()
        Task { await returnHome() }
    }

    /// Puts a stand-in sprite exactly over the real character and hides the
    /// real window. Nil in expanded chat: there is no floating character then.
    private func showSprite() -> NSPanel? {
        guard let window = Self.characterWindow() else { return nil }
        let size = Self.characterSize
        let offset = Self.characterOffset(in: window)
        let panel = NSPanel(
            contentRect: CGRect(x: window.frame.minX + offset.x - size / 2, y: window.frame.minY + offset.y - size / 2, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = clippyOverlayWindowIdentifier
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        spriteModel.mood = .idle
        panel.contentView = NSHostingView(rootView: PointerSpriteView(model: spriteModel))
        panel.orderFrontRegardless()
        window.alphaValue = 0
        hiddenWindow = window
        sprite = panel
        return panel
    }

    private func returnHome() async {
        guard let sprite else { return }
        self.sprite = nil
        spriteModel.mood = .idle
        if let window = hiddenWindow {
            try? await Task.sleep(for: .milliseconds(300))
            let offset = Self.characterOffset(in: window)
            await fly(sprite, to: NSPoint(x: window.frame.minX + offset.x, y: window.frame.minY + offset.y))
            window.alphaValue = 1
        }
        hiddenWindow = nil
        sprite.orderOut(nil)
    }

    private static func appKitPoint(_ point: CGPoint) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSPoint(x: point.x, y: primaryHeight - point.y)
    }

    // MARK: Geometry

    /// The 110pt sprite, drawn 31pt right of centre and 3pt above the bottom
    /// of the compact window (ContentView `floatingAssistant`).
    static let characterSize: CGFloat = 110

    private static func characterOffset(in window: NSWindow) -> CGPoint {
        CGPoint(x: window.frame.width / 2 + 31, y: 3 + characterSize / 2)
    }

    private static func characterWindow() -> NSWindow? {
        NSApp.windows.first {
            !$0.isSheet && !($0 is NSPanel) && $0.isVisible
                && $0.identifier != clippyOverlayWindowIdentifier
                && $0.level == .floating
                && $0.frame.width < 300
        }
    }

    /// Where the character's centre should go (global top-left points) to sit
    /// beside `target` without covering it, and which way it then points.
    /// Pure, so it is tested without a window.
    nonisolated static func characterSpot(
        beside target: CGRect,
        size: CGFloat,
        screens: [CGRect]
    ) -> (center: CGPoint, direction: ClippyMood.PointDirection)? {
        guard let screen = screens.first(where: { $0.intersects(target) }) ?? screens.first else { return nil }
        let gap: CGFloat = 6
        let half = size / 2
        let y = min(max(target.midY, screen.minY + half), screen.maxY - half)
        if target.maxX + gap + size <= screen.maxX {
            return (CGPoint(x: target.maxX + gap + half, y: y), .left)
        }
        if target.minX - gap - size >= screen.minX {
            return (CGPoint(x: target.minX - gap - half, y: y), .right)
        }
        let x = min(max(target.midX, screen.minX + half), screen.maxX - half)
        if target.maxY + gap + size <= screen.maxY {
            return (CGPoint(x: x, y: target.maxY + gap + half), .up)
        }
        return (CGPoint(x: x, y: max(target.minY - gap - half, screen.minY + half)), .down)
    }

    /// NSScreen frames are bottom-left from the primary display; flip into
    /// the global top-left space using the primary display's height.
    static func topLeftFrame(_ screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    // MARK: Flight

    /// Bluey's duration: quick for short hops, never more than 1.2 s.
    nonisolated static func flightDuration(distance: CGFloat) -> Double {
        min(1.2, max(0.45, 0.4 + 0.12 * log2(1 + Double(distance) / 24)))
    }

    /// CSS-style cubic-bezier(0.42, 0, 0.22, 1) easing.
    nonisolated static func ease(_ t: Double) -> Double {
        let (x1, y1, x2, y2) = (0.42, 0.0, 0.22, 1.0)
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * a + 3 * (1 - s) * s * s * b + s * s * s
        }
        var s = t
        for _ in 0..<8 {
            let x = bezier(s, x1, x2) - t
            let dx = 3 * (1 - s) * (1 - s) * x1 + 6 * (1 - s) * s * (x2 - x1) + 3 * s * s * (1 - x2)
            guard abs(dx) > 1e-6 else { break }
            s = min(max(s - x / dx, 0), 1)
        }
        return bezier(s, y1, y2)
    }

    /// Moves the sprite's centre to `center` (AppKit coordinates) along a
    /// gently bowed curve.
    private func fly(_ window: NSWindow, to center: NSPoint) async {
        let half = window.frame.width / 2
        let start = window.frame.origin
        let end = NSPoint(x: center.x - half, y: center.y - half)
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 2 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrameOrigin(end)
            return
        }
        // Bow perpendicular to the path, a fifth of its length, capped.
        let bow = min(distance * 0.2, 120)
        let normal = CGPoint(x: -(end.y - start.y) / distance, y: (end.x - start.x) / distance)
        let c1 = CGPoint(x: start.x + (end.x - start.x) / 3 + normal.x * bow, y: start.y + (end.y - start.y) / 3 + normal.y * bow)
        let c2 = CGPoint(x: start.x + 2 * (end.x - start.x) / 3 + normal.x * bow, y: start.y + 2 * (end.y - start.y) / 3 + normal.y * bow)
        let duration = Self.flightDuration(distance: distance)
        let began = Date()
        while !Task.isCancelled {
            let t = min(Date().timeIntervalSince(began) / duration, 1)
            let s = Self.ease(t)
            let a = (1 - s) * (1 - s) * (1 - s), b = 3 * (1 - s) * (1 - s) * s, c = 3 * (1 - s) * s * s, d = s * s * s
            window.setFrameOrigin(NSPoint(
                x: a * start.x + b * c1.x + c * c2.x + d * end.x,
                y: a * start.y + b * c1.y + c * c2.y + d * end.y
            ))
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}

@MainActor
final class PointerSpriteModel: ObservableObject {
    @Published var mood: ClippyMood = .idle
}

/// The character alone, for the touring stand-in.
private struct PointerSpriteView: View {
    @ObservedObject var model: PointerSpriteModel
    @StateObject private var controller = ClippyAnimationController(character: .persisted)

    var body: some View {
        Group {
            if let frame = controller.frame {
                Image(decorative: frame, scale: 1).resizable().interpolation(.high).scaledToFit()
            }
        }
        .frame(width: PointingChoreographer.characterSize, height: PointingChoreographer.characterSize)
        .onAppear { controller.setMood(model.mood) }
        .onChange(of: model.mood) { _, mood in controller.setMood(mood) }
    }
}
