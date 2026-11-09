import AppKit
import ApplicationServices
import Carbon
import CryptoKit
import SwiftUI

private let justWisperHotKeySignature: OSType = 0x4A575350

private func justWisperHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard result == noErr, identifier.signature == justWisperHotKeySignature else { return OSStatus(eventNotHandledErr) }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let service = Unmanaged<DesktopIntegration>.fromOpaque(context).takeUnretainedValue()
    let id = identifier.id
    Task { @MainActor [weak service] in service?.receiveHotKey(id: id, pressed: pressed) }
    return noErr
}

@MainActor
final class DesktopIntegration {
    typealias HotKey = HotKeySpec

    enum IntegrationError: LocalizedError {
        case accessibilityRequired, noTarget, targetUnavailable, targetChanged, unsupportedField, eventCreationFailed, clipboardWriteFailed
        var errorDescription: String? {
            switch self {
            case .accessibilityRequired: return "Enable Cortala in System Settings → Privacy & Security → Accessibility to paste into other apps. Your transcript is still available to copy."
            case .noTarget: return "Choose the app where you want to insert the transcript and try again."
            case .targetUnavailable: return "The destination app could not be activated. Your transcript is still available to copy."
            case .targetChanged: return "The destination text field changed while recording. Copy the transcript into the field you want to use."
            case .unsupportedField: return "Select an editable, non-password text field before recording. Your transcript is still available to copy."
            case .eventCreationFailed: return "Could not create the paste keyboard event. Copy the transcript manually."
            case .clipboardWriteFailed: return "Could not write the transcript to the clipboard. Try copying it from History."
            }
        }
    }

    var onWorkflow: (() -> Void)?
    var onToggle: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var onMouseHoldStart: (() -> Void)?
    var onMouseHoldEnd: (() -> Void)?
    var onShowModeSwitcher: (() -> Void)?
    var onCancel: (() -> Void)?
    var onModeShortcut: ((UUID) -> Void)?
    var cancelHotKey = HotKey.cancel
    var toggleHotKey = HotKey.toggle
    var holdHotKey = HotKey.hold
    var workflowHotKey = HotKey.workflow
    private var workflowReference: EventHotKeyRef?
    var restoreClipboard = true
    private(set) var hotKeyError: String?
    private(set) var targetAppName: String?
    private(set) var targetBundleID: String?
    private(set) var targetSiteHost: String?
    var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    var canAutoPaste: Bool { accessibilityTrusted && CGPreflightPostEventAccess() }

    private var target: NSRunningApplication?
    private var targetElement: AXUIElement?
    private var targetFingerprint: PasteDestinationFingerprint?
    private var targetWindow: AXUIElement?
    private var targetParent: AXUIElement?
    private var handler: EventHandlerRef?
    private var toggleReference: EventHotKeyRef?
    private var holdReference: EventHotKeyRef?
    private var switcherReference: EventHotKeyRef?
    private var switcherHotKey: HotKeySpec?
    private var mouseGesture = MouseRecordingGesture()
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var clipboardEnabled = false
    private var clipboardTracker = RecentClipboardTracker()
    private var clipboardTimer: Timer?
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var holding = false
    private var modeReferences: [EventHotKeyRef] = []
    private var modeIDs: [UInt32: UUID] = [:]
    private var configuredModes: [DictationMode] = []
    private var capturedContext: CapturedContext?
    private var capturedSelection: (range: CFRange, digest: SHA256.Digest, capturedAt: Date)?
    private var contextExpiry: Task<Void, Never>?

    @discardableResult
    func configure(settings: AppSettings, modes: [DictationMode]) -> Bool {
        if let message = HotKeySpec.validationError(toggle: settings.toggleShortcut, hold: settings.holdShortcut, modes: modes, switcher: settings.modeSwitcherShortcut, workflow: settings.workflowShortcut, cancel: settings.cancelShortcut) {
            hotKeyError = message
            return false
        }
        guard MouseRecordingGesture.isSupported(settings.mouseRecordingButton) else { hotKeyError = "Choose the middle mouse button or a supported side button."; return false }
        stop()
        cancelHotKey = settings.cancelShortcut
        toggleHotKey = settings.toggleShortcut
        holdHotKey = settings.holdShortcut
        workflowHotKey = settings.workflowShortcut
        configuredModes = modes
        switcherHotKey = settings.modeSwitcherShortcut
        mouseGesture = MouseRecordingGesture(button: settings.mouseRecordingButton, behavior: settings.mouseRecordingBehavior)
        clipboardEnabled = settings.captureRecentClipboard
        start()
        return hotKeyError == nil
    }

    func start() {
        stop()
        hotKeyError = HotKeySpec.validationError(toggle: toggleHotKey, hold: holdHotKey, modes: configuredModes, switcher: switcherHotKey, workflow: workflowHotKey, cancel: cancelHotKey)
        guard hotKeyError == nil else { return }
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), justWisperHotKeyHandler, eventTypes.count,
                                         &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { hotKeyError = "Could not install keyboard shortcuts (\(status))."; return }
        let toggleStatus = RegisterEventHotKey(toggleHotKey.keyCode, toggleHotKey.modifiers,
                                              EventHotKeyID(signature: justWisperHotKeySignature, id: 1),
                                              GetApplicationEventTarget(), 0, &toggleReference)
        let holdStatus = RegisterEventHotKey(holdHotKey.keyCode, holdHotKey.modifiers,
                                            EventHotKeyID(signature: justWisperHotKeySignature, id: 2),
                                            GetApplicationEventTarget(), 0, &holdReference)
        let workflowStatus = RegisterEventHotKey(workflowHotKey.keyCode, workflowHotKey.modifiers, EventHotKeyID(signature: justWisperHotKeySignature, id: UInt32.max - 1), GetApplicationEventTarget(), 0, &workflowReference)
        var modeStatus = noErr
        if let key = switcherHotKey {
            modeStatus = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: justWisperHotKeySignature, id: UInt32.max), GetApplicationEventTarget(), 0, &switcherReference)
        }
        for (index, mode) in configuredModes.enumerated() {
            guard let key = mode.shortcut else { continue }
            let id = UInt32(index + 3)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: justWisperHotKeySignature, id: id), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { modeReferences.append(reference); modeIDs[id] = mode.id }
            else { modeStatus = status }
        }
        if toggleStatus != noErr || holdStatus != noErr || workflowStatus != noErr || modeStatus != noErr {
            hotKeyError = "A shortcut is unavailable or used by another app. Choose another combination."
        }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.cancelHotKey.matches(keyCode: event.keyCode, flags: event.modifierFlags), !event.isARepeat else { return }
            Task { @MainActor in self.onCancel?() }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, self.cancelHotKey.matches(keyCode: event.keyCode, flags: event.modifierFlags), !event.isARepeat {
                Task { @MainActor in self.onCancel?() }
            }
            return event
        }
        if let button = mouseGesture.button {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
                guard event.buttonNumber == button else { return }
                let down = event.type == .otherMouseDown
                Task { @MainActor in self?.receiveMouse(button: button, down: down) }
            }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
                guard event.buttonNumber == button else { return event }
                let down = event.type == .otherMouseDown
                Task { @MainActor in self?.receiveMouse(button: button, down: down) }
                return nil
            }
        }
        startClipboardMonitoring()
    }

    func stop() {
        if let toggleReference { UnregisterEventHotKey(toggleReference) }
        if let holdReference { UnregisterEventHotKey(holdReference) }
        if let switcherReference { UnregisterEventHotKey(switcherReference) }
        if let workflowReference { UnregisterEventHotKey(workflowReference) }; workflowReference = nil
        for reference in modeReferences { UnregisterEventHotKey(reference) }
        modeReferences.removeAll(); modeIDs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        clipboardTimer?.invalidate(); clipboardTimer = nil
        clipboardTracker.reset()
        toggleReference = nil; holdReference = nil; handler = nil
        escapeMonitor = nil; localEscapeMonitor = nil
        switcherReference = nil; mouseMonitor = nil; localMouseMonitor = nil
        if holding { onHoldEnd?() }
        if mouseGesture.pressed && mouseGesture.behavior == .hold { onMouseHoldEnd?() }
        holding = false
        mouseGesture = MouseRecordingGesture(button: mouseGesture.button, behavior: mouseGesture.behavior)
    }

    fileprivate func receiveHotKey(id: UInt32, pressed: Bool) {
        if id == 1, pressed { onToggle?() }
        if id == UInt32.max - 1, pressed { onWorkflow?() }
        if id == UInt32.max, pressed { onShowModeSwitcher?() }
        if pressed, let modeID = modeIDs[id] { onModeShortcut?(modeID) }
        if id == 2 {
            if pressed, !holding { holding = true; onHoldStart?() }
            else if !pressed, holding { holding = false; onHoldEnd?() }
        }
    }

    private func receiveMouse(button: Int, down: Bool) {
        switch mouseGesture.receive(button: button, down: down) {
        case .toggle: onToggle?()
        case .beginHold: onMouseHoldStart?()
        case .endHold: onMouseHoldEnd?()
        case nil: break
        }
    }

    private func startClipboardMonitoring() {
        guard clipboardEnabled else { return }
        clipboardTracker.reset(changeCount: NSPasteboard.general.changeCount)
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollRecentClipboard() }
        }
    }

    private func pollRecentClipboard(now: Date = Date()) {
        guard clipboardEnabled else { return }
        let board = NSPasteboard.general
        let count = board.changeCount
        guard count != clipboardTracker.observedChangeCount else { _ = clipboardTracker.recent(at: now); return }
        let types = (board.types ?? []).map(\.rawValue)
        let text = RecentClipboardTracker.allows(types: types) ? board.string(forType: .string) : nil
        clipboardTracker.observe(changeCount: count, types: types, text: text, at: now)
    }

    func captureTarget(settings: AppSettings = AppSettings(), preserveContext: Bool = false) {
        // Clicking Stop inside JustWisper should retain the last external field.
        if preserveContext, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        if !preserveContext { clearContext(); capturedSelection = nil }
        targetSiteHost = nil
        target = nil
        targetElement = nil
        targetFingerprint = nil
        targetWindow = nil
        targetParent = nil
        targetAppName = nil
        targetBundleID = nil
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        target = app
        targetAppName = app.localizedName
        targetBundleID = app.bundleIdentifier
        if accessibilityTrusted,
           let element = focusedElement(in: app), isEditableNonsecureField(element) {
            targetElement = element
            targetFingerprint = fingerprint(of: element)
            targetWindow = relatedElement(kAXWindowAttribute, of: element)
            targetParent = relatedElement(kAXParentAttribute, of: element)
            if configuredModes.contains(where: { !$0.siteDomains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) || settings.captureFocusedText || settings.captureSelectedText || settings.captureRecentClipboard {
                targetSiteHost = siteHost(in: app, focused: element)
            }
            let metadata = [kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXDescriptionAttribute, "AXIdentifier", "AXPlaceholderValue"].compactMap { attribute($0, of: element) as? String }
            let placeholder = attribute("AXPlaceholderValue", of: element) as? String
            if !preserveContext, (settings.captureFocusedText || settings.captureSelectedText || settings.captureRecentClipboard), ContextCapturePolicy.allows(metadata: metadata, secure: isSecure(element)) {
                let fieldValue = attribute(kAXValueAttribute, of: element) as? String
                guard ContextCapturePolicy.allows(metadata: metadata, value: fieldValue, placeholder: placeholder) else { return }
                let selectedText = settings.captureSelectedText ? attribute(kAXSelectedTextAttribute, of: element) as? String : nil
                let boundedSelection = selectedText.flatMap { $0.count <= 2000 ? $0 : nil }
                if let boundedSelection, !boundedSelection.isEmpty, let range = selectionRange(of: element) {
                    capturedSelection = (range, SHA256.hash(data: Data(boundedSelection.utf8)), Date())
                }
                let context = CapturedContext(capturedAt: Date(), application: app.localizedName, siteHost: targetSiteHost,
                    focusedText: settings.captureFocusedText ? CapturedContext.sanitize(fieldValue, limit: 4000) : nil,
                    selectedText: CapturedContext.sanitize(boundedSelection, limit: 2000),
                    recentClipboard: settings.captureRecentClipboard ? clipboardTracker.recent(at: Date()) : nil)
                if !context.isEmpty {
                    capturedContext = context
                    contextExpiry = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: UInt64(CapturedContext.maximumAge * 1_000_000_000)) }
                        catch { return }
                        self?.clearContext()
                    }
                }
            }
        }
    }

    func consumeContext() -> CapturedContext? {
        // Keep the expiry task alive for selection validation, while removing raw
        // context from this service as soon as an operation takes ownership.
        defer { capturedContext = nil }
        guard let context = capturedContext, context.isFresh() else { return nil }
        return context
    }

    func clearContext() {
        contextExpiry?.cancel()
        contextExpiry = nil
        capturedContext = nil
        capturedSelection = nil
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { break }
            if attribute(kAXSubroleAttribute, of: node) as? String == kAXSecureTextFieldSubrole || attribute("AXProtectedContent", of: node) as? Bool == true { return true }
            guard let parent = attribute(kAXParentAttribute, of: node), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return false
    }

    /// Only accessibility-provided page metadata; no browser scripting or page content traversal.
    private func siteHost(in app: NSRunningApplication, focused: AXUIElement) -> String? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        var candidates = [focused]
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = attribute(name, of: application), CFGetTypeID(window) == AXUIElementGetTypeID() { candidates.append(window as! AXUIElement) }
        }
        for node in candidates where !isSecure(node) {
            for key in ["AXURL", kAXDocumentAttribute] {
                let value = attribute(key, of: node)
                let string = (value as? URL)?.absoluteString ?? (value as? String)
                if let host = ModeContextMatcher.host(from: string) { return host }
            }
        }
        return nil
    }

    @discardableResult
    func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        let written = NSPasteboard.general.setString(text, forType: .string)
        if clipboardEnabled { clipboardTracker.reset(changeCount: NSPasteboard.general.changeCount) }
        return written
    }

    func pasteSelection(_ text: String) async throws {
        try await paste(text, requireOriginalSelection: true)
    }

    func paste(_ text: String, requireOriginalSelection: Bool = false) async throws {
        guard canAutoPaste else { throw IntegrationError.accessibilityRequired }
        guard let destination = target else { throw IntegrationError.noTarget }
        guard var capturedElement = targetElement else { throw IntegrationError.unsupportedField }
        guard !destination.isTerminated else { throw IntegrationError.targetUnavailable }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmost != destination.processIdentifier {
            // Clicking Stop in Cortala may need to return focus to the captured app.
            guard frontmost == ProcessInfo.processInfo.processIdentifier else { throw IntegrationError.targetChanged }
            guard destination.activate(options: []) else { throw IntegrationError.targetUnavailable }
            try await Task.sleep(for: .milliseconds(180))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.processIdentifier else {
            throw IntegrationError.targetUnavailable
        }
        capturedElement = try validateFocus(in: destination, capturedElement: capturedElement, allowReplacement: !requireOriginalSelection)
        if requireOriginalSelection { try validateSelection(in: capturedElement) }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            throw IntegrationError.eventCreationFailed
        }
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let saved = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { saved.setData(data, forType: type) } }
            return saved
        } ?? []
        try Task.checkCancellation()
        capturedElement = try validateFocus(in: destination, capturedElement: capturedElement, allowReplacement: !requireOriginalSelection)
        if requireOriginalSelection { try validateSelection(in: capturedElement) }
        if !copy(text) {
            if !previous.isEmpty { pasteboard.writeObjects(previous) }
            if clipboardEnabled { clipboardTracker.reset(changeCount: pasteboard.changeCount) }
            throw IntegrationError.clipboardWriteFailed
        }
        let ownedChangeCount = pasteboard.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(destination.processIdentifier); up.postToPid(destination.processIdentifier)
        if restoreClipboard {
            // A later copy from the user or another application owns the clipboard.
            // Never restore over it, including a concurrent JustWisper operation.
            try? await Task.sleep(nanoseconds: 900_000_000)
            if pasteboard.changeCount == ownedChangeCount {
                pasteboard.clearContents()
                if !previous.isEmpty { pasteboard.writeObjects(previous) }
                if clipboardEnabled { clipboardTracker.reset(changeCount: pasteboard.changeCount) }
            }
        }
    }

    private func selectionRange(of element: AXUIElement) -> CFRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private func validateSelection(in element: AXUIElement) throws {
        guard let capturedSelection, Date().timeIntervalSince(capturedSelection.capturedAt) <= CapturedContext.maximumAge,
              let range = selectionRange(of: element), range.location == capturedSelection.range.location,
              range.length == capturedSelection.range.length,
              let text = attribute(kAXSelectedTextAttribute, of: element) as? String,
              SHA256.hash(data: Data(text.utf8)) == capturedSelection.digest else { throw IntegrationError.targetChanged }
    }

    private func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func isEditableNonsecureField(_ element: AXUIElement) -> Bool {
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        var settable: DarwinBoolean = false
        let canSetValue = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        return PasteFieldPolicy.allows(role: attribute(kAXRoleAttribute) as? String,
            secure: isSecure(element), enabled: attribute(kAXEnabledAttribute) as? Bool,
            editable: attribute("AXEditable") as? Bool, valueSettable: canSetValue,
            hasSelectionRange: selectionRange(of: element) != nil)
    }

    private func relatedElement(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func fingerprint(of element: AXUIElement) -> PasteDestinationFingerprint? {
        guard let role = attribute(kAXRoleAttribute, of: element) as? String,
              let value = attribute(kAXValueAttribute, of: element) as? String,
              value.utf8.count <= 100_000, let selection = selectionRange(of: element),
              let position = attribute(kAXPositionAttribute, of: element), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(kAXSizeAttribute, of: element), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        let positionValue = position as! AXValue
        let sizeValue = size as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return PasteDestinationFingerprint(role: role, identifier: attribute("AXIdentifier", of: element) as? String,
            placeholder: attribute("AXPlaceholderValue", of: element) as? String,
            contentDigest: SHA256.hash(data: Data(value.utf8)).description,
            selection: NSRange(location: selection.location, length: selection.length), frame: CGRect(origin: point, size: extent))
    }

    private func validateFocus(in app: NSRunningApplication, capturedElement: AXUIElement, allowReplacement: Bool) throws -> AXUIElement {
        guard canAutoPaste else { throw IntegrationError.accessibilityRequired }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let focused = focusedElement(in: app) else {
            throw IntegrationError.targetChanged
        }
        guard isEditableNonsecureField(focused) else { throw IntegrationError.unsupportedField }
        if CFEqual(focused, capturedElement) { return focused }
        guard allowReplacement, let original = targetFingerprint, let current = fingerprint(of: focused),
              let window = targetWindow, let currentWindow = relatedElement(kAXWindowAttribute, of: focused),
              let parent = targetParent, let currentParent = relatedElement(kAXParentAttribute, of: focused),
              original.permitsReplacement(current, sameWindow: CFEqual(window, currentWindow), sameParent: CFEqual(parent, currentParent)) else {
            throw IntegrationError.targetChanged
        }
        targetElement = focused
        return focused
    }
}

@MainActor
final class RecordingOverlay {
    private let state = OverlayState()
    private var panel: NSPanel?

    func show(text: String, level: Float = 0, style: RecordingOverlayStyle = .classic) {
        guard style != .none else { hide(); return }
        state.style = style
        update(text: text, level: level)
        let size = style == .mini ? NSSize(width: 180, height: 50) : NSSize(width: 320, height: 74)
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView: OverlayView(state: state))
            self.panel = panel
        }
        panel?.setContentSize(size)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 38))
        }
        panel?.orderFrontRegardless()
    }

    func update(text: String, level: Float) {
        state.text = text
        state.level = level.isFinite ? min(1, max(0, level)) : 0
    }

    func hide() { panel?.orderOut(nil) }
}

@MainActor
private final class OverlayState: ObservableObject {
    @Published var text = "Listening…"
    @Published var level: Float = 0
    @Published var style: RecordingOverlayStyle = .classic
}

private struct OverlayView: View {
    @ObservedObject var state: OverlayState
    var body: some View {
        HStack(spacing: state.style == .mini ? 8 : 14) {
            Image(systemName: "waveform").font(state.style == .mini ? .body : .title2).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: state.style == .mini ? 4 : 7) {
                Text(state.text).font(.system(size: state.style == .mini ? 11 : 13, weight: .medium)).lineLimit(state.style == .mini ? 1 : 2)
                ProgressView(value: Double(state.level)).tint(.purple).accessibilityLabel("Microphone level")
            }
            if state.style != .mini { Text("esc").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
        }
        .padding(state.style == .mini ? 10 : 16)
        .frame(width: state.style == .mini ? 180 : 320, height: state.style == .mini ? 50 : 74)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15)))
    }
}
