import AppKit

/// Watches the user-defined voice-action shortcuts. It is intentionally
/// separate from the two built-in dictation routes: actions can be added and
/// removed live in Settings, while an in-flight hold must remain tied to the
/// action that started it.
@MainActor
final class VoiceActionMonitor {
    private static let holdThreshold = Duration.milliseconds(500)

    private let actions: () -> [CustomPrompt]
    private let reservedShortcuts: () -> [DictationShortcut]
    private let start: (UUID) -> Void
    private let stop: (UUID) -> Void
    private let cancel: (UUID) -> Void

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var armingTask: Task<Void, Never>?
    private var armingActionID: UUID?
    private var engagedActionID: UUID?
    private var heldModifiers: NSEvent.ModifierFlags = []

    init(
        actions: @escaping () -> [CustomPrompt],
        reservedShortcuts: @escaping () -> [DictationShortcut],
        start: @escaping (UUID) -> Void,
        stop: @escaping (UUID) -> Void,
        cancel: @escaping (UUID) -> Void
    ) {
        self.actions = actions
        self.reservedShortcuts = reservedShortcuts
        self.start = start
        self.stop = stop
        self.cancel = cancel
    }

    func startMonitoring() {
        guard eventTap == nil, localMonitor == nil else { return }
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
                let monitor = Unmanaged<VoiceActionMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if let event = NSEvent(cgEvent: cgEvent) {
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
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { event in
            MainActor.assumeIsolated { self.handle(event) }
            return event
        }
    }

    func stopMonitoring() {
        armingTask?.cancel()
        armingTask = nil
        armingActionID = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTapSource = nil
        eventTap = nil
        if let engagedActionID {
            self.engagedActionID = nil
            cancel(engagedActionID)
        }
    }

    private func handle(_ event: NSEvent) {
        guard !DictationShortcutCapture.isActive else { return }
        if event.type == .flagsChanged, let changed = modifierFlag(for: event.keyCode) {
            if event.modifierFlags.contains(changed) { heldModifiers.insert(changed) }
            else { heldModifiers.remove(changed) }
        }

        if event.type == .keyUp {
            if let id = engagedActionID, let shortcut = shortcut(for: id),
               shortcut.keyCode == event.keyCode {
                engagedActionID = nil
                stop(id)
            }
            return
        }

        if event.type == .keyDown {
            guard let id = actionID(modifiers: heldModifiers, keyCode: event.keyCode) else {
                cancelArmedOrEngaged()
                return
            }
            if let armingActionID, armingActionID != id {
                armingTask?.cancel()
                armingTask = nil
                self.armingActionID = nil
            }
            guard engagedActionID == nil, armingTask == nil else { return }
            arm(id)
            return
        }

        if let id = engagedActionID, let shortcut = shortcut(for: id),
           shortcut.modifiers != heldModifiers {
            engagedActionID = nil
            stop(id)
        }

        let heldActionID = actionID(modifiers: heldModifiers, keyCode: nil)
        if armingActionID != heldActionID {
            armingTask?.cancel()
            armingTask = nil
            armingActionID = nil
        }

        guard let id = heldActionID,
              engagedActionID == nil, armingTask == nil else {
            return
        }
        arm(id)
    }

    private func arm(_ id: UUID) {
        armingTask?.cancel()
        armingActionID = id
        armingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdThreshold)
            guard !Task.isCancelled, let self else { return }
            self.armingTask = nil
            self.armingActionID = nil
            guard let shortcut = self.shortcut(for: id),
                  self.actionID(modifiers: self.heldModifiers, keyCode: shortcut.keyCode) == id,
                  self.engagedActionID == nil else { return }
            self.engagedActionID = id
            self.start(id)
        }
    }

    private func cancelArmedOrEngaged() {
        armingTask?.cancel()
        armingTask = nil
        armingActionID = nil
        if let engagedActionID {
            self.engagedActionID = nil
            cancel(engagedActionID)
        }
    }

    private func actionID(modifiers: NSEvent.ModifierFlags, keyCode: UInt16?) -> UUID? {
        actions().first {
            guard let shortcut = $0.voiceShortcut else { return false }
            return !reservedShortcuts().contains(shortcut)
                && shortcut.modifiers == modifiers && shortcut.keyCode == keyCode && $0.hasVoiceAction
        }?.id
    }

    private func shortcut(for id: UUID) -> DictationShortcut? {
        actions().first(where: { $0.id == id })?.voiceShortcut
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
