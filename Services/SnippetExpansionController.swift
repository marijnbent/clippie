import Cocoa
import SwiftUI
import ApplicationServices

enum SnippetExpansionPolicy {
    static func shouldAutoExpand(_ exactMatch: Snippet, among matches: [Snippet]) -> Bool {
        !matches.contains { snippet in
            snippet.id != exactMatch.id && snippet.trigger.hasPrefix(exactMatch.trigger)
        }
    }
}

@MainActor
final class SnippetExpansionController {
    private static let maximumVisibleSuggestions = 3

    private let generatedEventMarker: Int64 = 0x425546464552
    private let store: SnippetStore
    private lazy var suggestionWindowController = SnippetSuggestionWindowController(
        onSelectSnippet: { [weak self] snippet in
            self?.expand(snippet)
        },
        onHoverSuggestion: { [weak self] index in
            self?.selectSuggestion(at: index)
        }
    )
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activeQuery: String?
    private var matches: [Snippet] = []
    private var selectedIndex = 0
    private var hasNavigatedSuggestions = false
    private var activationObserver: NSObjectProtocol?
    private var sessionAnchorRect: CGRect?
    private var sessionAnchorStrategy: AnchorStrategy?
    private var axObserver: AXObserver?
    private var axObserverSource: CFRunLoopSource?
    private var observedApplication: NSRunningApplication?
    private var observedApplicationElement: AXUIElement?
    private var observedFocusedWindow: AXUIElement?
    private var observedFocusedElement: AXUIElement?
    private var lastAnchorLogKey: String?
    private var lastObserverLogKey: String?
    private var lastActivationLogKey: String?
    
    init(store: SnippetStore) {
        self.store = store
    }
    
    func start() {
        guard eventTap == nil else { return }
        
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<SnippetExpansionController>.fromOpaque(userInfo).takeUnretainedValue()
                return controller.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            print("[clippie] Failed to create snippet event tap")
            return
        }
        
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        
        CGEvent.tapEnable(tap: tap, enable: true)
        
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelSession()
            }
        }
    }
    
    func stop() {
        cancelSession()
        
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }
    
    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        
        if event.getIntegerValueField(.eventSourceUserData) == generatedEventMarker {
            return Unmanaged.passUnretained(event)
        }
        
        guard type == .keyDown, let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        
        if shouldConsumeControlKey(nsEvent) {
            return nil
        }
        
        processTextKey(nsEvent)
        return Unmanaged.passUnretained(event)
    }
    
    private func shouldConsumeControlKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Escape
            guard isSessionActive else { return false }
            cancelSession()
            return true
        case 125: // Down
            guard suggestionWindowController.isVisible, !matches.isEmpty else { return false }
            hasNavigatedSuggestions = true
            selectedIndex = min(selectedIndex + 1, matches.count - 1)
            refreshSuggestions()
            return true
        case 126: // Up
            guard suggestionWindowController.isVisible, !matches.isEmpty else { return false }
            hasNavigatedSuggestions = true
            selectedIndex = max(selectedIndex - 1, 0)
            refreshSuggestions()
            return true
        case 36: // Return
            guard suggestionWindowController.isVisible,
                  let snippet = selectedSnippet,
                  shouldCommitSnippetSelectionOnReturn else { return false }
            expand(snippet)
            return true
        case 48: // Tab
            guard suggestionWindowController.isVisible, let snippet = selectedSnippet else { return false }
            expand(snippet)
            return true
        case 51: // Backspace
            guard let activeQuery else { return false }
            if activeQuery.isEmpty {
                cancelSession()
            } else {
                self.activeQuery = String(activeQuery.dropLast())
                selectedIndex = 0
                refreshSuggestionsAsync()
            }
            return false
        default:
            return false
        }
    }
    
    private func processTextKey(_ event: NSEvent) {
        let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option])
        let characters = event.characters ?? ""

        guard !isTypingInsideClippie else {
            if isSessionActive {
                cancelSession()
            }
            return
        }
        
        if characters == ":" && disallowedModifiers.isEmpty {
            startSession()
            return
        }
        
        guard let activeQuery else { return }
        
        if !disallowedModifiers.isEmpty {
            cancelSession()
            return
        }
        
        guard Snippet.isSupportedTriggerCharacter(characters) else {
            cancelSession()
            return
        }

        let normalizedCharacters = Snippet.normalizeTrigger(characters)
        if normalizedCharacters.count == 1, let scalar = normalizedCharacters.first {
            self.activeQuery = activeQuery + String(scalar)
            selectedIndex = 0
            refreshSuggestionsAsync()
            return
        }
        
        cancelSession()
    }
    
    private func refreshSuggestionsAsync() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshSuggestions()
        }
    }
    
    private func refreshSuggestions() {
        guard let activeQuery else {
            suggestionWindowController.hide()
            return
        }

        guard !activeQuery.isEmpty else {
            matches = []
            selectedIndex = 0
            suggestionWindowController.hide()
            return
        }

        ensureObservationTargetCurrent()
        
        let allMatches = store.expansionMatches(for: activeQuery)

        if let exactMatch = exactMatch(for: activeQuery),
           SnippetExpansionPolicy.shouldAutoExpand(exactMatch, among: allMatches) {
            expand(exactMatch)
            return
        }

        matches = Array(allMatches.prefix(Self.maximumVisibleSuggestions))
        if selectedIndex >= matches.count {
            selectedIndex = max(0, matches.count - 1)
        }
        
        guard !matches.isEmpty else {
            suggestionWindowController.hide()
            return
        }
        
        let anchorResolution = resolveSessionAnchor()
        if anchorResolution.strategy.shouldCache {
            sessionAnchorRect = anchorResolution.rect
            sessionAnchorStrategy = anchorResolution.strategy
        }
        logAnchorResolutionIfNeeded(anchorResolution)

        suggestionWindowController.show(
            snippets: matches,
            selectedIndex: selectedIndex,
            anchorRect: anchorResolution.rect,
            anchorStrategy: anchorResolution.strategy
        )
    }
    
    private func cancelSession() {
        activeQuery = nil
        matches = []
        selectedIndex = 0
        hasNavigatedSuggestions = false
        sessionAnchorRect = nil
        sessionAnchorStrategy = nil
        lastAnchorLogKey = nil
        suggestionWindowController.hide()
        stopObservingActiveTarget()
    }
    
    private var isSessionActive: Bool {
        activeQuery != nil
    }
    
    private var selectedSnippet: Snippet? {
        guard matches.indices.contains(selectedIndex) else { return nil }
        return matches[selectedIndex]
    }

    private func selectSuggestion(at index: Int) {
        guard matches.indices.contains(index), selectedIndex != index else { return }
        selectedIndex = index
        hasNavigatedSuggestions = true
        suggestionWindowController.update(snippets: matches, selectedIndex: selectedIndex)
    }

    private func startSession() {
        activeQuery = ""
        matches = []
        selectedIndex = 0
        hasNavigatedSuggestions = false
        sessionAnchorRect = nil
        sessionAnchorStrategy = nil
        lastAnchorLogKey = nil
        ensureObservationTargetCurrent(force: true)
    }
    
    private func expand(_ snippet: Snippet) {
        let deleteCount = (activeQuery?.count ?? 0) + 1
        cancelSession()
        store.recordUsage(for: snippet.id)
        deleteTypedTrigger(characterCount: deleteCount)
        insertText(snippet.content)
        playInsertionSound()
    }
    
    private func deleteTypedTrigger(characterCount: Int) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        
        for _ in 0..<characterCount {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            keyDown?.setIntegerValueField(.eventSourceUserData, value: generatedEventMarker)
            keyUp?.setIntegerValueField(.eventSourceUserData, value: generatedEventMarker)
            keyDown?.post(tap: .cgAnnotatedSessionEventTap)
            keyUp?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
    
    private func insertText(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        
        let utf16 = Array(text.utf16)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        keyDown?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        keyUp?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyDown?.setIntegerValueField(.eventSourceUserData, value: generatedEventMarker)
        keyUp?.setIntegerValueField(.eventSourceUserData, value: generatedEventMarker)
        
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
    
    private func caretRect(for focusedElement: AXUIElement) -> CGRect? {
        guard let selectedRange = selectedTextRange(for: focusedElement),
              let bounds = boundsForRange(selectedRange, in: focusedElement) else {
            return nil
        }

        let elementFrame = accessibilityFrame(for: focusedElement)
        return resolvedCaretRect(fromAccessibilityBounds: bounds, constrainedTo: elementFrame)
    }

    private func focusedElementRect(for focusedElement: AXUIElement) -> CGRect? {
        guard let bounds = accessibilityFrame(for: focusedElement) else {
            return nil
        }

        return resolvedElementRect(fromAccessibilityBounds: bounds)
    }

    private func focusedWindowRect() -> CGRect? {
        guard let focusedWindow = currentFocusedWindow(),
              let bounds = accessibilityFrame(for: focusedWindow) else {
            return nil
        }

        return resolvedElementRect(fromAccessibilityBounds: bounds)
    }
    
    private func fallbackAnchorRect() -> CGRect {
        let screen = preferredFallbackScreen()
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: visibleFrame.midX, y: visibleFrame.midY, width: 1, height: 1)
    }

    private func preferredFallbackScreen() -> NSScreen? {
        if let sessionAnchorRect,
           let screen = screen(containing: sessionAnchorRect) {
            return screen
        }

        if let focusedWindowRect = focusedWindowRect(),
           let screen = screen(containing: focusedWindowRect) {
            return screen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        let anchorPoint = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first(where: {
            $0.frame.contains(anchorPoint) || $0.visibleFrame.intersects(rect)
        })
    }

    private func resolveSessionAnchor() -> AnchorResolution {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = frontmostApplication?.bundleIdentifier
        let processID = frontmostApplication?.processIdentifier
        let focusedElement = currentFocusedElement()
        let focusedRole = focusedElement.flatMap { stringAttribute(kAXRoleAttribute as CFString, for: $0) }
        let focusedSubrole = focusedElement.flatMap { stringAttribute(kAXSubroleAttribute as CFString, for: $0) }

        if let focusedElement,
           let caretRect = caretRect(for: focusedElement) {
            return AnchorResolution(
                rect: caretRect,
                strategy: .caretBounds,
                bundleIdentifier: bundleIdentifier,
                processID: processID,
                focusedRole: focusedRole,
                focusedSubrole: focusedSubrole
            )
        }

        return AnchorResolution(
            rect: fallbackAnchorRect(),
            strategy: .screenCenter,
            bundleIdentifier: bundleIdentifier,
            processID: processID,
            focusedRole: focusedRole,
            focusedSubrole: focusedSubrole
        )
    }

    private func exactMatch(for query: String) -> Snippet? {
        store.exactTriggerMatch(for: query)
    }

    private var isTypingInsideClippie: Bool {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        return frontmostApplication.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
              let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(focusedElementRef, to: AXUIElement.self)
    }

    private func currentFocusedElement() -> AXUIElement? {
        observedFocusedElement ?? focusedElement()
    }

    private func currentFocusedWindow() -> AXUIElement? {
        if let observedFocusedWindow {
            return observedFocusedWindow
        }

        guard let observedApplicationElement else {
            return nil
        }

        return focusedWindow(in: observedApplicationElement)
    }

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
        var selectedRangeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
              let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return nil
        }

        let rangeValue = selectedRangeRef as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selectedRange) else {
            return nil
        }

        return selectedRange
    }

    private func boundsForRange(_ range: CFRange, in element: AXUIElement) -> CGRect? {
        var insertionRange = range
        insertionRange.length = 0
        guard let insertionRangeValue = AXValueCreate(.cfRange, &insertionRange) else {
            return nil
        }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            insertionRangeValue,
            &boundsRef
        ) == .success,
        let boundsRef,
        CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }

        let boundsValue = boundsRef as! AXValue
        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &bounds) else {
            return nil
        }

        return bounds
    }

    private func accessibilityFrame(for element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func focusedWindow(in applicationElement: AXUIElement) -> AXUIElement? {
        axElementAttribute(kAXFocusedWindowAttribute as CFString, for: applicationElement)
            ?? axElementAttribute(kAXMainWindowAttribute as CFString, for: applicationElement)
    }

    private func focusedWindowAnchorRect(from windowRect: CGRect) -> CGRect? {
        guard windowRect.width > 0, windowRect.height > 0 else {
            return nil
        }

        let anchorX = min(windowRect.maxX - 24, windowRect.minX + 28)
        let anchorY = max(windowRect.minY + 24, windowRect.maxY - 56)
        return CGRect(x: anchorX, y: anchorY, width: 1, height: 1)
    }

    private func resolvedCaretRect(fromAccessibilityBounds bounds: CGRect, constrainedTo accessibilityElementBounds: CGRect?) -> CGRect? {
        guard isFinite(bounds) else {
            return nil
        }

        guard var convertedBounds = appKitRect(fromAccessibilityRect: bounds) else {
            return nil
        }

        if bounds.origin == .zero && bounds.size == .zero {
            return nil
        }

        if convertedBounds.width <= 0 {
            convertedBounds.size.width = 1
        }

        if convertedBounds.height <= 0 {
            convertedBounds.size.height = 18
        }

        let desktopFrame = NSScreen.screens.reduce(into: CGRect.null) { partialResult, screen in
            partialResult = partialResult.union(screen.frame)
        }
        let sanityFrame = desktopFrame.insetBy(dx: -320, dy: -320)
        guard sanityFrame.intersects(convertedBounds) else {
            return nil
        }

        if let accessibilityElementBounds,
           let convertedElementBounds = resolvedElementRect(fromAccessibilityBounds: accessibilityElementBounds) {
            let expandedElementBounds = convertedElementBounds.insetBy(dx: -24, dy: -24)
            guard expandedElementBounds.intersects(convertedBounds) else {
                return nil
            }
        }

        return convertedBounds.integral
    }

    private func resolvedElementRect(fromAccessibilityBounds bounds: CGRect) -> CGRect? {
        guard isFinite(bounds),
              bounds.width > 0,
              bounds.height > 0,
              var convertedBounds = appKitRect(fromAccessibilityRect: bounds) else {
            return nil
        }

        let desktopFrame = NSScreen.screens.reduce(into: CGRect.null) { partialResult, screen in
            partialResult = partialResult.union(screen.frame)
        }
        let sanityFrame = desktopFrame.insetBy(dx: -320, dy: -320)
        guard sanityFrame.intersects(convertedBounds) else {
            return nil
        }

        if convertedBounds.width < 24 {
            convertedBounds.size.width = 24
        }

        if convertedBounds.height < 24 {
            convertedBounds.size.height = 24
        }

        return convertedBounds.integral
    }

    private func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite &&
        rect.origin.y.isFinite &&
        rect.size.width.isFinite &&
        rect.size.height.isFinite
    }

    private func appKitRect(fromAccessibilityRect accessibilityRect: CGRect) -> CGRect? {
        let desktopFrame = NSScreen.screens.reduce(into: CGRect.null) { partialResult, screen in
            partialResult = partialResult.union(screen.frame)
        }
        guard !desktopFrame.isNull else {
            return nil
        }

        var convertedRect = accessibilityRect
        convertedRect.origin.y = desktopFrame.maxY - accessibilityRect.maxY
        return convertedRect
    }

    private func ensureObservationTargetCurrent(force: Bool = false) {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            stopObservingActiveTarget()
            return
        }

        if !force, observedApplication?.processIdentifier == frontmostApplication.processIdentifier {
            refreshObservedElements()
            return
        }

        stopObservingActiveTarget()
        observedApplication = frontmostApplication
        observedApplicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        activateAccessibilityIfNeeded(for: frontmostApplication)
        refreshObservedElements()

        guard let observedApplicationElement else {
            logObserver("Skipped AX observer setup because the app element was unavailable.")
            return
        }

        var observer: AXObserver?
        let observerError = AXObserverCreate(
            frontmostApplication.processIdentifier,
            { _, element, notification, refcon in
                guard let refcon else { return }
                let controller = Unmanaged<SnippetExpansionController>.fromOpaque(refcon).takeUnretainedValue()
                controller.handleAXNotification(notification as String, element: element)
            },
            &observer
        )

        guard observerError == .success, let observer else {
            logObserver("Failed to create AX observer for \(frontmostApplication.localizedName ?? "unknown") with error=\(describe(observerError))")
            return
        }

        axObserver = observer
        axObserverSource = AXObserverGetRunLoopSource(observer)

        if let axObserverSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), axObserverSource, .commonModes)
        }

        registerAppNotifications(observer, for: observedApplicationElement)
        registerFocusedWindowNotifications()
        registerFocusedElementNotifications()

        logObserver("Observing \(frontmostApplication.localizedName ?? "unknown") bundle=\(frontmostApplication.bundleIdentifier ?? "unknown") pid=\(frontmostApplication.processIdentifier)")
    }

    private func stopObservingActiveTarget() {
        unregisterFocusedElementNotifications()
        unregisterFocusedWindowNotifications()

        if let axObserverSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), axObserverSource, .commonModes)
            self.axObserverSource = nil
        }

        axObserver = nil
        observedApplication = nil
        observedApplicationElement = nil
        observedFocusedWindow = nil
        observedFocusedElement = nil
        lastObserverLogKey = nil
        lastActivationLogKey = nil
    }

    private func refreshObservedElements() {
        if let observedApplicationElement {
            observedFocusedWindow = focusedWindow(in: observedApplicationElement)
        } else {
            observedFocusedWindow = nil
        }

        observedFocusedElement = focusedElement()
    }

    private func handleAXNotification(_ notification: String, element: AXUIElement) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard isSessionActive else { return }

            sessionAnchorRect = nil

            switch notification {
            case kAXFocusedUIElementChangedNotification:
                unregisterFocusedElementNotifications()
                refreshObservedElements()
                registerFocusedElementNotifications()
            case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
                unregisterFocusedWindowNotifications()
                unregisterFocusedElementNotifications()
                refreshObservedElements()
                registerFocusedWindowNotifications()
                registerFocusedElementNotifications()
            case kAXMovedNotification, kAXResizedNotification, kAXValueChangedNotification, kAXSelectedTextChangedNotification:
                refreshObservedElements()
            default:
                refreshObservedElements()
            }

            let notificationDescription = notification
            let role = stringAttribute(kAXRoleAttribute as CFString, for: element) ?? "unknown"
            logObserver("Received \(notificationDescription) role=\(role)")
            refreshSuggestionsAsync()
        }
    }

    private func registerAppNotifications(_ observer: AXObserver, for applicationElement: AXUIElement) {
        for notification in [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXValueChangedNotification,
            kAXSelectedTextChangedNotification
        ] {
            addNotification(notification, to: applicationElement, observer: observer)
        }
    }

    private func registerFocusedWindowNotifications() {
        guard let axObserver, let observedFocusedWindow else { return }
        for notification in [kAXMovedNotification, kAXResizedNotification] {
            addNotification(notification, to: observedFocusedWindow, observer: axObserver)
        }
    }

    private func unregisterFocusedWindowNotifications() {
        guard let axObserver, let observedFocusedWindow else { return }
        for notification in [kAXMovedNotification, kAXResizedNotification] {
            _ = AXObserverRemoveNotification(axObserver, observedFocusedWindow, notification as CFString)
        }
    }

    private func registerFocusedElementNotifications() {
        guard let axObserver, let observedFocusedElement else { return }
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            addNotification(notification, to: observedFocusedElement, observer: axObserver)
        }
    }

    private func unregisterFocusedElementNotifications() {
        guard let axObserver, let observedFocusedElement else { return }
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            _ = AXObserverRemoveNotification(axObserver, observedFocusedElement, notification as CFString)
        }
    }

    private func addNotification(_ notification: String, to element: AXUIElement, observer: AXObserver) {
        let error = AXObserverAddNotification(
            observer,
            element,
            notification as CFString,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        switch error {
        case .success, .notificationAlreadyRegistered:
            return
        case .notificationUnsupported:
            logObserver("Notification \(notification) unsupported for current AX element.")
        default:
            logObserver("Failed to register notification \(notification) error=\(describe(error))")
        }
    }

    private func activateAccessibilityIfNeeded(for application: NSRunningApplication) {
        guard let observedApplicationElement else {
            return
        }

        guard let mode = accessibilityActivationMode(for: application.bundleIdentifier) else {
            return
        }

        let logKey = "\(application.processIdentifier)-\(mode.rawValue)"
        guard lastActivationLogKey != logKey else {
            return
        }
        lastActivationLogKey = logKey

        switch mode {
        case .chromiumEnhancedUI:
            guard let targetWindow = focusedWindow(in: observedApplicationElement) else {
                logObserver("Skipped Chromium accessibility activation because no focused window was available.")
                return
            }

            let error = AXUIElementSetAttributeValue(
                targetWindow,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanTrue
            )
            logObserver("Activated Chromium accessibility bundle=\(application.bundleIdentifier ?? "unknown") result=\(describe(error))")
        case .electronManualAccessibility:
            let error = AXUIElementSetAttributeValue(
                observedApplicationElement,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
            logObserver("Activated Electron accessibility bundle=\(application.bundleIdentifier ?? "unknown") result=\(describe(error))")
        }
    }

    private func accessibilityActivationMode(for bundleIdentifier: String?) -> AccessibilityActivationMode? {
        guard let bundleIdentifier else {
            return nil
        }

        let chromiumBundles: Set<String> = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "org.chromium.Chromium",
            "company.thebrowser.Browser",
            "com.vivaldi.Vivaldi"
        ]
        if chromiumBundles.contains(bundleIdentifier) {
            return .chromiumEnhancedUI
        }

        let electronBundles: Set<String> = [
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
            "com.microsoft.VSCode",
            "notion.id",
            "com.figma.Desktop"
        ]
        if electronBundles.contains(bundleIdentifier) {
            return .electronManualAccessibility
        }

        return nil
    }

    private func axElementAttribute(_ attribute: CFString, for element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func stringAttribute(_ attribute: CFString, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }

        return value as? String
    }

    private func logAnchorResolutionIfNeeded(_ resolution: AnchorResolution) {
        let logKey = [
            resolution.strategy.rawValue,
            resolution.bundleIdentifier ?? "unknown",
            resolution.focusedRole ?? "unknown",
            resolution.focusedSubrole ?? "none"
        ].joined(separator: "|")

        guard lastAnchorLogKey != logKey else {
            return
        }
        lastAnchorLogKey = logKey

        let strategySuffix = sessionAnchorStrategy.map { " previous=\($0.rawValue)" } ?? ""
        print(
            "[clippie snippet] anchor strategy=\(resolution.strategy.rawValue)\(strategySuffix) " +
            "bundle=\(resolution.bundleIdentifier ?? "unknown") pid=\(resolution.processID ?? 0) " +
            "role=\(resolution.focusedRole ?? "unknown") subrole=\(resolution.focusedSubrole ?? "none") " +
            "rect=\(NSStringFromRect(resolution.rect))"
        )
    }

    private func logObserver(_ message: String) {
        guard let observedApplication else {
            print("[clippie snippet] \(message)")
            return
        }

        let logKey = "\(observedApplication.processIdentifier)|\(message)"
        guard lastObserverLogKey != logKey else {
            return
        }
        lastObserverLogKey = logKey

        print(
            "[clippie snippet] \(message) " +
            "bundle=\(observedApplication.bundleIdentifier ?? "unknown") pid=\(observedApplication.processIdentifier)"
        )
    }

    private func describe(_ error: AXError) -> String {
        switch error {
        case .success:
            return "success"
        case .failure:
            return "failure"
        case .illegalArgument:
            return "illegalArgument"
        case .invalidUIElement:
            return "invalidUIElement"
        case .invalidUIElementObserver:
            return "invalidUIElementObserver"
        case .cannotComplete:
            return "cannotComplete"
        case .attributeUnsupported:
            return "attributeUnsupported"
        case .actionUnsupported:
            return "actionUnsupported"
        case .notificationUnsupported:
            return "notificationUnsupported"
        case .notImplemented:
            return "notImplemented"
        case .notificationAlreadyRegistered:
            return "notificationAlreadyRegistered"
        case .notificationNotRegistered:
            return "notificationNotRegistered"
        case .apiDisabled:
            return "apiDisabled"
        case .noValue:
            return "noValue"
        case .parameterizedAttributeUnsupported:
            return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision:
            return "notEnoughPrecision"
        default:
            return "unknown(\(error.rawValue))"
        }
    }

    private func playInsertionSound() {
        NSSound(named: NSSound.Name("Pop"))?.play()
    }

    private var shouldCommitSnippetSelectionOnReturn: Bool {
        guard let activeQuery else {
            return hasNavigatedSuggestions
        }

        return !activeQuery.isEmpty || hasNavigatedSuggestions
    }
}

private enum AnchorStrategy: String {
    case caretBounds
    case screenCenter

    var shouldCache: Bool {
        switch self {
        case .caretBounds:
            return true
        case .screenCenter:
            return false
        }
    }
}

private struct AnchorResolution {
    let rect: CGRect
    let strategy: AnchorStrategy
    let bundleIdentifier: String?
    let processID: pid_t?
    let focusedRole: String?
    let focusedSubrole: String?
}

private enum AccessibilityActivationMode: String {
    case chromiumEnhancedUI
    case electronManualAccessibility
}

@MainActor
private final class SnippetSuggestionWindowController: NSWindowController {
    private let hostingView: NSHostingView<SnippetSuggestionListView>
    private let onSelectSnippet: (Snippet) -> Void
    private let onHoverSuggestion: (Int) -> Void
    
    init(
        onSelectSnippet: @escaping (Snippet) -> Void,
        onHoverSuggestion: @escaping (Int) -> Void
    ) {
        self.onSelectSnippet = onSelectSnippet
        self.onHoverSuggestion = onHoverSuggestion
        hostingView = NSHostingView(
            rootView: SnippetSuggestionListView(
                snippets: [],
                selectedIndex: 0,
                onSelectSnippet: onSelectSnippet,
                onHoverSuggestion: onHoverSuggestion
            )
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.contentView = hostingView
        
        super.init(window: panel)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    var isVisible: Bool {
        window?.isVisible == true
    }
    
    func show(snippets: [Snippet], selectedIndex: Int, anchorRect: CGRect, anchorStrategy: AnchorStrategy) {
        update(snippets: snippets, selectedIndex: selectedIndex)
        
        let width: CGFloat = 310
        let rowHeight: CGFloat = 44
        let chromeHeight: CGFloat = 10
        let height = CGFloat(snippets.count) * rowHeight + chromeHeight
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        
        window?.setContentSize(contentRect.size)
        
        let preferredOrigin = preferredOrigin(
            for: anchorRect,
            popupSize: contentRect.size,
            anchorStrategy: anchorStrategy
        )
        window?.setFrameOrigin(preferredOrigin)
        window?.orderFrontRegardless()
    }

    func update(snippets: [Snippet], selectedIndex: Int) {
        hostingView.rootView = SnippetSuggestionListView(
            snippets: snippets,
            selectedIndex: selectedIndex,
            onSelectSnippet: onSelectSnippet,
            onHoverSuggestion: onHoverSuggestion
        )
    }
    
    func hide() {
        window?.orderOut(nil)
    }
    
    private func preferredOrigin(
        for anchorRect: CGRect,
        popupSize: CGSize,
        anchorStrategy: AnchorStrategy
    ) -> CGPoint {
        let anchorPoint = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(anchorPoint) || $0.visibleFrame.intersects(anchorRect)
        }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        if anchorStrategy == .screenCenter {
            let x = min(
                max(visibleFrame.midX - (popupSize.width / 2), visibleFrame.minX + 8),
                visibleFrame.maxX - popupSize.width - 8
            )
            let y = min(
                max(visibleFrame.midY - (popupSize.height / 2), visibleFrame.minY + 8),
                visibleFrame.maxY - popupSize.height - 8
            )
            return CGPoint(x: x, y: y)
        }
        
        var x = anchorRect.minX
        var y = anchorRect.minY - popupSize.height - 8
        
        if y < visibleFrame.minY + 8 {
            y = anchorRect.maxY + 8
        }
        
        x = min(max(x, visibleFrame.minX + 8), visibleFrame.maxX - popupSize.width - 8)
        y = min(max(y, visibleFrame.minY + 8), visibleFrame.maxY - popupSize.height - 8)
        
        return CGPoint(x: x, y: y)
    }
}

private struct SnippetSuggestionListView: View {
    let snippets: [Snippet]
    let selectedIndex: Int
    let onSelectSnippet: (Snippet) -> Void
    let onHoverSuggestion: (Int) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    
    var body: some View {
        Group {
            if reduceTransparency {
                content
                    .background(Color(nsColor: .windowBackgroundColor), in: shape)
            } else if #available(macOS 26.0, *) {
                content
                    .glassEffect(.regular.interactive(), in: shape)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
            }
        }
        .clipShape(shape)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ForEach(Array(snippets.enumerated()), id: \.element.id) { index, snippet in
                suggestionRow(snippet, index: index)
            }
        }
        .padding(5)
    }

    private func suggestionRow(_ snippet: Snippet, index: Int) -> some View {
        let isSelected = index == selectedIndex

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(":\(snippet.trigger)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(snippet.content.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 9)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isSelected ? 1 : 0.72)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                onHoverSuggestion(index)
            }
        }
        .onTapGesture {
            onSelectSnippet(snippet)
        }
    }
}
