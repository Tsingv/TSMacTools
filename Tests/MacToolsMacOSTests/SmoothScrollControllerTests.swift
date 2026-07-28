import AppKit
import ApplicationServices
import XCTest
import MacToolsCore
@testable import MacToolsMacOS

@MainActor
final class SmoothScrollControllerTests: XCTestCase {
    func testDisplayPrepareFailureLeavesTapUninstalledAndEventUntouched() throws {
        let fixture = Fixture()
        fixture.frame.prepareResult = false
        let controller = fixture.makeController()
        let event = try makeScrollEvent(targetPID: 101)
        let original = axisFields(event)

        controller.start()

        XCTAssertEqual(fixture.tap.installCount, 0)
        XCTAssertEqual(fixture.tap.trigger(.scroll(event)), .passThrough)
        XCTAssertEqual(axisFields(event), original)
        XCTAssertTrue(fixture.posts.values.isEmpty)
        controller.shutdown()
    }

    func testDisplayStartFailurePassesThroughOriginalFields() throws {
        let fixture = Fixture()
        fixture.frame.startResult = false
        let controller = fixture.makeController(
            settings: ScrollSettings(reverseVertical: true, excludeTrackpad: true)
        )
        controller.start()
        let event = try makeScrollEvent(targetPID: 101)

        XCTAssertEqual(fixture.tap.trigger(.scroll(event)), .passThrough)
        XCTAssertEqual(axisFields(event), AxisFields(line: -1, point: -28, fixed: -2.5))
        XCTAssertTrue(fixture.posts.values.isEmpty)
        controller.shutdown()
    }

    func testDisplayStartWithoutFirstCallbackPassesThroughUntilReady() throws {
        let fixture = Fixture()
        fixture.frame.hasDeliveredFrame = false
        let controller = fixture.makeController(
            settings: ScrollSettings(reverseVertical: true, excludeTrackpad: true)
        )
        controller.start()
        let first = try makeLineScrollEvent(targetPID: 101)

        XCTAssertEqual(fixture.tap.trigger(.scroll(first)), .passThrough)
        XCTAssertEqual(axisFields(first), AxisFields(line: -1, point: 0, fixed: 0))
        XCTAssertTrue(fixture.posts.values.isEmpty)

        fixture.frame.fire(at: 0.01)
        let second = try makeLineScrollEvent(targetPID: 101)
        XCTAssertEqual(fixture.tap.trigger(.scroll(second)), .consume)
        fixture.frame.fire(at: 0.02)
        XCTAssertFalse(fixture.posts.values.isEmpty)
        controller.shutdown()
    }

    func testPermissionRevocationRecoveryIsBounded() {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()
        XCTAssertEqual(fixture.tap.installCount, 1)

        fixture.trust.value = false
        fixture.scheduler.advance(by: 1)
        XCTAssertEqual(fixture.tap.removeCount, 1)
        fixture.scheduler.advance(by: 8)
        XCTAssertEqual(fixture.tap.installCount, 1, "must never rebuild while permission is absent")

        fixture.trust.value = true
        fixture.scheduler.advance(by: 1)
        XCTAssertEqual(fixture.tap.installCount, 2)

        fixture.tap.installEnables = false
        fixture.tap.setEnabledSucceeds = false
        fixture.tap.isEnabled = false
        _ = fixture.tap.trigger(.disabled)
        fixture.scheduler.advance(by: 10)

        XCTAssertLessThanOrEqual(fixture.tap.installCount, 3)
        XCTAssertLessThanOrEqual(fixture.tap.setEnabledCount, 1)
        controller.shutdown()
    }

    func testScreenChangeRebuildIsDebouncedAndCancelledByShutdown() {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()

        fixture.notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        fixture.notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        fixture.notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        fixture.scheduler.advance(by: 0.49)
        XCTAssertEqual(fixture.frame.recreateCount, 0)
        fixture.scheduler.advance(by: 0.01)
        XCTAssertEqual(fixture.frame.recreateCount, 1)

        controller.shutdown()
        fixture.notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        fixture.scheduler.advance(by: 1)
        XCTAssertEqual(fixture.frame.recreateCount, 1)
    }

    func testShutdownMakesLateFrameAndTapCallbacksHarmless() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()
        let event = try makeScrollEvent(targetPID: 101)
        XCTAssertEqual(fixture.tap.trigger(.scroll(event)), .consume)

        controller.shutdown()
        fixture.frame.fire(at: 0.02)
        let lateEvent = try makeScrollEvent(targetPID: 202)

        XCTAssertEqual(fixture.tap.trigger(.scroll(lateEvent)), .passThrough)
        XCTAssertTrue(fixture.posts.values.isEmpty)
        XCTAssertEqual(fixture.tap.invalidateCount, 1)
        XCTAssertEqual(fixture.frame.invalidateCount, 1)
        controller.shutdown()
        XCTAssertEqual(fixture.tap.invalidateCount, 1, "shutdown must be idempotent")
        XCTAssertEqual(fixture.frame.invalidateCount, 1)
    }

    func testPIDSwitchPostsOnlyToCurrentTarget() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()

        XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 101))), .consume)
        fixture.frame.fire(at: 0.01)
        XCTAssertEqual(fixture.posts.values.map(\.pid), [101])

        fixture.scheduler.now = 0.02
        XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 202))), .consume)
        fixture.frame.fire(at: 0.03)
        XCTAssertEqual(fixture.posts.values.map(\.pid), [101, 202])
        controller.shutdown()
    }

    func testDisplayFramesReuseOneSyntheticEventTemplate() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()

        XCTAssertEqual(
            fixture.tap.trigger(.scroll(try makeLineScrollEvent(targetPID: 101))),
            .consume
        )
        for index in 1 ... 8 {
            fixture.frame.fire(at: Double(index) / 120)
        }

        XCTAssertGreaterThan(fixture.posts.values.count, 1)
        XCTAssertEqual(
            Set(fixture.posts.values.map(\.sourceIdentity)).count,
            1,
            "display frames must mutate and reuse one event template instead of allocating per frame"
        )
        controller.shutdown()
    }

    func testIdleStopRequiresCurrentRunCallbackBeforeConsumingNextGesture() throws {
        let fixture = Fixture()
        fixture.frame.tracksReadinessEpoch = true
        let controller = fixture.makeController()
        controller.start()

        let warmup = try makeLineScrollEvent(targetPID: 101)
        XCTAssertEqual(fixture.tap.trigger(.scroll(warmup)), .passThrough)
        fixture.frame.fire(at: 0.001)

        XCTAssertEqual(
            fixture.tap.trigger(.scroll(try makeLineScrollEvent(targetPID: 101))),
            .consume
        )
        for index in 1 ... 600 {
            fixture.frame.fire(at: Double(index) / 120)
            if let last = fixture.posts.values.last,
               last.momentumPhase == 3 || (last.scrollPhase == 4 && index > 20) {
                break
            }
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        fixture.scheduler.advance(by: 0.16)

        XCTAssertEqual(fixture.frame.stopCount, 1)
        XCTAssertFalse(fixture.frame.hasDeliveredFrame)
        XCTAssertEqual(fixture.frame.prepareCount, 1)
        XCTAssertEqual(fixture.frame.recreateCount, 0)

        fixture.frame.fire(at: 6, allowWhileStopped: true)
        XCTAssertFalse(
            fixture.frame.hasDeliveredFrame,
            "a callback from the stopped run must not establish readiness for a future run"
        )

        let restartedBeforeCallback = try makeLineScrollEvent(targetPID: 101)
        XCTAssertEqual(
            fixture.tap.trigger(.scroll(restartedBeforeCallback)),
            .passThrough,
            "a successful restart must remain fail-open until that run delivers its first callback"
        )
        XCTAssertEqual(fixture.frame.prepareCount, 1)
        XCTAssertEqual(fixture.frame.recreateCount, 0)

        fixture.frame.fire(at: 6.01)
        XCTAssertTrue(fixture.frame.hasDeliveredFrame)
        XCTAssertEqual(
            fixture.tap.trigger(.scroll(try makeLineScrollEvent(targetPID: 101))),
            .consume,
            "the current run's callback should make the reusable display link ready"
        )
        controller.shutdown()
    }

    func testLineUnitWheelPostsUsableLineDeltaInFirstSyntheticFrame() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()
        let event = try makeLineScrollEvent(targetPID: 101)

        XCTAssertEqual(axisFields(event), AxisFields(line: 1, point: 0, fixed: 0))
        XCTAssertEqual(fixture.tap.trigger(.scroll(event)), .consume)
        fixture.frame.fire(at: 0.01)

        let posted = try XCTUnwrap(fixture.posts.values.first)
        XCTAssertNotEqual(posted.delta, 0, "the consumed wheel input must produce motion on its first frame")
        XCTAssertEqual(posted.event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 1)
        let appKitEvent = try XCTUnwrap(NSEvent(cgEvent: posted.event))
        XCTAssertTrue(appKitEvent.hasPreciseScrollingDeltas)
        XCTAssertEqual(appKitEvent.scrollingDeltaY, posted.delta, accuracy: 0.001)
        XCTAssertEqual(posted.scrollPhase, 1)
        XCTAssertEqual(posted.momentumPhase, 0)

        for index in 2 ... 600 {
            fixture.frame.fire(at: Double(index) / 120)
            if let last = fixture.posts.values.last,
               last.momentumPhase == 3 || (last.scrollPhase == 4 && index > 20) {
                break
            }
        }
        let totalLineDelta = fixture.posts.values.reduce(Int64(0)) { partial, frame in
            partial + frame.event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        }
        XCTAssertEqual(
            totalLineDelta,
            1,
            "line-oriented consumers must receive one physical notch, not one line per animation frame"
        )
        controller.shutdown()
    }

    func testLineCompatibilityAccumulatesBurstWithoutRepeatingAcrossFrames() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()

        XCTAssertEqual(
            fixture.tap.trigger(.scroll(try makeLineScrollEvent(targetPID: 101))),
            .consume
        )
        XCTAssertEqual(
            fixture.tap.trigger(.scroll(try makeLineScrollEvent(targetPID: 101))),
            .consume
        )
        for index in 1 ... 600 {
            fixture.frame.fire(at: Double(index) / 120)
            if let last = fixture.posts.values.last,
               last.momentumPhase == 3 || (last.scrollPhase == 4 && index > 20) {
                break
            }
        }

        let lineDeltas = fixture.posts.values.map {
            $0.event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        }
        XCTAssertEqual(lineDeltas.first, 2)
        XCTAssertEqual(lineDeltas.dropFirst().reduce(0, +), 0)
        XCTAssertEqual(lineDeltas.reduce(0, +), 2)
        controller.shutdown()
    }

    func testExpiredTailDoesNotPost() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()
        XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 101))), .consume)

        fixture.frame.fire(at: 2.01)

        XCTAssertTrue(fixture.posts.values.isEmpty)
        controller.shutdown()
    }

    func testMixedAxisInputPassesUnsmoothedAxisExactlyOnce() throws {
        let fixture = Fixture()
        let controller = fixture.makeController(
            settings: ScrollSettings(
                smoothVertical: true,
                smoothHorizontal: false,
                excludeTrackpad: true
            )
        )
        controller.start()
        let event = try makeScrollEvent(targetPID: 101)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -12)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -1.5)

        XCTAssertEqual(fixture.tap.trigger(.scroll(event)), .passThrough)
        XCTAssertEqual(axisFields(event), .zero)
        XCTAssertEqual(
            AxisFields(
                line: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                point: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            ),
            AxisFields(line: -1, point: -12, fixed: -1.5)
        )

        fixture.frame.fire(at: 0.01)
        XCTAssertEqual(fixture.posts.values.count, 1)
        XCTAssertGreaterThan(fixture.posts.values[0].delta, 0)
        controller.shutdown()
    }

    func testConfigurationApplyReusesDriversAndOnlyReinstallsTapAfterDisable() {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()
        XCTAssertEqual(fixture.tap.installCount, 1)

        let glide = ScrollSettings(preset: .glide, excludeTrackpad: true)
        controller.apply(glide)
        controller.apply(glide)
        XCTAssertEqual(fixture.tap.installCount, 1)
        XCTAssertEqual(fixture.tap.invalidateCount, 0)
        XCTAssertEqual(fixture.frame.invalidateCount, 0)

        var disabled = glide
        disabled.enabled = false
        controller.apply(disabled)
        XCTAssertEqual(fixture.tap.removeCount, 1)

        controller.apply(glide)
        XCTAssertEqual(fixture.tap.installCount, 2)
        XCTAssertEqual(fixture.tap.invalidateCount, 0)
        XCTAssertEqual(fixture.frame.invalidateCount, 0)
        controller.shutdown()
    }

    func testConcurrentFrameCallbacksAreSerializedAndShutdownRejectsLateFrames() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()
        XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 101))), .consume)

        let frame = fixture.frame
        let group = DispatchGroup()
        for index in 1 ... 32 {
            group.enter()
            DispatchQueue.global().async {
                frame.fire(at: Double(index) / 240)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(fixture.posts.maximumConcurrentPosts, 1)

        controller.shutdown()
        let countAfterShutdown = fixture.posts.values.count
        frame.fire(at: 1)
        XCTAssertEqual(fixture.posts.values.count, countAfterShutdown)
    }

    func testDisplayUnavailableDropsPendingTail() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()
        XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 101))), .consume)

        fixture.frame.becomeUnavailable()
        fixture.frame.fire(at: 0.02)

        XCTAssertTrue(fixture.posts.values.isEmpty)
        controller.shutdown()
    }

    func testSyntheticMarkerPassesThroughWithoutReenteringSmoothing() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()
        XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 101))), .consume)
        fixture.frame.fire(at: 0.01)
        let synthetic = try XCTUnwrap(fixture.posts.values.last?.event)
        let postCount = fixture.posts.values.count

        fixture.source.value = .remoteDesktop
        XCTAssertEqual(fixture.tap.trigger(.scroll(synthetic)), .passThrough)
        XCTAssertEqual(fixture.posts.values.count, postCount)
        controller.shutdown()
    }

    func testMixedAxisSyntheticEventZerosEveryUnsmoothedRepresentation() throws {
        let fixture = Fixture()
        let controller = fixture.makeController(
            settings: ScrollSettings(
                smoothVertical: true,
                smoothHorizontal: false,
                excludeTrackpad: true
            )
        )
        controller.start()
        let event = try makeScrollEvent(targetPID: 101)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -12)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -1.5)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis3, value: 1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis3, value: 4)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3, value: 0.5)

        XCTAssertEqual(fixture.tap.trigger(.scroll(event)), .passThrough)
        fixture.frame.fire(at: 0.01)

        let posted = try XCTUnwrap(fixture.posts.values.last)
        XCTAssertEqual(posted.horizontal, .zero)
        XCTAssertEqual(posted.depth, .zero)
        controller.shutdown()
    }

    func testUnknownPIDDoesNotReuseCompletedSessionTarget() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()
        XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 101))), .consume)

        for index in 1 ... 600 {
            fixture.frame.fire(at: Double(index) / 120)
            if let last = fixture.posts.values.last,
               last.momentumPhase == 3 || (last.scrollPhase == 4 && index > 20) {
                fixture.frame.fire(at: Double(index + 1) / 120)
                break
            }
        }

        fixture.scheduler.now = 6
        XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 0))), .consume)
        fixture.frame.fire(at: 6.01)
        XCTAssertEqual(fixture.posts.values.last?.pid, 0)
        controller.shutdown()
    }

    func testDisabledControllerIgnoresPendingAndLaterScreenChanges() {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()
        fixture.notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        var disabled = ScrollSettings(excludeTrackpad: true)
        disabled.enabled = false
        controller.apply(disabled)
        fixture.scheduler.advance(by: 1)
        XCTAssertEqual(fixture.frame.recreateCount, 0)

        fixture.notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        fixture.scheduler.advance(by: 1)
        XCTAssertEqual(fixture.frame.recreateCount, 0)
        controller.shutdown()
    }

    func testInjectedPosterCanReenterApplyAndShutdown() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        let box = WeakControllerBox(controller)
        let invoked = MutableBool(false)
        fixture.posts.onPost = { [box, invoked] in
            guard !invoked.value else { return }
            invoked.value = true
            box.value?.apply(ScrollSettings(preset: .glide, excludeTrackpad: true))
            box.value?.shutdown()
        }
        controller.start()
        XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 101))), .consume)

        fixture.frame.fire(at: 0.01)

        XCTAssertTrue(invoked.value)
        XCTAssertEqual(fixture.tap.invalidateCount, 1)
        XCTAssertEqual(fixture.frame.invalidateCount, 1)
    }

    func testRemoteContinuousBypassesAndLogitechWheelOverridesScrollCount() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()

        let remote = try makeScrollEvent(targetPID: 101)
        remote.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1)
        fixture.source.value = .remoteDesktop
        XCTAssertEqual(fixture.tap.trigger(.scroll(remote)), .passThrough)
        XCTAssertEqual(fixture.frame.startCount, 0)

        let localTrackpadLike = try makeScrollEvent(targetPID: 101)
        localTrackpadLike.setDoubleValueField(.scrollWheelEventScrollCount, value: 1)
        fixture.source.value = .local
        XCTAssertEqual(fixture.tap.trigger(.scroll(localTrackpadLike)), .passThrough)

        let logitech = try makeScrollEvent(targetPID: 101)
        logitech.setDoubleValueField(.scrollWheelEventScrollCount, value: 1)
        fixture.source.value = .logitechOptions
        XCTAssertEqual(fixture.tap.trigger(.scroll(logitech)), .consume)
        fixture.frame.fire(at: 0.01)
        XCTAssertEqual(fixture.posts.values.last?.pid, 101)
        controller.shutdown()
    }

    func testSourceIdentityClassifierUsesIndependentFragmentsAndLogitechPrecedence() {
        XCTAssertEqual(
            ScrollEventSourceIdentityClassifier.classify(
                bundleIdentifier: "com.teamviewer.TeamViewer_Service",
                executablePath: ""
            ),
            .remoteDesktop
        )
        XCTAssertEqual(
            ScrollEventSourceIdentityClassifier.classify(
                bundleIdentifier: "com.microsoft.rdc.macos.beta",
                executablePath: ""
            ),
            .remoteDesktop
        )
        XCTAssertEqual(
            ScrollEventSourceIdentityClassifier.classify(
                bundleIdentifier: nil,
                executablePath: "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/MacOS/ARDAgent"
            ),
            .remoteDesktop
        )
        XCTAssertEqual(
            ScrollEventSourceIdentityClassifier.classify(
                bundleIdentifier: "com.logitech.manager.daemon",
                executablePath: "/Applications/Logi Options+.app/Contents/MacOS/logioptionsplus_agent"
            ),
            .logitechOptions
        )
        XCTAssertEqual(
            ScrollEventSourceIdentityClassifier.classify(
                bundleIdentifier: "com.example.editor",
                executablePath: "/Applications/Editor.app/Contents/MacOS/Editor"
            ),
            .local
        )
    }

    func testLegacyDockBypassAndMouseDownCancelTail() throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        controller.start()

        fixture.bypassTarget.value = true
        XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 101))), .passThrough)
        XCTAssertEqual(fixture.frame.startCount, 0)

        fixture.bypassTarget.value = false
        XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 101))), .consume)
        XCTAssertEqual(fixture.tap.trigger(.cancelMotion), .passThrough)
        fixture.frame.fire(at: 0.02)
        XCTAssertTrue(fixture.posts.values.isEmpty)
        controller.shutdown()
    }

    func testLiveDriversCanDeinitializeOffMain() {
        let address: UInt = {
            var environment = SmoothScrollEnvironment.live
            environment.isAccessibilityTrusted = { false }
            let controller = SmoothScrollController(
                settings: ScrollSettings(excludeTrackpad: true),
                environment: environment,
                notificationCenter: NotificationCenter()
            )
            controller.start()
            return UInt(bitPattern: Unmanaged.passRetained(controller).toOpaque())
        }()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let pointer = UnsafeRawPointer(bitPattern: address)!
            let controller = Unmanaged<SmoothScrollController>.fromOpaque(pointer).takeRetainedValue()
            withExtendedLifetime(controller) {}
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    }

    func testPreparedLiveDisplayDriverCanInvalidateOffMain() throws {
        let environment = SmoothScrollEnvironment.live
        let driver = environment.makeFrameDriver({ _ in }, {})
        guard driver.prepare() else {
            throw XCTSkip("No active CoreVideo display is available")
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            driver.invalidate()
            driver.invalidate()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    }

    func testBackgroundDeinitCancelsHealthAndIdleTasks() throws {
        let fixture = Fixture()
        let address: UInt = try {
            let controller = fixture.makeController()
            controller.start()
            XCTAssertEqual(fixture.tap.trigger(.scroll(try makeScrollEvent(targetPID: 101))), .consume)
            for index in 1 ... 600 {
                fixture.frame.fire(at: Double(index) / 120)
                if let last = fixture.posts.values.last,
                   last.momentumPhase == 3 || (last.scrollPhase == 4 && index > 20) {
                    break
                }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            XCTAssertEqual(fixture.scheduler.pendingRepeatingCount, 1)
            XCTAssertEqual(fixture.scheduler.pendingOneShotCount, 1)
            return UInt(bitPattern: Unmanaged.passRetained(controller).toOpaque())
        }()

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let pointer = UnsafeRawPointer(bitPattern: address)!
            let controller = Unmanaged<SmoothScrollController>.fromOpaque(pointer).takeRetainedValue()
            withExtendedLifetime(controller) {}
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(fixture.scheduler.pendingRepeatingCount, 0)
        XCTAssertEqual(fixture.scheduler.pendingOneShotCount, 0)
    }

    private func makeScrollEvent(targetPID: pid_t) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 28,
            wheel2: 0,
            wheel3: 0
        ))
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID))
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        event.setDoubleValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setDoubleValueField(.scrollWheelEventScrollCount, value: 0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 28)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 2.5)
        return event
    }

    private func makeLineScrollEvent(targetPID: pid_t) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ))
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID))
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        event.setDoubleValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: 0)
        event.setDoubleValueField(.scrollWheelEventScrollCount, value: 0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        return event
    }

    private func axisFields(_ event: CGEvent) -> AxisFields {
        AxisFields(
            line: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            point: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        )
    }
}

private struct AxisFields: Equatable {
    var line: Int64
    var point: Double
    var fixed: Double

    static let zero = AxisFields(line: 0, point: 0, fixed: 0)
}

@MainActor
private final class Fixture {
    let scheduler = FakeScheduler()
    let tap = FakeEventTap()
    let frame = FakeFrameDriver()
    let trust = MutableBool(true)
    let source = MutableEventSource(.local)
    let bypassTarget = MutableBool(false)
    let posts = PostRecorder()
    let notificationCenter = NotificationCenter()

    func makeController(
        settings: ScrollSettings = ScrollSettings(excludeTrackpad: true)
    ) -> SmoothScrollController {
        let environment = SmoothScrollEnvironment(
            makeEventTap: { [tap] handler in
                tap.handler = handler
                return tap
            },
            makeFrameDriver: { [frame] frameHandler, unavailableHandler in
                frame.frameHandler = frameHandler
                frame.unavailableHandler = unavailableHandler
                return frame
            },
            scheduler: scheduler,
            now: { [scheduler] in scheduler.now },
            isAccessibilityTrusted: { [trust] in trust.value },
            resolveTargetPID: { event in
                pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            },
            classifyEventSource: { [source] _ in source.value },
            shouldBypassTarget: { [bypassTarget] _ in bypassTarget.value },
            post: { [posts] event, pid in
                posts.record(event: event, pid: pid)
            }
        )
        return SmoothScrollController(
            settings: settings,
            environment: environment,
            notificationCenter: notificationCenter
        )
    }
}

private final class MutableBool: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

private final class MutableEventSource: @unchecked Sendable {
    var value: ScrollEventSource
    init(_ value: ScrollEventSource) { self.value = value }
}

private final class WeakControllerBox: @unchecked Sendable {
    weak var value: SmoothScrollController?
    init(_ value: SmoothScrollController) { self.value = value }
}

private struct PostedEvent {
    var pid: pid_t
    var sourceIdentity: UInt
    var delta: Double
    var horizontal: AxisFields
    var depth: AxisFields
    var marker: Int64
    var scrollPhase: Double
    var momentumPhase: Double
    var event: CGEvent
}

private final class PostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [PostedEvent] = []
    private var activePosts = 0
    private var storedMaximumConcurrentPosts = 0
    var onPost: (@Sendable () -> Void)?

    var values: [PostedEvent] {
        lock.withLock { storedValues }
    }

    var maximumConcurrentPosts: Int {
        lock.withLock { storedMaximumConcurrentPosts }
    }

    func record(event: CGEvent, pid: pid_t) {
        let action: (@Sendable () -> Void)? = lock.withLock {
            activePosts += 1
            storedMaximumConcurrentPosts = max(storedMaximumConcurrentPosts, activePosts)
            storedValues.append(
                PostedEvent(
                    pid: pid,
                    sourceIdentity: UInt(
                        bitPattern: Unmanaged.passUnretained(event).toOpaque()
                    ),
                    delta: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                    horizontal: AxisFields(
                        line: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                        point: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                        fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
                    ),
                    depth: AxisFields(
                        line: event.getIntegerValueField(.scrollWheelEventDeltaAxis3),
                        point: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis3),
                        fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3)
                    ),
                    marker: event.getIntegerValueField(.eventSourceUserData),
                    scrollPhase: event.getDoubleValueField(.scrollWheelEventScrollPhase),
                    momentumPhase: event.getDoubleValueField(.scrollWheelEventMomentumPhase),
                    event: event.copy() ?? event
                )
            )
            return onPost
        }
        action?()
        lock.withLock { activePosts -= 1 }
    }
}

private final class FakeEventTap: ScrollEventTapDriving, @unchecked Sendable {
    var handler: (@Sendable (ScrollTapInput) -> ScrollTapDisposition)?
    var isInstalled = false
    var isEnabled = false
    var installSucceeds = true
    var installEnables = true
    var setEnabledSucceeds = true
    private(set) var installCount = 0
    private(set) var setEnabledCount = 0
    private(set) var removeCount = 0
    private(set) var invalidateCount = 0

    func install() -> Bool {
        installCount += 1
        isInstalled = installSucceeds
        isEnabled = installSucceeds && installEnables
        return isInstalled
    }

    func setEnabled(_ enabled: Bool) {
        setEnabledCount += 1
        if setEnabledSucceeds { isEnabled = enabled }
    }

    func remove() {
        removeCount += 1
        isInstalled = false
        isEnabled = false
    }

    func invalidate() {
        invalidateCount += 1
        isInstalled = false
        isEnabled = false
    }

    func trigger(_ input: ScrollTapInput) -> ScrollTapDisposition {
        handler?(input) ?? .passThrough
    }
}

private final class FakeFrameDriver: ScrollFrameDriving, @unchecked Sendable {
    var frameHandler: (@Sendable (TimeInterval) -> Void)?
    var unavailableHandler: (@Sendable () -> Void)?
    var prepareResult = true
    var startResult = true
    var hasDeliveredFrame = true
    var tracksReadinessEpoch = false
    private var running = false
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var recreateCount = 0
    private(set) var invalidateCount = 0

    func prepare() -> Bool {
        prepareCount += 1
        return prepareResult
    }

    func start() -> Bool {
        startCount += 1
        guard prepareResult && startResult else {
            if tracksReadinessEpoch {
                running = false
                hasDeliveredFrame = false
            }
            return false
        }
        if tracksReadinessEpoch, !running {
            running = true
            hasDeliveredFrame = false
        }
        return true
    }

    func stop() {
        stopCount += 1
        if tracksReadinessEpoch {
            running = false
            hasDeliveredFrame = false
        }
    }

    func recreate(force: Bool) -> Bool {
        recreateCount += 1
        if tracksReadinessEpoch {
            running = false
            hasDeliveredFrame = false
        }
        return prepareResult
    }

    func invalidate() {
        invalidateCount += 1
        if tracksReadinessEpoch {
            running = false
            hasDeliveredFrame = false
        }
    }

    func fire(at timestamp: TimeInterval, allowWhileStopped: Bool = false) {
        if tracksReadinessEpoch, !running {
            if allowWhileStopped {
                frameHandler?(timestamp)
            }
            return
        }
        hasDeliveredFrame = true
        frameHandler?(timestamp)
    }

    func becomeUnavailable() {
        unavailableHandler?()
    }
}

private final class FakeScheduler: SmoothScrollScheduling, @unchecked Sendable {
    final class Task: SmoothScrollScheduledTask, @unchecked Sendable {
        var deadline: TimeInterval
        let interval: TimeInterval?
        let action: @Sendable () -> Void
        var isCancelled = false

        init(deadline: TimeInterval, interval: TimeInterval?, action: @escaping @Sendable () -> Void) {
            self.deadline = deadline
            self.interval = interval
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    var now: TimeInterval = 0
    private var tasks: [Task] = []

    var pendingRepeatingCount: Int {
        tasks.filter { !$0.isCancelled && $0.interval != nil }.count
    }

    var pendingOneShotCount: Int {
        tasks.filter { !$0.isCancelled && $0.interval == nil }.count
    }

    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        _ action: @escaping @Sendable () -> Void
    ) -> any SmoothScrollScheduledTask {
        let task = Task(deadline: now + delay, interval: interval, action: action)
        tasks.append(task)
        return task
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let task = tasks
            .filter({ !$0.isCancelled && $0.deadline <= target })
            .min(by: { $0.deadline < $1.deadline }) {
            now = task.deadline
            if let repeating = task.interval {
                task.deadline += repeating
            } else {
                task.isCancelled = true
            }
            task.action()
        }
        now = target
    }
}
