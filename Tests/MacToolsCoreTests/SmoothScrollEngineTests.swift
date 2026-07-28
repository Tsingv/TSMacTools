import XCTest
import MacToolsCore

final class SmoothScrollEngineTests: XCTestCase {
    func testPresetAppliesDocumentedTuning() {
        var settings = ScrollSettings(preset: .precise)

        settings.applyPreset(.glide)

        XCTAssertEqual(settings.preset, .glide)
        XCTAssertEqual(settings.tuning, ScrollPreset.glide.tuning)
        XCTAssertGreaterThan(settings.tuning.duration, ScrollPreset.precise.tuning.duration)
        XCTAssertGreaterThan(settings.tuning.speed, ScrollPreset.precise.tuning.speed)
    }

    func testCustomTuningIsSanitizedWhenDecoded() throws {
        let data = Data(
            #"""
            {
              "enabled": true,
              "preset": "custom",
              "tuning": { "step": -5, "speed": 90, "duration": 0, "acceleration": 4, "deadZone": 0 }
            }
            """#.utf8
        )

        let settings = try JSONDecoder().decode(ScrollSettings.self, from: data)

        XCTAssertEqual(settings.tuning.step, 1)
        XCTAssertEqual(settings.tuning.speed, 6)
        XCTAssertEqual(settings.tuning.duration, 0.08)
        XCTAssertEqual(settings.tuning.acceleration, 1)
        XCTAssertEqual(settings.tuning.deadZone, 0.01)
    }

    func testSingleNotchConvergesAndEmitsTerminalFrame() {
        let tuning = ScrollTuning(step: 20, speed: 1, duration: 0.30, acceleration: 0, deadZone: 0.05)
        var engine = SmoothScrollEngine(tuning: tuning)
        XCTAssertTrue(engine.ingest(ScrollVector(y: 1), at: 0))

        var sum = 0.0
        var phases: [SmoothScrollFrame.Phase] = []
        for frameIndex in 1 ... 240 {
            guard let frame = engine.nextFrame(at: Double(frameIndex) / 120) else { break }
            sum += frame.delta.y
            phases.append(frame.phase)
            if frame.phase == .ended { break }
        }

        XCTAssertEqual(sum, 20, accuracy: 0.06)
        XCTAssertEqual(phases.first, .began)
        XCTAssertEqual(phases.last, .ended)
        XCTAssertFalse(engine.isActive)
    }

    func testPhaseStateMachineEmitsEveryTrackingAndMomentumBoundaryInOrder() {
        let tuning = ScrollTuning(step: 20, speed: 1, duration: 0.60, acceleration: 0, deadZone: 0.01)
        var engine = SmoothScrollEngine(tuning: tuning)
        XCTAssertTrue(engine.ingest(ScrollVector(y: 1), at: 0))

        var phases: [SmoothScrollFrame.Phase] = []
        var cumulative = 0.0
        for frameIndex in 1 ... 600 {
            guard let frame = engine.nextFrame(at: Double(frameIndex) / 120) else { break }
            XCTAssertGreaterThanOrEqual(frame.delta.y, 0)
            let previous = cumulative
            cumulative += frame.delta.y
            XCTAssertGreaterThanOrEqual(cumulative, previous)
            phases.append(frame.phase)
            if frame.phase == .momentumEnded { break }
        }

        XCTAssertEqual(
            collapsed(phases),
            [.began, .changed, .trackingEnded, .momentumBegan, .momentumChanged, .momentumEnded]
        )
        XCTAssertEqual(cumulative, 20, accuracy: 0.02)
        XCTAssertFalse(engine.isActive)
    }

    func testNewInputEndsMomentumBeforeRestartingTrackingWithoutLosingDelta() throws {
        let tuning = ScrollTuning(step: 20, speed: 1, duration: 0.60, acceleration: 0, deadZone: 0.01)
        var engine = SmoothScrollEngine(tuning: tuning)
        XCTAssertTrue(engine.ingest(ScrollVector(y: 1), at: 0))

        var total = 0.0
        var timestamp = 0.0
        while timestamp < 1 {
            timestamp += 1.0 / 120.0
            let frame = try XCTUnwrap(engine.nextFrame(at: timestamp))
            total += frame.delta.y
            if frame.phase == .momentumChanged { break }
        }

        XCTAssertTrue(engine.ingest(ScrollVector(y: 1), at: timestamp + 0.001))
        timestamp += 1.0 / 120.0
        let momentumEnd = try XCTUnwrap(engine.nextFrame(at: timestamp))
        timestamp += 1.0 / 120.0
        let trackingBegin = try XCTUnwrap(engine.nextFrame(at: timestamp))
        total += momentumEnd.delta.y + trackingBegin.delta.y

        XCTAssertEqual(momentumEnd.phase, .momentumEnded)
        XCTAssertEqual(momentumEnd.delta, .zero, "a phase boundary must not consume queued input")
        XCTAssertEqual(trackingBegin.phase, .began)
        XCTAssertGreaterThan(trackingBegin.delta.y, 0)

        var restartedPhases = [momentumEnd.phase, trackingBegin.phase]
        for _ in 1 ... 600 {
            timestamp += 1.0 / 120.0
            guard let frame = engine.nextFrame(at: timestamp) else { break }
            total += frame.delta.y
            restartedPhases.append(frame.phase)
            if frame.phase == .momentumEnded { break }
        }

        XCTAssertEqual(
            collapsed(restartedPhases),
            [.momentumEnded, .began, .changed, .trackingEnded, .momentumBegan, .momentumChanged, .momentumEnded]
        )
        XCTAssertEqual(total, 40, accuracy: 0.03)
        XCTAssertFalse(engine.isActive)
    }

    func testDirectionChangeDropsOpposingTail() {
        let tuning = ScrollTuning(step: 20, speed: 1, duration: 0.70, acceleration: 0, deadZone: 0.05)
        var engine = SmoothScrollEngine(tuning: tuning)
        engine.ingest(ScrollVector(y: 1), at: 0)
        let first = engine.nextFrame(at: 1.0 / 120.0)
        XCTAssertGreaterThan(first?.delta.y ?? 0, 0)

        engine.ingest(ScrollVector(y: -1), at: 0.02)
        let reversed = engine.nextFrame(at: 0.03)

        XCTAssertLessThan(reversed?.delta.y ?? 0, 0)
    }

    func testAccelerationIsBoundedAcrossBurst() {
        let tuning = ScrollTuning(step: 10, speed: 1, duration: 0.30, acceleration: 1, deadZone: 0.01)
        var engine = SmoothScrollEngine(tuning: tuning)
        for index in 0 ..< 30 {
            engine.ingest(ScrollVector(y: 1), at: Double(index) * 0.03)
        }

        var sum = 0.0
        for frameIndex in 1 ... 600 {
            guard let frame = engine.nextFrame(at: 0.90 + Double(frameIndex) / 120) else { break }
            sum += frame.delta.y
            if frame.phase == .ended { break }
        }

        XCTAssertGreaterThan(sum, 300)
        XCTAssertLessThanOrEqual(sum, 900.1, "burst multiplier must stay at or below 3x")
    }

    func testSeparatedInputDoesNotReuseOldMomentum() {
        let tuning = ScrollTuning(step: 20, speed: 1, duration: 1, acceleration: 0, deadZone: 0.05)
        var engine = SmoothScrollEngine(tuning: tuning)
        engine.ingest(ScrollVector(y: 1), at: 0)
        _ = engine.nextFrame(at: 0.02)

        engine.ingest(ScrollVector(y: 1), at: 0.60)
        var newGestureSum = 0.0
        for index in 1 ... 600 {
            guard let frame = engine.nextFrame(at: 0.60 + Double(index) / 120) else { break }
            newGestureSum += frame.delta.y
            if frame.phase == .ended { break }
        }

        XCTAssertEqual(newGestureSum, 20, accuracy: 0.06)
    }

    func testSeparatedInputDoesNotReuseOldBurstAcceleration() {
        let tuning = ScrollTuning(step: 10, speed: 1, duration: 0.30, acceleration: 1, deadZone: 0.01)
        var engine = SmoothScrollEngine(tuning: tuning)
        for index in 0 ..< 12 {
            engine.ingest(ScrollVector(y: 1), at: Double(index) * 0.03)
        }

        engine.ingest(ScrollVector(y: 1), at: 1.0)
        var newGestureSum = 0.0
        for index in 1 ... 600 {
            guard let frame = engine.nextFrame(at: 1.0 + Double(index) / 120) else { break }
            newGestureSum += frame.delta.y
            if frame.phase == .ended { break }
        }

        XCTAssertEqual(newGestureSum, 10, accuracy: 0.02)
    }

    func testScrollAxisSampleKeepsRepresentationsIndependent() {
        let sample = ScrollAxisSample(lineDelta: 1, pointDelta: 28.5, fixedPointDelta: 2.25)

        XCTAssertEqual(sample.usableDelta, 28.5)
        XCTAssertEqual(
            sample.reversed,
            ScrollAxisSample(lineDelta: -1, pointDelta: -28.5, fixedPointDelta: -2.25)
        )
        XCTAssertEqual(ScrollAxisSample.zero.usableDelta, 0)
        XCTAssertTrue(ScrollAxisSample.zero.isZero)
    }

    func testScrollAxisSampleFallsBackWithoutReconstructingFields() {
        let fixed = ScrollAxisSample(lineDelta: 1, pointDelta: 0, fixedPointDelta: 3.5)
        let line = ScrollAxisSample(lineDelta: -1, pointDelta: 0, fixedPointDelta: 0)
        let malformed = ScrollAxisSample(lineDelta: 2, pointDelta: .nan, fixedPointDelta: .infinity)

        XCTAssertEqual(fixed.usableDelta, 3.5)
        XCTAssertEqual(line.usableDelta, -1)
        XCTAssertEqual(malformed.usableDelta, 2)
        XCTAssertEqual(fixed.lineDelta, 1, "choosing a usable value must not rewrite the line field")
    }

    func testTrackpadClassificationUsesPhasesNotDeltaSize() {
        XCTAssertTrue(ScrollInputCharacteristics(scrollPhase: 2, momentumPhase: 0).isTrackpadLike)
        XCTAssertTrue(ScrollInputCharacteristics(scrollPhase: 0, momentumPhase: 1).isTrackpadLike)
        XCTAssertTrue(ScrollInputCharacteristics(scrollPhase: 0, momentumPhase: 0, scrollCount: 1).isTrackpadLike)
        XCTAssertFalse(ScrollInputCharacteristics(scrollPhase: 0, momentumPhase: 0).isTrackpadLike)
    }

    func testEngineKeepsHorizontalAndVerticalMotionIndependent() {
        let tuning = ScrollTuning(step: 12, speed: 1, duration: 0.30, acceleration: 0, deadZone: 0.01)
        var engine = SmoothScrollEngine(tuning: tuning)
        engine.ingest(ScrollVector(x: 1), at: 0)

        var sum = ScrollVector.zero
        for index in 1 ... 600 {
            guard let frame = engine.nextFrame(at: Double(index) / 120) else { break }
            sum.x += frame.delta.x
            sum.y += frame.delta.y
            if frame.phase == .ended { break }
        }

        XCTAssertEqual(sum.x, 12, accuracy: 0.02)
        XCTAssertEqual(sum.y, 0, accuracy: 0.000_001)
    }

    func testEventTapRestartLimiterThrottlesAndRecovers() {
        var limiter = EventTapRestartLimiter(window: 60, limit: 3)

        XCTAssertTrue(limiter.shouldAllowRestart(at: 0))
        XCTAssertTrue(limiter.shouldAllowRestart(at: 10))
        XCTAssertTrue(limiter.shouldAllowRestart(at: 20))
        XCTAssertFalse(limiter.shouldAllowRestart(at: 30))
        XCTAssertTrue(limiter.shouldAllowRestart(at: 61))
    }

    func testSessionRejectsPreparedFrameAfterPIDSwitch() throws {
        let tuning = ScrollTuning(step: 20, speed: 1, duration: 0.3, acceleration: 0, deadZone: 0.01)
        var session = SmoothScrollSession(tuning: tuning)
        session.ingest(ScrollVector(y: 1), targetPID: 101, at: 0)
        let oldPlan = try XCTUnwrap(framePlan(from: session.prepareFrame(at: 1.0 / 120)))

        session.ingest(ScrollVector(y: 1), targetPID: 202, at: 0.02)

        XCTAssertFalse(session.isCurrent(generation: oldPlan.generation))
        XCTAssertEqual(session.currentTargetPID, 202)
        let newPlan = try XCTUnwrap(framePlan(from: session.prepareFrame(at: 0.03)))
        XCTAssertEqual(newPlan.targetPID, 202)
    }

    func testSessionExpiresStaleTail() {
        let tuning = ScrollTuning(step: 20, speed: 1, duration: 0.3, acceleration: 0, deadZone: 0.01)
        var session = SmoothScrollSession(tuning: tuning)
        session.ingest(ScrollVector(y: 1), targetPID: 101, at: 0)
        let generation = session.currentGeneration

        XCTAssertEqual(session.prepareFrame(at: 2.01), .expired)
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isCurrent(generation: generation))
    }

    func testSessionKeepsKnownPIDWhenEventTargetIsUnavailable() throws {
        let tuning = ScrollTuning(step: 20, speed: 1, duration: 0.3, acceleration: 0, deadZone: 0.01)
        var session = SmoothScrollSession(tuning: tuning)
        session.ingest(ScrollVector(y: 1), targetPID: 101, at: 0)
        session.ingest(ScrollVector(y: 1), targetPID: 0, at: 0.01)

        let plan = try XCTUnwrap(framePlan(from: session.prepareFrame(at: 0.02)))
        XCTAssertEqual(plan.targetPID, 101)
    }

    func testSessionDoesNotInheritTargetPIDAfterTerminalFrame() throws {
        let tuning = ScrollTuning(step: 20, speed: 1, duration: 0.3, acceleration: 0, deadZone: 0.01)
        var session = SmoothScrollSession(tuning: tuning)
        session.ingest(ScrollVector(y: 1), targetPID: 101, at: 0)

        var timestamp = 0.0
        var terminalPlan: SmoothScrollSession.FramePlan?
        for _ in 1 ... 600 {
            timestamp += 1.0 / 120.0
            guard let plan = framePlan(from: session.prepareFrame(at: timestamp)) else { break }
            if plan.frame.phase == .momentumEnded || plan.frame.phase == .trackingEnded {
                terminalPlan = plan
                if !session.isActive { break }
            }
        }

        let ended = try XCTUnwrap(terminalPlan)
        XCTAssertEqual(ended.targetPID, 101, "the terminal frame must keep its captured route")
        XCTAssertTrue(session.isCurrent(generation: ended.generation))
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.currentTargetPID, 0)

        session.ingest(ScrollVector(y: 1), targetPID: 0, at: timestamp + 0.01)
        let next = try XCTUnwrap(framePlan(from: session.prepareFrame(at: timestamp + 0.02)))
        XCTAssertEqual(next.targetPID, 0)
        XCTAssertEqual(next.frame.phase, .began)
    }

    private func framePlan(
        from preparation: SmoothScrollSession.FramePreparation
    ) -> SmoothScrollSession.FramePlan? {
        guard case let .frame(plan) = preparation else { return nil }
        return plan
    }

    private func collapsed(_ phases: [SmoothScrollFrame.Phase]) -> [SmoothScrollFrame.Phase] {
        phases.reduce(into: []) { result, phase in
            if result.last != phase { result.append(phase) }
        }
    }
}
