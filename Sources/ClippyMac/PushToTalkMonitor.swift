import AppKit
import OSLog

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

/// A user-configurable push-to-talk key combination. `keyCode == nil` keeps
/// the original modifier-only behaviour; otherwise the key must be held with
/// exactly these modifiers.
struct DictationShortcut: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16?
    var modifiersRawValue: UInt
    /// The user-facing representation captured from AppKit. Key codes are an
    /// implementation detail and must never leak into Settings.
    var keyDisplay: String?

    init(keyCode: UInt16?, modifiersRawValue: UInt, keyDisplay: String? = nil) {
        self.keyCode = keyCode
        self.modifiersRawValue = modifiersRawValue
        self.keyDisplay = keyDisplay
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiersRawValue) }

    static let focusedAppDefault = DictationShortcut(keyCode: nil, modifiersRawValue: NSEvent.ModifierFlags([.command, .option]).rawValue)
    static let clippyDefault = DictationShortcut(keyCode: nil, modifiersRawValue: NSEvent.ModifierFlags([.option, .shift]).rawValue)

    var displayName: String {
        let names: [(NSEvent.ModifierFlags, String)] = [(.command, "⌘"), (.option, "⌥"), (.shift, "⇧"), (.control, "⌃")]
        let prefix = names.filter { modifiers.contains($0.0) }.map(\.1).joined()
        guard let keyCode else { return prefix.isEmpty ? "None" : prefix }
        return prefix + (keyDisplay?.isEmpty == false ? keyDisplay! : Self.keyName(for: keyCode))
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: "Space"
        case 44: "/"
        case 43: ","
        case 47: "."
        case 50: "`"
        case 27: "-"
        case 24: "="
        case 33: "["
        case 30: "]"
        case 42: "\\"
        case 41: ";"
        case 39: "'"
        case 36: "Return"
        case 48: "Tab"
        case 53: "Esc"
        case 122: "F1"; case 120: "F2"; case 99: "F3"; case 118: "F4"
        case 96: "F5"; case 97: "F6"; case 98: "F7"; case 100: "F8"
        case 101: "F9"; case 109: "F10"; case 103: "F11"; case 111: "F12"
        default: "Key \(keyCode)"
        }
    }
}

enum DictationShortcutStore {
    static func get(_ route: DictationRoute) -> DictationShortcut {
        let key = route == .focusedApp ? "dictationShortcut.focusedApp" : "dictationShortcut.clippy"
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(DictationShortcut.self, from: data) else {
            return route == .focusedApp ? .focusedAppDefault : .clippyDefault
        }
        return value
    }

    static func set(_ value: DictationShortcut, for route: DictationRoute) {
        let key = route == .focusedApp ? "dictationShortcut.focusedApp" : "dictationShortcut.clippy"
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Capture state deliberately lives only in memory. Persisting this would let
/// a force-quit while Settings was recording a shortcut disable push-to-talk
/// forever on the next launch.
enum DictationShortcutCapture {
    static var isActive = false
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
    private static let logger = Logger(subsystem: "com.ar9av.clippy", category: "PushToTalk")
    /// How long a chord must be held before dictation actually starts.
    /// Without this, every ordinary ⌘⌥- or ⌥⇧-prefixed shortcut in any app
    /// (⌘⌥I, ⌥⇧K, ⌘⌥Esc) would flick the microphone open on its way to the
    /// real shortcut.
    private static let holdThreshold = Duration.milliseconds(500)

    private let shortcut: (DictationRoute) -> DictationShortcut
    private let start: (DictationRoute) -> Void
    private let stop: (DictationRoute) -> Void
    private let cancel: (DictationRoute) -> Void

    private var monitors: [Any] = []
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var armingTask: Task<Void, Never>?
    private var armingRoute: DictationRoute?
    private var engagedRoute: DictationRoute?
    private var heldModifiers: NSEvent.ModifierFlags = []

    init(
        shortcut: @escaping (DictationRoute) -> DictationShortcut,
        start: @escaping (DictationRoute) -> Void,
        stop: @escaping (DictationRoute) -> Void,
        cancel: @escaping (DictationRoute) -> Void
    ) {
        self.shortcut = shortcut
        self.start = start
        self.stop = stop
        self.cancel = cancel
    }

    func startMonitoring() {
        guard monitors.isEmpty, eventTap == nil else { return }

        // `.keyDown` is watched only to notice that *some* key was pressed
        // while a chord was held, which means the user is reaching for a real
        // shortcut (or typing an ⌥⇧ glyph) rather than dictating. The event's
        // characters are never read — only its type.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]

        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, cgEvent, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
                let monitor = Unmanaged<PushToTalkMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if let event = NSEvent(cgEvent: cgEvent) {
                    // The tap's source is attached to the main run loop below,
                    // so the callback is already on the main actor.
                    MainActor.assumeIsolated { monitor.handle(event) }
                }
                return Unmanaged.passUnretained(cgEvent)
            },
            userInfo: refcon
        ) {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            eventTap = tap
            eventTapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            UserDefaults.standard.set("global", forKey: "dictationShortcutMonitorStatus")
            Self.logger.info("Global keyboard event tap installed")
            return
        }

        // Fall back to AppKit when Input Monitoring has not been granted yet.
        // This still permits shortcuts while Clippy itself is frontmost.
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { self.handle(event) }
            return event
        }
        if let local { monitors.append(local) }
        UserDefaults.standard.set("localOnly", forKey: "dictationShortcutMonitorStatus")
        Self.logger.warning("Global keyboard event tap unavailable; using local-only fallback")
    }

    func stopMonitoring() {
        armingTask?.cancel()
        armingTask = nil
        armingRoute = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTapSource = nil
        eventTap = nil
        if let engagedRoute {
            self.engagedRoute = nil
            cancel(engagedRoute)
        }
    }

    private func handle(_ event: NSEvent) {
        // While Settings is recording a new shortcut, those very same key
        // presses must never trigger the old shortcut underneath it.
        guard !DictationShortcutCapture.isActive else { return }
        if event.type == .flagsChanged, let changed = modifierFlag(for: event.keyCode) {
            if event.modifierFlags.contains(changed) { heldModifiers.insert(changed) }
            else { heldModifiers.remove(changed) }
        }
        if event.type == .keyUp {
            if let engagedRoute, matches(event, route: engagedRoute) {
                self.engagedRoute = nil
                stop(engagedRoute)
            }
            return
        }

        if event.type == .keyDown {
            guard let held = route(for: heldModifiers, keyCode: event.keyCode) else {
                armingTask?.cancel()
                armingTask = nil
                armingRoute = nil
                cancelEngagedSession()
                return
            }
            if let armingRoute, armingRoute != held {
                armingTask?.cancel()
                armingTask = nil
                self.armingRoute = nil
            }
            guard engagedRoute == nil, armingTask == nil else { return }
            arm(held)
            return
        }

        // A key-based shortcut ends as soon as one of its modifiers is
        // released. Modifier-only shortcuts continue to use this path.
        if let engagedRoute,
           shortcut(for: engagedRoute).keyCode != nil,
           !matchesModifiers(heldModifiers, route: engagedRoute) {
            self.engagedRoute = nil
            stop(engagedRoute)
            return
        }

        // A flagsChanged event may describe only the modifier that changed
        // (not every modifier currently held). Match modifier-only shortcuts
        // against the session-wide state so ⌘ followed by ⌥ resolves to ⌘⌥.
        let held = route(for: heldModifiers)

        // If the user continues from one valid chord into another (for
        // example ⌘, then ⌘⌥), restart the half-second hold for the final
        // combination instead of leaving the first action armed.
        if armingRoute != held {
            armingTask?.cancel()
            armingTask = nil
            armingRoute = nil
        }

        // Releasing a modifier-only chord — or switching to a different one —
        // ends the running session and delivers what it heard.
        if let engagedRoute, engagedRoute != held {
            self.engagedRoute = nil
            stop(engagedRoute)
        }

        guard let held, shortcut(for: held).keyCode == nil else {
            armingTask?.cancel()
            armingTask = nil
            armingRoute = nil
            return
        }

        guard engagedRoute == nil, armingTask == nil else { return }
        arm(held)
    }

    private func arm(_ held: DictationRoute) {
        Self.logger.debug("Push-to-talk chord detected; arming")
        armingTask?.cancel()
        armingRoute = held
        armingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdThreshold)
            guard !Task.isCancelled, let self else { return }
            self.armingTask = nil
            self.armingRoute = nil
            guard self.route(for: self.heldModifiers, keyCode: self.shortcut(for: held).keyCode) == held,
                  self.engagedRoute == nil else { return }
            self.engagedRoute = held
            Self.logger.info("Push-to-talk engaged")
            self.start(held)
        }
    }

    private func cancelEngagedSession() {
        if let engagedRoute {
            // A keystroke mid-session means the chord was a typing modifier
            // after all (⌥⇧ is a live text-entry combo). Drop the recording
            // rather than delivering whatever was picked up.
            self.engagedRoute = nil
            cancel(engagedRoute)
        }
    }

    /// Exact match, so ⌘⌥⇧ and ⌘⌥⌃ chords (which belong to other shortcuts)
    /// don't count as push-to-talk.
    private func route(for flags: NSEvent.ModifierFlags, keyCode: UInt16? = nil) -> DictationRoute? {
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        return DictationRoute.allCases.first {
            let configured = shortcut(for: $0)
            return configured.modifiers == normalized && configured.keyCode == keyCode
        }
    }

    private func route(for event: NSEvent) -> DictationRoute? {
        route(for: event.modifierFlags.intersection(.deviceIndependentFlagsMask), keyCode: event.keyCode)
    }

    private func shortcut(for route: DictationRoute) -> DictationShortcut { shortcut(route) }

    private func matches(_ event: NSEvent, route: DictationRoute) -> Bool {
        shortcut(for: route).keyCode == event.keyCode && matchesModifiers(event.modifierFlags, route: route)
    }

    private func matchesModifiers(_ flags: NSEvent.ModifierFlags, route: DictationRoute) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask) == shortcut(for: route).modifiers
    }

    private func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        default: nil
        }
    }
}
