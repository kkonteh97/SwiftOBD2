@testable import SwiftOBD2
import XCTest

/// Mode 03/07/0A replies through the real parsers and `ELM327.dtcCodeBytes` into the DTC decoder.
/// CAN replies carry a count byte before the codes (ISO 15031-5); legacy replies come back from the
/// parser with a `43 00` placeholder. Neither may be decoded as part of a code.
final class DtcCodeBytesTests: XCTestCase {

    private func codes(_ lines: [String], _ proto: CANProtocol) throws -> [String] {
        let messages = try proto.parse(lines)
        return messages.flatMap { message -> [String] in
            guard let data = message.data else { return [] }
            let bytes = ELM327.dtcCodeBytes(data, isLegacy: message is LegacyMessage)
            guard case let .success(.troubleCode(found)) = OBDCommand.Mode3.GET_DTC.properties.decode(data: bytes)
            else { return [] }
            return found.map(\.code)
        }
    }

    /// One stored code on 11-bit CAN: `43 <count=01> 0A 11`. Before the fix it read as P010A.
    func test_can_count_byte_is_not_half_a_code() throws {
        for proto in CAN_11_PROTOCOLS {
            XCTAssertEqual(try codes(["7E8 04 43 01 0A 11"], proto), ["P0A11"])
        }
    }

    /// The Jaguar I-Pace's real reply with no codes stored (2026-11-17): `43 <count=00>`.
    func test_can_no_codes_from_the_ipace() throws {
        for proto in CAN_11_PROTOCOLS {
            XCTAssertEqual(try codes(["7E8 02 43 00"], proto), [])
        }
    }

    /// Four codes over a first frame and a consecutive frame: count 04, then 8 code bytes.
    func test_can_multi_frame_codes() throws {
        for proto in CAN_11_PROTOCOLS {
            let lines = ["7E8 10 0A 43 04 01 33 01 34", "7E8 21 01 35 02 22 00 00 00"]
            XCTAssertEqual(try codes(lines, proto), ["P0133", "P0134", "P0135", "P0222"])
        }
    }

    /// Two codes on 29-bit CAN.
    func test_can_29bit_count_byte() throws {
        for proto in CAN_29_PROTOCOLS {
            XCTAssertEqual(try codes(["18DAF110 06 43 02 01 33 C1 00"], proto), ["P0133", "U0100"])
        }
    }

    /// ISO 9141-2: `48 6B 10` header, `43`, three code slots, checksum. The parser's `43 00`
    /// placeholder used to decode as a phantom C0300.
    func test_legacy_placeholder_is_not_a_code() throws {
        let proto = ISO_9141_2()
        XCTAssertEqual(try codes(["48 6B 10 43 01 33 00 00 00 00 5A"], proto), ["P0133"])
        XCTAssertEqual(try codes(["48 6B 10 43 00 00 00 00 00 00 5A"], proto), [])
    }

    func test_shapes() {
        XCTAssertEqual(ELM327.dtcCodeBytes(Data([0x01, 0x0A, 0x11]), isLegacy: false), Data([0x0A, 0x11]))
        XCTAssertEqual(ELM327.dtcCodeBytes(Data([0x0A, 0x11]), isLegacy: false), Data([0x0A, 0x11]))
        XCTAssertEqual(ELM327.dtcCodeBytes(Data([0x43, 0x00, 0x01, 0x33]), isLegacy: true), Data([0x01, 0x33]))
        XCTAssertEqual(ELM327.dtcCodeBytes(Data([0x01, 0x33]), isLegacy: true), Data([0x01, 0x33]))
    }
}
