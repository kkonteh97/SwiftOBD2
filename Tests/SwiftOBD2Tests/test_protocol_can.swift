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
            var data = canprotocol.parcer(["7E8 06 41 00 00 01 02 03"]).first?.data
            XCTAssertNotNil(data)
            XCTAssertEqual(data, Data([0x00, 0x00,0x01, 0x02, 0x03]))

            // minimum valid length
            data = canprotocol.parcer(["7E8 01 41"]).first?.data
            XCTAssertNotNil(data)

            // to short
            data = canprotocol.parcer(["7E8 01"]).first?.data

            XCTAssertNil(data)

            // to long
        }
    }
}
