import AppKit

/// Where a push-to-talk session sends what it heard. Each route is a distinct
/// modifier chord held down for the duration of the dictation.
enum DictationRoute: CaseIterable {
    /// Hold ⌘⌥ — type into whatever editable field is focused in the
    /// frontmost app, falling back to the clipboard.
    case focusedApp
    /// Hold ⌥⇧ — send the transcript to Clippy as a chat message.
    case clippy

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .focusedApp: [.command, .option]
        case .clippy: [.option, .shift]
        }
    }
}

/// Push-to-talk dictation: hold a chord to record, release to stop.
///
/// This can't be a `.keyboardShortcut` — those only fire on key *down*, and a
/// modifier-only chord isn't a shortcut at all as far as AppKit is concerned.
/// So the chord is tracked directly off `.flagsChanged`, with both a local and
/// a global monitor so it still works while another app is focused (the global
/// one needs Accessibility, which Clippy already asks for; without it
/// push-to-talk simply degrades to working only when Clippy is frontmost).
@MainActor
final class PushToTalkMonitor {
    /// How long a chord must be held before dictation actually starts.
    /// Without this, every ordinary ⌘⌥- or ⌥⇧-prefixed shortcut in any app
    /// (⌘⌥I, ⌥⇧K, ⌘⌥Esc) would flick the microphone open on its way to the
    /// real shortcut.
    private static let holdThreshold = Duration.milliseconds(250)

    private let start: (DictationRoute) -> Void
    private let stop: (DictationRoute) -> Void
    private let cancel: (DictationRoute) -> Void

    private var monitors: [Any] = []
    private var armingTask: Task<Void, Never>?
    private var engagedRoute: DictationRoute?

    init(
        start: @escaping (DictationRoute) -> Void,
        stop: @escaping (DictationRoute) -> Void,
        cancel: @escaping (DictationRoute) -> Void
    ) {
        self.start = start
        self.stop = stop
        self.cancel = cancel
    }

    func startMonitoring() {
        guard monitors.isEmpty else { return }

        // `.keyDown` is watched only to notice that *some* key was pressed
        // while a chord was held, which means the user is reaching for a real
        // shortcut (or typing an ⌥⇧ glyph) rather than dictating. The event's
        // characters are never read — only its type.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]

        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
            return event
        })
        if let local { monitors.append(local) }

        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
        })
        if let global { monitors.append(global) }
    }

    func stopMonitoring() {
        armingTask?.cancel()
        armingTask = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let engagedRoute {
            self.engagedRoute = nil
            cancel(engagedRoute)
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            armingTask?.cancel()
            armingTask = nil
            // A keystroke mid-session means the chord was a typing modifier
            // after all (⌥⇧ is a live text-entry combo). Drop the recording
            // rather than delivering whatever was picked up.
            if let engagedRoute {
                self.engagedRoute = nil
                cancel(engagedRoute)
            }
            return
        }

        let held = route(for: event.modifierFlags)

        // Releasing the chord — or switching to a different one — ends the
        // running session and delivers what it heard.
        if let engagedRoute, engagedRoute != held {
            self.engagedRoute = nil
            stop(engagedRoute)
        }

        guard let held else {
            armingTask?.cancel()
            armingTask = nil
            return
        }

        guard engagedRoute == nil, armingTask == nil else { return }
        armingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdThreshold)
            guard !Task.isCancelled, let self else { return }
            self.armingTask = nil
            // Re-read the live modifier state rather than trusting the event
            // that armed us: a release during the hold window can be
            // delivered to only one of the two monitors.
            guard self.route(for: NSEvent.modifierFlags) == held,
                  self.engagedRoute == nil else { return }
            self.engagedRoute = held
            self.start(held)
        }
    }

    /// Exact match, so ⌘⌥⇧ and ⌘⌥⌃ chords (which belong to other shortcuts)
    /// don't count as push-to-talk.
    private func route(for flags: NSEvent.ModifierFlags) -> DictationRoute? {
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        return DictationRoute.allCases.first { $0.modifiers == normalized }
    }
}
