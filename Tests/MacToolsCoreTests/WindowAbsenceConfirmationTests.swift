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
