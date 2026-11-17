//
//  FormulaTests.swift
//  SwiftOBD2Tests
//

@testable import SwiftOBD2
import XCTest

final class FormulaTests: XCTestCase {
    private func evaluate(_ formula: String, _ bytes: [UInt8] = []) throws -> Double {
        try Formula(formula).evaluate(bytes)
    }

    func testArithmetic() throws {
        XCTAssertEqual(try evaluate("2+3*4"), 14)
        XCTAssertEqual(try evaluate("(2+3)*4"), 20)
        XCTAssertEqual(try evaluate("10/4"), 2.5)
        XCTAssertEqual(try evaluate("10 % 4"), 2)
        XCTAssertEqual(try evaluate("-3+5"), 2)
        XCTAssertEqual(try evaluate("2^3"), 8)
        XCTAssertEqual(try evaluate("-2^2"), -4)
        XCTAssertEqual(try evaluate("0x10 + 1.5"), 17.5)
    }

    func testBytes() throws {
        XCTAssertEqual(try evaluate("((A*256)+B)/4", [0x1A, 0xF8]), 1726)
        XCTAssertEqual(try evaluate("a-40", [0x7D]), 85)
        XCTAssertEqual(try evaluate("C", [1, 2, 3]), 3)
        XCTAssertEqual(try evaluate("AA", [UInt8](0 ... 30)), 26)
        XCTAssertEqual(try evaluate("AB + Z", [UInt8](0 ... 30)), 52)
    }

    func testBits() throws {
        XCTAssertEqual(try evaluate("{A:0}", [0b0000_1001]), 1)
        XCTAssertEqual(try evaluate("{A:1}", [0b0000_1001]), 0)
        XCTAssertEqual(try evaluate("{A:3}", [0b0000_1001]), 1)
        XCTAssertEqual(try evaluate("BIT(A, 3)", [0b0000_1001]), 1)
        XCTAssertEqual(try evaluate("A & 0x0F", [0xAB]), 0x0B)
        XCTAssertEqual(try evaluate("A >> 4", [0xAB]), 0x0A)
        XCTAssertEqual(try evaluate("A << 8 | B", [0x12, 0x34]), 0x1234)
    }

    func testFunctions() throws {
        XCTAssertEqual(try evaluate("SIGNED(A)", [0xFF]), -1)
        XCTAssertEqual(try evaluate("Signed(A)*0.5", [0x10]), 8)
        XCTAssertEqual(try evaluate("SIGNED16(A*256+B)", [0xFF, 0xFE]), -2)
        XCTAssertEqual(try evaluate("INT16(A,B)/10", [0xFF, 0x9C]), -10)
        XCTAssertEqual(try evaluate("UINT16(A,B)", [0xFF, 0x9C]), 65436)
        XCTAssertEqual(try evaluate("ABS(A-200)", [50]), 150)
        XCTAssertEqual(try evaluate("MIN(A, B, 7)", [9, 8]), 7)
        XCTAssertEqual(try evaluate("MAX(A, B)", [9, 8]), 9)
    }

    func testErrors() {
        XCTAssertThrowsError(try Formula("A +"))
        XCTAssertThrowsError(try Formula("(A"))
        XCTAssertThrowsError(try Formula("A B"))
        XCTAssertThrowsError(try Formula("A # B"))
        XCTAssertThrowsError(try Formula("{A:9}"))
        XCTAssertThrowsError(try Formula("ABC"))
        XCTAssertThrowsError(try Formula(""))

        XCTAssertThrowsError(try evaluate("B", [1])) { error in
            XCTAssertEqual(error as? FormulaError, .missingByte("B"))
        }
        XCTAssertThrowsError(try evaluate("NOPE(A)", [1]))
        XCTAssertThrowsError(try evaluate("1/0")) { error in
            XCTAssertEqual(error as? FormulaError, .notANumber)
        }
    }
}

final class CustomCommandTests: XCTestCase {
    func testNormalisation() {
        let command = CustomCommand(name: "Boost", request: "0x22 11 5a", formula: "A", header: "7e0")
        XCTAssertEqual(command.request, "22115A")
        XCTAssertEqual(command.target, ECUTarget(header: "7E0"))
        XCTAssertNoThrow(try command.validate())
        XCTAssertNil(CustomCommand(name: "x", request: "0142", header: "").target)

        XCTAssertThrowsError(try CustomCommand(name: "x", request: "22F").validate())
        XCTAssertThrowsError(try CustomCommand(name: "x", request: "22F190", formula: "A+").validate())
    }

    func testDataBytes() {
        let uds = CustomCommand(name: "x", request: "221154")
        XCTAssertEqual(uds.dataBytes(in: Data([0x62, 0x11, 0x54, 0x7D, 0x01])), Data([0x7D, 0x01]))
        XCTAssertNil(uds.dataBytes(in: Data([0x41, 0x0C, 0x1A, 0xF8])), "answer to another service")

        let local = CustomCommand(name: "x", request: "2101")
        XCTAssertEqual(local.dataBytes(in: Data([0x61, 0x01, 0xAA, 0xBB])), Data([0xAA, 0xBB]))
    }

    func testDecoding() throws {
        let command = OBDCommand.custom(CustomCommand(name: "Oil temperature", request: "221154", formula: "A-40", unit: "°C"))
        XCTAssertEqual(command.properties.command, "221154")
        XCTAssertEqual(command.properties.description, "Oil temperature")
        XCTAssertEqual(command.service, 0x22)

        let result = try XCTUnwrap(command.properties.decode(data: Data([0x7D])).get().measurementResult)
        XCTAssertEqual(result.value, 85)
        XCTAssertEqual(result.unit.symbol, "°C")
    }

    func testCodable() throws {
        let commands: [OBDCommand] = [
            .mode1(.rpm),
            .custom(CustomCommand(name: "Gear", request: "221E12", formula: "A", header: "7E1", receiveAddress: "7E9")),
        ]
        let decoded = try JSONDecoder().decode([OBDCommand].self, from: JSONEncoder().encode(commands))
        XCTAssertEqual(decoded, commands)
    }

    func testCSVImport() {
        let csv = """
        Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,Units,Header
        "Transmission temperature",Trans,0x221E1C,(A*256+B)/16,-40,215,°C,7E1
        "Boost, relative",Boost,22115A,"A-101",0,255,kPa,Auto
        Broken formula,Bad,221234,A+,0,1,,7E0
        Not hexadecimal,Bad,22XY,A,0,1,,7E0

        """
        let commands = CustomCommand.parseCSV(csv)

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].name, "Transmission temperature")
        XCTAssertEqual(commands[0].request, "221E1C")
        XCTAssertEqual(commands[0].formula, "(A*256+B)/16")
        XCTAssertEqual(commands[0].minValue, -40)
        XCTAssertEqual(commands[0].maxValue, 215)
        XCTAssertEqual(commands[0].unit, "°C")
        XCTAssertEqual(commands[0].target?.header, "7E1")
        XCTAssertEqual(commands[1].name, "Boost, relative")
        XCTAssertNil(commands[1].target)
    }
}
