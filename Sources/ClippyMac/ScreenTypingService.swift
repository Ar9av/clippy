import AppKit
import ApplicationServices
import Foundation

enum ScreenTypingError: LocalizedError {
    case accessibilityPermission
    case noEditableTarget
    case secureField
    case unsupportedField

    var errorDescription: String? {
        switch self {
        case .accessibilityPermission:
            "Allow Clippy in System Settings → Privacy & Security → Accessibility, then click your destination field and ask again."
        case .noEditableTarget:
            "Click the text box where you want this written, then open Clippy and ask again."
        case .secureField:
            "Clippy won’t type into password or other secure fields."
        case .unsupportedField:
            "That app does not expose this text box to macOS Accessibility. Try a standard text field."
        }
    }
}

@MainActor
final class ScreenTypingService {
    static let shared = ScreenTypingService()

    private struct Target {
        let element: AXUIElement
        let processIdentifier: pid_t
        let appName: String
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private var target: Target?
    private var captureTimer: Timer?
    private var mouseMonitor: Any?
    private var activationMonitor: Any?
    private var lastExternalApplication: NSRunningApplication?

    private init() {}

    func startTracking() {
        guard captureTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.captureFocusedElement()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
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
                      application.processIdentifier
                        != ProcessInfo.processInfo.processIdentifier,
                      !AutomationSafety.isRestricted(application) else {
                    return
                }
                self?.lastExternalApplication = application
                self?.captureFocusedElement(from: application)
            }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = CGEvent(source: nil)?.location ?? .zero
            Task { @MainActor in
                self?.captureElement(at: point)
            }
        }
        captureFocusedElement()
    }

    var targetDescription: String? {
        target?.appName
    }

    var isAuthorized: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        _ = isAccessibilityTrusted(promptIfNeeded: true)
        _ = CGRequestPostEventAccess()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func prepareForInsertion() throws {
        guard isAccessibilityTrusted(promptIfNeeded: true) else {
            throw ScreenTypingError.accessibilityPermission
        }
        if target == nil, let lastExternalApplication {
            captureFocusedElement(from: lastExternalApplication)
        }
        guard target != nil else {
            throw ScreenTypingError.noEditableTarget
        }
    }

    @discardableResult
    func insert(_ text: String) async throws -> String {
        try prepareForInsertion()
        guard var target else { throw ScreenTypingError.noEditableTarget }

        let role = stringAttribute(kAXRoleAttribute, from: target.element) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute, from: target.element) ?? ""
        guard role != kAXSecureTextFieldSubrole as String,
              subrole != kAXSecureTextFieldSubrole as String else {
            throw ScreenTypingError.secureField
        }

        // Accessibility writes are unreliable while the destination app is
        // inactive. Bring it forward, restore focus, then reacquire the
        // editor because custom controls may replace their AX node on focus.
        activate(target)
        try await Task.sleep(for: .milliseconds(180))
        AXUIElementSetAttributeValue(
            target.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        try await Task.sleep(for: .milliseconds(80))
        if let refreshedElement = focusedEditableElement(
            for: target.processIdentifier
        ) {
            target = Target(
                element: refreshedElement,
                processIdentifier: target.processIdentifier,
                appName: target.appName
            )
        }

        let valueBeforeInsertion = stringAttribute(kAXValueAttribute, from: target.element)
        if isSettable(kAXValueAttribute as CFString, on: target.element),
           let currentValue = valueBeforeInsertion {
            let nsValue = currentValue as NSString
            let reportedRange = rangeAttribute(
                kAXSelectedTextRangeAttribute,
                from: target.element
            )
            let selectedRange: CFRange
            if let reportedRange,
               reportedRange.location >= 0,
               reportedRange.length >= 0,
               reportedRange.location + reportedRange.length <= nsValue.length {
                selectedRange = reportedRange
            } else {
                selectedRange = CFRange(location: nsValue.length, length: 0)
            }
            do {
                let updated = nsValue.replacingCharacters(
                    in: NSRange(location: selectedRange.location, length: selectedRange.length),
                    with: text
                )
                let result = AXUIElementSetAttributeValue(
                    target.element,
                    kAXValueAttribute as CFString,
                    updated as CFString
                )
                if result == .success {
                    try await Task.sleep(for: .milliseconds(350))
                }
                let verificationElement = focusedEditableElement(
                    for: target.processIdentifier
                ) ?? target.element
                if result == .success,
                   stringAttribute(kAXValueAttribute, from: verificationElement) == updated {
                    setSelection(
                        CFRange(location: selectedRange.location + text.utf16.count, length: 0),
                        on: verificationElement
                    )
                    return target.appName
                }
            }
        }

        // Some custom editors expose only selected-text replacement. Try it
        // after the standard AXValue route, since AppKit text views can
        // invalidate their accessibility node after a selected-text write.
        if let refreshedElement = focusedEditableElement(
            for: target.processIdentifier
        ) {
            target = Target(
                element: refreshedElement,
                processIdentifier: target.processIdentifier,
                appName: target.appName
            )
        }
        let selectedTextAttribute = kAXSelectedTextAttribute as CFString
        if valueBeforeInsertion != nil,
           isSettable(selectedTextAttribute, on: target.element) {
            let currentRange = rangeAttribute(
                kAXSelectedTextRangeAttribute,
                from: target.element
            ) ?? CFRange(location: valueBeforeInsertion?.utf16.count ?? 0, length: 0)
            setSelection(currentRange, on: target.element)
            let result = AXUIElementSetAttributeValue(
                target.element,
                selectedTextAttribute,
                text as CFString
            )
            if result == .success {
                try await Task.sleep(for: .milliseconds(350))
                let verificationElement = focusedEditableElement(
                    for: target.processIdentifier
                ) ?? target.element
                if stringAttribute(
                    kAXValueAttribute,
                    from: verificationElement
                )?.contains(text) == true {
                    return target.appName
                }
            }
        }

        try await typeWithKeyboard(text, into: target)
        return target.appName
    }

    private func captureFocusedElement() {
        guard isAccessibilityTrusted(promptIfNeeded: false),
              let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !AutomationSafety.isRestricted(application) else {
            return
        }
        lastExternalApplication = application
        captureFocusedElement(from: application)
    }

    private func captureFocusedElement(from application: NSRunningApplication) {
        guard let focusedElement = focusedElement(
            for: application.processIdentifier
        ) else { return }
        if hasSecureAncestor(focusedElement) {
            target = nil
            return
        }
        guard let element = editableElement(near: focusedElement) else {
            // Electron/WebKit editors can momentarily focus a container while
            // changing windows. Keep the last confirmed editor through that
            // transient state instead of discarding it.
            return
        }

        target = Target(
            element: element,
            processIdentifier: application.processIdentifier,
            appName: application.localizedName ?? "the other app"
        )
    }

    private func focusedElement(for processIdentifier: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        return elementAttribute(kAXFocusedUIElementAttribute, from: appElement)
    }

    private func focusedEditableElement(for processIdentifier: pid_t) -> AXUIElement? {
        guard let focusedElement = focusedElement(for: processIdentifier),
              !hasSecureAncestor(focusedElement) else {
            return nil
        }
        return editableElement(near: focusedElement)
    }

    private func captureElement(at screenPoint: CGPoint) {
        guard isAccessibilityTrusted(promptIfNeeded: false) else { return }
        let systemWide = AXUIElementCreateSystemWide()
        var rawElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(screenPoint.x),
            Float(screenPoint.y),
            &rawElement
        ) == .success,
              let rawElement else {
            return
        }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(rawElement, &processIdentifier) == .success,
              processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        if hasSecureAncestor(rawElement) {
            target = nil
            return
        }
        guard let element = editableElement(near: rawElement) else { return }
        let application = NSRunningApplication(processIdentifier: processIdentifier)
        target = Target(
            element: element,
            processIdentifier: processIdentifier,
            appName: application?.localizedName ?? "the other app"
        )
    }

    private func editableElement(near element: AXUIElement) -> AXUIElement? {
        if isEditable(element) { return element }

        var ancestor = element
        for _ in 0..<6 {
            guard let parent = elementAttribute(kAXParentAttribute, from: ancestor) else { break }
            if isEditable(parent) { return parent }
            ancestor = parent
        }

        var queue: [(AXUIElement, Int)] = [(element, 0)]
        var fallback: AXUIElement?
        while !queue.isEmpty {
            let (candidate, depth) = queue.removeFirst()
            if isEditable(candidate) {
                if boolAttribute(kAXFocusedAttribute, from: candidate) == true {
                    return candidate
                }
                fallback = fallback ?? candidate
            }
            guard depth < 5 else { continue }
            queue.append(contentsOf: children(of: candidate).map { ($0, depth + 1) })
        }
        return fallback
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        let editableRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        return editableRoles.contains(role)
            || isSettable(kAXSelectedTextAttribute as CFString, on: element)
            || isSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
    }

    private func hasSecureAncestor(_ element: AXUIElement) -> Bool {
        var candidate: AXUIElement? = element
        for _ in 0..<7 {
            guard let current = candidate else { return false }
            let role = stringAttribute(kAXRoleAttribute, from: current) ?? ""
            let subrole = stringAttribute(kAXSubroleAttribute, from: current) ?? ""
            if role == kAXSecureTextFieldSubrole as String
                || subrole == kAXSecureTextFieldSubrole as String {
                return true
            }
            candidate = elementAttribute(kAXParentAttribute, from: current)
        }
        return false
    }

    private func isAccessibilityTrusted(promptIfNeeded: Bool) -> Bool {
        guard promptIfNeeded else { return AXIsProcessTrusted() }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        return (value as? NSAttributedString)?.string
    }

    private func rangeAttribute(_ attribute: String, from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(
            unsafeBitCast(value, to: AXValue.self),
            .cfRange,
            &range
        ) else {
            return nil
        }
        return range
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
              let values = value as? [AXUIElement] else {
            return []
        }
        return values
    }

    private func isSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }

    private func setSelection(_ range: CFRange, on element: AXUIElement) {
        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return }
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
    }

    private func activate(_ target: Target) {
        NSRunningApplication(processIdentifier: target.processIdentifier)?
            .activate(options: [.activateAllWindows])
    }

    private func typeWithKeyboard(_ text: String, into target: Target) async throws {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            throw ScreenTypingError.accessibilityPermission
        }
        let valueBeforeInsertion = stringAttribute(kAXValueAttribute, from: target.element)
        let rangeBeforeInsertion = rangeAttribute(
            kAXSelectedTextRangeAttribute,
            from: target.element
        )

        AXUIElementSetAttributeValue(
            target.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        try await Task.sleep(for: .milliseconds(60))

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier else {
            throw ScreenTypingError.noEditableTarget
        }

        // A normal paste shortcut is the most compatible path for editors
        // implemented by Electron and WebKit. Preserve the user's clipboard
        // exactly and restore it immediately after the shortcut.
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if performPasteMenuAction(for: target.processIdentifier) {
            try await Task.sleep(for: .milliseconds(500))
            restorePasteboard(snapshot, to: pasteboard)
            let verificationElement = focusedEditableElement(
                for: target.processIdentifier
            ) ?? target.element
            if insertionSucceeded(
                text: text,
                valueBefore: valueBeforeInsertion,
                rangeBefore: rangeBeforeInsertion,
                in: verificationElement
            ) {
                return
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        if performPasteWithSystemEvents() {
            try await Task.sleep(for: .milliseconds(300))
            restorePasteboard(snapshot, to: pasteboard)
            let verificationElement = focusedEditableElement(
                for: target.processIdentifier
            ) ?? target.element
            if insertionSucceeded(
                text: text,
                valueBefore: valueBeforeInsertion,
                rangeBefore: rangeBeforeInsertion,
                in: verificationElement
            ) {
                return
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        let eventSource = CGEventSource(stateID: .combinedSessionState)
        eventSource?.localEventsSuppressionInterval = 0
        guard let pasteDown = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: 9,
            keyDown: true
        ), let pasteUp = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: 9,
            keyDown: false
        ) else {
            restorePasteboard(snapshot, to: pasteboard)
            throw ScreenTypingError.unsupportedField
        }
        pasteDown.flags = .maskCommand
        pasteUp.flags = .maskCommand
        pasteDown.post(tap: .cghidEventTap)
        pasteUp.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(180))
        restorePasteboard(snapshot, to: pasteboard)

        if insertionSucceeded(
            text: text,
            valueBefore: valueBeforeInsertion,
            rangeBefore: rangeBeforeInsertion,
            in: target.element
        ) {
            return
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ScreenTypingError.unsupportedField
        }
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 32) {
            var chunk = Array(units[start..<min(start + 32, units.count)])
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ), let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) else {
                throw ScreenTypingError.unsupportedField
            }
            keyDown.keyboardSetUnicodeString(
                stringLength: chunk.count,
                unicodeString: &chunk
            )
            keyUp.keyboardSetUnicodeString(
                stringLength: chunk.count,
                unicodeString: &chunk
            )
            // Posting at the HID tap is required for custom AppKit, Electron,
            // and WebKit editors that accept focus through Accessibility but
            // ignore process-directed synthetic key events.
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        try await Task.sleep(for: .milliseconds(120))
        guard insertionSucceeded(
            text: text,
            valueBefore: valueBeforeInsertion,
            rangeBefore: rangeBeforeInsertion,
            in: target.element
        ) else {
            throw ScreenTypingError.unsupportedField
        }
    }

    private func insertionSucceeded(
        text: String,
        valueBefore: String?,
        rangeBefore: CFRange?,
        in element: AXUIElement
    ) -> Bool {
        let valueAfterInsertion = stringAttribute(kAXValueAttribute, from: element)
        let rangeAfterInsertion = rangeAttribute(kAXSelectedTextRangeAttribute, from: element)
        let valueChanged = valueAfterInsertion != valueBefore
            && valueAfterInsertion?.contains(text) == true
        let selectionAdvanced: Bool
        if let before = rangeBefore, let after = rangeAfterInsertion {
            selectionAdvanced = after.location >= before.location + text.utf16.count
        } else {
            selectionAdvanced = false
        }
        return valueChanged || selectionAdvanced
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        return PasteboardSnapshot(items: items)
    }

    private func performPasteMenuAction(for processIdentifier: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let menuBar = elementAttribute(kAXMenuBarAttribute, from: application) else {
            return false
        }

        let editMenu = children(of: menuBar).first { item in
            let title = stringAttribute(kAXTitleAttribute, from: item)?
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title == "edit"
        }
        if let editMenu {
            AXUIElementPerformAction(editMenu, kAXPressAction as CFString)
            usleep(60_000)
        }

        var queue: [(AXUIElement, Int)] = [(editMenu ?? menuBar, 0)]
        while !queue.isEmpty {
            let (candidate, depth) = queue.removeFirst()
            let role = stringAttribute(kAXRoleAttribute, from: candidate) ?? ""
            let title = stringAttribute(kAXTitleAttribute, from: candidate)?
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if role == kAXMenuItemRole as String,
               (title == "paste" || title.hasPrefix("paste ")),
               boolAttribute(kAXEnabledAttribute, from: candidate) != false,
               AXUIElementPerformAction(
                   candidate,
                   kAXPressAction as CFString
               ) == .success {
                return true
            }
            guard depth < 5 else { continue }
            queue.append(contentsOf: children(of: candidate).map { ($0, depth + 1) })
        }
        return false
    }

    private func performPasteWithSystemEvents() -> Bool {
        guard let script = NSAppleScript(
            source: #"tell application "System Events" to keystroke "v" using command down"#
        ) else {
            return false
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    private func restorePasteboard(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
