//
//  test_protocol_legacy.swift
//
//
//  Created by kemo konteh on 5/15/24.
//
@testable import SwiftOBD2
import XCTest

let LEGACY_PROTOCOLS: [CANProtocol] = [
    SAE_J1850_PWM(),
    SAE_J1850_VPW(),
    ISO_9141_2(),
    ISO_14230_4_KWP_5Baud(),
    ISO_14230_4_KWP_Fast(),
]

final class test_protocol_legacy: XCTestCase {
    func test_single_frame() {
        for canprotocol in LEGACY_PROTOCOLS {
            // minimum valid length
            var data = try? canprotocol.parse(["48 6B 10 41 00 FF"]).first?.data
            XCTAssertEqual(data, Data([0x00]))

            // maximum valid length

            data = try? canprotocol.parse(["48 6B 10 41 00 00 01 02 03 04 FF"]).first?.data
            XCTAssertEqual(data, Data([0x00, 0x00, 0x01, 0x02, 0x03, 0x04]))

            // to short
            data = try? canprotocol.parse(["48 6B 10 41"]).first?.data
            XCTAssertNil(data)
        }
    }
}
