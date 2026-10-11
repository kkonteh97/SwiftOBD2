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

final class test_protocol_can: XCTestCase {
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

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

            // to long
        }
    }

    /// A single-frame response padded out to 8 bytes with a NON-zero byte (0xAA — "common
    /// in practice" for ISO-TP even though the spec calls for 0xCC) must not leak that
    /// byte into the decoded payload. DTCDecoder walks the full length two bytes at a
    /// time, so an unstripped pad byte pairs with whatever follows and can decode as a
    /// trouble code that has nothing to do with the vehicle.
    func test_single_frame_padding_stripped() {
        for canprotocol in CAN_11_PROTOCOLS {
            // PCI 0x03 = mode byte + 2 real payload bytes; 3 bytes of 0xAA padding follow.
            let data = try? canprotocol.parse(["7E8 03 43 01 23 AA AA AA"]).first?.data
            XCTAssertEqual(data, Data([0x01, 0x23]), "padding must be truncated, not returned as payload")
        }
    }

    /// Real capture from a 2016 Jeep Cherokee KL (protocol 7, ISO 15765-4 29-bit):
    /// two ECUs (source addresses 0x10 and 0x18) each answering 0100 with a single
    /// frame. Regression-locks two bugs at once: 29-bit frames being fed through the
    /// 11-bit "00000" padding path (odd-length hex → every byte boundary shifted →
    /// every frame rejected by the size guard → zero data from the whole vehicle),
    /// and distinct ECUs collapsing into one group via the `& 0x07` txID mask
    /// (0x10 and 0x18 both mask to 0), which merged their single-frame replies into
    /// a bogus multi-frame group that failed to assemble.
    func test_29bit_two_ecus() {
        for canprotocol in CAN_29_PROTOCOLS {
            let messages = (try? canprotocol.parse([
                "18DAF11806410098180001AA",
                "18DAF110064100983B201300",
            ])) ?? []
            XCTAssertEqual(messages.count, 2, "each 29-bit ECU must produce its own message")

            // Single-frame extraction drops the PCI byte and the mode echo (0x41), then
            // truncates to the PCI's declared length — dropping the trailing CAN pad
            // byte (0xAA / 0x00 here) instead of leaking it into the payload. What's left
            // is exactly PID-echo (0x00) + a 4-byte supported-PID bitmap, as it should be.
            let payloads = Set(messages.compactMap { $0.data.map { Data($0) } })
            XCTAssertEqual(payloads, [
                Data([0x00, 0x98, 0x18, 0x00, 0x01]),
                Data([0x00, 0x98, 0x3B, 0x20, 0x13]),
            ])
        }
    }
}

let CAN_29_PROTOCOLS: [CANProtocol] = [
    ISO_15765_4_29bit_500k(),
    ISO_15765_4_29bit_250k(),
]
