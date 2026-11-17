@testable import SwiftOBD2
import XCTest

/// ISO 14229 status byte → badge status, using the four codes from a real
/// I-Pace BECM read (P1B48 active, the rest stored from earlier).
final class UDSDTCStatusTests: XCTestCase {
    func testTestFailedIsActive() {
        XCTAssertEqual(ELM327.udsStatus(0x09), .confirmed)   // P1B48: testFailed + confirmed
        XCTAssertEqual(ELM327.udsStatus(0x2F), .confirmed)
    }

    func testConfirmedWithoutTestFailedIsHistorical() {
        XCTAssertEqual(ELM327.udsStatus(0x08), .historical)  // P0AA6 / P304D / U3001
        XCTAssertEqual(ELM327.udsStatus(0x28), .historical)
    }

    func testPendingOnlyIsPending() {
        XCTAssertEqual(ELM327.udsStatus(0x04), .pending)
    }

    func testHistoricalLosesMergeToEveryOtherStatus() {
        for other in [DTCStatus.pending, .confirmed, .permanent] {
            XCTAssertLessThan(DTCStatus.historical.priority, other.priority)
        }
    }
}
