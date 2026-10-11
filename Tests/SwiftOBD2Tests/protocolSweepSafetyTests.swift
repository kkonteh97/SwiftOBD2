@testable import SwiftOBD2
import XCTest

/// The connect fallback sweep must never transmit on non-OBD-II CAN protocols. J1939 (A)
/// and user CAN (B, C) run at bitrates a passenger car's diagnostic bus isn't running,
/// so probing them on a live bus generates error frames.
final class ProtocolSweepSafetyTests: XCTestCase {
    func testManualSweepExcludesNonOBDProtocols() {
        let sweep = ELM327.manualSweepOrder
        XCTAssertFalse(sweep.contains(.protocolA))
        XCTAssertFalse(sweep.contains(.protocolB))
        XCTAssertFalse(sweep.contains(.protocolC))
    }

    func testManualSweepTriesCANFirst() {
        XCTAssertEqual(Array(ELM327.manualSweepOrder.prefix(4)),
                       [.protocol6, .protocol7, .protocol8, .protocol9])
    }
}
