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

    func test_service_only_answer() throws {
        // The acknowledgement of "clear trouble codes" is a single byte.
        let message = try XCTUnwrap(ISO_9141_2().parse(["48 6B 10 44 FF"]).first)
        XCTAssertEqual(message.payload, Data([0x44]))
        XCTAssertEqual(message.ecu, .engine)
        XCTAssertEqual(message.address, 0x10)
    }

    func test_trouble_codes_over_several_frames() throws {
        // Three codes per frame, each frame repeats the service byte and there is no count.
        let message = try XCTUnwrap(SAE_J1850_VPW().parse([
            "48 6B 10 43 01 04 01 71 03 00 FF",
            "48 6B 10 43 C2 07 00 00 00 00 FF",
        ]).first)

        XCTAssertEqual(message.troubleCodeBytes.count, 12)
        let codes = try DTCDecoder().decode(data: message.troubleCodeBytes, unit: .metric).get().troubleCode
        XCTAssertEqual(codes?.map(\.code), ["P0104", "P0171", "P0300", "U0207"])
    }

    func test_vehicle_information_frames_are_reordered() throws {
        let message = try XCTUnwrap(ISO_9141_2().parse([
            "48 6B 10 49 02 03 33 41 50 37 FF",
            "48 6B 10 49 02 01 00 00 00 31 FF",
            "48 6B 10 49 02 05 39 35 38 33 FF",
            "48 6B 10 49 02 02 4E 34 41 4C FF",
            "48 6B 10 49 02 04 44 43 31 39 FF",
        ]).first)

        XCTAssertEqual(message.payload.prefix(2), Data([0x49, 0x02]))
        let vin = String(decoding: message.payload.dropFirst(2).filter { $0 != 0 }, as: UTF8.self)
        XCTAssertEqual(vin, "1N4AL3AP7DC199583")
    }

    func test_kwp_length_is_read_from_the_header() throws {
        let messages = try ISO_14230_4_KWP_Fast().parse([
            "86 F1 10 41 00 BF 9F E8 91 9F",
            "86 F1 1A 41 00 88 18 80 10 02",
        ])

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].payload, Data([0x41, 0x00, 0xBF, 0x9F, 0xE8, 0x91]))
        XCTAssertEqual(messages[0].ecu, .engine)
        XCTAssertEqual(messages[1].payload, Data([0x41, 0x00, 0x88, 0x18, 0x80, 0x10]))
        XCTAssertEqual(messages[1].ecu, .transmission)

        // Long frame: the length moves to a fourth header byte.
        let long = try XCTUnwrap(ISO_14230_4_KWP_Fast().parse(["80 F1 10 03 62 F1 90 FF"]).first)
        XCTAssertEqual(long.payload, Data([0x62, 0xF1, 0x90]))
    }

    func test_two_ecus() throws {
        let messages = try SAE_J1850_PWM().parse([
            "41 6B 10 41 0D 32 FF",
            "41 6B 18 41 0D 33 FF",
        ])
        XCTAssertEqual(messages.map(\.ecu), [.engine, .transmission])
        XCTAssertEqual(messages.map(\.address), [0x10, 0x18])
    }
}
