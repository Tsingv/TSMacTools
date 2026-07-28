import AppKit
import ApplicationServices
import CoreVideo
import Foundation
import MacToolsCore
import os

private let smoothScrollSyntheticMarker: Int64 = 0x54534D535343524C

enum ScrollTapInput {
    case scroll(CGEvent)
    case cancelMotion
    case disabled
}

enum ScrollTapDisposition: Equatable {
    case passThrough
    case consume
}

enum ScrollEventSource: Equatable, Sendable {
    case local
    case remoteDesktop
    case logitechOptions
}

protocol ScrollEventTapDriving: AnyObject, Sendable {
    var isInstalled: Bool { get }
    var isEnabled: Bool { get }
    func install() -> Bool
    func setEnabled(_ enabled: Bool)
    func remove()
    func invalidate()
}

protocol ScrollFrameDriving: AnyObject, Sendable {
    var hasDeliveredFrame: Bool { get }
    func prepare() -> Bool
    func start() -> Bool
    func stop()
    @discardableResult func recreate(force: Bool) -> Bool
    func invalidate()
}

protocol SmoothScrollScheduledTask: AnyObject, Sendable {
    func cancel()
}

protocol SmoothScrollScheduling: Sendable {
    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        _ action: @escaping @Sendable () -> Void
    ) -> any SmoothScrollScheduledTask
}

struct SmoothScrollEnvironment: @unchecked Sendable {
    var makeEventTap: (@escaping @Sendable (ScrollTapInput) -> ScrollTapDisposition) -> any ScrollEventTapDriving
    var makeFrameDriver: (
        @escaping @Sendable (TimeInterval) -> Void,
        @escaping @Sendable () -> Void
    ) -> any ScrollFrameDriving
    var scheduler: any SmoothScrollScheduling
    var now: @Sendable () -> TimeInterval
    var isAccessibilityTrusted: @Sendable () -> Bool
    var resolveTargetPID: @Sendable (CGEvent) -> pid_t
    var classifyEventSource: @Sendable (CGEvent) -> ScrollEventSource
    var shouldBypassTarget: @Sendable (pid_t) -> Bool
    var post: @Sendable (CGEvent, pid_t) -> Void

    static let live: SmoothScrollEnvironment = {
        let scheduler = DispatchSmoothScrollScheduler()
        let now: @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
        let sourceResolver = ScrollEventSourceResolver()
        return SmoothScrollEnvironment(
            makeEventTap: { handler in
                CGScrollEventTapDriver(handler: handler)
            },
            makeFrameDriver: { frameHandler, unavailableHandler in
                ScrollDisplayDriver(
                    frameHandler: frameHandler,
                    unavailableHandler: unavailableHandler,
                    scheduler: scheduler,
                    now: now
                )
            },
            scheduler: scheduler,
            now: now,
            isAccessibilityTrusted: {
                AXIsProcessTrusted()
            },
            resolveTargetPID: { event in
                let eventPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
                if eventPID > 1 { return eventPID }
                guard Thread.isMainThread else { return 0 }
                return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            },
            classifyEventSource: { event in
                sourceResolver.classify(event)
            },
            shouldBypassTarget: { targetPID in
                guard targetPID > 1 else { return false }
                if #available(macOS 26.0, *) { return false }
                return NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier == "com.apple.dock"
            },
            post: { event, targetPID in
                if #available(macOS 26.0, *) {
                    // Direct-to-PID wheel events are ignored by representative macOS 26 targets.
                    // The copied physical location lets WindowServer route the marked event to the
                    // window under the pointer, and the marker prevents this tap from smoothing it again.
                    event.post(tap: .cgSessionEventTap)
                } else if targetPID > 1 {
                    event.postToPid(targetPID)
                } else {
                    event.post(tap: .cgSessionEventTap)
                }
            }
        )
    }()
}

/// Owns smooth-scrolling policy while delegating all macOS handles and time scheduling to injected
/// drivers. The default environment uses one reusable event tap and display link.
public final class SmoothScrollController: @unchecked Sendable {
    #if DEBUG
    private static let diagnosticLogger = Logger(
        subsystem: "local.clearain.MacTools",
        category: "smooth-scroll"
    )
    #endif

    private enum Lifecycle {
        case stopped
        case running
        case shutdown
    }

    private struct PendingLineDelta {
        var horizontal: Int64 = 0
        var vertical: Int64 = 0

        mutating func clear() {
            horizontal = 0
            vertical = 0
        }
    }

    private struct State {
        var settings: ScrollSettings
        var session: SmoothScrollSession
        var template: CGEvent?
        var templateGeneration: UInt64 = 0
        var pendingLineDelta = PendingLineDelta()
        var restartLimiter = EventTapRestartLimiter()
        var lifecycle: Lifecycle = .stopped
    }

    private let lock = NSLock()
    private let operationLock = NSRecursiveLock()
    private var state: State
    private let environment: SmoothScrollEnvironment
    private let notificationCenter: NotificationCenter
    private var eventTapDriver: (any ScrollEventTapDriving)!
    private var displayDriver: (any ScrollFrameDriving)!
    private var screenObserver: NSObjectProtocol?
    private var screenRebuildTask: (any SmoothScrollScheduledTask)?
    private var idleDisplayStopTask: (any SmoothScrollScheduledTask)?
    private var eventTapHealthTask: (any SmoothScrollScheduledTask)?
    #if DEBUG
    private var diagnosticInputCount: UInt64 = 0
    private var diagnosticFrameCount: UInt64 = 0
    #endif

    public convenience init(settings: ScrollSettings) {
        self.init(settings: settings, environment: .live, notificationCenter: .default)
    }

    init(
        settings: ScrollSettings,
        environment: SmoothScrollEnvironment,
        notificationCenter: NotificationCenter
    ) {
        precondition(Thread.isMainThread)
        let sanitized = Self.sanitized(settings)
        state = State(
            settings: sanitized,
            session: SmoothScrollSession(tuning: sanitized.tuning)
        )
        self.environment = environment
        self.notificationCenter = notificationCenter
        eventTapDriver = environment.makeEventTap { [weak self] input in
            self?.handleTapInput(input) ?? .passThrough
        }
        displayDriver = environment.makeFrameDriver(
            { [weak self] timestamp in self?.renderFrame(at: timestamp) },
            { [weak self] in self?.displayDriverBecameUnavailable() }
        )
        screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleDisplayRebuild()
        }
    }

    deinit {
        performShutdown()
    }

    public func apply(_ settings: ScrollSettings) {
        precondition(Thread.isMainThread)
        operationLock.lock()
        defer { operationLock.unlock() }
        let sanitized = Self.sanitized(settings)
        let previous: ScrollSettings? = withState { state in
            guard state.lifecycle != .shutdown else { return nil }
            return state.settings
        }
        guard let previous else { return }
        guard previous != sanitized else {
            if sanitized.enabled, !eventTapDriver.isEnabled { start() }
            return
        }

        cancelIdleDisplayStop()
        withState { state in
            state.settings = sanitized
            state.session.update(tuning: sanitized.tuning)
            clearSessionState(&state)
        }
        if sanitized.enabled {
            displayDriver.stop()
            start()
        } else {
            stopListening()
        }
    }

    public func start() {
        precondition(Thread.isMainThread)
        operationLock.lock()
        defer { operationLock.unlock() }
        let shouldStart = withState { state -> Bool in
            guard state.lifecycle != .shutdown, state.settings.enabled else { return false }
            state.lifecycle = .running
            return true
        }
        guard shouldStart else { return }
        scheduleEventTapHealthCheck()
        guard environment.isAccessibilityTrusted() else { return }
        if eventTapDriver.isInstalled {
            if !eventTapDriver.isEnabled { recoverEventTapIfPermitted() }
            return
        }
        installEventTap()
    }

    public func shutdown() {
        precondition(Thread.isMainThread)
        performShutdown()
    }

    private func performShutdown() {
        operationLock.lock()
        defer { operationLock.unlock() }
        let shouldShutdown = withState { state -> Bool in
            guard state.lifecycle != .shutdown else { return false }
            state.lifecycle = .shutdown
            clearSessionState(&state)
            return true
        }
        guard shouldShutdown else { return }

        screenRebuildTask?.cancel()
        screenRebuildTask = nil
        cancelIdleDisplayStop()
        cancelEventTapHealthCheck()
        if let screenObserver {
            notificationCenter.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        displayDriver.invalidate()
        eventTapDriver.invalidate()
    }

    private func installEventTap() {
        precondition(Thread.isMainThread)
        guard withState({ $0.lifecycle == .running }),
              environment.isAccessibilityTrusted(),
              displayDriver.prepare() else {
            return
        }
        guard eventTapDriver.install(), eventTapDriver.isEnabled else {
            eventTapDriver.remove()
            return
        }
    }

    private func stopListening() {
        precondition(Thread.isMainThread)
        screenRebuildTask?.cancel()
        screenRebuildTask = nil
        cancelIdleDisplayStop()
        cancelEventTapHealthCheck()
        withState { state in
            guard state.lifecycle != .shutdown else { return }
            state.lifecycle = .stopped
            clearSessionState(&state)
            state.restartLimiter.reset()
        }
        displayDriver.stop()
        eventTapDriver.remove()
    }

    private func handleTapInput(_ input: ScrollTapInput) -> ScrollTapDisposition {
        precondition(Thread.isMainThread)
        operationLock.lock()
        defer { operationLock.unlock() }
        guard withState({ $0.lifecycle == .running }) else { return .passThrough }
        switch input {
        case .cancelMotion:
            resetSession()
            cancelIdleDisplayStop()
            displayDriver.stop()
            return .passThrough
        case .disabled:
            resetSession()
            cancelIdleDisplayStop()
            displayDriver.stop()
            scheduleEventTapHealthCheck()
            recoverEventTapIfPermitted()
            return .passThrough
        case let .scroll(event):
            return handleScrollEvent(event) ? .consume : .passThrough
        }
    }

    private func recoverEventTapIfPermitted() {
        precondition(Thread.isMainThread)
        guard environment.isAccessibilityTrusted(),
              withState({ $0.lifecycle == .running && $0.settings.enabled }) else {
            return
        }
        let timestamp = environment.now()
        guard withState({ $0.restartLimiter.shouldAllowRestart(at: timestamp) }) else { return }

        if !eventTapDriver.isInstalled {
            installEventTap()
            return
        }
        eventTapDriver.setEnabled(true)
        guard !eventTapDriver.isEnabled else { return }
        eventTapDriver.remove()
    }

    private func scheduleEventTapHealthCheck() {
        precondition(Thread.isMainThread)
        guard eventTapHealthTask == nil,
              withState({ $0.lifecycle == .running && $0.settings.enabled }) else {
            return
        }
        eventTapHealthTask = environment.scheduler.schedule(after: 1, repeating: 1) { [weak self] in
            self?.maintainEventTap()
        }
    }

    private func maintainEventTap() {
        precondition(Thread.isMainThread)
        operationLock.lock()
        defer { operationLock.unlock() }
        guard withState({ $0.lifecycle == .running && $0.settings.enabled }) else {
            cancelEventTapHealthCheck()
            return
        }
        guard environment.isAccessibilityTrusted() else {
            if eventTapDriver.isInstalled {
                cancelIdleDisplayStop()
                displayDriver.stop()
                resetSession()
                eventTapDriver.remove()
            }
            return
        }
        guard !eventTapDriver.isEnabled else { return }
        recoverEventTapIfPermitted()
    }

    private func cancelEventTapHealthCheck() {
        eventTapHealthTask?.cancel()
        eventTapHealthTask = nil
    }

    private func handleScrollEvent(_ event: CGEvent) -> Bool {
        precondition(Thread.isMainThread)
        if event.getIntegerValueField(.eventSourceUserData) == smoothScrollSyntheticMarker {
            return false
        }

        let settings: ScrollSettings? = withState { state in
            guard state.lifecycle == .running else { return nil }
            return state.settings
        }
        guard let settings, settings.enabled else { return false }
        let source = environment.classifyEventSource(event)
        if source == .remoteDesktop,
           event.getDoubleValueField(.scrollWheelEventIsContinuous) != 0 {
            return false
        }
        let characteristics = ScrollInputCharacteristics(
            scrollPhase: event.getDoubleValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getDoubleValueField(.scrollWheelEventMomentumPhase),
            scrollCount: event.getDoubleValueField(.scrollWheelEventScrollCount)
        )
        if settings.excludeTrackpad,
           source != .logitechOptions,
           characteristics.isTrackpadLike {
            logPhysicalEvent(event, source: source, targetPID: 0, disposition: "trackpad-pass")
            return false
        }

        let originalHorizontal = axisSample(event, axis: .horizontal)
        let originalVertical = axisSample(event, axis: .vertical)
        let depth = axisSample(event, axis: .depth)
        let horizontal = settings.reverseHorizontal ? originalHorizontal.reversed : originalHorizontal
        let vertical = settings.reverseVertical ? originalVertical.reversed : originalVertical
        let input = ScrollVector(x: horizontal.usableDelta, y: vertical.usableDelta)
        guard input.magnitude > 0 else { return false }
        let targetPID = environment.resolveTargetPID(event)
        if environment.shouldBypassTarget(targetPID) {
            applyReversedPassthrough(
                to: event,
                horizontal: horizontal,
                vertical: vertical,
                settings: settings
            )
            return false
        }

        let smoothX = settings.smoothHorizontal && input.x != 0
        let smoothY = settings.smoothVertical && input.y != 0
        guard smoothX || smoothY else {
            applyReversedPassthrough(
                to: event,
                horizontal: horizontal,
                vertical: vertical,
                settings: settings
            )
            return false
        }
        guard let captured = makeSyntheticTemplate(from: event) else {
            applyReversedPassthrough(
                to: event,
                horizontal: horizontal,
                vertical: vertical,
                settings: settings
            )
            return false
        }
        cancelIdleDisplayStop()
        guard displayDriver.start(), displayDriver.hasDeliveredFrame else {
            resetSession()
            logPhysicalEvent(
                event,
                source: source,
                targetPID: targetPID,
                disposition: "display-not-ready-pass"
            )
            applyReversedPassthrough(
                to: event,
                horizontal: horizontal,
                vertical: vertical,
                settings: settings
            )
            return false
        }

        let smoothedInput = ScrollVector(x: smoothX ? input.x : 0, y: smoothY ? input.y : 0)
        let timestamp = environment.now()
        let accepted = withState { state -> Bool in
            let previousTargetPID = state.session.currentTargetPID
            let changesTarget = state.session.isActive
                && previousTargetPID > 1
                && targetPID > 1
                && previousTargetPID != Int32(targetPID)
            guard state.lifecycle == .running,
                  let generation = state.session.ingest(
                    smoothedInput,
                    targetPID: Int32(targetPID),
                    at: timestamp
                  ) else {
                return false
            }
            if changesTarget {
                state.pendingLineDelta.clear()
            }
            if smoothX {
                state.pendingLineDelta.horizontal = Self.accumulating(
                    state.pendingLineDelta.horizontal,
                    horizontal.lineDelta
                )
            }
            if smoothY {
                state.pendingLineDelta.vertical = Self.accumulating(
                    state.pendingLineDelta.vertical,
                    vertical.lineDelta
                )
            }
            state.template = captured
            state.templateGeneration = generation
            return true
        }
        guard accepted else {
            resetSession()
            return false
        }

        let needsPassthrough = (input.x != 0 && !smoothX)
            || (input.y != 0 && !smoothY)
            || !depth.isZero
        if needsPassthrough {
            if smoothX {
                write(.zero, to: event, axis: .horizontal)
            } else if settings.reverseHorizontal, input.x != 0 {
                write(horizontal, to: event, axis: .horizontal)
            }
            if smoothY {
                write(.zero, to: event, axis: .vertical)
            } else if settings.reverseVertical, input.y != 0 {
                write(vertical, to: event, axis: .vertical)
            }
            logPhysicalEvent(
                event,
                source: source,
                targetPID: targetPID,
                disposition: "mixed-axis-pass"
            )
            return false
        }
        logPhysicalEvent(event, source: source, targetPID: targetPID, disposition: "consume")
        return true
    }

    private func renderFrame(at timestamp: TimeInterval) {
        operationLock.lock()
        defer { operationLock.unlock() }
        struct Package {
            var event: CGEvent
            var plan: SmoothScrollSession.FramePlan
            var completesSession: Bool
        }

        var shouldStop = false
        let package: Package? = withState { state in
            guard state.lifecycle == .running else { return nil }
            switch state.session.prepareFrame(at: timestamp) {
            case .idle:
                shouldStop = !state.session.isActive
                if shouldStop {
                    clearSessionState(&state)
                }
                return nil
            case .expired:
                state.template = nil
                state.templateGeneration = 0
                state.pendingLineDelta.clear()
                shouldStop = true
                return nil
            case let .frame(plan):
                guard state.templateGeneration == plan.generation,
                      let event = state.template else {
                    clearSessionState(&state)
                    shouldStop = true
                    return nil
                }
                configureSyntheticEvent(
                    event,
                    frame: plan.frame,
                    lineDelta: state.pendingLineDelta
                )
                state.pendingLineDelta.clear()
                return Package(
                    event: event,
                    plan: plan,
                    completesSession: !state.session.isActive
                )
            }
        }
        guard let package else {
            if shouldStop { requestDisplayStopIfIdle() }
            return
        }

        // `operationLock` serializes frame callbacks and session mutations. The event is committed
        // above while holding the state lock, but the injected poster stays outside that lock so a
        // synchronous observer can safely call apply() or shutdown().
        environment.post(package.event, pid_t(package.plan.targetPID))
        logSyntheticFrame(package.event, targetPID: pid_t(package.plan.targetPID))
        if package.completesSession {
            withState { state in
                guard state.lifecycle == .running,
                      state.session.isCurrent(generation: package.plan.generation),
                      !state.session.isActive else {
                    return
                }
                clearSessionState(&state)
            }
            requestDisplayStopIfIdle()
        }
    }

    private func requestDisplayStopIfIdle() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.operationLock.lock()
            defer { self.operationLock.unlock() }
            guard self.withState({ $0.lifecycle == .running && !$0.session.isActive }),
                  self.idleDisplayStopTask == nil else {
                return
            }
            self.idleDisplayStopTask = self.environment.scheduler.schedule(
                after: 0.15,
                repeating: nil
            ) { [weak self] in
                guard let self else { return }
                self.operationLock.lock()
                defer { self.operationLock.unlock() }
                self.idleDisplayStopTask = nil
                guard self.withState({ $0.lifecycle == .running && !$0.session.isActive }) else {
                    return
                }
                self.displayDriver.stop()
            }
        }
    }

    private func cancelIdleDisplayStop() {
        idleDisplayStopTask?.cancel()
        idleDisplayStopTask = nil
    }

    private func resetSession() {
        withState { state in
            clearSessionState(&state)
        }
    }

    private func clearSessionState(_ state: inout State) {
        state.session.reset()
        state.template = nil
        state.templateGeneration = 0
        state.pendingLineDelta.clear()
    }

    private func displayDriverBecameUnavailable() {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard withState({ $0.lifecycle != .shutdown }) else { return }
        resetSession()
    }

    private func scheduleDisplayRebuild() {
        precondition(Thread.isMainThread)
        guard withState({ $0.lifecycle == .running && $0.settings.enabled }) else { return }
        cancelIdleDisplayStop()
        screenRebuildTask?.cancel()
        screenRebuildTask = environment.scheduler.schedule(after: 0.5, repeating: nil) { [weak self] in
            guard let self else { return }
            self.operationLock.lock()
            defer { self.operationLock.unlock() }
            guard self.withState({ $0.lifecycle == .running && $0.settings.enabled }) else { return }
            self.screenRebuildTask = nil
            self.resetSession()
            _ = self.displayDriver.recreate(force: true)
        }
    }

    private func configureSyntheticEvent(
        _ event: CGEvent,
        frame: SmoothScrollFrame,
        lineDelta: PendingLineDelta
    ) {
        let scrollPhase: Double
        let momentumPhase: Double
        switch frame.phase {
        case .began: (scrollPhase, momentumPhase) = (1, 0)
        case .changed: (scrollPhase, momentumPhase) = (2, 0)
        case .trackingEnded: (scrollPhase, momentumPhase) = (4, 0)
        case .momentumBegan: (scrollPhase, momentumPhase) = (0, 1)
        case .momentumChanged: (scrollPhase, momentumPhase) = (0, 2)
        case .ended: (scrollPhase, momentumPhase) = (0, 3)
        }
        event.setIntegerValueField(.eventSourceUserData, value: smoothScrollSyntheticMarker)
        event.setDoubleValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventScrollCount, value: 0)
        writeSynthetic(
            frame.delta.y,
            lineDelta: lineDelta.vertical,
            to: event,
            axis: .vertical
        )
        writeSynthetic(
            frame.delta.x,
            lineDelta: lineDelta.horizontal,
            to: event,
            axis: .horizontal
        )
        write(.zero, to: event, axis: .depth)
    }

    private func applyReversedPassthrough(
        to event: CGEvent,
        horizontal: ScrollAxisSample,
        vertical: ScrollAxisSample,
        settings: ScrollSettings
    ) {
        if settings.reverseHorizontal, !horizontal.isZero {
            write(horizontal, to: event, axis: .horizontal)
        }
        if settings.reverseVertical, !vertical.isZero {
            write(vertical, to: event, axis: .vertical)
        }
    }

    private func writeSynthetic(
        _ value: Double,
        lineDelta: Int64,
        to event: CGEvent,
        axis: EventAxis
    ) {
        write(
            ScrollAxisSample(lineDelta: lineDelta, pointDelta: value, fixedPointDelta: value),
            to: event,
            axis: axis
        )
    }

    /// A copied line-unit wheel event remains line-unit even after its point fields are changed.
    /// Some applications therefore ignore point-only synthetic output. Normalize each physical
    /// input to one reusable pixel-unit template while preserving routing-relevant metadata.
    private func makeSyntheticTemplate(from event: CGEvent) -> CGEvent? {
        guard let template = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 3,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ) else {
            return nil
        }
        template.flags = event.flags
        template.location = event.location
        template.timestamp = event.timestamp
        template.setIntegerValueField(
            .eventTargetUnixProcessID,
            value: event.getIntegerValueField(.eventTargetUnixProcessID)
        )
        return template
    }

    private enum EventAxis {
        case vertical
        case horizontal
        case depth
    }

    private func axisSample(_ event: CGEvent, axis: EventAxis) -> ScrollAxisSample {
        let fields = fields(for: axis)
        return ScrollAxisSample(
            lineDelta: event.getIntegerValueField(fields.line),
            pointDelta: event.getDoubleValueField(fields.point),
            fixedPointDelta: event.getDoubleValueField(fields.fixed)
        )
    }

    private func write(_ sample: ScrollAxisSample, to event: CGEvent, axis: EventAxis) {
        let fields = fields(for: axis)
        event.setIntegerValueField(fields.line, value: sample.lineDelta)
        event.setDoubleValueField(fields.point, value: sample.pointDelta)
        event.setDoubleValueField(fields.fixed, value: sample.fixedPointDelta)
    }

    private func fields(
        for axis: EventAxis
    ) -> (line: CGEventField, point: CGEventField, fixed: CGEventField) {
        switch axis {
        case .vertical:
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1)
        case .horizontal:
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2)
        case .depth:
            (.scrollWheelEventDeltaAxis3, .scrollWheelEventPointDeltaAxis3, .scrollWheelEventFixedPtDeltaAxis3)
        }
    }

    private static func sanitized(_ settings: ScrollSettings) -> ScrollSettings {
        ScrollSettings(
            enabled: settings.enabled,
            preset: settings.preset,
            smoothVertical: settings.smoothVertical,
            smoothHorizontal: settings.smoothHorizontal,
            reverseVertical: settings.reverseVertical,
            reverseHorizontal: settings.reverseHorizontal,
            excludeTrackpad: settings.excludeTrackpad,
            tuning: settings.tuning
        )
    }

    private static func accumulating(_ current: Int64, _ next: Int64) -> Int64 {
        let (result, overflow) = current.addingReportingOverflow(next)
        guard overflow else { return result }
        return next >= 0 ? .max : .min
    }

    #if DEBUG
    private func logPhysicalEvent(
        _ event: CGEvent,
        source: ScrollEventSource,
        targetPID: pid_t,
        disposition: String
    ) {
        guard diagnosticInputCount < 80 else { return }
        diagnosticInputCount &+= 1
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let rawTargetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let vertical = axisSample(event, axis: .vertical)
        let horizontal = axisSample(event, axis: .horizontal)
        let sourceName = String(describing: source)
        let targetBundle = targetPID > 1
            ? NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier ?? "unknown"
            : "session"
        Self.diagnosticLogger.notice(
            "input=\(self.diagnosticInputCount) disposition=\(disposition, privacy: .public) source=\(sourceName, privacy: .public) sourcePID=\(sourcePID) rawTargetPID=\(rawTargetPID) resolvedTargetPID=\(targetPID) targetBundle=\(targetBundle, privacy: .public) verticalLine=\(vertical.lineDelta) verticalPoint=\(vertical.pointDelta) verticalFixed=\(vertical.fixedPointDelta) horizontalLine=\(horizontal.lineDelta) horizontalPoint=\(horizontal.pointDelta) horizontalFixed=\(horizontal.fixedPointDelta) continuous=\(event.getDoubleValueField(.scrollWheelEventIsContinuous)) scrollCount=\(event.getDoubleValueField(.scrollWheelEventScrollCount)) scrollPhase=\(event.getDoubleValueField(.scrollWheelEventScrollPhase)) momentumPhase=\(event.getDoubleValueField(.scrollWheelEventMomentumPhase))"
        )
    }

    private func logSyntheticFrame(_ event: CGEvent, targetPID: pid_t) {
        guard diagnosticFrameCount < 120 else { return }
        diagnosticFrameCount &+= 1
        let vertical = axisSample(event, axis: .vertical)
        let horizontal = axisSample(event, axis: .horizontal)
        let route: String
        if #available(macOS 26.0, *) {
            route = "session"
        } else {
            route = targetPID > 1 ? "pid" : "session"
        }
        Self.diagnosticLogger.notice(
            "frame=\(self.diagnosticFrameCount) route=\(route, privacy: .public) targetPID=\(targetPID) verticalLine=\(vertical.lineDelta) verticalPoint=\(vertical.pointDelta) verticalFixed=\(vertical.fixedPointDelta) horizontalLine=\(horizontal.lineDelta) horizontalPoint=\(horizontal.pointDelta) horizontalFixed=\(horizontal.fixedPointDelta) scrollPhase=\(event.getDoubleValueField(.scrollWheelEventScrollPhase)) momentumPhase=\(event.getDoubleValueField(.scrollWheelEventMomentumPhase))"
        )
    }
    #else
    private func logPhysicalEvent(
        _ event: CGEvent,
        source: ScrollEventSource,
        targetPID: pid_t,
        disposition: String
    ) {}

    private func logSyntheticFrame(_ event: CGEvent, targetPID: pid_t) {}
    #endif

    @discardableResult
    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

struct ScrollEventSourceIdentityClassifier {
    private static let remoteIdentityFragments = [
        "anydesk",
        "microsoft.rdc",
        "parsec",
        "rustdesk",
        "teamviewer",
        "uuremote",
        "vncviewer",
    ]

    private static let systemRemoteProcessFragments = [
        "ardagent",
        "screensharingagent",
        "screensharingd",
    ]

    static func classify(bundleIdentifier: String?, executablePath: String) -> ScrollEventSource {
        let normalizedBundleIdentifier = bundleIdentifier?.lowercased() ?? ""
        if normalizedBundleIdentifier == "com.logitech.manager.daemon" {
            return .logitechOptions
        }

        let normalizedExecutablePath = executablePath.lowercased()
        if remoteIdentityFragments.contains(where: {
            normalizedBundleIdentifier.contains($0) || normalizedExecutablePath.contains($0)
        }) || systemRemoteProcessFragments.contains(where: normalizedExecutablePath.contains) {
            return .remoteDesktop
        }
        return .local
    }
}

private final class ScrollEventSourceResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedPID: pid_t = 0
    private var cachedSource = ScrollEventSource.local
    private var cachedApplication: NSRunningApplication?

    func classify(_ event: CGEvent) -> ScrollEventSource {
        let sourcePID = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        guard sourcePID > 1 else { return .local }
        if let cached = lock.withLock({ () -> ScrollEventSource? in
            guard sourcePID == cachedPID,
                  let cachedApplication,
                  !cachedApplication.isTerminated else {
                return nil
            }
            return cachedSource
        }) {
            return cached
        }

        let application = NSRunningApplication(processIdentifier: sourcePID)
        let bundleIdentifier = application?.bundleIdentifier
        let executablePath = application?.executableURL?.path ?? ""
        let source = ScrollEventSourceIdentityClassifier.classify(
            bundleIdentifier: bundleIdentifier,
            executablePath: executablePath
        )
        lock.withLock {
            cachedPID = sourcePID
            cachedSource = source
            cachedApplication = application
        }
        return source
    }
}

private final class DispatchSmoothScrollTask: SmoothScrollScheduledTask, @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceTimer?

    init(
        queue: DispatchQueue,
        delay: TimeInterval,
        interval: TimeInterval?,
        action: @escaping @Sendable () -> Void
    ) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        if let interval {
            source.schedule(
                deadline: .now() + delay,
                repeating: interval,
                leeway: .milliseconds(100)
            )
        } else {
            source.schedule(deadline: .now() + delay, leeway: .milliseconds(50))
        }
        source.setEventHandler(handler: action)
        self.source = source
        source.resume()
    }

    deinit {
        cancel()
    }

    func cancel() {
        let source = lock.withLock { () -> DispatchSourceTimer? in
            let source = self.source
            self.source = nil
            return source
        }
        source?.cancel()
    }
}

private struct DispatchSmoothScrollScheduler: SmoothScrollScheduling {
    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        _ action: @escaping @Sendable () -> Void
    ) -> any SmoothScrollScheduledTask {
        DispatchSmoothScrollTask(
            queue: .main,
            delay: delay,
            interval: interval,
            action: action
        )
    }
}

private func smoothScrollEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo,
          let driver = CGScrollEventTapRegistry.shared.resolve(userInfo) else {
        return Unmanaged.passUnretained(event)
    }
    return driver.handle(type: type, event: event) == .consume
        ? nil
        : Unmanaged.passUnretained(event)
}

private final class CGScrollEventTapDriver: ScrollEventTapDriving, @unchecked Sendable {
    private let handler: @Sendable (ScrollTapInput) -> ScrollTapDisposition
    private let token: UInt
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var invalidated = false

    init(handler: @escaping @Sendable (ScrollTapInput) -> ScrollTapDisposition) {
        self.handler = handler
        token = CGScrollEventTapRegistry.shared.reserveToken()
        CGScrollEventTapRegistry.shared.attach(self, token: token)
    }

    deinit {
        invalidate()
    }

    var isInstalled: Bool {
        lock.withLock { eventTap != nil && runLoopSource != nil && !invalidated }
    }

    var isEnabled: Bool {
        lock.withLock {
            guard !invalidated, let eventTap else { return false }
            return CGEvent.tapIsEnabled(tap: eventTap)
        }
    }

    func install() -> Bool {
        precondition(Thread.isMainThread)
        return lock.withLock {
            guard !invalidated else { return false }
            if let eventTap, runLoopSource != nil {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                return CGEvent.tapIsEnabled(tap: eventTap)
            }
            guard let context = UnsafeMutableRawPointer(bitPattern: token) else { return false }
            let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
                | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: smoothScrollEventTapCallback,
                userInfo: context
            ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                return false
            }
            eventTap = tap
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return CGEvent.tapIsEnabled(tap: tap)
        }
    }

    func setEnabled(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        lock.withLock {
            guard !invalidated, let eventTap else { return }
            CGEvent.tapEnable(tap: eventTap, enable: enabled)
        }
    }

    func remove() {
        let resources = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            let resources = (eventTap, runLoopSource)
            eventTap = nil
            runLoopSource = nil
            return resources
        }
        tearDown(tap: resources.0, source: resources.1)
    }

    func invalidate() {
        let resources: (CFMachPort?, CFRunLoopSource?)? = lock.withLock {
            guard !invalidated else { return nil }
            invalidated = true
            let resources = (eventTap, runLoopSource)
            eventTap = nil
            runLoopSource = nil
            return resources
        }
        guard let resources else { return }
        CGScrollEventTapRegistry.shared.unregister(token)
        tearDown(tap: resources.0, source: resources.1)
    }

    func handle(type: CGEventType, event: CGEvent) -> ScrollTapDisposition {
        guard lock.withLock({ !invalidated && eventTap != nil && runLoopSource != nil }) else {
            return .passThrough
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return handler(.disabled)
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            return handler(.cancelMotion)
        }
        guard type == .scrollWheel else { return .passThrough }
        return handler(.scroll(event))
    }

    private func tearDown(tap: CFMachPort?, source: CFRunLoopSource?) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source,
           CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}

private final class CGScrollEventTapRegistry: @unchecked Sendable {
    private final class Entry {
        weak var driver: CGScrollEventTapDriver?
        init(_ driver: CGScrollEventTapDriver) { self.driver = driver }
    }

    static let shared = CGScrollEventTapRegistry()
    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var entries: [UInt: Entry] = [:]

    func reserveToken() -> UInt {
        lock.withLock {
            repeat {
                nextToken &+= 1
                if nextToken == 0 { nextToken = 1 }
            } while entries[nextToken] != nil
            return nextToken
        }
    }

    func attach(_ driver: CGScrollEventTapDriver, token: UInt) {
        lock.withLock { entries[token] = Entry(driver) }
    }

    func resolve(_ context: UnsafeMutableRawPointer) -> CGScrollEventTapDriver? {
        let token = UInt(bitPattern: context)
        return lock.withLock { entries[token]?.driver }
    }

    func unregister(_ token: UInt) {
        lock.withLock { entries[token] = nil }
    }
}

private final class ScrollDisplayDriver: ScrollFrameDriving, @unchecked Sendable {
    private let frameHandler: @Sendable (TimeInterval) -> Void
    private let unavailableHandler: @Sendable () -> Void
    private let scheduler: any SmoothScrollScheduling
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var displayLink: CVDisplayLink?
    private var running = false
    private var deliveredFrame = false
    private var lastCallbackTime: TimeInterval = 0
    private var healthTask: (any SmoothScrollScheduledTask)?
    private var callbackToken: UInt?
    private var lastRebuildTime: TimeInterval = 0
    private var invalidated = false

    private static let rebuildCooldown: TimeInterval = 1.5

    init(
        frameHandler: @escaping @Sendable (TimeInterval) -> Void,
        unavailableHandler: @escaping @Sendable () -> Void,
        scheduler: any SmoothScrollScheduling,
        now: @escaping @Sendable () -> TimeInterval
    ) {
        self.frameHandler = frameHandler
        self.unavailableHandler = unavailableHandler
        self.scheduler = scheduler
        self.now = now
    }

    deinit {
        invalidate()
    }

    var hasDeliveredFrame: Bool {
        lock.withLock { deliveredFrame }
    }

    func prepare() -> Bool {
        precondition(Thread.isMainThread)
        if lock.withLock({ !invalidated && displayLink != nil }) { return true }
        guard lock.withLock({ !invalidated }) else { return false }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
            return false
        }
        let token = ScrollDisplayCallbackRegistry.shared.register(self)
        guard let context = UnsafeMutableRawPointer(bitPattern: token) else {
            ScrollDisplayCallbackRegistry.shared.unregister(token)
            return false
        }
        let result = CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
            guard let context,
                  let driver = ScrollDisplayCallbackRegistry.shared.resolve(context) else {
                return kCVReturnSuccess
            }
            driver.didRenderFrame()
            return kCVReturnSuccess
        }, context)
        guard result == kCVReturnSuccess else {
            ScrollDisplayCallbackRegistry.shared.unregister(token)
            return false
        }
        let accepted = lock.withLock { () -> Bool in
            guard !invalidated, displayLink == nil else { return false }
            displayLink = link
            callbackToken = token
            deliveredFrame = false
            return true
        }
        guard accepted else {
            ScrollDisplayCallbackRegistry.shared.unregister(token)
            return lock.withLock { !invalidated && displayLink != nil }
        }
        return true
    }

    func start() -> Bool {
        precondition(Thread.isMainThread)
        guard prepare() else { return false }
        let package: (wasRunning: Bool, link: CVDisplayLink?, token: UInt?) = lock.withLock {
            guard !invalidated, let displayLink, let callbackToken else { return (false, nil, nil) }
            if running { return (true, displayLink, callbackToken) }
            running = true
            // Readiness belongs to this particular CVDisplayLink run. A callback delivered by an
            // earlier run cannot prove that a restarted link will deliver synthetic scroll frames.
            deliveredFrame = false
            lastCallbackTime = now()
            return (false, displayLink, callbackToken)
        }
        guard let link = package.link, let token = package.token else { return false }
        if package.wasRunning { return true }

        let result = CVDisplayLinkStart(link)
        let isCurrent = lock.withLock { () -> Bool in
            guard !invalidated, callbackToken == token else {
                running = false
                return false
            }
            if result != kCVReturnSuccess { running = false }
            return true
        }
        guard isCurrent else {
            if result == kCVReturnSuccess, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
            return false
        }
        guard result == kCVReturnSuccess else {
            _ = recreate(force: false)
            return false
        }
        startHealthCheck()
        return true
    }

    func stop() {
        let resources = lock.withLock { () -> (CVDisplayLink?, (any SmoothScrollScheduledTask)?) in
            running = false
            deliveredFrame = false
            let task = healthTask
            healthTask = nil
            return (displayLink, task)
        }
        resources.1?.cancel()
        if let link = resources.0, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
    }

    @discardableResult
    func recreate(force: Bool) -> Bool {
        precondition(Thread.isMainThread)
        let timestamp = now()
        guard lock.withLock({ () -> Bool in
            guard !invalidated,
                  force || timestamp - lastRebuildTime >= Self.rebuildCooldown else {
                return false
            }
            lastRebuildTime = timestamp
            return true
        }) else { return false }
        stop()
        detachDisplayLink()
        return prepare()
    }

    func invalidate() {
        let resources: (CVDisplayLink?, UInt?, (any SmoothScrollScheduledTask)?)? = lock.withLock {
            guard !invalidated else { return nil }
            invalidated = true
            running = false
            deliveredFrame = false
            let resources = (displayLink, callbackToken, healthTask)
            displayLink = nil
            callbackToken = nil
            healthTask = nil
            return resources
        }
        guard let resources else { return }
        resources.2?.cancel()
        if let link = resources.0, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
        if let token = resources.1 { ScrollDisplayCallbackRegistry.shared.unregister(token) }
    }

    private func didRenderFrame() {
        let timestamp = now()
        let shouldRender = lock.withLock { () -> Bool in
            guard running, !invalidated else { return false }
            lastCallbackTime = timestamp
            deliveredFrame = true
            return true
        }
        guard shouldRender else { return }
        frameHandler(timestamp)
    }

    private func detachDisplayLink() {
        let token = lock.withLock { () -> UInt? in
            let token = callbackToken
            callbackToken = nil
            displayLink = nil
            deliveredFrame = false
            return token
        }
        if let token { ScrollDisplayCallbackRegistry.shared.unregister(token) }
    }

    private func startHealthCheck() {
        let task = scheduler.schedule(after: 0.75, repeating: 0.75) { [weak self] in
            guard let self else { return }
            let snapshot = self.lock.withLock { (self.running && !self.invalidated, self.lastCallbackTime) }
            guard snapshot.0, self.now() - snapshot.1 > 1.5 else { return }
            let rebuilt = self.recreate(force: false)
            self.unavailableHandler()
            if !rebuilt {
                NSLog("[scroll] display clock recovery deferred or unavailable")
            }
        }
        let previous: (any SmoothScrollScheduledTask)? = lock.withLock {
            guard !invalidated, running else { return nil }
            let previous = healthTask
            healthTask = task
            return previous
        }
        if lock.withLock({ invalidated || !running }) {
            task.cancel()
        }
        previous?.cancel()
    }
}

private final class ScrollDisplayCallbackRegistry: @unchecked Sendable {
    private final class Entry {
        weak var driver: ScrollDisplayDriver?
        init(_ driver: ScrollDisplayDriver) { self.driver = driver }
    }

    static let shared = ScrollDisplayCallbackRegistry()
    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var entries: [UInt: Entry] = [:]

    func register(_ driver: ScrollDisplayDriver) -> UInt {
        lock.withLock {
            repeat {
                nextToken &+= 1
                if nextToken == 0 { nextToken = 1 }
            } while entries[nextToken] != nil
            entries[nextToken] = Entry(driver)
            return nextToken
        }
    }

    func resolve(_ context: UnsafeMutableRawPointer) -> ScrollDisplayDriver? {
        let token = UInt(bitPattern: context)
        return lock.withLock { entries[token]?.driver }
    }

    func unregister(_ token: UInt) {
        lock.withLock { entries[token] = nil }
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
