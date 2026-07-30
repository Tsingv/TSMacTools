import XCTest
import MacToolsCore

final class WindowAbsenceConfirmationTests: XCTestCase {
    func testRequiresConsecutiveAbsenceSamplesBeforeRestoring() {
        var confirmation = WindowAbsenceConfirmation(requiredConsecutiveAbsences: 3)

        XCTAssertEqual(confirmation.observe(.absent), .retry)
        XCTAssertEqual(confirmation.observe(.absent), .retry)
        XCTAssertEqual(confirmation.observe(.absent), .restorePreviousApplication)
    }

    func testPresentWindowCancelsRestoration() {
        var confirmation = WindowAbsenceConfirmation(requiredConsecutiveAbsences: 3)

        XCTAssertEqual(confirmation.observe(.absent), .retry)
        XCTAssertEqual(confirmation.observe(.present), .cancel)
        XCTAssertEqual(confirmation.consecutiveAbsences, 0)
    }

    func testIndeterminateAXReadDoesNotCountAsWindowAbsence() {
        var confirmation = WindowAbsenceConfirmation(requiredConsecutiveAbsences: 2)

        XCTAssertEqual(confirmation.observe(.absent), .retry)
        XCTAssertEqual(confirmation.observe(.indeterminate), .retry)
        XCTAssertEqual(confirmation.consecutiveAbsences, 0)
        XCTAssertEqual(confirmation.observe(.absent), .retry)
    }
}

final class WindowActivationCapturePolicyTests: XCTestCase {
    func testDefaultRetriesAreBoundedAndOrdered() {
        XCTAssertEqual(WindowActivationCapturePolicy().retryDelays, [0.05, 0.18, 0.45])
    }

    func testRejectsCaptureAfterAnotherApplicationActivation() {
        XCTAssertFalse(WindowActivationCapturePolicy().shouldCapture(
            expectedProcessIdentifier: 42,
            frontmostProcessIdentifier: 42,
            generation: 7,
            currentGeneration: 8
        ))
    }

    func testRejectsCaptureWhenExpectedApplicationIsNoLongerFrontmost() {
        XCTAssertFalse(WindowActivationCapturePolicy().shouldCapture(
            expectedProcessIdentifier: 42,
            frontmostProcessIdentifier: 99,
            generation: 7,
            currentGeneration: 7
        ))
    }

    func testAcceptsCurrentFrontmostApplicationCapture() {
        XCTAssertTrue(WindowActivationCapturePolicy().shouldCapture(
            expectedProcessIdentifier: 42,
            frontmostProcessIdentifier: 42,
            generation: 7,
            currentGeneration: 7
        ))
    }
}

final class WindowSwitcherSelectionPolicyTests: XCTestCase {
    func testPreviousSelectionMovesUpOneRow() {
        XCTAssertEqual(WindowSwitcherSelectionPolicy.previousIndex(currentIndex: 1, choiceCount: 4), 0)
    }

    func testPreviousSelectionWrapsFromCurrentWindowToLastWindow() {
        XCTAssertEqual(WindowSwitcherSelectionPolicy.previousIndex(currentIndex: 0, choiceCount: 4), 3)
    }

    func testEmptySelectionHasNoIndex() {
        XCTAssertNil(WindowSwitcherSelectionPolicy.previousIndex(currentIndex: 0, choiceCount: 0))
    }
}

final class WindowSwitcherBackwardRepeatPolicyTests: XCTestCase {
    func testPreservesProvidedSystemRepeatTiming() {
        let policy = WindowSwitcherBackwardRepeatPolicy(initialDelay: 0.4, repeatInterval: 0.03)

        XCTAssertEqual(policy.initialDelay, 0.4)
        XCTAssertEqual(policy.repeatInterval, 0.03)
        XCTAssertGreaterThan(policy.initialDelay, policy.repeatInterval)
    }
}
