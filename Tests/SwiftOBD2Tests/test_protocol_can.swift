//
//  test_protocol_can.swift
//
//
//  Created by kemo konteh on 5/15/24.
//
@testable import SwiftOBD2
import XCTest

let CAN_11_PROTOCOLS: [CANProtocol] = [
    ISO_15765_4_11bit_500k(),
    ISO_15765_4_11bit_250K(),
]

let CAN_29_PROTOCOLS: [CANProtocol] = [
    ISO_15765_4_29bit_500k(),
    ISO_15765_4_29bit_250k(),
]

final class test_protocol_can: XCTestCase {
    func test_single_frame() {
        for canprotocol in CAN_11_PROTOCOLS {
            var data = try? canprotocol.parse(["7E8 06 41 00 00 01 02 03"]).first?.data
            XCTAssertNotNil(data)
            XCTAssertEqual(data, Data([0x00, 0x00, 0x01, 0x02, 0x03]))

            // minimum valid length
            data = try? canprotocol.parse(["7E8 01 41"]).first?.data
            XCTAssertNotNil(data)

            // to short
            data = try? canprotocol.parse(["7E8 01"]).first?.data

            XCTAssertNil(data)
        }
    }

    func test_single_frame_29_bit() {
        for canprotocol in CAN_29_PROTOCOLS {
            let message = try? canprotocol.parse(["18DAF110 06 41 00 00 01 02 03"]).first
            XCTAssertEqual(message?.data, Data([0x00, 0x00, 0x01, 0x02, 0x03]))
            XCTAssertEqual(message?.ecu, .engine)
        }
    }

    func test_every_protocol_has_a_parser() {
        for obdProtocol in PROTOCOL.allCases where obdProtocol != .NONE {
            XCTAssertNotNil(obdProtocol.parser, obdProtocol.description)
            XCTAssertEqual(obdProtocol.parser?.elmID, obdProtocol.rawValue)
        }
        XCTAssertTrue(PROTOCOL.protocol6.isCAN)
        XCTAssertFalse(PROTOCOL.protocol3.isCAN)
        XCTAssertEqual(PROTOCOL.protocol7.defaultHeader, "18DB33F1")
    }
}
