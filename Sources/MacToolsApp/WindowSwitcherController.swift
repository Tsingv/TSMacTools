import AppKit
import ApplicationServices
import Carbon
import MacToolsCore
import OSLog

private let windowSwitcherReplayedEventMarker: Int64 = 0x5453_4D57_534B_4559
private let windowSwitcherCommandKeyCodes: [Int64] = [Int64(kVK_Command), Int64(kVK_RightCommand)]
private let windowSwitcherLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TSMacTools",
    category: "window-switcher"
)

private func logWindowSwitcherDebug(_ message: String, debugEnabled: Bool) {
    guard debugEnabled else {
        return
    }
    windowSwitcherLogger.info("\(message, privacy: .public)")
}

private func logWindowSwitcherSlowDebug(_ message: String, since started: CFAbsoluteTime, debugEnabled: Bool) {
    let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
    guard elapsed >= 25 else {
        return
    }
    logWindowSwitcherDebug("\(message) elapsed=\(String(format: "%.1fms", elapsed))", debugEnabled: debugEnabled)
}

private final class WindowSwitcherAXElement: @unchecked Sendable {
    let value: AXUIElement

    init(_ value: AXUIElement) {
        self.value = value
    }
}

private final class WindowSwitcherFocusGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var currentGeneration: UInt64 = 0

    func activate(_ generation: UInt64) {
        lock.lock()
        currentGeneration = generation
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        currentGeneration = 0
        lock.unlock()
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration == generation
    }
}

private final class WindowSwitcherEventTapRunLoop: @unchecked Sendable {
    private final class Context: @unchecked Sendable {
        let tap: CFMachPort
        let source: CFRunLoopSource
        let ready = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)

        private let lock = NSLock()
        private var runLoop: CFRunLoop?
        private var stopRequested = false
        private var running = false

        init(tap: CFMachPort, source: CFRunLoopSource) {
            self.tap = tap
            self.source = source
        }

        func run() {
            autoreleasepool {
                let currentRunLoop = CFRunLoopGetCurrent()
                lock.lock()
                if stopRequested {
                    lock.unlock()
                    ready.signal()
                    stopped.signal()
                    return
                }
                runLoop = currentRunLoop
                running = true
                lock.unlock()

                CFRunLoopAddSource(currentRunLoop, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                ready.signal()
                CFRunLoopRun()
                CGEvent.tapEnable(tap: tap, enable: false)
                CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)

                lock.lock()
                running = false
                runLoop = nil
                lock.unlock()
                stopped.signal()
            }
        }

        func stop() {
            lock.lock()
            stopRequested = true
            let currentRunLoop = runLoop
            lock.unlock()
            CGEvent.tapEnable(tap: tap, enable: false)
            if let currentRunLoop {
                CFRunLoopStop(currentRunLoop)
                CFRunLoopWakeUp(currentRunLoop)
            }
        }

        func enable() {
            lock.lock()
            let shouldEnable = running && !stopRequested
            lock.unlock()
            if shouldEnable {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return running && !stopRequested
        }
    }

    private let lock = NSLock()
    private var context: Context?

    func start(mask: CGEventMask, userInfo: UnsafeMutableRawPointer) -> Bool {
        stop()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: windowSwitcherEventTapCallback,
            userInfo: userInfo
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }

        let context = Context(tap: tap, source: source)
        lock.lock()
        self.context = context
        lock.unlock()

        let thread = Thread {
            context.run()
        }
        thread.name = "TSMacTools.WindowSwitcherEventTap"
        thread.qualityOfService = .userInteractive
        thread.start()

        guard context.ready.wait(timeout: .now() + 1) == .success,
              context.isRunning else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        lock.lock()
        let currentContext = context
        context = nil
        lock.unlock()
        guard let currentContext else {
            return
        }
        currentContext.stop()
        _ = currentContext.stopped.wait(timeout: .now() + 1)
    }

    func enable() {
        lock.lock()
        let currentContext = context
        lock.unlock()
        currentContext?.enable()
    }

    var isActive: Bool {
        lock.lock()
        let currentContext = context
        lock.unlock()
        return currentContext?.isRunning == true
    }
}

private final class WindowSwitcherInputEventQueue: @unchecked Sendable {
    enum Event {
        case step(sameApplication: Bool, reverse: Bool)
        case flagsChanged(commandPressed: Bool, shiftPressed: Bool)
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var drainScheduled = false

    func enqueue(_ event: Event) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        guard !drainScheduled else {
            return false
        }
        drainScheduled = true
        return true
    }

    func takeBatch() -> [Event]? {
        lock.lock()
        defer { lock.unlock() }
        guard !events.isEmpty else {
            drainScheduled = false
            return nil
        }
        let batch = events
        events.removeAll(keepingCapacity: true)
        return batch
    }

    func reset() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        drainScheduled = false
        lock.unlock()
    }
}

private final class WindowSwitcherCommandModifierGate: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumDeferral: TimeInterval = 0.20
    private var isolation = WindowSwitcherCommandModifierIsolation()
    private var deferredCommandDown: CGEvent?
    private var generation: UInt64 = 0

    func shouldSuppress(
        event: CGEvent,
        type: CGEventType,
        keyCode: Int64,
        commandPressed: Bool
    ) -> Bool {
        let commandKeyCodes = windowSwitcherCommandKeyCodes
        let input: WindowSwitcherCommandModifierIsolation.Input
        if type == .flagsChanged, commandKeyCodes.contains(keyCode) {
            input = commandPressed ? .commandDown : .commandUp
        } else if type == .keyDown,
                  commandPressed,
                  keyCode == Int64(kVK_Tab) || keyCode == Int64(kVK_ANSI_Grave) {
            input = .switcherKeyDown
        } else {
            input = .other
        }

        var eventsToPost: [CGEvent] = []
        var scheduledGeneration: UInt64?
        var shouldSuppress = false

        lock.lock()
        let action = isolation.handle(input)
        switch action {
        case .passCurrent:
            break
        case .deferCurrent:
            guard let copiedEvent = event.copy() else {
                _ = isolation.reset()
                lock.unlock()
                return false
            }
            deferredCommandDown = copiedEvent
            generation &+= 1
            scheduledGeneration = generation
            shouldSuppress = true
        case .replayDeferredAndPassCurrent:
            // Preserve the physical shortcut key so Carbon can match it reliably.
            if let deferredCommandDown {
                eventsToPost = [deferredCommandDown]
            }
            self.deferredCommandDown = nil
            generation &+= 1
        case .replayDeferredAndCurrent:
            if let deferredCommandDown,
               let copiedCurrentEvent = event.copy() {
                eventsToPost = [deferredCommandDown, copiedCurrentEvent]
                shouldSuppress = true
            } else if let deferredCommandDown {
                eventsToPost = [deferredCommandDown]
            }
            self.deferredCommandDown = nil
            generation &+= 1
        case .suppressCurrent:
            deferredCommandDown = nil
            generation &+= 1
            shouldSuppress = true
        }
        lock.unlock()

        post(eventsToPost)
        if let scheduledGeneration {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + maximumDeferral) { [weak self] in
                self?.flushDeferredCommandDown(generation: scheduledGeneration)
            }
        }
        return shouldSuppress
    }

    func reset() {
        var eventToPost: CGEvent?
        lock.lock()
        if isolation.reset() {
            eventToPost = deferredCommandDown
        }
        deferredCommandDown = nil
        generation &+= 1
        lock.unlock()
        if let eventToPost {
            post([eventToPost])
        }
    }

    private func flushDeferredCommandDown(generation expectedGeneration: UInt64) {
        var eventToPost: CGEvent?
        lock.lock()
        if generation == expectedGeneration,
           isolation.expireDeferredCommandDown() {
            eventToPost = deferredCommandDown
            deferredCommandDown = nil
            generation &+= 1
        }
        lock.unlock()
        if let eventToPost {
            post([eventToPost])
        }
    }

    private func post(_ events: [CGEvent]) {
        events.forEach { event in
            event.setIntegerValueField(
                .eventSourceUserData,
                value: windowSwitcherReplayedEventMarker
            )
            // Re-enter before Carbon hotkey matching so replayed Command shortcuts still
            // reach RegisterEventHotKey. The marker bypasses this controller's session tap.
            event.post(tap: .cghidEventTap)
        }
    }
}

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
            controller.reenableEventTapFromCallback()
        }
        return Unmanaged.passUnretained(event)
    }

    if event.getIntegerValueField(.eventSourceUserData) == windowSwitcherReplayedEventMarker {
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
        event: event,
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
        var storedMinimized: Bool?
        var storedFocused: Bool?
        var storedMain: Bool?
    }

    private struct AXWindowListEntry {
        var candidates: [AXWindowCandidate]
        var fetchedAt: CFAbsoluteTime
        var failed: Bool
    }

    private final class OverlayRowViews {
        let container: NSView
        let iconView: NSImageView
        let titleLabel: NSTextField
        let subtitleLabel: NSTextField
        var isHighlighted = false

        init(container: NSView, iconView: NSImageView, titleLabel: NSTextField, subtitleLabel: NSTextField) {
            self.container = container
            self.iconView = iconView
            self.titleLabel = titleLabel
            self.subtitleLabel = subtitleLabel
        }
    }

    private struct PendingFocusVerification {
        var generation: UInt64
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

    private struct AXWindowSnapshot {
        var role: String?
        var subrole: String?
        var title: String?
        var minimized: Bool?
        var position: CGPoint?
        var size: CGSize?
        var main: Bool?
        var focused: Bool?

        var isSwitchable: Bool {
            guard role == kAXWindowRole as String,
                  let size,
                  size.width >= 80,
                  size.height >= 60 else {
                return false
            }
            if let subrole,
               subrole != kAXStandardWindowSubrole as String,
               subrole != kAXDialogSubrole as String {
                return false
            }
            return true
        }

        var bounds: CGRect? {
            guard let position, let size else {
                return nil
            }
            return CGRect(origin: position, size: size)
        }
    }

    private struct AXWindowCandidate {
        var window: AXUIElement
        var key: String
        var snapshot: AXWindowSnapshot?
    }

    private struct FrontmostApplicationIdentity {
        var bundleIdentifier: String?
        var processIdentifier: pid_t
        var localizedName: String?
    }

    private let runtime: AutomationRuntime
    private let commandModifierGate = WindowSwitcherCommandModifierGate()
    private let eventTapRunLoop = WindowSwitcherEventTapRunLoop()
    private let inputEventQueue = WindowSwitcherInputEventQueue()
    private let focusOperationGate = WindowSwitcherFocusGenerationGate()
    private let focusQueue = DispatchQueue(
        label: "TSMacTools.WindowSwitcherFocus",
        qos: .userInteractive
    )
    private var configuration: UserConfiguration
    private var retainedSelf: UnsafeMutableRawPointer?
    private var choices: [WindowChoice] = []
    private var recentChoices: [String: WindowChoice] = [:]
    private var recentKeys: [String] = []
    private var selectedIndex = 0
    private var sameApplicationMode = false
    private var commandPressed = false
    private var shiftPressed = false
    private var overlayWindow: NSWindow?
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
    private var pendingAXObserverInstallationKeys: Set<String> = []
    private var pendingFocusVerification: PendingFocusVerification?
    private var focusGeneration: UInt64 = 0
    private let activationCapturePolicy = WindowActivationCapturePolicy()
    private var activationCaptureGeneration: UInt64 = 0
    private var completedActivationCaptureGeneration: UInt64?
    private nonisolated static let axMessagingTimeout: Float = 0.08
    // A switch starts on the main actor. Keep each bootstrap AX call short; the
    // full 80/300 ms enumeration policy is used by the background refresh below.
    private static let axMainThreadBootstrapTimeout: Float = 0.025
    private static let axWindowEnumerationRetryTimeout: Float = 0.30
    private let axWindowListRefreshInterval: CFAbsoluteTime = 1.0
    private let axWindowListFailureRetryInterval: CFAbsoluteTime = 2.0
    private let cgWindowInfoCacheTTL: CFAbsoluteTime = 0.25
    private var axWindowListCache: [pid_t: AXWindowListEntry] = [:]
    private var inFlightAXWindowListPIDs: Set<pid_t> = []
    private var axWindowListRefreshGeneration: UInt64 = 0
    private var cgWindowInfoCache: (infos: [[String: Any]], fetchedAt: CFAbsoluteTime)?
    private var overlayRebuildPending = false
    private var overlayRowCache: [String: OverlayRowViews] = [:]
    private var overlayRowCacheWidth: CGFloat?
    private var arrangedOverlayRowKeys: [String] = []

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

        guard let retainedSelf,
              eventTapRunLoop.start(mask: CGEventMask(mask), userInfo: retainedSelf) else {
            self.retainedSelf = nil
            showStatus("Unable to create window switcher event tap. Check Accessibility permission.")
            return
        }
        installWorkspaceObservers()
        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            scheduleAXWindowListRefresh(for: [frontmostPID])
        }
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
        case (true, true) where !eventTapRunLoop.isActive:
            start()
        default:
            break
        }
    }

    func stop() {
        activationCaptureGeneration &+= 1
        completedActivationCaptureGeneration = nil
        focusGeneration &+= 1
        focusOperationGate.invalidate()
        eventTapRunLoop.stop()
        commandModifierGate.reset()
        inputEventQueue.reset()
        hideOverlay()
        removeWorkspaceObservers()
        retainedSelf = nil
        removeAXObservers()
        pendingAXObserverInstallationKeys.removeAll()
        pendingFocusVerification = nil
        axWindowListRefreshGeneration &+= 1
        axWindowListCache.removeAll()
        inFlightAXWindowListPIDs.removeAll()
        cgWindowInfoCache = nil
        overlayRebuildPending = false
        overlayRowCache.values.forEach { $0.container.removeFromSuperview() }
        overlayRowCache.removeAll()
        overlayRowCacheWidth = nil
        arrangedOverlayRowKeys.removeAll()
        choices.removeAll()
        recentChoices.removeAll()
        recentKeys.removeAll()
    }

    nonisolated func reenableEventTapFromCallback() {
        eventTapRunLoop.enable()
    }

    nonisolated func handleEvent(
        event: CGEvent,
        type: CGEventType,
        keyCode: Int64,
        commandPressed: Bool,
        shiftPressed: Bool
    ) -> Bool {
        let isTab = keyCode == Int64(kVK_Tab)
        let isBacktick = keyCode == Int64(kVK_ANSI_Grave)
        let commandModifierShouldSuppress = commandModifierGate.shouldSuppress(
            event: event,
            type: type,
            keyCode: keyCode,
            commandPressed: commandPressed
        )

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.recordFocusedWindow()
            }
            return commandModifierShouldSuppress
        }

        if type == .keyDown, commandPressed, isTab {
            enqueueInputEvent(.step(sameApplication: false, reverse: shiftPressed))
            return true
        }

        if type == .keyDown, commandPressed, isBacktick {
            enqueueInputEvent(.step(sameApplication: true, reverse: shiftPressed))
            return true
        }

        if type == .keyUp, commandPressed, (isTab || isBacktick) {
            return true
        }

        if type == .flagsChanged {
            enqueueInputEvent(.flagsChanged(commandPressed: commandPressed, shiftPressed: shiftPressed))
            return commandModifierShouldSuppress
        }

        return commandModifierShouldSuppress
    }

    nonisolated private func enqueueInputEvent(_ event: WindowSwitcherInputEventQueue.Event) {
        guard inputEventQueue.enqueue(event) else {
            return
        }
        DispatchQueue.main.async {
            self.drainInputEvents()
        }
    }

    private func drainInputEvents() {
        while let batch = inputEventQueue.takeBatch() {
            for event in batch {
                switch event {
                case let .step(sameApplication, reverse):
                    log("event step sameApplication=\(sameApplication) reverse=\(reverse)")
                    step(sameApplication: sameApplication, reverse: reverse)
                case let .flagsChanged(commandPressed, shiftPressed):
                    handleFlagsChanged(commandPressed: commandPressed, shiftPressed: shiftPressed)
                }
            }
        }
    }

    private func step(sameApplication: Bool, reverse: Bool) {
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            log("step total elapsed=\(elapsedMilliseconds(since: started)) sameApplication=\(sameApplication) reverse=\(reverse) choices=\(choices.count)")
        }

        if choices.isEmpty || sameApplicationMode != sameApplication {
            sameApplicationMode = sameApplication
            // Do not synchronously re-read the focused window here. AX reads can block
            // the main actor; activation/focus notifications keep recentChoices warm and
            // buildChoices has a focused-window fallback when that cache is stale.
            choices = buildChoices(sameApplication: sameApplication, preferFreshWindowInfo: true)
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
        remember(focus(choice))
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
        DispatchQueue.main.asyncAfter(
            deadline: .now() + configuration.windowSwitcher.effectiveDisplayDelay,
            execute: workItem
        )
    }

    private func cancelScheduledOverlay() {
        overlayDisplayWorkItem?.cancel()
        overlayDisplayWorkItem = nil
    }

    private func buildChoices(sameApplication: Bool, preferFreshWindowInfo: Bool) -> [WindowChoice] {
        let started = CFAbsoluteTimeGetCurrent()
        var cgCount = 0
        var enumeratedCount = 0
        defer {
            log("buildChoices elapsed=\(elapsedMilliseconds(since: started)) sameApplication=\(sameApplication) cgWindows=\(cgCount) enumerated=\(enumeratedCount)")
        }

        pruneRecentWindows()
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostBundleIdentifier = frontmostApplication?.bundleIdentifier
        let frontmostPID = frontmostApplication?.processIdentifier
        let ignoredNames = Set(configuration.application.ignoredWindowApplicationNames)

        guard let windowInfo = copyVisibleCGWindowInfos(preferFresh: preferFreshWindowInfo) else {
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
        var axCandidatesByProcessIdentifier: [pid_t: [AXWindowCandidate]] = [:]
        var freshAXCandidateProcessIdentifiers = Set<pid_t>()
        var unavailableAXWindowLists = Set<pid_t>()
        var axListRefreshPIDs = Set<pid_t>()
        let now = CFAbsoluteTimeGetCurrent()
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

            let resolvedAXCandidates: [AXWindowCandidate]?
            if let cached = axCandidatesByProcessIdentifier[pid] {
                resolvedAXCandidates = cached
            } else if unavailableAXWindowLists.contains(pid) {
                resolvedAXCandidates = nil
            } else {
                let resolution = resolveAXWindows(processIdentifier: pid, isFrontmost: pid == frontmostPID)
                if resolution.needsBackgroundRefresh {
                    axListRefreshPIDs.insert(pid)
                }
                if let fetchedAt = resolution.fetchedAt,
                   now - fetchedAt <= 0.20 {
                    freshAXCandidateProcessIdentifiers.insert(pid)
                }
                if resolution.unavailable {
                    unavailableAXWindowLists.insert(pid)
                }
                if let candidates = resolution.candidates {
                    axCandidatesByProcessIdentifier[pid] = candidates
                    resolvedAXCandidates = candidates
                } else {
                    resolvedAXCandidates = nil
                }
            }
            guard let axCandidates = resolvedAXCandidates else {
                log("skip AX owner=\(ownerName) pid=\(pid) cgTitle=\(cgTitle) reason=no-ax-window-list attrs=\(debugWindowInfo(info))")
                return nil
            }
            guard let (axWindow, axSnapshot) = findAXWindow(
                title: cgTitle,
                bounds: bounds,
                candidates: axCandidates,
                excludingKeys: seen
            ) else {
                log("skip AX owner=\(ownerName) pid=\(pid) cgTitle=\(cgTitle) reason=no-ax-window attrs=\(debugWindowInfo(info))")
                return nil
            }

            let key = windowKey(processIdentifier: pid, axWindow: axWindow)
            guard !seen.contains(key) else {
                log("skip duplicate owner=\(ownerName) pid=\(pid) cgTitle=\(cgTitle) key=\(key) ax=\(debugAXWindow(axWindow))")
                return nil
            }
            seen.insert(key)

            let title = displayTitle(
                cgTitle: cgTitle,
                axTitle: (axSnapshot?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                appName: app?.localizedName ?? ownerName
            )
            return WindowChoice(
                key: key,
                title: title,
                appName: app?.localizedName ?? ownerName,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: pid,
                icon: app?.icon,
                axWindow: axWindow,
                cgWindowIdentifier: cgWindowIdentifier,
                lastKnownBounds: bounds,
                storedMinimized: axSnapshot?.minimized,
                storedFocused: freshAXCandidateProcessIdentifiers.contains(pid)
                    ? axSnapshot?.focused
                    : nil,
                storedMain: freshAXCandidateProcessIdentifiers.contains(pid)
                    ? axSnapshot?.main
                    : nil
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

        var currentChoiceSource = "none"
        var currentFrontmostWindow: WindowChoice? = nil
        if let frontmostPID {
            if let recordedCurrentKey = recordedFrontmostCurrentKey(
                processIdentifier: frontmostPID,
                enumerated: enumerated
            ) {
                currentChoiceSource = "recorded-focus"
                currentFrontmostWindow = choicesByKey[recordedCurrentKey]
            } else if let focusedChoice = enumerated.first(where: {
                $0.processIdentifier == frontmostPID && $0.storedFocused == true
            }) {
                currentChoiceSource = "fresh-ax-focused"
                currentFrontmostWindow = focusedChoice
            } else if let mainChoice = enumerated.first(where: {
                $0.processIdentifier == frontmostPID && $0.storedMain == true
            }) {
                currentChoiceSource = "fresh-ax-main"
                currentFrontmostWindow = mainChoice
            } else if let focusedChoice = sameAppCurrentChoice(
                processIdentifier: frontmostPID,
                enumerated: enumerated
            ) {
                currentChoiceSource = "ax-focused"
                currentFrontmostWindow = focusedChoice
            } else {
                currentFrontmostWindow = enumerated.first(where: { $0.processIdentifier == frontmostPID })
                if currentFrontmostWindow != nil {
                    currentChoiceSource = "cg-zorder"
                }
            }
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
        if let firstEnumerated = enumerated.first(where: { $0.processIdentifier == frontmostPID }),
           let currentFrontmostWindow,
           firstEnumerated.key != currentFrontmostWindow.key {
            log("choices current-window corrected source=\(currentChoiceSource) cgTop=\(describe(firstEnumerated)) current=\(describe(currentFrontmostWindow))")
        }
        scheduleAXWindowListRefresh(for: axListRefreshPIDs, force: true)
        return result
    }

    /// Identifies the frontmost application's actual current window so the switcher
    /// lists it first even when a non-focused auxiliary window sits above it in CG
    /// z-order. Without this, cycling selects the real current window at index 1
    /// and the switch appears to do nothing.
    private func sameAppCurrentChoice(
        processIdentifier: pid_t,
        enumerated: [WindowChoice]
    ) -> WindowChoice? {
        let appElement = axApplication(processIdentifier: processIdentifier)
        guard let currentWindow = copySwitchableWindow(attribute: kAXFocusedWindowAttribute, from: appElement)
            ?? copySwitchableWindow(attribute: kAXMainWindowAttribute, from: appElement) else {
            return nil
        }
        let key = windowKey(processIdentifier: processIdentifier, axWindow: currentWindow)
        if let match = enumerated.first(where: { $0.key == key }) {
            return match
        }
        return enumerated.first(where: { CFEqual($0.axWindow, currentWindow) })
    }

    /// Skips the synchronous focused/main AX reads in `sameAppCurrentChoice` by
    /// trusting the latest recorded focus, verified against this build's enumerated keys.
    private func recordedFrontmostCurrentKey(
        processIdentifier: pid_t,
        enumerated: [WindowChoice]
    ) -> String? {
        guard let key = recentKeys.first(where: {
            guard let choice = recentChoices[$0],
                  choice.processIdentifier == processIdentifier else {
                return false
            }
            return choice.storedFocused == true || choice.storedMain == true
        }),
        let choice = recentChoices[key] else {
            return nil
        }
        return enumerated.first(where: { $0.key == choice.key })?.key
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

    private struct AXWindowListResolution {
        var candidates: [AXWindowCandidate]?
        var fetchedAt: CFAbsoluteTime?
        var unavailable = false
        var needsBackgroundRefresh = false
    }

    private func copyVisibleCGWindowInfos(preferFresh: Bool) -> [[String: Any]]? {
        if !preferFresh,
           let cache = cgWindowInfoCache,
           CFAbsoluteTimeGetCurrent() - cache.fetchedAt <= cgWindowInfoCacheTTL {
            return cache.infos
        }
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        cgWindowInfoCache = (infos, CFAbsoluteTimeGetCurrent())
        return infos
    }

    private func resolveAXWindows(processIdentifier: pid_t, isFrontmost: Bool) -> AXWindowListResolution {
        if let entry = axWindowListCache[processIdentifier] {
            let now = CFAbsoluteTimeGetCurrent()
            if entry.failed {
                var resolution = AXWindowListResolution(
                    candidates: entry.candidates.isEmpty ? nil : entry.candidates,
                    fetchedAt: entry.fetchedAt,
                    unavailable: entry.candidates.isEmpty
                )
                if now - entry.fetchedAt >= axWindowListFailureRetryInterval {
                    resolution.needsBackgroundRefresh = true
                }
                return resolution
            }
            var resolution = AXWindowListResolution(
                candidates: entry.candidates,
                fetchedAt: entry.fetchedAt
            )
            if now - entry.fetchedAt >= axWindowListRefreshInterval {
                resolution.needsBackgroundRefresh = true
            }
            return resolution
        }
        if inFlightAXWindowListPIDs.contains(processIdentifier), !isFrontmost {
            return AXWindowListResolution(candidates: nil, unavailable: true)
        }
        if isFrontmost {
            // Never enumerate the complete AX window list synchronously while the
            // user is pressing Command-Tab. A short focused-window probe gives the
            // overlay a useful current row; the full list is refreshed in the
            // background and will rebuild the overlay when it arrives.
            let fetchedAt = CFAbsoluteTimeGetCurrent()
            if let candidates = Self.fetchFocusedAXWindow(
                processIdentifier: processIdentifier,
                timeout: Self.axMainThreadBootstrapTimeout,
                debugEnabled: configuration.windowSwitcher.debug
            ) {
                axWindowListCache[processIdentifier] = AXWindowListEntry(
                    candidates: candidates,
                    fetchedAt: fetchedAt,
                    failed: true
                )
                log("AX windows bootstrap used focused window pid=\(processIdentifier)")
                return AXWindowListResolution(
                    candidates: candidates,
                    fetchedAt: fetchedAt,
                    needsBackgroundRefresh: true
                )
            }
            axWindowListCache[processIdentifier] = AXWindowListEntry(candidates: [], fetchedAt: fetchedAt, failed: true)
            log("AX windows deferred to background retry pid=\(processIdentifier)")
            return AXWindowListResolution(candidates: nil, unavailable: true, needsBackgroundRefresh: true)
        }
        return AXWindowListResolution(candidates: nil, unavailable: true, needsBackgroundRefresh: true)
    }

    private func scheduleAXWindowListRefresh(for pids: Set<pid_t>, force: Bool = false) {
        guard !pids.isEmpty else {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let processIdentifiers = pids.filter { processIdentifier in
            guard !inFlightAXWindowListPIDs.contains(processIdentifier) else {
                return false
            }
            guard !force else {
                return true
            }
            guard let entry = axWindowListCache[processIdentifier] else {
                return true
            }
            let interval = entry.failed ? axWindowListFailureRetryInterval : axWindowListRefreshInterval
            return now - entry.fetchedAt >= interval
        }
        guard !processIdentifiers.isEmpty else {
            return
        }
        let enumerationTimeout = Self.axMessagingTimeout
        let retryTimeout = Self.axWindowEnumerationRetryTimeout
        let debugEnabled = configuration.windowSwitcher.debug
        let refreshGeneration = axWindowListRefreshGeneration
        for processIdentifier in processIdentifiers.sorted() {
            inFlightAXWindowListPIDs.insert(processIdentifier)
            DispatchQueue.global(qos: .userInitiated).async {
                let windows = Self.fetchAXWindowList(
                    processIdentifier: processIdentifier,
                    enumerationTimeout: enumerationTimeout,
                    retryTimeout: retryTimeout,
                    debugEnabled: debugEnabled
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.axWindowListRefreshGeneration == refreshGeneration else {
                        return
                    }
                    self.inFlightAXWindowListPIDs.remove(processIdentifier)
                    guard self.configuration.windowSwitcher.enabled else {
                        return
                    }
                    self.storeAXWindowList(
                        processIdentifier: processIdentifier,
                        candidates: windows,
                        fetchedAt: CFAbsoluteTimeGetCurrent()
                    )
                }
            }
        }
    }

    private func storeAXWindowList(processIdentifier: pid_t, candidates: [AXWindowCandidate]?, fetchedAt: CFAbsoluteTime) {
        let previous = axWindowListCache[processIdentifier]
        if let candidates {
            axWindowListCache[processIdentifier] = AXWindowListEntry(candidates: candidates, fetchedAt: fetchedAt, failed: false)
        } else {
            // Keep a last-known-good list during a transient AX timeout. Hiding an
            // application's windows until the next retry is more disruptive than
            // showing a slightly stale candidate set.
            axWindowListCache[processIdentifier] = AXWindowListEntry(
                candidates: previous?.candidates ?? [],
                fetchedAt: fetchedAt,
                failed: true
            )
        }
        if axWindowListCache.count > 64 {
            let evictableCount = axWindowListCache.count - 64
            let stalePIDs = axWindowListCache
                .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
                .prefix(evictableCount)
                .map(\.key)
            for pid in stalePIDs {
                axWindowListCache[pid] = nil
            }
        }
        guard let candidates,
              overlayWindow?.isVisible == true else {
            return
        }
        let structureChanged = previous.map { previous in
            previous.failed || !Self.areAXWindowListsEquivalent(previous.candidates, candidates)
        } ?? true
        if structureChanged {
            scheduleOverlayRebuild()
        }
    }

    private nonisolated static func fetchFocusedAXWindow(
        processIdentifier: pid_t,
        timeout: Float,
        debugEnabled: Bool
    ) -> [AXWindowCandidate]? {
        let started = CFAbsoluteTimeGetCurrent()
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else {
            logWindowSwitcherSlowDebug(
                "AX focused window bootstrap failed pid=\(processIdentifier)",
                since: started,
                debugEnabled: debugEnabled
            )
            return nil
        }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, timeout)
        guard let snapshot = copyAXWindowSnapshot(window),
              snapshot.isSwitchable else {
            return nil
        }
        return [AXWindowCandidate(
            window: window,
            key: "\(processIdentifier):ax:\(CFHash(window))",
            snapshot: snapshot
        )]
    }

    private nonisolated static func fetchAXWindowList(
        processIdentifier: pid_t,
        enumerationTimeout: Float,
        retryTimeout: Float,
        debugEnabled: Bool
    ) -> [AXWindowCandidate]? {
        let started = CFAbsoluteTimeGetCurrent()
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, enumerationTimeout)
        var value: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if result == .cannotComplete, retryTimeout > 0 {
            AXUIElementSetMessagingTimeout(app, retryTimeout)
            value = nil
            result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            logWindowSwitcherDebug(
                "AX windows retry pid=\(processIdentifier) timeout=\(retryTimeout)s result=\(result.rawValue)",
                debugEnabled: debugEnabled
            )
        }
        guard result == .success, let windows = value as? [AXUIElement] else {
            logWindowSwitcherSlowDebug(
                "AX windows failed pid=\(processIdentifier) result=\(result.rawValue)",
                since: started,
                debugEnabled: debugEnabled
            )
            var focusedValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
                  let focusedValue else {
                return nil
            }
            let focusedWindow = focusedValue as! AXUIElement
            AXUIElementSetMessagingTimeout(focusedWindow, enumerationTimeout)
            guard isSwitchableAXWindow(focusedWindow) else {
                return nil
            }
            logWindowSwitcherDebug(
                "AX windows fallback to focused window pid=\(processIdentifier)",
                debugEnabled: debugEnabled
            )
            return makeAXWindowCandidates(
                processIdentifier: processIdentifier,
                windows: [focusedWindow]
            )
        }

        windows.forEach { AXUIElementSetMessagingTimeout($0, enumerationTimeout) }
        let candidates = makeAXWindowCandidates(
            processIdentifier: processIdentifier,
            windows: windows
        )
        logWindowSwitcherSlowDebug(
            "AX windows copied pid=\(processIdentifier) windows=\(windows.count) candidates=\(candidates.count)",
            since: started,
            debugEnabled: debugEnabled
        )
        return candidates
    }

    private nonisolated static func areAXWindowListsEquivalent(
        _ lhs: [AXWindowCandidate],
        _ rhs: [AXWindowCandidate]
    ) -> Bool {
        Set(lhs.map(\.key)) == Set(rhs.map(\.key))
    }

    private nonisolated static func makeAXWindowCandidates(
        processIdentifier: pid_t,
        windows: [AXUIElement]
    ) -> [AXWindowCandidate] {
        windows.compactMap { window in
            let key = "\(processIdentifier):ax:\(CFHash(window))"
            if let snapshot = Self.copyAXWindowSnapshot(window) {
                guard snapshot.isSwitchable else {
                    return nil
                }
                return AXWindowCandidate(window: window, key: key, snapshot: snapshot)
            }
            guard Self.isSwitchableAXWindow(window) else {
                return nil
            }
            return AXWindowCandidate(window: window, key: key, snapshot: nil)
        }
    }

    private func findAXWindow(
        title: String,
        bounds: CGRect?,
        candidates: [AXWindowCandidate],
        excludingKeys: Set<String>
    ) -> (window: AXUIElement, snapshot: AXWindowSnapshot?)? {
        let available = candidates.filter { !excludingKeys.contains($0.key) }
        if !title.isEmpty,
           let exact = available.first(where: { $0.snapshot?.title == title }) {
            return (exact.window, exact.snapshot)
        }

        if let bounds,
           let matchingBounds = available.first(where: {
               ($0.snapshot?.bounds).map { approximatelyEqual($0, bounds) } == true
           }) {
            return (matchingBounds.window, matchingBounds.snapshot)
        }

        guard let first = available.first else {
            return nil
        }
        return (first.window, first.snapshot)
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

    private nonisolated static func isSwitchableAXWindow(_ window: AXUIElement) -> Bool {
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

    private func lifecycleState(for choice: WindowChoice) -> WindowLifecycleState {
        guard let application = NSRunningApplication(processIdentifier: choice.processIdentifier) else {
            return .destroyed
        }
        if application.isHidden {
            return .dormant
        }
        if let minimized = choice.storedMinimized {
            return minimized ? .dormant : .active
        }
        // Do not synchronously validate every cached AX element while opening the
        // switcher. Destruction/miniaturization notifications update this state;
        // an unknown value is intentionally retained as indeterminate by the
        // ordering policy rather than blocking the main actor on AX.
        return .indeterminate
    }

    private func isSubstantialAXWindow(_ window: AXUIElement) -> Bool {
        guard Self.axStringAttribute(kAXRoleAttribute, for: window) == kAXWindowRole as String,
              let size = Self.axSize(for: window),
              size.width >= 80,
              size.height >= 60 else {
            return false
        }
        return true
    }

    private nonisolated static func axStringAttribute(_ attribute: String, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private nonisolated static func axSize(for element: AXUIElement) -> CGSize? {
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
              let size = Self.axSize(for: element) else {
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

    private func displayTitle(cgTitle: String, axTitle: String, appName: String) -> String {
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

    @discardableResult
    private func focus(_ choice: WindowChoice) -> WindowChoice {
        var updatedChoice = choice
        updatedChoice.storedFocused = true
        updatedChoice.storedMain = true
        // Focus always clears minimization; keep the recency model responsive
        // while the asynchronous AX operation is in flight.
        updatedChoice.storedMinimized = false

        focusGeneration &+= 1
        let generation = focusGeneration
        focusOperationGate.activate(generation)
        let started = CFAbsoluteTimeGetCurrent()
        let processIdentifier = choice.processIdentifier
        let targetWindow = WindowSwitcherAXElement(choice.axWindow)
        let focusOperationGate = self.focusOperationGate
        log("focus begin \(describe(choice)) frontmostBefore=\(frontmostDescription())")
        expectFocusedWindowChange(to: choice, generation: generation)
        scheduleAXObserverInstallation(for: choice)

        focusQueue.async {
            guard focusOperationGate.isCurrent(generation) else {
                return
            }
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let unminimizeResult = AXUIElementSetAttributeValue(
                targetWindow.value,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
            let initialAX = Self.applyFocus(to: targetWindow.value, appElement: appElement, raise: true)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.focusGeneration == generation else {
                    return
                }
                if unminimizeResult == .success {
                    self.cgWindowInfoCache = nil
                }
                self.log("focus ax-only elapsed=\(self.elapsedMilliseconds(since: started)) unminimize=\(unminimizeResult.rawValue) ax=\(initialAX) frontmostNow=\(self.frontmostDescription())")
            }
        }

        scheduleFocusAttempt(
            choice: choice,
            generation: generation,
            delay: 0.05,
            source: "retry1"
        )
        scheduleFocusAttempt(
            choice: choice,
            generation: generation,
            delay: 0.18,
            source: "retry2",
            recordFocusedWindow: true
        )

        if choice.bundleIdentifier == "com.apple.finder" {
            scheduleFocusAttempt(
                choice: choice,
                generation: generation,
                delay: 0.3,
                source: "finder-workaround"
            )
        }
        return updatedChoice
    }

    private func scheduleFocusAttempt(
        choice: WindowChoice,
        generation: UInt64,
        delay: TimeInterval,
        source: String,
        recordFocusedWindow: Bool = false
    ) {
        let processIdentifier = choice.processIdentifier
        let targetWindow = WindowSwitcherAXElement(choice.axWindow)
        let choiceKey = choice.key
        let focusOperationGate = self.focusOperationGate
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                return
            }
            guard self.focusGeneration == generation,
                  self.pendingFocusVerification?.generation == generation else {
                self.log("focus \(source) skipped; stale generation=\(generation) current=\(self.focusGeneration) key=\(choiceKey)")
                return
            }
            self.focusQueue.async {
                guard focusOperationGate.isCurrent(generation) else {
                    return
                }
                let appElement = AXUIElementCreateApplication(processIdentifier)
                let retryAX = Self.applyFocus(to: targetWindow.value, appElement: appElement, raise: true)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.focusGeneration == generation,
                          self.pendingFocusVerification?.generation == generation else {
                        return
                    }
                    self.verifyFocusedWindowChangeIfNeeded(
                        processIdentifier: processIdentifier,
                        source: source
                    )
                    self.log("focus \(source) ax=\(retryAX) frontmostAfter=\(self.frontmostDescription())")
                    if recordFocusedWindow {
                        self.recordFocusedWindow()
                    }
                }
            }
        }
    }

    private nonisolated static func applyFocus(
        to window: AXUIElement,
        appElement: AXUIElement,
        raise: Bool
    ) -> String {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, Self.axMessagingTimeout)
        AXUIElementSetMessagingTimeout(appElement, Self.axMessagingTimeout)
        AXUIElementSetMessagingTimeout(window, Self.axMessagingTimeout)
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
        remember(focus(candidate))
        return true
    }

    @discardableResult
    func focusMostRecentWindow(matching bundleIdentifier: String) -> Bool {
        recordFocusedWindow()
        guard let candidate = recentKeys.compactMap({ self.recentChoices[$0] }).first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return false
        }
        remember(focus(candidate))
        return true
    }

    private func renderOverlay() {
        overlayDisplayWorkItem = nil
        let window = overlayWindow ?? makeOverlayWindow()

        let rowWidth = CGFloat(max(320, configuration.windowSwitcher.width)) - 28
        if overlayRowCacheWidth != rowWidth {
            overlayRowCacheWidth = rowWidth
            overlayRowCache.values.forEach { $0.container.removeFromSuperview() }
            overlayRowCache.removeAll()
            arrangedOverlayRowKeys.removeAll()
        }

        let visibleRange = visibleRangeForSelection()
        var arrangedRows: [(key: String, row: OverlayRowViews)] = []
        for index in visibleRange {
            let choice = choices[index]
            let row = overlayRowCache[choice.key] ?? makeOverlayRow(rowWidth: rowWidth)
            overlayRowCache[choice.key] = row
            applyOverlayRowContent(row, choice: choice)
            updateOverlayRowSelection(row, selected: index == selectedIndex)
            arrangedRows.append((choice.key, row))
        }

        let arrangedIdentifiers = Set(arrangedRows.map { ObjectIdentifier($0.row.container) })
        for (key, row) in overlayRowCache where !arrangedIdentifiers.contains(ObjectIdentifier(row.container)) {
            row.container.removeFromSuperview()
            overlayRowCache[key] = nil
        }
        let arrangedKeys = arrangedRows.map(\.key)
        if arrangedOverlayRowKeys != arrangedKeys {
            overlayStack.arrangedSubviews.forEach {
                overlayStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            arrangedRows.forEach { overlayStack.addArrangedSubview($0.row.container) }
            arrangedOverlayRowKeys = arrangedKeys
        }

        let frame = overlayFrame()
        if !NSEqualRects(window.frame, frame) {
            window.setFrame(frame, display: true)
        }
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

    private func makeOverlayRow(rowWidth: CGFloat) -> OverlayRowViews {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail

        let subtitleLabel = NSTextField(labelWithString: "")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
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
            container.widthAnchor.constraint(equalToConstant: rowWidth),
            container.heightAnchor.constraint(equalToConstant: 48),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            rowStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            rowStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            rowStack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return OverlayRowViews(
            container: container,
            iconView: iconView,
            titleLabel: titleLabel,
            subtitleLabel: subtitleLabel
        )
    }

    private func applyOverlayRowContent(_ row: OverlayRowViews, choice: WindowChoice) {
        if row.titleLabel.stringValue != choice.title {
            row.titleLabel.stringValue = choice.title
        }
        let subtitleParts = [choice.appName, choice.bundleIdentifier.isEmpty ? nil : choice.bundleIdentifier].compactMap { $0 }
        let subtitle = subtitleParts.joined(separator: " · ")
        if row.subtitleLabel.stringValue != subtitle {
            row.subtitleLabel.stringValue = subtitle
        }
        if row.iconView.image !== choice.icon {
            row.iconView.image = choice.icon
        }
    }

    private func updateOverlayRowSelection(_ row: OverlayRowViews, selected: Bool) {
        guard row.isHighlighted != selected else {
            return
        }
        row.isHighlighted = selected
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        row.container.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor
        CATransaction.commit()
        let font = NSFont.systemFont(ofSize: 14, weight: selected ? .semibold : .medium)
        if row.titleLabel.font != font {
            row.titleLabel.font = font
        }
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
              let windowBounds = choices[selectedIndex].lastKnownBounds ?? axBounds(for: choices[selectedIndex].axWindow) else {
            return fallback
        }
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
        guard let window = copyAXWindow(attribute: preferredAttribute, from: appElement)
            ?? copyAXWindow(attribute: fallbackAttribute, from: appElement) else {
            return false
        }
        configureAXTimeout(window)
        let snapshot = Self.copyAXWindowSnapshot(window)
        if let snapshot {
            guard snapshot.isSwitchable else {
                return false
            }
        } else {
            guard Self.isSwitchableAXWindow(window) else {
                return false
            }
        }
        let title = (snapshot?.title ?? axTitle(for: window))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            lastKnownBounds: cgIdentity?.bounds,
            storedMinimized: snapshot?.minimized,
            storedFocused: true,
            storedMain: preferMainWindow
        )
        remember(choice)
        scheduleAXObserverInstallation(for: choice)
        return true
    }

    private func visibleCGWindowIdentity(
        processIdentifier: pid_t,
        title: String
    ) -> (identifier: CGWindowID?, bounds: CGRect?)? {
        guard let windowInfo = copyVisibleCGWindowInfos(preferFresh: false) else {
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

    private func copyAXWindow(attribute: String, from appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        let window = value as! AXUIElement
        configureAXTimeout(window)
        return window
    }

    private func copySwitchableWindow(attribute: String, from appElement: AXUIElement) -> AXUIElement? {
        guard let window = copyAXWindow(attribute: attribute, from: appElement) else {
            return nil
        }
        if let snapshot = Self.copyAXWindowSnapshot(window) {
            return snapshot.isSwitchable ? window : nil
        }
        return Self.isSwitchableAXWindow(window) ? window : nil
    }

    private func remember(_ choice: WindowChoice) {
        if choice.storedFocused == true || choice.storedMain == true {
            for key in recentKeys where key != choice.key {
                guard var previous = recentChoices[key],
                      previous.processIdentifier == choice.processIdentifier else {
                    continue
                }
                previous.storedFocused = false
                previous.storedMain = false
                recentChoices[key] = previous
            }
        }
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
                self?.axWindowListCache[application.processIdentifier] = nil
                self?.pruneRecentWindows()
            }
        })
    }

    private func scheduleActivatedWindowCaptures(for application: NSRunningApplication) {
        activationCaptureGeneration &+= 1
        let generation = activationCaptureGeneration
        completedActivationCaptureGeneration = nil
        let processIdentifier = application.processIdentifier
        scheduleAXWindowListRefresh(for: [processIdentifier])
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

    private func pruneRecentWindows() {
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        recentKeys.removeAll { key in
            guard let choice = recentChoices[key] else {
                return true
            }
            let keep = runningPIDs.contains(choice.processIdentifier)
            if !keep {
                recentChoices[key] = nil
                removeAXObserver(forWindowKey: key)
            }
            return !keep
        }
    }

    private func moveDormantWindowsToEnd() {
        pruneRecentWindows()
        let dormantKeys = Set(recentKeys.filter { key in
            recentChoices[key].map(isDormantRecentChoice) ?? false
        })
        recentKeys.sort { lhs, rhs in
            dormantKeys.contains(lhs) && !dormantKeys.contains(rhs)
        }
        if overlayWindow?.isVisible == true {
            scheduleOverlayRebuild()
        }
    }

    private func isDormantRecentChoice(_ choice: WindowChoice) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: choice.processIdentifier) else {
            return true
        }
        if application.isHidden {
            return true
        }
        if let minimized = choice.storedMinimized {
            return minimized
        }
        return choice.storedMinimized == true
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

    private func scheduleAXObserverInstallation(for choice: WindowChoice) {
        guard !pendingAXObserverInstallationKeys.contains(choice.key) else {
            return
        }
        pendingAXObserverInstallationKeys.insert(choice.key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) { [weak self] in
            guard let self else {
                return
            }
            self.pendingAXObserverInstallationKeys.remove(choice.key)
            guard self.configuration.windowSwitcher.enabled,
                  self.eventTapRunLoop.isActive,
                  NSRunningApplication(processIdentifier: choice.processIdentifier) != nil else {
                return
            }
            self.installAXObserver(processIdentifier: choice.processIdentifier)
            self.installAXObserver(for: choice)
        }
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
            axWindowListCache[processIdentifier] = nil
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
             kAXWindowDeminiaturizedNotification:
            updateStoredMinimizedState(
                processIdentifier: processIdentifier,
                elementHash: elementHash,
                minimized: notification == kAXWindowMiniaturizedNotification
            )
            moveDormantWindowsToEnd()
        case kAXApplicationHiddenNotification,
             kAXApplicationShownNotification:
            moveDormantWindowsToEnd()
        case kAXWindowCreatedNotification:
            axWindowListCache[processIdentifier] = nil
            recordFocusedWindow(expectedProcessIdentifier: processIdentifier)
        case kAXFocusedWindowChangedNotification:
            verifyFocusedWindowChangeIfNeeded(processIdentifier: processIdentifier, source: "notification")
            recordFocusedWindow(expectedProcessIdentifier: processIdentifier)
        case kAXMainWindowChangedNotification:
            recordFocusedWindow(
                expectedProcessIdentifier: processIdentifier,
                preferMainWindow: true
            )
        default:
            pruneRecentWindows()
        }

        if overlayWindow?.isVisible == true {
            scheduleOverlayRebuild()
        }
    }

    private func updateStoredMinimizedState(
        processIdentifier: pid_t,
        elementHash: CFHashCode,
        minimized: Bool
    ) {
        for key in recentKeys {
            guard let choice = recentChoices[key],
                  choice.processIdentifier == processIdentifier,
                  CFHash(choice.axWindow) == elementHash else {
                continue
            }
            var updated = choice
            updated.storedMinimized = minimized
            recentChoices[key] = updated
        }
    }

    private func scheduleOverlayRebuild() {
        guard overlayWindow?.isVisible == true, !overlayRebuildPending else {
            return
        }
        overlayRebuildPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.overlayRebuildPending = false
            guard self.overlayWindow?.isVisible == true else {
                return
            }
            self.rebuildChoicesForOverlay()
        }
    }

    private func rebuildChoicesForOverlay() {
        let selectedKey = choices.indices.contains(selectedIndex) ? choices[selectedIndex].key : nil
        choices = buildChoices(sameApplication: sameApplicationMode, preferFreshWindowInfo: false)
        if let selectedKey, let newIndex = choices.firstIndex(where: { $0.key == selectedKey }) {
            selectedIndex = newIndex
        } else {
            selectedIndex = min(selectedIndex, max(choices.count - 1, 0))
        }
        renderOverlay()
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

    private func expectFocusedWindowChange(to choice: WindowChoice, generation: UInt64) {
        pendingFocusVerification = PendingFocusVerification(
            generation: generation,
            key: choice.key,
            title: choice.title,
            processIdentifier: choice.processIdentifier,
            window: choice.axWindow,
            startedAt: CFAbsoluteTimeGetCurrent()
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  let pending = self.pendingFocusVerification,
                  pending.generation == generation,
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

    private func log(_ message: @autoclosure () -> String) {
        guard configuration.windowSwitcher.debug else {
            return
        }
        let renderedMessage = message()
        windowSwitcherLogger.info("\(renderedMessage, privacy: .public)")
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
        AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout)
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
        guard let snapshot = Self.copyAXWindowSnapshot(window) else {
            return "pid=\(processIdentifier(for: window)) hash=\(CFHash(window)) snapshot=<unavailable>"
        }
        let hidden = NSRunningApplication(processIdentifier: processIdentifier(for: window))?.isHidden.description ?? "<nil>"
        let size = snapshot.size.map { "\($0.width)x\($0.height)" } ?? "<nil>"
        let position = snapshot.position.map { "\($0.x),\($0.y)" } ?? "<nil>"
        return "role=\(snapshot.role ?? "<nil>") subrole=\(snapshot.subrole ?? "<nil>") title=\(snapshot.title ?? "") minimized=\(snapshot.minimized.map(String.init(describing:)) ?? "<nil>") hidden=\(hidden) main=\(snapshot.main.map(String.init(describing:)) ?? "<nil>") focused=\(snapshot.focused.map(String.init(describing:)) ?? "<nil>") position=\(position) size=\(size)"
    }

    private nonisolated static func copyAXWindowSnapshot(_ window: AXUIElement) -> AXWindowSnapshot? {
        let attributes: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXMinimizedAttribute as CFString,
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            kAXMainAttribute as CFString,
            kAXFocusedAttribute as CFString
        ]
        var copiedValues: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            window,
            attributes as CFArray,
            [],
            &copiedValues
        )
        guard result == .success,
              let values = copiedValues as? [Any],
              values.count == attributes.count else {
            return nil
        }

        func point(at index: Int) -> CGPoint? {
            guard CFGetTypeID(values[index] as CFTypeRef) == AXValueGetTypeID() else {
                return nil
            }
            let value = values[index] as! AXValue
            var point = CGPoint.zero
            return AXValueGetValue(value, .cgPoint, &point) ? point : nil
        }

        func size(at index: Int) -> CGSize? {
            guard CFGetTypeID(values[index] as CFTypeRef) == AXValueGetTypeID() else {
                return nil
            }
            let value = values[index] as! AXValue
            var size = CGSize.zero
            return AXValueGetValue(value, .cgSize, &size) ? size : nil
        }

        return AXWindowSnapshot(
            role: values[0] as? String,
            subrole: values[1] as? String,
            title: values[2] as? String,
            minimized: values[3] as? Bool,
            position: point(at: 4),
            size: size(at: 5),
            main: values[6] as? Bool,
            focused: values[7] as? Bool
        )
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

}
