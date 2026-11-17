//
//  parcerTest.swift
//  SMARTOBD2Tests
//
//  Created by kemo konteh on 2/8/24.
//

@testable import SwiftOBD2
import XCTest

final class OBDParcerTest: XCTestCase {
    func testSingleFrame() throws {
        let frame = try XCTUnwrap(CANFrame(hex: "7E8064100BE3FA813"))
        XCTAssertEqual(frame.kind, .single)
        XCTAssertEqual(frame.id, 0x7E8)
        XCTAssertFalse(frame.isExtended)
        XCTAssertEqual(frame.defaultECU, .engine)
    }

    func testFirstFrame() throws {
        let frame = try XCTUnwrap(CANFrame(hex: "7E8103E000000000000"))
        XCTAssertEqual(frame.kind, .first)
    }

    func testInvalidFrames() {
        XCTAssertNil(CANFrame(hex: "7E8"))
        XCTAssertNil(CANFrame(hex: "7E806410"), "half a byte")
        XCTAssertNil(CANFrame(hex: "7E8064100BE3FA81300FF"), "more than 8 data bytes")
    }

    func testPaddingIsRemoved() throws {
        // ECUs fill unused bytes with whatever they like: 00, 55, AA…
        let messages = try CANParser(["7E8 03 41 0D 32 AA AA AA AA"]).messages
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].payload, Data([0x41, 0x0D, 0x32]))
        XCTAssertEqual(messages[0].data, Data([0x0D, 0x32]))
        XCTAssertEqual(messages[0].serviceID, 0x41)
    }

    func testMultiFrameMessage() throws {
        let messages = try CANParser([
            "7E8 10 14 49 02 01 31 4E 34",
            "7E8 21 41 4C 33 41 50 37 44",
            "7E8 22 43 31 39 39 35 38 33",
        ]).messages

        XCTAssertEqual(messages.count, 1)
        let payload = messages[0].payload
        XCTAssertEqual(payload.count, 0x14)
        XCTAssertEqual(payload.prefix(3), Data([0x49, 0x02, 0x01]))
        XCTAssertEqual(String(decoding: payload.dropFirst(3), as: UTF8.self), "1N4AL3AP7DC199583")
    }

    func testMultiFrameLongerThanFifteenFrames() throws {
        // The sequence number wraps from F to 0.
        let payload = (0 ..< 130).map { UInt8($0) }
        var lines = ["7E8 10 82 " + payload.prefix(6).map { String(format: "%02X", $0) }.joined(separator: " ")]
        var sequence = 1
        for chunk in Array(payload.dropFirst(6)).chunked(into: 7) {
            lines.append("7E8 " + String(format: "2%X ", sequence) + chunk.map { String(format: "%02X", $0) }.joined(separator: " "))
            sequence = (sequence + 1) % 16
        }

        let messages = try CANParser(lines).messages
        XCTAssertEqual(messages.first?.payload, Data(payload))
    }

    func testInterleavedECUs() throws {
        let messages = try CANParser([
            "7E8 10 0A 41 00 BE 3F A8 13",
            "7E9 06 41 00 80 08 00 00",
            "7E8 21 0D 32 05 7B 00 00 00",
        ]).messages

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].ecu, .engine)
        XCTAssertEqual(messages[0].address, 0x7E8)
        XCTAssertEqual(messages[0].payload.count, 10)
        XCTAssertEqual(messages[1].ecu, .transmission)
        XCTAssertEqual(messages[1].payload, Data([0x41, 0x00, 0x80, 0x08, 0x00, 0x00]))
    }

    func testExtendedIdentifiers() throws {
        let messages = try CANParser(["18 DA F1 10 06 41 00 BE 3F A8 13", "18DAF11806410080080000"]).messages

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].address, 0x18DA_F110)
        XCTAssertEqual(messages[0].ecu, .engine)
        XCTAssertEqual(messages[0].payload, Data([0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13]))
        XCTAssertEqual(messages[1].ecu, .transmission)
    }

    func testInformativeLinesAreIgnored() throws {
        let messages = try CANParser(["SEARCHING...", "7E8 06 41 00 BE 3F A8 13", "OK"]).messages
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(try CANParser(["OK"]).messages.isEmpty)
    }

    func testOutOfSequenceFrameDropsTheMessage() {
        XCTAssertThrowsError(try CANParser([
            "7E8 10 14 49 02 01 31 4E 34",
            "7E8 22 43 31 39 39 35 38 33",
        ]))
    }

    func testIncompleteMessageIsDropped() {
        XCTAssertThrowsError(try CANParser(["7E8 10 14 49 02 01 31 4E 34"]))
    }

    func testNegativeResponse() throws {
        let messages = try CANParser(["7E8 03 7F 22 31", "7E8 03 7F 22 78"]).messages
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].isNegativeResponse)
        XCTAssertFalse(messages[0].isResponsePending)
        XCTAssertTrue(messages[1].isResponsePending)
    }

    func testTroubleCodeBytesOnCAN() throws {
        // 43 <number of codes> <codes…>, padded with 55
        let message = try XCTUnwrap(CANParser(["7E8 06 43 02 01 04 C2 07 55"]).messages.first)
        XCTAssertEqual(message.troubleCodeBytes, Data([0x01, 0x04, 0xC2, 0x07]))

        let none = try XCTUnwrap(CANParser(["7E8 02 43 00 55 55 55 55 55"]).messages.first)
        XCTAssertTrue(none.troubleCodeBytes.isEmpty)
    }
}
