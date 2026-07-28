import Foundation

public enum ScrollPreset: String, Codable, CaseIterable, Sendable {
    case precise
    case balanced
    case fluid
    case glide
    case custom

    public var displayName: String {
        switch self {
        case .precise: "Precise"
        case .balanced: "Balanced"
        case .fluid: "Fluid"
        case .glide: "Glide"
        case .custom: "Custom"
        }
    }

    public var summary: String {
        switch self {
        case .precise: "Short, controlled movement for documents and code."
        case .balanced: "A responsive everyday curve with a restrained tail."
        case .fluid: "Softer acceleration and a longer, continuous-feeling tail."
        case .glide: "Fast travel with the strongest momentum for long pages."
        case .custom: "Uses the individual values below."
        }
    }

    public var tuning: ScrollTuning {
        switch self {
        case .precise:
            ScrollTuning(step: 16, speed: 1.15, duration: 0.22, acceleration: 0.10, deadZone: 0.10)
        case .balanced:
            ScrollTuning(step: 24, speed: 1.55, duration: 0.36, acceleration: 0.28, deadZone: 0.10)
        case .fluid:
            ScrollTuning(step: 30, speed: 1.85, duration: 0.52, acceleration: 0.42, deadZone: 0.08)
        case .glide:
            ScrollTuning(step: 36, speed: 2.20, duration: 0.78, acceleration: 0.60, deadZone: 0.08)
        case .custom:
            ScrollTuning(step: 24, speed: 1.55, duration: 0.36, acceleration: 0.28, deadZone: 0.10)
        }
    }
}

public struct ScrollTuning: Equatable, Codable, Sendable {
    public var step: Double
    public var speed: Double
    public var duration: Double
    public var acceleration: Double
    public var deadZone: Double

    public init(step: Double, speed: Double, duration: Double, acceleration: Double, deadZone: Double) {
        self.step = step
        self.speed = speed
        self.duration = duration
        self.acceleration = acceleration
        self.deadZone = deadZone
    }

    public var sanitized: ScrollTuning {
        ScrollTuning(
            step: step.clamped(to: 1 ... 120),
            speed: speed.clamped(to: 0.20 ... 6),
            duration: duration.clamped(to: 0.08 ... 1.50),
            acceleration: acceleration.clamped(to: 0 ... 1),
            deadZone: deadZone.clamped(to: 0.01 ... 2)
        )
    }
}

public struct ScrollSettings: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var preset: ScrollPreset
    public var smoothVertical: Bool
    public var smoothHorizontal: Bool
    public var reverseVertical: Bool
    public var reverseHorizontal: Bool
    public var excludeTrackpad: Bool
    public var tuning: ScrollTuning

    public init(
        enabled: Bool = true,
        preset: ScrollPreset = .balanced,
        smoothVertical: Bool = true,
        smoothHorizontal: Bool = true,
        reverseVertical: Bool = false,
        reverseHorizontal: Bool = false,
        excludeTrackpad: Bool = true,
        tuning: ScrollTuning? = nil
    ) {
        self.enabled = enabled
        self.preset = preset
        self.smoothVertical = smoothVertical
        self.smoothHorizontal = smoothHorizontal
        self.reverseVertical = reverseVertical
        self.reverseHorizontal = reverseHorizontal
        self.excludeTrackpad = excludeTrackpad
        self.tuning = (tuning ?? preset.tuning).sanitized
    }

    public static let `default` = ScrollSettings()

    public mutating func applyPreset(_ preset: ScrollPreset) {
        self.preset = preset
        if preset != .custom {
            tuning = preset.tuning
        }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case preset
        case smoothVertical
        case smoothHorizontal
        case reverseVertical
        case reverseHorizontal
        case excludeTrackpad
        case tuning
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        preset = try container.decodeIfPresent(ScrollPreset.self, forKey: .preset) ?? .balanced
        smoothVertical = try container.decodeIfPresent(Bool.self, forKey: .smoothVertical) ?? true
        smoothHorizontal = try container.decodeIfPresent(Bool.self, forKey: .smoothHorizontal) ?? true
        reverseVertical = try container.decodeIfPresent(Bool.self, forKey: .reverseVertical) ?? false
        reverseHorizontal = try container.decodeIfPresent(Bool.self, forKey: .reverseHorizontal) ?? false
        excludeTrackpad = try container.decodeIfPresent(Bool.self, forKey: .excludeTrackpad) ?? true
        tuning = try container.decodeIfPresent(ScrollTuning.self, forKey: .tuning)?.sanitized ?? preset.tuning
    }
}

public struct ScrollVector: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    public static let zero = ScrollVector()
    public var magnitude: Double { max(abs(x), abs(y)) }
}

/// The three representations carried by one `CGEvent` scroll axis.
///
/// Keeping them separate is important for passthrough events: a mechanical wheel can carry a
/// one-line delta alongside a much larger point delta. Reconstructing every field from the point
/// value makes applications that consume the line field scroll many times farther than intended.
public struct ScrollAxisSample: Equatable, Sendable {
    public var lineDelta: Int64
    public var pointDelta: Double
    public var fixedPointDelta: Double

    public init(lineDelta: Int64, pointDelta: Double, fixedPointDelta: Double) {
        self.lineDelta = lineDelta
        self.pointDelta = pointDelta
        self.fixedPointDelta = fixedPointDelta
    }

    public static let zero = ScrollAxisSample(lineDelta: 0, pointDelta: 0, fixedPointDelta: 0)

    public var usableDelta: Double {
        if pointDelta.isFinite, pointDelta != 0 { return pointDelta }
        if fixedPointDelta.isFinite, fixedPointDelta != 0 { return fixedPointDelta }
        return Double(lineDelta)
    }

    public var isZero: Bool {
        lineDelta == 0 && pointDelta == 0 && fixedPointDelta == 0
    }

    public var reversed: ScrollAxisSample {
        ScrollAxisSample(
            lineDelta: lineDelta == .min ? .max : -lineDelta,
            pointDelta: -pointDelta,
            fixedPointDelta: -fixedPointDelta
        )
    }
}

public struct SmoothScrollFrame: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case began
        case changed
        case trackingEnded
        case momentumBegan
        case momentumChanged
        case ended

        /// Semantic alias retained alongside the historical `ended` spelling.
        public static let momentumEnded: Self = .ended
    }

    public var delta: ScrollVector
    public var phase: Phase

    public init(delta: ScrollVector, phase: Phase) {
        self.delta = delta
        self.phase = phase
    }
}

/// Allocation-free smoothing state. The macOS event tap and display clock live in the app target;
/// this type only owns deterministic values so its behavior can be tested without permissions.
public struct SmoothScrollEngine: Sendable {
    private enum MotionState: Sendable {
        case idle
        case trackingNeedsBegin
        case tracking
        case momentumNeedsBegin
        case momentum
        case trackingInterruptionNeedsEnd
        case momentumInterruptionNeedsEnd
    }

    private var tuning: ScrollTuning
    private var remaining = ScrollVector.zero
    private var lastInputTime: TimeInterval?
    private var lastFrameTime: TimeInterval?
    private var burstStrength = 0.0
    private var motionState = MotionState.idle

    public private(set) var isActive = false

    public init(tuning: ScrollTuning) {
        self.tuning = tuning.sanitized
    }

    public mutating func update(tuning: ScrollTuning) {
        self.tuning = tuning.sanitized
    }

    @discardableResult
    public mutating func ingest(_ rawDelta: ScrollVector, at timestamp: TimeInterval) -> Bool {
        guard rawDelta.magnitude > 0 else { return false }

        let priorState = motionState
        var startsSeparatedGesture = false
        if let lastInputTime {
            let interval = max(0, timestamp - lastInputTime)
            if interval >= 0.45 {
                remaining = .zero
                lastFrameTime = nil
                burstStrength = 0
                startsSeparatedGesture = true
            } else {
                let decay = exp(-interval / 0.16)
                burstStrength = min(1, burstStrength * decay + 0.24)
            }
        } else {
            burstStrength = 0
        }

        let multiplier = 1 + tuning.acceleration * burstStrength * 2
        let delta = ScrollVector(
            x: normalized(rawDelta.x) * tuning.speed * multiplier,
            y: normalized(rawDelta.y) * tuning.speed * multiplier
        )

        // A direction change must not fight an old momentum tail.
        if delta.x * remaining.x < 0 { remaining.x = 0 }
        if delta.y * remaining.y < 0 { remaining.y = 0 }
        remaining.x += delta.x
        remaining.y += delta.y
        lastInputTime = timestamp
        if lastFrameTime == nil { lastFrameTime = timestamp - (1.0 / 60.0) }

        switch priorState {
        case .idle:
            motionState = .trackingNeedsBegin
        case .trackingNeedsBegin:
            break
        case .tracking:
            if startsSeparatedGesture {
                motionState = .trackingInterruptionNeedsEnd
            }
        case .momentumNeedsBegin:
            // Tracking has already ended, but momentum has not been announced. A new input
            // therefore starts a fresh tracking sequence without inventing a momentum pair.
            motionState = .trackingNeedsBegin
        case .momentum:
            motionState = .momentumInterruptionNeedsEnd
        case .trackingInterruptionNeedsEnd, .momentumInterruptionNeedsEnd:
            // More input belongs to the already queued replacement tracking sequence.
            break
        }
        isActive = true
        return true
    }

    public mutating func nextFrame(at timestamp: TimeInterval) -> SmoothScrollFrame? {
        guard isActive else { return nil }

        switch motionState {
        case .trackingInterruptionNeedsEnd:
            motionState = .trackingNeedsBegin
            return SmoothScrollFrame(delta: .zero, phase: .trackingEnded)
        case .momentumInterruptionNeedsEnd:
            motionState = .trackingNeedsBegin
            return SmoothScrollFrame(delta: .zero, phase: .momentumEnded)
        case .idle:
            return nil
        case .trackingNeedsBegin, .tracking, .momentumNeedsBegin, .momentum:
            break
        }

        let previousFrameTime = lastFrameTime ?? timestamp - (1.0 / 60.0)
        let deltaTime = (timestamp - previousFrameTime).clamped(to: (1.0 / 240.0) ... (1.0 / 20.0))
        lastFrameTime = timestamp
        let timeSinceInput = timestamp - (lastInputTime ?? timestamp)
        let responseTime = max(0.018, tuning.duration / 4.8)
        let fraction = 1 - exp(-deltaTime / responseTime)

        var output = ScrollVector(
            x: remaining.x * fraction,
            y: remaining.y * fraction
        )
        output.x = minimumVisibleDelta(output.x, remaining: remaining.x)
        output.y = minimumVisibleDelta(output.y, remaining: remaining.y)
        remaining.x -= output.x
        remaining.y -= output.y

        let phase: SmoothScrollFrame.Phase
        switch motionState {
        case .trackingNeedsBegin:
            motionState = .tracking
            phase = .began
        case .tracking:
            if remaining.magnitude <= tuning.deadZone, timeSinceInput >= 0.08 {
                resetMotion()
                phase = .trackingEnded
            } else if timeSinceInput >= 0.12 {
                motionState = .momentumNeedsBegin
                phase = .trackingEnded
            } else {
                phase = .changed
            }
        case .momentumNeedsBegin:
            motionState = .momentum
            phase = .momentumBegan
        case .momentum:
            if remaining.magnitude <= tuning.deadZone {
                resetMotion()
                phase = .momentumEnded
            } else {
                phase = .momentumChanged
            }
        case .idle, .trackingInterruptionNeedsEnd, .momentumInterruptionNeedsEnd:
            preconditionFailure("boundary states must be handled before integrating a frame")
        }
        return SmoothScrollFrame(delta: output, phase: phase)
    }

    public mutating func reset() {
        resetMotion()
        lastInputTime = nil
        burstStrength = 0
    }

    private mutating func resetMotion() {
        remaining = .zero
        lastFrameTime = nil
        motionState = .idle
        isActive = false
    }

    private func normalized(_ value: Double) -> Double {
        guard value != 0 else { return 0 }
        return value.sign == .minus ? -max(abs(value), tuning.step) : max(abs(value), tuning.step)
    }

    private func minimumVisibleDelta(_ value: Double, remaining: Double) -> Double {
        guard remaining != 0 else { return 0 }
        let minimum = min(tuning.deadZone, abs(remaining))
        guard abs(value) < minimum else { return value }
        return remaining.sign == .minus ? -minimum : minimum
    }
}

/// Permission-independent session state shared by the macOS event-tap and display-clock adapters.
/// The session deliberately stores no `CGEvent`; the platform layer associates its event template
/// with the returned generation and validates that generation immediately before posting.
public struct SmoothScrollSession: Sendable {
    public struct FramePlan: Equatable, Sendable {
        public var generation: UInt64
        public var targetPID: Int32
        public var frame: SmoothScrollFrame

        public init(generation: UInt64, targetPID: Int32, frame: SmoothScrollFrame) {
            self.generation = generation
            self.targetPID = targetPID
            self.frame = frame
        }
    }

    public enum FramePreparation: Equatable, Sendable {
        case frame(FramePlan)
        case idle
        case expired
    }

    private var engine: SmoothScrollEngine
    private var tuning: ScrollTuning
    private var capturedAt: TimeInterval?
    private var targetPID: Int32 = 0
    private var generation: UInt64 = 0

    public init(tuning: ScrollTuning) {
        let sanitized = tuning.sanitized
        self.tuning = sanitized
        engine = SmoothScrollEngine(tuning: sanitized)
    }

    public var isActive: Bool { engine.isActive }
    public var currentGeneration: UInt64 { generation }
    public var currentTargetPID: Int32 { targetPID }

    public mutating func update(tuning: ScrollTuning) {
        let sanitized = tuning.sanitized
        self.tuning = sanitized
        engine.update(tuning: sanitized)
    }

    @discardableResult
    public mutating func ingest(
        _ delta: ScrollVector,
        targetPID requestedTargetPID: Int32,
        at timestamp: TimeInterval
    ) -> UInt64? {
        let inheritedTargetPID = engine.isActive ? targetPID : 0
        let fixedTargetPID = requestedTargetPID > 1 ? requestedTargetPID : inheritedTargetPID
        if engine.isActive,
           targetPID > 1,
           fixedTargetPID > 1,
           targetPID != fixedTargetPID {
            engine.reset()
        }
        guard engine.ingest(delta, at: timestamp) else { return nil }
        generation &+= 1
        targetPID = fixedTargetPID
        capturedAt = timestamp
        return generation
    }

    public mutating func prepareFrame(at timestamp: TimeInterval) -> FramePreparation {
        guard engine.isActive, let capturedAt else {
            clearRouting()
            return .idle
        }
        let timeToLive = max(2, tuning.duration + 1)
        guard timestamp - capturedAt <= timeToLive else {
            reset()
            return .expired
        }
        guard let frame = engine.nextFrame(at: timestamp) else { return .idle }
        let plan = FramePlan(generation: generation, targetPID: targetPID, frame: frame)
        if !engine.isActive {
            // Keep the generation valid long enough for the terminal frame to be posted, but
            // never let a later PID-less gesture inherit the route of an ended session.
            clearRouting()
        }
        return .frame(plan)
    }

    public func isCurrent(generation: UInt64) -> Bool {
        self.generation == generation
    }

    public mutating func reset() {
        engine.reset()
        clearRouting()
        generation &+= 1
    }

    private mutating func clearRouting() {
        capturedAt = nil
        targetPID = 0
    }
}

public struct ScrollInputCharacteristics: Equatable, Sendable {
    public var scrollPhase: Double
    public var momentumPhase: Double
    public var scrollCount: Double

    public init(scrollPhase: Double, momentumPhase: Double, scrollCount: Double = 0) {
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
        self.scrollCount = scrollCount
    }

    public var isTrackpadLike: Bool {
        scrollPhase != 0 || momentumPhase != 0 || scrollCount != 0
    }
}

/// Bounds event-tap recovery so a permission prompt or blocked callback cannot create a restart storm.
public struct EventTapRestartLimiter: Equatable, Sendable {
    public var window: TimeInterval
    public var limit: Int
    private var attempts: [TimeInterval] = []

    public init(window: TimeInterval = 60, limit: Int = 3) {
        self.window = window
        self.limit = limit
    }

    public mutating func shouldAllowRestart(at timestamp: TimeInterval) -> Bool {
        attempts.removeAll { timestamp - $0 >= window }
        guard attempts.count < limit else { return false }
        attempts.append(timestamp)
        return true
    }

    public mutating func reset() {
        attempts.removeAll(keepingCapacity: true)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
