import AppKit
import ApplicationServices
import Carbon
import Darwin
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

@MainActor
final class WindowSwitcherController {
    private struct WindowChoice {
        var key: String
        var title: String
        var appName: String
        var bundleIdentifier: String
        var processIdentifier: pid_t
        var icon: NSImage?
        var axWindow: AXUIElement
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
    private let overlayStack = NSStackView()
    private var workspaceObservers: [NSObjectProtocol] = []

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.recordFocusedWindow()
        }
    }

    func stop() {
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
                self.step(sameApplication: false, reverse: false)
            }
            return true
        }

        if type == .keyDown, commandPressed, isBacktick {
            DispatchQueue.main.async {
                self.log("event keyDown cmd+`")
                self.step(sameApplication: true, reverse: false)
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
            return commandPressed
        }

        return false
    }

    private func step(sameApplication: Bool, reverse: Bool) {
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

        renderOverlay()
    }

    private func handleFlagsChanged(commandPressed: Bool, shiftPressed: Bool) {
        let wasCommandPressed = self.commandPressed
        let wasShiftPressed = self.shiftPressed
        self.commandPressed = commandPressed
        self.shiftPressed = shiftPressed

        if commandPressed, shiftPressed, !wasShiftPressed {
            stepBackwardIfVisible()
        }

        if wasCommandPressed, !commandPressed {
            commitSelectionIfNeeded()
        }
    }

    private func stepBackwardIfVisible() {
        guard overlayWindow?.isVisible == true, !choices.isEmpty else {
            return
        }
        selectedIndex = (selectedIndex - 1 + choices.count) % choices.count
        renderOverlay()
    }

    private func commitSelectionIfNeeded() {
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

    private func buildChoices(sameApplication: Bool) -> [WindowChoice] {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ignoredNames = Set(configuration.application.ignoredWindowApplicationNames)

        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else {
            return []
        }

        var seen = Set<String>()
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
            guard let axWindow = findAXWindow(processIdentifier: pid, title: cgTitle, bounds: cgBounds(from: info)) else {
                log("skip AX owner=\(ownerName) pid=\(pid) cgTitle=\(cgTitle) reason=no-ax-window attrs=\(debugWindowInfo(info))")
                return nil
            }
            guard isRealAXWindow(axWindow) else {
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
                axWindow: axWindow
            )
        }

        let byKey = Dictionary(uniqueKeysWithValues: enumerated.map { ($0.key, $0) })
        let recent = recentKeys.compactMap { key -> WindowChoice? in
            guard let choice = byKey[key] ?? recentChoices[key] else {
                return nil
            }
            if sameApplication,
               choice.processIdentifier != frontmostPID,
               choice.bundleIdentifier != frontmostBundleIdentifier {
                return nil
            }
            return choice
        }
        let recentSet = Set(recent.map(\.key))
        let result = recent + enumerated.filter { !recentSet.contains($0.key) }
        let orderedDescription = result.enumerated()
            .map { "#\($0.offset):\(describe($0.element))" }
            .joined(separator: " | ")
        log("choices ordered=\(orderedDescription)")
        return result
    }

    private func findAXWindow(processIdentifier: pid_t, title: String, bounds: CGRect?) -> AXUIElement? {
        let app = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else {
            return nil
        }

        let realWindows = windows.filter { isRealAXWindow($0) }
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

    private func isRealAXWindow(_ window: AXUIElement) -> Bool {
        let role = axStringAttribute(kAXRoleAttribute, for: window)
        let subrole = axStringAttribute(kAXSubroleAttribute, for: window)
        guard role == kAXWindowRole as String else {
            return false
        }
        if let subrole, subrole != kAXStandardWindowSubrole as String && subrole != kAXDialogSubrole as String {
            return false
        }

        if axBoolAttribute(kAXMinimizedAttribute, for: window) == true {
            return false
        }
        guard let size = axSize(for: window),
              size.width >= 80,
              size.height >= 60 else {
            return false
        }
        return true
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
        let appElement = AXUIElementCreateApplication(choice.processIdentifier)
        let app = NSRunningApplication(processIdentifier: choice.processIdentifier)
        log("focus begin \(describe(choice)) ax=\(debugAXWindow(choice.axWindow)) frontmostBefore=\(frontmostDescription())")

        let unhideResult = app?.unhide() ?? false
        let initialAX = applyFocus(to: choice.axWindow, appElement: appElement, raise: false)
        let carbonFrontmost = setFrontProcess(processIdentifier: choice.processIdentifier, allWindows: false)
        let activateResult = app?.activate(options: [.activateIgnoringOtherApps]) ?? false
        let raiseResult = AXUIElementPerformAction(choice.axWindow, kAXRaiseAction as CFString)
        log("focus hammerspoon-style unhide=\(unhideResult) ax=\(initialAX) setFrontmost=\(carbonFrontmost) activate=\(activateResult) raise=\(raiseResult.rawValue) frontmostNow=\(frontmostDescription())")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let retryAX = self.applyFocus(to: choice.axWindow, appElement: appElement, raise: true)
            let frontmostRetry = self.setFrontProcess(processIdentifier: choice.processIdentifier, allWindows: false)
            self.log("focus retry1 setFrontmost=\(frontmostRetry) ax=\(retryAX) frontmostAfter=\(self.frontmostDescription()) focusedAX=\(self.focusedAXDescription(processIdentifier: choice.processIdentifier))")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != choice.processIdentifier else {
                self.recordFocusedWindow()
                return
            }
            let frontmostRetry = self.setFrontProcess(processIdentifier: choice.processIdentifier, allWindows: false)
            let activateRetry = app?.activate(options: [.activateIgnoringOtherApps, .activateAllWindows]) ?? false
            let retryAX = self.applyFocus(to: choice.axWindow, appElement: appElement, raise: true)
            self.log("focus retry2 setFrontmost=\(frontmostRetry) activate=\(activateRetry) ax=\(retryAX) frontmostAfter=\(self.frontmostDescription()) focusedAX=\(self.focusedAXDescription(processIdentifier: choice.processIdentifier))")
            self.recordFocusedWindow()
        }
    }

    private func applyFocus(to window: AXUIElement, appElement: AXUIElement, raise: Bool) -> String {
        let raiseBefore = raise ? AXUIElementPerformAction(window, kAXRaiseAction as CFString) : .success
        let mainResult = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let windowFocusResult = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let appFocusResult = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        let raiseAfter = raise ? AXUIElementPerformAction(window, kAXRaiseAction as CFString) : .success
        return "raiseBefore=\(raiseBefore.rawValue) main=\(mainResult.rawValue) windowFocused=\(windowFocusResult.rawValue) appFocused=\(appFocusResult.rawValue) raiseAfter=\(raiseAfter.rawValue)"
    }

    private func setFrontProcess(processIdentifier: pid_t, allWindows: Bool) -> String {
        typealias GetProcessForPIDFunction = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
        typealias SetFrontProcessWithOptionsFunction = @convention(c) (UnsafePointer<ProcessSerialNumber>, OptionBits) -> OSStatus

        guard let getProcessSymbol = dlsym(dlopen(nil, RTLD_NOW), "GetProcessForPID"),
              let setFrontSymbol = dlsym(dlopen(nil, RTLD_NOW), "SetFrontProcessWithOptions") else {
            return "carbonSymbols=missing"
        }

        let getProcessForPID = unsafeBitCast(getProcessSymbol, to: GetProcessForPIDFunction.self)
        let setFrontProcessWithOptions = unsafeBitCast(setFrontSymbol, to: SetFrontProcessWithOptionsFunction.self)
        var processSerialNumber = ProcessSerialNumber()
        let getStatus = getProcessForPID(processIdentifier, &processSerialNumber)
        guard getStatus == noErr else {
            return "getProcess=\(getStatus)"
        }
        let options: OptionBits = allWindows ? 0 : OptionBits(kSetFrontProcessFrontWindowOnly)
        let frontStatus = setFrontProcessWithOptions(&processSerialNumber, options)
        return "getProcess=\(getStatus) setFront=\(frontStatus)"
    }

    @discardableResult
    func focusMostRecentWindow(excluding excludedBundleIdentifier: String? = nil) -> Bool {
        recordFocusedWindow()
        guard let candidate = recentKeys.lazy.compactMap({ self.recentChoices[$0] }).first(where: { choice in
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
        guard let candidate = recentKeys.lazy.compactMap({ self.recentChoices[$0] }).first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return false
        }
        focus(candidate)
        remember(candidate)
        return true
    }

    private func renderOverlay() {
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
            container.widthAnchor.constraint(equalToConstant: CGFloat(configuration.windowSwitcher.width - 28)),
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
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = CGFloat(configuration.windowSwitcher.width)
        let rows = max(1, min(configuration.windowSwitcher.maxVisibleRows, max(choices.count, 1)))
        let height = min(CGFloat(configuration.windowSwitcher.height), CGFloat(rows * 54 + 28))
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func hideOverlay() {
        overlayWindow?.orderOut(nil)
    }

    func recordFocusedWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else {
            return
        }

        let window = value as! AXUIElement
        let rawTitle = axTitle(for: window)
        guard isRealAXWindow(window) else {
            return
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        remember(WindowChoice(
            key: windowKey(processIdentifier: app.processIdentifier, axWindow: window),
            title: title.isEmpty ? "\(app.localizedName ?? "Application") Window" : title,
            appName: app.localizedName ?? app.bundleIdentifier ?? "Application",
            bundleIdentifier: app.bundleIdentifier ?? "",
            processIdentifier: app.processIdentifier,
            icon: app.icon,
            axWindow: window
        ))
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
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.recordFocusedWindow()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pruneRecentWindows()
            }
        })
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
            }
            return !keep
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
        let size = axSize(for: window).map { "\($0.width)x\($0.height)" } ?? "<nil>"
        let position = axPosition(for: window).map { "\($0.x),\($0.y)" } ?? "<nil>"
        let main = axBoolAttribute(kAXMainAttribute, for: window).map(String.init(describing:)) ?? "<nil>"
        let focused = axBoolAttribute(kAXFocusedAttribute, for: window).map(String.init(describing:)) ?? "<nil>"
        return "role=\(role) subrole=\(subrole) title=\(title) minimized=\(minimized) main=\(main) focused=\(focused) position=\(position) size=\(size)"
    }

    private func frontmostDescription() -> String {
        let app = NSWorkspace.shared.frontmostApplication
        return "name=\(app?.localizedName ?? "<nil>") bundle=\(app?.bundleIdentifier ?? "<nil>") pid=\(app?.processIdentifier.description ?? "<nil>")"
    }

    private func focusedAXDescription(processIdentifier: pid_t) -> String {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else {
            return "<none>"
        }
        return debugAXWindow(value as! AXUIElement)
    }
}
