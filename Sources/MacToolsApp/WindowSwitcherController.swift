import AppKit
import ApplicationServices
import Carbon
import MacToolsCore

private func windowSwitcherEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let controller = Unmanaged<WindowSwitcherController>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                controller.enableEventTap()
            }
        }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let eventType = type
    let commandPressed = flags.contains(.maskCommand)
    let shiftPressed = flags.contains(.maskShift)

    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let controller = Unmanaged<WindowSwitcherController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()

    let shouldSuppress = controller.handleEvent(
        type: eventType,
        keyCode: keyCode,
        commandPressed: commandPressed,
        shiftPressed: shiftPressed
    )

    return shouldSuppress ? nil : Unmanaged.passUnretained(event)
}

private func windowSwitcherAXObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else {
        return
    }

    let controller = Unmanaged<WindowSwitcherController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    let notificationName = notification as String
    var processIdentifier: pid_t = 0
    AXUIElementGetPid(element, &processIdentifier)
    let elementHash = CFHash(element)
    DispatchQueue.main.async {
        controller.handleAXNotification(
            notificationName,
            processIdentifier: processIdentifier,
            elementHash: elementHash
        )
    }
}

@MainActor
final class WindowSwitcherController {
    private enum WindowLifecycleState {
        case active
        case dormant
        case indeterminate
        case destroyed
    }

    private enum AXWindowValidity {
        case switchable
        case notSwitchable
        case indeterminate
        case destroyed
    }

    private struct WindowChoice {
        var key: String
        var title: String
        var appName: String
        var bundleIdentifier: String
        var processIdentifier: pid_t
        var icon: NSImage?
        var axWindow: AXUIElement
        var cgWindowIdentifier: CGWindowID?
        var lastKnownBounds: CGRect?
    }

    private struct PendingFocusVerification {
        var key: String
        var title: String
        var processIdentifier: pid_t
        var window: AXUIElement
        var startedAt: CFAbsoluteTime
    }

    private struct AXApplicationObservation {
        var observer: AXObserver
        var appElement: AXUIElement
        var registeredNotifications: Set<String>
        var unsupportedNotifications: Set<String>
    }

    private struct AXWindowObservation {
        var observer: AXObserver
        var window: AXUIElement
    }

    private struct FrontmostApplicationIdentity {
        var bundleIdentifier: String?
        var processIdentifier: pid_t
        var localizedName: String?
    }

    private let runtime: AutomationRuntime
    private var configuration: UserConfiguration
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: UnsafeMutableRawPointer?
    private var choices: [WindowChoice] = []
    private var recentChoices: [String: WindowChoice] = [:]
    private var recentKeys: [String] = []
    private var selectedIndex = 0
    private var sameApplicationMode = false
    private var commandPressed = false
    private var shiftPressed = false
    private var overlayWindow: NSWindow?
    private let overlayDisplayDelay: TimeInterval = 0.15
    private var overlayDisplayWorkItem: DispatchWorkItem?
    private var backwardRepeatPolicy: WindowSwitcherBackwardRepeatPolicy {
        WindowSwitcherBackwardRepeatPolicy(
            initialDelay: NSEvent.keyRepeatDelay,
            repeatInterval: NSEvent.keyRepeatInterval
        )
    }
    private var backwardRepeatWorkItem: DispatchWorkItem?
    private let overlayStack = NSStackView()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axApplicationObservers: [pid_t: AXApplicationObservation] = [:]
    private var axWindowObservers: [String: AXWindowObservation] = [:]
    private var pendingFocusVerification: PendingFocusVerification?
    private let activationCapturePolicy = WindowActivationCapturePolicy()
    private var activationCaptureGeneration: UInt64 = 0
    private var completedActivationCaptureGeneration: UInt64?
    private let axMessagingTimeout: Float = 0.08
    private let axWindowEnumerationRetryTimeout: Float = 0.30

    init(runtime: AutomationRuntime, configuration: UserConfiguration) {
        self.runtime = runtime
        self.configuration = configuration
    }

    func start() {
        guard configuration.windowSwitcher.enabled else {
            return
        }
        stop()
        retainedSelf = Unmanaged.passUnretained(self).toOpaque()
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: windowSwitcherEventTapCallback,
            userInfo: retainedSelf
        )

        guard let eventTap else {
            showStatus("Unable to create window switcher event tap. Check Accessibility permission.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        installWorkspaceObservers()
        enableEventTap()
    }

    func apply(configuration: UserConfiguration) {
        precondition(Thread.isMainThread)
        let wasEnabled = self.configuration.windowSwitcher.enabled
        let isEnabled = configuration.windowSwitcher.enabled
        self.configuration = configuration

        switch (wasEnabled, isEnabled) {
        case (false, true):
            start()
        case (true, false):
            stop()
        case (true, true) where eventTap == nil:
            start()
        default:
            break
        }
    }

    func stop() {
        activationCaptureGeneration &+= 1
        completedActivationCaptureGeneration = nil
        hideOverlay()
        removeWorkspaceObservers()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        retainedSelf = nil
        removeAXObservers()
        pendingFocusVerification = nil
        choices.removeAll()
        recentChoices.removeAll()
        recentKeys.removeAll()
    }

    func enableEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    nonisolated func handleEvent(
        type: CGEventType,
        keyCode: Int64,
        commandPressed: Bool,
        shiftPressed: Bool
    ) -> Bool {
        let isTab = keyCode == Int64(kVK_Tab)
        let isBacktick = keyCode == Int64(kVK_ANSI_Grave)

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.recordFocusedWindow()
            }
            return false
        }

        if type == .keyDown, commandPressed, isTab {
            DispatchQueue.main.async {
                self.log("event keyDown cmd+tab")
                self.step(sameApplication: false, reverse: shiftPressed)
            }
            return true
        }

        if type == .keyDown, commandPressed, isBacktick {
            DispatchQueue.main.async {
                self.log("event keyDown cmd+`")
                self.step(sameApplication: true, reverse: shiftPressed)
            }
            return true
        }

        if type == .keyUp, commandPressed, (isTab || isBacktick) {
            return true
        }

        if type == .flagsChanged {
            DispatchQueue.main.async {
                self.handleFlagsChanged(commandPressed: commandPressed, shiftPressed: shiftPressed)
            }
            return false
        }

        return false
    }

    private func step(sameApplication: Bool, reverse: Bool) {
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            log("step total elapsed=\(elapsedMilliseconds(since: started)) sameApplication=\(sameApplication) reverse=\(reverse) choices=\(choices.count)")
        }

        if choices.isEmpty || sameApplicationMode != sameApplication {
            sameApplicationMode = sameApplication
            choices = buildChoices(sameApplication: sameApplication)
            selectedIndex = choices.count > 1 ? 1 : 0
            log("build choices sameApplication=\(sameApplication) count=\(choices.count) selectedIndex=\(selectedIndex)")
        } else if !choices.isEmpty {
            selectedIndex = reverse
                ? (selectedIndex - 1 + choices.count) % choices.count
                : (selectedIndex + 1) % choices.count
            log("step reverse=\(reverse) selectedIndex=\(selectedIndex) choice=\(describe(choices[selectedIndex]))")
        }

        guard !choices.isEmpty else {
            showStatus(sameApplication ? "No same-application windows" : "No windows to switch")
            return
        }

        showOrScheduleOverlay()
    }

    private func handleFlagsChanged(commandPressed: Bool, shiftPressed: Bool) {
        let wasCommandPressed = self.commandPressed
        let wasShiftPressed = self.shiftPressed
        self.commandPressed = commandPressed
        self.shiftPressed = shiftPressed

        if commandPressed, shiftPressed, !wasShiftPressed {
            startBackwardRepeatIfPossible()
        }

        if !commandPressed || !shiftPressed {
            cancelBackwardRepeat()
        }

        if wasCommandPressed, !commandPressed {
            commitSelectionIfNeeded()
        }
    }

    private func startBackwardRepeatIfPossible() {
        guard overlayWindow?.isVisible == true,
              commandPressed,
              shiftPressed,
              choices.count > 1,
              backwardRepeatWorkItem == nil else {
            return
        }
        stepBackwardSelection()
        scheduleBackwardRepeat(after: backwardRepeatPolicy.initialDelay)
    }

    private func scheduleBackwardRepeat(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.backwardRepeatWorkItem = nil
            guard self.overlayWindow?.isVisible == true,
                  self.commandPressed,
                  self.shiftPressed else {
                return
            }
            self.stepBackwardSelection()
            self.scheduleBackwardRepeat(after: self.backwardRepeatPolicy.repeatInterval)
        }
        backwardRepeatWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func stepBackwardSelection() {
        guard let previousIndex = WindowSwitcherSelectionPolicy.previousIndex(
            currentIndex: selectedIndex,
            choiceCount: choices.count
        ) else {
            return
        }
        selectedIndex = previousIndex
        renderOverlay()
    }

    private func cancelBackwardRepeat() {
        backwardRepeatWorkItem?.cancel()
        backwardRepeatWorkItem = nil
    }

    private func commitSelectionIfNeeded() {
        cancelScheduledOverlay()
        guard !choices.isEmpty, choices.indices.contains(selectedIndex) else {
            hideOverlay()
            return
        }

        let choice = choices[selectedIndex]
        log("commit selectedIndex=\(selectedIndex) choice=\(describe(choice))")
        hideOverlay()
        choices.removeAll()
        focus(choice)
        remember(choice)
    }

    private func showOrScheduleOverlay() {
        guard !choices.isEmpty else {
            return
        }
        if overlayWindow?.isVisible == true {
            renderOverlay()
            return
        }
        guard overlayDisplayWorkItem == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.commandPressed,
                  !self.choices.isEmpty else {
                return
            }
            self.renderOverlay()
            self.startBackwardRepeatIfPossible()
        }
        overlayDisplayWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + overlayDisplayDelay, execute: workItem)
    }

    private func cancelScheduledOverlay() {
        overlayDisplayWorkItem?.cancel()
        overlayDisplayWorkItem = nil
    }

    private func buildChoices(sameApplication: Bool) -> [WindowChoice] {
        let started = CFAbsoluteTimeGetCurrent()
        var cgCount = 0
        var enumeratedCount = 0
        defer {
            log("buildChoices elapsed=\(elapsedMilliseconds(since: started)) sameApplication=\(sameApplication) cgWindows=\(cgCount) enumerated=\(enumeratedCount)")
        }

        pruneRecentWindows(validateAccessibility: false)
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ignoredNames = Set(configuration.application.ignoredWindowApplicationNames)

        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else {
            return []
        }
        cgCount = windowInfo.count

        let visibleWindowCountByProcessIdentifier = windowInfo.reduce(into: [pid_t: Int]()) { counts, info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  !ignoredNames.contains(ownerName),
                  isRealWindow(info: info) else {
                return
            }
            counts[pid, default: 0] += 1
        }

        var seen = Set<String>()
        var axWindowsByProcessIdentifier: [pid_t: [AXUIElement]] = [:]
        var unavailableAXWindowLists = Set<pid_t>()
        let enumerated = windowInfo.compactMap { info -> WindowChoice? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  !ignoredNames.contains(ownerName) else {
                return nil
            }
            guard isRealWindow(info: info) else {
                log("skip CGWindow owner=\(ownerName) pid=\(pid) reason=not-real-cg attrs=\(debugWindowInfo(info))")
                return nil
            }

            if sameApplication, let frontmostPID, pid != frontmostPID {
                return nil
            }

            let app = NSRunningApplication(processIdentifier: pid)
            let bundleIdentifier = app?.bundleIdentifier ?? ""
            if sameApplication,
               let frontmostBundleIdentifier,
               !bundleIdentifier.isEmpty,
               bundleIdentifier != frontmostBundleIdentifier {
                return nil
            }

            let cgTitle = cgTitle(from: info)
            let bounds = cgBounds(from: info)
            let cgWindowIdentifier = info[kCGWindowNumber as String] as? CGWindowID
            if var cachedChoice = cachedRecentChoice(
                processIdentifier: pid,
                title: cgTitle,
                bounds: bounds,
                cgWindowIdentifier: cgWindowIdentifier,
                visibleWindowCount: visibleWindowCountByProcessIdentifier[pid] ?? 0,
                excludingKeys: seen
            ) {
                cachedChoice.cgWindowIdentifier = cgWindowIdentifier ?? cachedChoice.cgWindowIdentifier
                cachedChoice.lastKnownBounds = bounds ?? cachedChoice.lastKnownBounds
                recentChoices[cachedChoice.key] = cachedChoice
                seen.insert(cachedChoice.key)
                return cachedChoice
            }

            let axWindows: [AXUIElement]
            if let cached = axWindowsByProcessIdentifier[pid] {
                axWindows = cached
            } else {
                guard !unavailableAXWindowLists.contains(pid),
                      let copied = copyAXWindows(processIdentifier: pid) else {
                    unavailableAXWindowLists.insert(pid)
                    log("skip AX owner=\(ownerName) pid=\(pid) cgTitle=\(cgTitle) reason=no-ax-window-list attrs=\(debugWindowInfo(info))")
                    return nil
                }
                axWindowsByProcessIdentifier[pid] = copied
                axWindows = copied
            }
            guard let axWindow = findAXWindow(
                processIdentifier: pid,
                title: cgTitle,
                bounds: bounds,
                windows: axWindows,
                excludingKeys: seen
            ) else {
                log("skip AX owner=\(ownerName) pid=\(pid) cgTitle=\(cgTitle) reason=no-ax-window attrs=\(debugWindowInfo(info))")
                return nil
            }
            guard isSwitchableAXWindow(axWindow) else {
                log("skip AX owner=\(ownerName) pid=\(pid) cgTitle=\(cgTitle) reason=not-real-ax cg=\(debugWindowInfo(info)) ax=\(debugAXWindow(axWindow))")
                return nil
            }

            let key = windowKey(processIdentifier: pid, axWindow: axWindow)
            guard !seen.contains(key) else {
                log("skip duplicate owner=\(ownerName) pid=\(pid) cgTitle=\(cgTitle) key=\(key) ax=\(debugAXWindow(axWindow))")
                return nil
            }
            seen.insert(key)

            let title = displayTitle(cgTitle: cgTitle, axWindow: axWindow, appName: app?.localizedName ?? ownerName)
            return WindowChoice(
                key: key,
                title: title,
                appName: app?.localizedName ?? ownerName,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: pid,
                icon: app?.icon,
                axWindow: axWindow,
                cgWindowIdentifier: cgWindowIdentifier,
                lastKnownBounds: bounds
            )
        }
        enumeratedCount = enumerated.count

        let byKey = Dictionary(uniqueKeysWithValues: enumerated.map { ($0.key, $0) })
        var choicesByKey = byKey
        var stateByKey = Dictionary(uniqueKeysWithValues: enumerated.map {
            ($0.key, WindowSwitcherWindowState.active)
        })
        for key in recentKeys {
            guard let choice = byKey[key] ?? recentChoices[key] else {
                continue
            }
            if sameApplication,
               choice.processIdentifier != frontmostPID,
               choice.bundleIdentifier != frontmostBundleIdentifier {
                continue
            }
            choicesByKey[key] = choice
            let state = byKey[key] == nil ? lifecycleState(for: choice) : .active
            switch state {
            case .active:
                stateByKey[key] = .active
            case .dormant:
                stateByKey[key] = .dormant
            case .indeterminate:
                stateByKey[key] = .indeterminate
            case .destroyed:
                stateByKey[key] = .destroyed
            }
        }

        let currentFrontmostWindow = frontmostPID.flatMap { frontmostPID in
            enumerated.first(where: { $0.processIdentifier == frontmostPID })
        }
        let orderedKeys = WindowSwitcherCandidateOrderingPolicy.orderedKeys(
            recentKeys: recentKeys,
            enumeratedKeys: enumerated.map(\.key),
            stateByKey: stateByKey,
            frontmostKey: currentFrontmostWindow?.key
        )
        let result = orderedKeys.compactMap { choicesByKey[$0] }
        if let currentFrontmostWindow {
            remember(currentFrontmostWindow)
        }
        let orderedDescription = result.enumerated()
            .map { "#\($0.offset):\(describe($0.element))" }
            .joined(separator: " | ")
        log("choices ordered=\(orderedDescription)")
        return result
    }

    private func cachedRecentChoice(
        processIdentifier: pid_t,
        title: String,
        bounds: CGRect?,
        cgWindowIdentifier: CGWindowID?,
        visibleWindowCount: Int,
        excludingKeys: Set<String>
    ) -> WindowChoice? {
        let candidates = recentKeys.compactMap { key -> WindowChoice? in
            guard !excludingKeys.contains(key),
                  let choice = recentChoices[key],
                  choice.processIdentifier == processIdentifier else {
                return nil
            }
            return choice
        }
        guard !candidates.isEmpty else {
            return nil
        }

        if let cgWindowIdentifier,
           let identifierMatch = candidates.first(where: {
               $0.cgWindowIdentifier == cgWindowIdentifier
           }) {
            return identifierMatch
        }
        if !title.isEmpty,
           let titleMatch = candidates.first(where: { $0.title == title }) {
            return titleMatch
        }
        if let bounds,
           let boundsMatch = candidates.first(where: {
               $0.lastKnownBounds.map { approximatelyEqual($0, bounds) } == true
           }) {
            return boundsMatch
        }
        if visibleWindowCount == 1,
           candidates.count == 1,
           candidates[0].cgWindowIdentifier == nil {
            return candidates[0]
        }
        return nil
    }

    private func copyAXWindows(processIdentifier: pid_t) -> [AXUIElement]? {
        let started = CFAbsoluteTimeGetCurrent()
        let app = axApplication(processIdentifier: processIdentifier)
        var value: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if result == .cannotComplete {
            AXUIElementSetMessagingTimeout(app, axWindowEnumerationRetryTimeout)
            value = nil
            result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            log("AX windows retry pid=\(processIdentifier) timeout=\(axWindowEnumerationRetryTimeout)s result=\(result.rawValue)")
        }
        guard result == .success, let windows = value as? [AXUIElement] else {
            logSlowAX("AX windows failed pid=\(processIdentifier) result=\(result.rawValue)", since: started)
            var focusedValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
                  let focusedValue else {
                return nil
            }
            let focusedWindow = focusedValue as! AXUIElement
            configureAXTimeout(focusedWindow)
            guard isSwitchableAXWindow(focusedWindow) else {
                return nil
            }
            log("AX windows fallback to focused window pid=\(processIdentifier)")
            return [focusedWindow]
        }

        windows.forEach(configureAXTimeout)
        logSlowAX("AX windows copied pid=\(processIdentifier) windows=\(windows.count)", since: started)
        return windows
    }

    private func findAXWindow(
        processIdentifier: pid_t,
        title: String,
        bounds: CGRect?,
        windows: [AXUIElement],
        excludingKeys: Set<String>
    ) -> AXUIElement? {
        let realWindows = windows.filter {
            isSwitchableAXWindow($0)
                && !excludingKeys.contains(windowKey(processIdentifier: processIdentifier, axWindow: $0))
        }
        if !title.isEmpty, let exact = realWindows.first(where: { axTitle(for: $0) == title }) {
            return exact
        }

        if let bounds, let matchingBounds = realWindows.first(where: { axBounds(for: $0).map { approximatelyEqual($0, bounds) } == true }) {
            return matchingBounds
        }

        return realWindows.first
    }

    private func isRealWindow(info: [String: Any]) -> Bool {
        if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.05 {
            return false
        }
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double,
              width >= 80,
              height >= 60 else {
            return false
        }

        return true
    }

    private func isSwitchableAXWindow(_ window: AXUIElement) -> Bool {
        let role = axStringAttribute(kAXRoleAttribute, for: window)
        let subrole = axStringAttribute(kAXSubroleAttribute, for: window)
        guard role == kAXWindowRole as String else {
            return false
        }
        if let subrole, subrole != kAXStandardWindowSubrole as String && subrole != kAXDialogSubrole as String {
            return false
        }

        guard let size = axSize(for: window),
              size.width >= 80,
              size.height >= 60 else {
            return false
        }
        return true
    }

    private func cachedAXWindowValidity(_ window: AXUIElement) -> AXWindowValidity {
        let (roleResult, roleValue) = copyAXAttribute(kAXRoleAttribute, from: window)
        if roleResult == .invalidUIElement {
            return .destroyed
        }
        guard roleResult == .success else {
            return .indeterminate
        }
        guard roleValue as? String == kAXWindowRole as String else {
            return .notSwitchable
        }

        let (subroleResult, subroleValue) = copyAXAttribute(kAXSubroleAttribute, from: window)
        if subroleResult == .invalidUIElement {
            return .destroyed
        }
        if subroleResult == .success,
           let subrole = subroleValue as? String,
           subrole != kAXStandardWindowSubrole as String,
           subrole != kAXDialogSubrole as String {
            return .notSwitchable
        }
        if subroleResult != .success && subroleResult != .attributeUnsupported {
            return .indeterminate
        }

        let (sizeResult, sizeValue) = copyAXAttribute(kAXSizeAttribute, from: window)
        if sizeResult == .invalidUIElement {
            return .destroyed
        }
        guard sizeResult == .success,
              let sizeValue,
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return sizeResult == .success ? .notSwitchable : .indeterminate
        }
        var size = CGSize.zero
        guard AXValueGetValue((sizeValue as! AXValue), .cgSize, &size),
              size.width >= 80,
              size.height >= 60 else {
            return .notSwitchable
        }
        return .switchable
    }

    private func isSubstantialAXWindow(_ window: AXUIElement) -> Bool {
        guard axStringAttribute(kAXRoleAttribute, for: window) == kAXWindowRole as String,
              let size = axSize(for: window),
              size.width >= 80,
              size.height >= 60 else {
            return false
        }
        return true
    }

    private func lifecycleState(for choice: WindowChoice) -> WindowLifecycleState {
        guard let application = NSRunningApplication(processIdentifier: choice.processIdentifier) else {
            return .destroyed
        }

        switch cachedAXWindowValidity(choice.axWindow) {
        case .destroyed, .notSwitchable:
            return .destroyed
        case .indeterminate:
            return .indeterminate
        case .switchable:
            break
        }

        if application.isHidden {
            return .dormant
        }

        let (minimizedResult, minimizedValue) = copyAXAttribute(kAXMinimizedAttribute, from: choice.axWindow)
        if minimizedResult == .invalidUIElement {
            return .destroyed
        }
        if minimizedResult == .success, minimizedValue as? Bool == true {
            return .dormant
        }
        if minimizedResult != .success && minimizedResult != .attributeUnsupported {
            return .indeterminate
        }

        return .active
    }

    private func copyAXAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (result, value)
    }

    private func axStringAttribute(_ attribute: String, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axBoolAttribute(_ attribute: String, for element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func axSize(for element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue((axValue as! AXValue), .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func axPosition(for element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        guard AXValueGetValue((axValue as! AXValue), .cgPoint, &position) else {
            return nil
        }
        return position
    }

    private func axBounds(for element: AXUIElement) -> CGRect? {
        guard let position = axPosition(for: element),
              let size = axSize(for: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func cgBounds(from info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? Double,
              let y = bounds["Y"] as? Double,
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= 8
            && abs(lhs.origin.y - rhs.origin.y) <= 8
            && abs(lhs.size.width - rhs.size.width) <= 12
            && abs(lhs.size.height - rhs.size.height) <= 12
    }

    private func cgTitle(from info: [String: Any]) -> String {
        (info[kCGWindowName as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func displayTitle(cgTitle: String, axWindow: AXUIElement, appName: String) -> String {
        let axTitle = axTitle(for: axWindow).trimmingCharacters(in: .whitespacesAndNewlines)
        if !axTitle.isEmpty {
            return axTitle
        }
        if !cgTitle.isEmpty {
            return cgTitle
        }
        return "\(appName) Window"
    }

    private func axTitle(for window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }

    private func focus(_ choice: WindowChoice) {
        let started = CFAbsoluteTimeGetCurrent()
        let appElement = axApplication(processIdentifier: choice.processIdentifier)
        configureAXTimeout(choice.axWindow)
        log("focus begin \(describe(choice)) ax=\(debugAXWindow(choice.axWindow)) frontmostBefore=\(frontmostDescription())")

        expectFocusedWindowChange(to: choice)
        let unminimizeResult = AXUIElementSetAttributeValue(choice.axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let initialAX = applyFocus(to: choice.axWindow, appElement: appElement, raise: true)
        log("focus ax-only elapsed=\(elapsedMilliseconds(since: started)) unminimize=\(unminimizeResult.rawValue) ax=\(initialAX) focusedAX=\(focusedAXDescription(processIdentifier: choice.processIdentifier)) frontmostNow=\(frontmostDescription())")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let retryAX = self.applyFocus(to: choice.axWindow, appElement: appElement, raise: true)
            self.verifyFocusedWindowChangeIfNeeded(processIdentifier: choice.processIdentifier, source: "retry1")
            self.log("focus retry1 ax=\(retryAX) frontmostAfter=\(self.frontmostDescription()) focusedAX=\(self.focusedAXDescription(processIdentifier: choice.processIdentifier))")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            let retryAX = self.applyFocus(to: choice.axWindow, appElement: appElement, raise: true)
            self.verifyFocusedWindowChangeIfNeeded(processIdentifier: choice.processIdentifier, source: "retry2")
            self.log("focus retry2 ax=\(retryAX) frontmostAfter=\(self.frontmostDescription()) focusedAX=\(self.focusedAXDescription(processIdentifier: choice.processIdentifier))")
            self.recordFocusedWindow()
        }

        if choice.bundleIdentifier == "com.apple.finder" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let retryAX = self.applyFocus(to: choice.axWindow, appElement: appElement, raise: true)
                self.verifyFocusedWindowChangeIfNeeded(processIdentifier: choice.processIdentifier, source: "finder-workaround")
                self.log("focus finder-workaround ax=\(retryAX) frontmostAfter=\(self.frontmostDescription()) focusedAX=\(self.focusedAXDescription(processIdentifier: choice.processIdentifier))")
            }
        }
    }

    private func applyFocus(to window: AXUIElement, appElement: AXUIElement, raise: Bool) -> String {
        let systemWideElement = AXUIElementCreateSystemWide()
        configureAXTimeout(systemWideElement)
        let systemFocusResult = AXUIElementSetAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            appElement
        )
        let appFrontmostResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        let raiseBefore = raise ? AXUIElementPerformAction(window, kAXRaiseAction as CFString) : .success
        let mainResult = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let windowFocusResult = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let appFocusResult = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        let raiseAfter = raise ? AXUIElementPerformAction(window, kAXRaiseAction as CFString) : .success
        return "systemFocusedApplication=\(systemFocusResult.rawValue) appFrontmost=\(appFrontmostResult.rawValue) raiseBefore=\(raiseBefore.rawValue) main=\(mainResult.rawValue) windowFocused=\(windowFocusResult.rawValue) appFocusedWindow=\(appFocusResult.rawValue) raiseAfter=\(raiseAfter.rawValue)"
    }

    @discardableResult
    func focusMostRecentWindow(excluding excludedBundleIdentifier: String? = nil) -> Bool {
        focusMostRecentWindow(excluding: excludedBundleIdentifier, recordCurrentFocus: true)
    }

    @discardableResult
    private func focusMostRecentWindow(
        excluding excludedBundleIdentifier: String? = nil,
        recordCurrentFocus: Bool
    ) -> Bool {
        if recordCurrentFocus {
            recordFocusedWindow()
        }
        guard let candidate = recentKeys.compactMap({ self.recentChoices[$0] }).first(where: { choice in
            if let excludedBundleIdentifier, choice.bundleIdentifier == excludedBundleIdentifier {
                return false
            }
            return true
        }) else {
            return false
        }
        focus(candidate)
        remember(candidate)
        return true
    }

    @discardableResult
    func focusMostRecentWindow(matching bundleIdentifier: String) -> Bool {
        recordFocusedWindow()
        guard let candidate = recentKeys.compactMap({ self.recentChoices[$0] }).first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return false
        }
        focus(candidate)
        remember(candidate)
        return true
    }

    private func renderOverlay() {
        overlayDisplayWorkItem = nil
        let window = overlayWindow ?? makeOverlayWindow()
        overlayStack.arrangedSubviews.forEach { view in
            overlayStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let visibleRange = visibleRangeForSelection()
        for index in visibleRange {
            overlayStack.addArrangedSubview(row(for: choices[index], selected: index == selectedIndex))
        }

        let frame = overlayFrame()
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    private func makeOverlayWindow() -> NSWindow {
        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        contentView.layer?.cornerRadius = 14

        overlayStack.orientation = .vertical
        overlayStack.alignment = .leading
        overlayStack.spacing = 6
        overlayStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(overlayStack)
        NSLayoutConstraint.activate([
            overlayStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            overlayStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            overlayStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            overlayStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14)
        ])

        let window = NSWindow(
            contentRect: overlayFrame(),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .modalPanel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlayWindow = window
        return window
    }

    private func row(for choice: WindowChoice, selected: Bool) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = choice.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: choice.title)
        title.font = .systemFont(ofSize: 14, weight: selected ? .semibold : .medium)
        title.lineBreakMode = .byTruncatingTail

        let subtitleParts = [choice.appName, choice.bundleIdentifier.isEmpty ? nil : choice.bundleIdentifier].compactMap { $0 }
        let subtitle = NSTextField(labelWithString: subtitleParts.joined(separator: " · "))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let rowStack = NSStackView(views: [iconView, textStack])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 10
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rowStack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: CGFloat(max(320, configuration.windowSwitcher.width) - 28)),
            container.heightAnchor.constraint(equalToConstant: 48),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            rowStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            rowStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            rowStack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    private func visibleRangeForSelection() -> Range<Int> {
        guard !choices.isEmpty else {
            return 0..<0
        }
        let maxRows = max(1, configuration.windowSwitcher.maxVisibleRows)
        guard choices.count > maxRows else {
            return 0..<choices.count
        }

        let buffer = 1
        var start = max(0, selectedIndex - (maxRows - buffer - 1))
        if selectedIndex <= start + buffer {
            start = max(0, selectedIndex - buffer)
        }
        let maxStart = max(0, choices.count - maxRows)
        start = min(start, maxStart)
        return start..<(start + maxRows)
    }

    private func overlayFrame() -> NSRect {
        let screenFrame = overlayScreen()?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = CGFloat(max(320, configuration.windowSwitcher.width))
        let rows = max(1, min(configuration.windowSwitcher.maxVisibleRows, max(choices.count, 1)))
        let height = min(CGFloat(max(120, configuration.windowSwitcher.height)), CGFloat(rows * 54 + 28))
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func overlayScreen() -> NSScreen? {
        let fallback = NSScreen.main ?? NSScreen.screens.first
        guard configuration.windowSwitcher.followFocusedScreen,
              choices.indices.contains(selectedIndex),
              let position = axPosition(for: choices[selectedIndex].axWindow),
              let size = axSize(for: choices[selectedIndex].axWindow) else {
            return fallback
        }

        let windowBounds = CGRect(origin: position, size: size)
        let ranked = NSScreen.screens.compactMap { screen -> (NSScreen, CGFloat)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            let intersection = displayBounds.intersection(windowBounds)
            guard !intersection.isNull else { return (screen, 0) }
            return (screen, intersection.width * intersection.height)
        }
        guard let best = ranked.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return fallback }
        return best.0
    }

    private func hideOverlay() {
        cancelBackwardRepeat()
        cancelScheduledOverlay()
        overlayWindow?.orderOut(nil)
    }

    @discardableResult
    func recordFocusedWindow(
        expectedProcessIdentifier: pid_t? = nil,
        preferMainWindow: Bool = false
    ) -> Bool {
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            logSlowAX("recordFocusedWindow", since: started)
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              expectedProcessIdentifier.map({ $0 == app.processIdentifier }) ?? true else {
            return false
        }

        let appElement = axApplication(processIdentifier: app.processIdentifier)
        let preferredAttribute = preferMainWindow ? kAXMainWindowAttribute : kAXFocusedWindowAttribute
        let fallbackAttribute = preferMainWindow ? kAXFocusedWindowAttribute : kAXMainWindowAttribute
        guard let window = copySwitchableWindow(attribute: preferredAttribute, from: appElement)
            ?? copySwitchableWindow(attribute: fallbackAttribute, from: appElement) else {
            return false
        }
        configureAXTimeout(window)
        let rawTitle = axTitle(for: window)
        guard isSwitchableAXWindow(window) else {
            return false
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cgIdentity = visibleCGWindowIdentity(
            processIdentifier: app.processIdentifier,
            title: title
        )
        let choice = WindowChoice(
            key: windowKey(processIdentifier: app.processIdentifier, axWindow: window),
            title: title.isEmpty ? "\(app.localizedName ?? "Application") Window" : title,
            appName: app.localizedName ?? app.bundleIdentifier ?? "Application",
            bundleIdentifier: app.bundleIdentifier ?? "",
            processIdentifier: app.processIdentifier,
            icon: app.icon,
            axWindow: window,
            cgWindowIdentifier: cgIdentity?.identifier,
            lastKnownBounds: cgIdentity?.bounds
        )
        remember(choice)
        installAXObserver(processIdentifier: app.processIdentifier)
        installAXObserver(for: choice)
        return true
    }

    private func visibleCGWindowIdentity(
        processIdentifier: pid_t,
        title: String
    ) -> (identifier: CGWindowID?, bounds: CGRect?)? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        let candidates = windowInfo.filter { info in
            (info[kCGWindowLayer as String] as? Int) == 0
                && (info[kCGWindowOwnerPID as String] as? pid_t) == processIdentifier
                && isRealWindow(info: info)
        }
        if !title.isEmpty,
           let titleMatch = candidates.first(where: { cgTitle(from: $0) == title }) {
            return (
                titleMatch[kCGWindowNumber as String] as? CGWindowID,
                cgBounds(from: titleMatch)
            )
        }
        if candidates.count == 1 {
            return (
                candidates[0][kCGWindowNumber as String] as? CGWindowID,
                cgBounds(from: candidates[0])
            )
        }
        return nil
    }

    private func copySwitchableWindow(attribute: String, from appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        let window = value as! AXUIElement
        configureAXTimeout(window)
        return isSwitchableAXWindow(window) ? window : nil
    }

    private func remember(_ choice: WindowChoice) {
        recentChoices[choice.key] = choice
        recentKeys.removeAll { $0 == choice.key }
        recentKeys.insert(choice.key, at: 0)
        if recentKeys.count > 80 {
            let removed = Array(recentKeys.suffix(recentKeys.count - 80))
            recentKeys.removeLast(recentKeys.count - 80)
            for key in removed {
                recentChoices[key] = nil
            }
        }
    }

    private func windowKey(processIdentifier: pid_t, axWindow: AXUIElement) -> String {
        "\(processIdentifier):ax:\(CFHash(axWindow))"
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.scheduleActivatedWindowCaptures(for: application)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.moveDormantWindowsToEnd()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.moveDormantWindowsToEnd()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.installAXObserver(processIdentifier: application.processIdentifier)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.removeAXObserver(processIdentifier: application.processIdentifier)
                self?.pruneRecentWindows()
            }
        })
    }

    private func scheduleActivatedWindowCaptures(for application: NSRunningApplication) {
        activationCaptureGeneration &+= 1
        let generation = activationCaptureGeneration
        completedActivationCaptureGeneration = nil
        let processIdentifier = application.processIdentifier
        for delay in activationCapturePolicy.retryDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else {
                    return
                }
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard self.activationCapturePolicy.shouldCapture(
                    expectedProcessIdentifier: processIdentifier,
                    frontmostProcessIdentifier: frontmostPID,
                    generation: generation,
                    currentGeneration: self.activationCaptureGeneration,
                    completedGeneration: self.completedActivationCaptureGeneration
                ) else {
                    return
                }
                let captured = self.recordFocusedWindow(
                    expectedProcessIdentifier: processIdentifier,
                    preferMainWindow: true
                )
                if captured {
                    self.completedActivationCaptureGeneration = generation
                }
                self.log("activation capture pid=\(processIdentifier) delay=\(delay)s captured=\(captured)")
            }
        }
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private func pruneRecentWindows(validateAccessibility: Bool = true) {
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        recentKeys.removeAll { key in
            guard let choice = recentChoices[key] else {
                return true
            }
            let keep = runningPIDs.contains(choice.processIdentifier)
                && (!validateAccessibility || lifecycleState(for: choice) != .destroyed)
            if !keep {
                recentChoices[key] = nil
                removeAXObserver(forWindowKey: key)
            }
            return !keep
        }
    }

    private func moveDormantWindowsToEnd() {
        pruneRecentWindows()
        let stateByKey = Dictionary(uniqueKeysWithValues: recentKeys.map { key in
            (key, recentChoices[key].map(lifecycleState(for:)) ?? .destroyed)
        })
        recentKeys.sort { lhs, rhs in
            let lhsDormant = stateByKey[lhs] == .dormant
            let rhsDormant = stateByKey[rhs] == .dormant
            if lhsDormant != rhsDormant {
                return !lhsDormant && rhsDormant
            }
            return false
        }
        if overlayWindow?.isVisible == true {
            choices = buildChoices(sameApplication: sameApplicationMode)
            selectedIndex = min(selectedIndex, max(choices.count - 1, 0))
            renderOverlay()
        }
    }

    private func installAXObserver(processIdentifier: pid_t) {
        var observation: AXApplicationObservation
        if let existing = axApplicationObservers[processIdentifier] {
            observation = existing
        } else {
            var observer: AXObserver?
            let result = AXObserverCreate(processIdentifier, windowSwitcherAXObserverCallback, &observer)
            guard result == .success, let observer else {
                log("AX app observer failed pid=\(processIdentifier) result=\(result.rawValue)")
                return
            }
            observation = AXApplicationObservation(
                observer: observer,
                appElement: axApplication(processIdentifier: processIdentifier),
                registeredNotifications: [],
                unsupportedNotifications: []
            )
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }

        let notifications = [
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXWindowCreatedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification
        ]
        for notification in notifications where
            !observation.registeredNotifications.contains(notification)
                && !observation.unsupportedNotifications.contains(notification) {
            let addResult = AXObserverAddNotification(
                observation.observer,
                observation.appElement,
                notification as CFString,
                retainedSelf
            )
            switch addResult {
            case .success, .notificationAlreadyRegistered:
                observation.registeredNotifications.insert(notification)
            case .notificationUnsupported:
                observation.unsupportedNotifications.insert(notification)
            default:
                break
            }
            log("AX app observe pid=\(processIdentifier) notification=\(notification) result=\(addResult.rawValue)")
        }
        axApplicationObservers[processIdentifier] = observation
    }

    private func removeAXObserver(processIdentifier: pid_t) {
        guard let observation = axApplicationObservers.removeValue(forKey: processIdentifier) else {
            return
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observation.observer),
            .commonModes
        )
    }

    private func installAXObserver(for choice: WindowChoice) {
        guard axWindowObservers[choice.key] == nil else {
            return
        }

        var observer: AXObserver?
        let result = AXObserverCreate(choice.processIdentifier, windowSwitcherAXObserverCallback, &observer)
        guard result == .success, let observer else {
            log("AX window observer failed \(describe(choice)) result=\(result.rawValue)")
            return
        }

        let notifications = [
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification
        ]
        for notification in notifications {
            let addResult = AXObserverAddNotification(
                observer,
                choice.axWindow,
                notification as CFString,
                retainedSelf
            )
            log("AX window observe key=\(choice.key) notification=\(notification) result=\(addResult.rawValue)")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axWindowObservers[choice.key] = AXWindowObservation(observer: observer, window: choice.axWindow)
    }

    private func removeAXObserver(forWindowKey key: String) {
        guard let observation = axWindowObservers.removeValue(forKey: key) else {
            return
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
    }

    private func removeAXObservers() {
        for observation in axApplicationObservers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
        }
        for observation in axWindowObservers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
        }
        axApplicationObservers.removeAll()
        axWindowObservers.removeAll()
    }

    func handleAXNotification(_ notification: String, processIdentifier: pid_t, elementHash: CFHashCode) {
        log("AX notification=\(notification) pid=\(processIdentifier) elementHash=\(elementHash)")
        switch notification {
        case kAXUIElementDestroyedNotification:
            let keys = recentKeys.filter { key in
                recentChoices[key].map {
                    $0.processIdentifier == processIdentifier && CFHash($0.axWindow) == elementHash
                } ?? false
            }
            for key in keys {
                recentChoices[key] = nil
                recentKeys.removeAll { $0 == key }
                removeAXObserver(forWindowKey: key)
            }
            restorePreviousApplicationIfFrontmostHasNoWindows(
                processIdentifier: processIdentifier,
                destroyedElementHash: elementHash
            )
        case kAXWindowMiniaturizedNotification,
             kAXWindowDeminiaturizedNotification,
             kAXApplicationHiddenNotification,
             kAXApplicationShownNotification:
            moveDormantWindowsToEnd()
        case kAXWindowCreatedNotification,
             kAXFocusedWindowChangedNotification,
             kAXMainWindowChangedNotification:
            if notification == kAXFocusedWindowChangedNotification {
                verifyFocusedWindowChangeIfNeeded(processIdentifier: processIdentifier, source: "notification")
            }
            recordFocusedWindow(
                expectedProcessIdentifier: processIdentifier,
                preferMainWindow: notification == kAXMainWindowChangedNotification
            )
        default:
            pruneRecentWindows()
        }

        if overlayWindow?.isVisible == true {
            choices = buildChoices(sameApplication: sameApplicationMode)
            selectedIndex = min(selectedIndex, max(choices.count - 1, 0))
            renderOverlay()
        }
    }

    private func restorePreviousApplicationIfFrontmostHasNoWindows(
        processIdentifier: pid_t,
        destroyedElementHash: CFHashCode
    ) {
        guard configuration.windowSwitcher.restorePreviousApplicationWhenNoWindows else {
            return
        }
        guard let expectedFrontmost = frontmostApplicationIdentity(),
              expectedFrontmost.processIdentifier == processIdentifier else {
            return
        }

        confirmFrontmostApplicationHasNoWindows(
            expectedFrontmost: expectedFrontmost,
            destroyedElementHash: destroyedElementHash,
            confirmation: WindowAbsenceConfirmation(),
            remainingAttempts: 5
        )
    }

    private func confirmFrontmostApplicationHasNoWindows(
        expectedFrontmost: FrontmostApplicationIdentity,
        destroyedElementHash: CFHashCode,
        confirmation: WindowAbsenceConfirmation,
        remainingAttempts: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self,
                  self.frontmostApplicationMatches(expectedFrontmost) else {
                return
            }
            if self.hasFocusedSubstantialWindowAfterDestroy(
                processIdentifier: expectedFrontmost.processIdentifier,
                destroyedElementHash: destroyedElementHash
            ) {
                return
            }

            let presence = self.substantialWindowPresence(
                processIdentifier: expectedFrontmost.processIdentifier
            )
            var nextConfirmation = confirmation
            let decision = nextConfirmation.observe(presence)
            self.log("restore check app=\(self.describe(expectedFrontmost)) presence=\(presence) consecutiveAbsences=\(nextConfirmation.consecutiveAbsences) remainingAttempts=\(remainingAttempts)")

            switch decision {
            case .cancel:
                return
            case .retry where remainingAttempts > 1:
                self.confirmFrontmostApplicationHasNoWindows(
                    expectedFrontmost: expectedFrontmost,
                    destroyedElementHash: destroyedElementHash,
                    confirmation: nextConfirmation,
                    remainingAttempts: remainingAttempts - 1
                )
            case .retry:
                self.log("skip restore previous app; unable to confirm stable window absence for \(self.describe(expectedFrontmost))")
            case .restorePreviousApplication:
                guard self.frontmostApplicationMatches(expectedFrontmost),
                      !self.hasFocusedSubstantialWindowAfterDestroy(
                        processIdentifier: expectedFrontmost.processIdentifier,
                        destroyedElementHash: destroyedElementHash
                      ) else {
                    return
                }
                self.log("frontmost app \(self.describe(expectedFrontmost)) has no substantial windows after repeated checks; restoring previous app")
                _ = self.focusMostRecentWindow(excluding: expectedFrontmost.bundleIdentifier, recordCurrentFocus: false)
            }
        }
    }

    private func substantialWindowPresence(processIdentifier: pid_t) -> WindowPresence {
        let appElement = axApplication(processIdentifier: processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success,
              let windows = value as? [AXUIElement] else {
            log("AX windows unavailable during restore check pid=\(processIdentifier) result=\(result.rawValue)")
            return .indeterminate
        }
        windows.forEach(configureAXTimeout)
        return windows.contains { isSubstantialAXWindow($0) } ? .present : .absent
    }

    private func hasFocusedSubstantialWindowAfterDestroy(
        processIdentifier: pid_t,
        destroyedElementHash: CFHashCode
    ) -> Bool {
        guard let focusedWindow = focusedAXWindow(processIdentifier: processIdentifier),
              isSubstantialAXWindow(focusedWindow) else {
            return false
        }
        let focusedHash = CFHash(focusedWindow)
        guard focusedHash != destroyedElementHash else {
            return false
        }
        log("skip restore previous app; focused substantial window changed after destroy pid=\(processIdentifier) destroyedHash=\(destroyedElementHash) focusedHash=\(focusedHash) focused=\(debugAXWindow(focusedWindow))")
        recordFocusedWindow()
        return true
    }

    private func expectFocusedWindowChange(to choice: WindowChoice) {
        if axApplicationObservers[choice.processIdentifier] == nil {
            installAXObserver(processIdentifier: choice.processIdentifier)
        }
        pendingFocusVerification = PendingFocusVerification(
            key: choice.key,
            title: choice.title,
            processIdentifier: choice.processIdentifier,
            window: choice.axWindow,
            startedAt: CFAbsoluteTimeGetCurrent()
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  let pending = self.pendingFocusVerification,
                  pending.key == choice.key else {
                return
            }
            self.verifyFocusedWindowChangeIfNeeded(
                processIdentifier: pending.processIdentifier,
                source: "timeout"
            )
        }
    }

    private func verifyFocusedWindowChangeIfNeeded(processIdentifier: pid_t, source: String) {
        guard let pending = pendingFocusVerification,
              pending.processIdentifier == processIdentifier else {
            return
        }

        guard let focusedWindow = focusedAXWindow(processIdentifier: processIdentifier) else {
            log("focus verify source=\(source) key=\(pending.key) title=\(pending.title) elapsed=\(elapsedMilliseconds(since: pending.startedAt)) result=no-focused-window")
            if source == "timeout" {
                pendingFocusVerification = nil
            }
            return
        }

        let matches = CFEqual(focusedWindow, pending.window)
        log("focus verify source=\(source) key=\(pending.key) title=\(pending.title) elapsed=\(elapsedMilliseconds(since: pending.startedAt)) matches=\(matches) focused=\(debugAXWindow(focusedWindow))")
        if matches || source == "timeout" {
            pendingFocusVerification = nil
        }
    }

    private func showStatus(_ message: String) {
        runtime.handle(.showWindow(
            id: NativeWindowID("window-switcher-status"),
            content: NativeWindowContent(title: "Window Switcher", body: .plainText(message))
        ))
    }

    private func log(_ message: String) {
        guard configuration.windowSwitcher.debug else {
            return
        }
        NSLog("[window-switcher] %@", message)
    }

    private func logSlowAX(_ message: String, since started: CFAbsoluteTime) {
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        guard elapsed >= 25 else {
            return
        }
        log("\(message) elapsed=\(String(format: "%.1fms", elapsed))")
    }

    private func elapsedMilliseconds(since started: CFAbsoluteTime) -> String {
        String(format: "%.1fms", (CFAbsoluteTimeGetCurrent() - started) * 1000)
    }

    private func axApplication(processIdentifier: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(processIdentifier)
        configureAXTimeout(app)
        return app
    }

    private func configureAXTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
    }

    private func describe(_ choice: WindowChoice) -> String {
        "app=\(choice.appName) bundle=\(choice.bundleIdentifier) pid=\(choice.processIdentifier) title=\(choice.title) key=\(choice.key)"
    }

    private func debugWindowInfo(_ info: [String: Any]) -> String {
        let alpha = info[kCGWindowAlpha as String] ?? "?"
        let bounds = info[kCGWindowBounds as String] ?? "?"
        let name = info[kCGWindowName as String] ?? ""
        let layer = info[kCGWindowLayer as String] ?? "?"
        return "layer=\(layer) alpha=\(alpha) bounds=\(bounds) name=\(name)"
    }

    private func debugAXWindow(_ window: AXUIElement) -> String {
        let role = axStringAttribute(kAXRoleAttribute, for: window) ?? "<nil>"
        let subrole = axStringAttribute(kAXSubroleAttribute, for: window) ?? "<nil>"
        let title = axTitle(for: window)
        let minimized = axBoolAttribute(kAXMinimizedAttribute, for: window).map(String.init(describing:)) ?? "<nil>"
        let hidden = NSRunningApplication(processIdentifier: processIdentifier(for: window))?.isHidden.description ?? "<nil>"
        let size = axSize(for: window).map { "\($0.width)x\($0.height)" } ?? "<nil>"
        let position = axPosition(for: window).map { "\($0.x),\($0.y)" } ?? "<nil>"
        let main = axBoolAttribute(kAXMainAttribute, for: window).map(String.init(describing:)) ?? "<nil>"
        let focused = axBoolAttribute(kAXFocusedAttribute, for: window).map(String.init(describing:)) ?? "<nil>"
        return "role=\(role) subrole=\(subrole) title=\(title) minimized=\(minimized) hidden=\(hidden) main=\(main) focused=\(focused) position=\(position) size=\(size)"
    }

    private func processIdentifier(for element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    private func frontmostDescription() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        return "name=\(app?.localizedName ?? "<nil>") bundle=\(app?.bundleIdentifier ?? "<nil>") pid=\(app?.processIdentifier.description ?? "<nil>")"
    }

    private func frontmostApplicationIdentity() -> FrontmostApplicationIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return FrontmostApplicationIdentity(
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            localizedName: app.localizedName
        )
    }

    private func frontmostApplicationMatches(_ identity: FrontmostApplicationIdentity) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return app.processIdentifier == identity.processIdentifier
            && app.bundleIdentifier == identity.bundleIdentifier
    }

    private func describe(_ identity: FrontmostApplicationIdentity) -> String {
        "name=\(identity.localizedName ?? "<nil>") bundle=\(identity.bundleIdentifier ?? "<nil>") pid=\(identity.processIdentifier)"
    }

    private func focusedAXWindow(processIdentifier: pid_t) -> AXUIElement? {
        let appElement = axApplication(processIdentifier: processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        let window = value as! AXUIElement
        configureAXTimeout(window)
        return window
    }

    private func focusedAXDescription(processIdentifier: pid_t) -> String {
        guard let window = focusedAXWindow(processIdentifier: processIdentifier) else {
            return "<none>"
        }
        return debugAXWindow(window)
    }
}
