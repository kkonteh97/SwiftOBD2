//
//  parcerTest.swift
//  SMARTOBD2Tests
//
//  Created by kemo konteh on 2/8/24.
//

@testable import SwiftOBD2
import XCTest

final class OBDParcerTest: XCTestCase {
    func testOBDParcer() {
        let responses: [[String]] = [["7E8 06 41 00 BE 3F A8 13 00"],
                                     ["7E8 06 41 00 FF 00 00 00 00"],
                                     ["7E8 10 14 49 02 01 31 4E 34 ", "7E8 21 41 4C 33 41 50 37 44 ", "7E8 22 43 31 39 39 35 38 33 "]]
        measure {
            for response in responses {
                // Setup
                let obdParcer = OBDParcer(response, idBits: 11)
                // Verify
                XCTAssertNotNil(obdParcer)
                XCTAssertNotNil(obdParcer?.messages.first?.data)
            }
        }
    }

    func testSingleFrameInitialization() {
        // Setup
        let rawFrameString = ["7E8 06 41 00 BE 3F A8 13 00"]
            .compactMap { $0.replacingOccurrences(of: " ", with: "") }
            .filter { $0.isHex }
        let frameType = FrameType.singleFrame
        let frame = Frame(raw: rawFrameString[0], idBits: 11)

        // Verify
        XCTAssertEqual(frame?.type, frameType)
        // Add additional assertions based on your expected frame initialization
    }

    func testMultiFrameInitialization() {
        // Setup
        let rawFrameString = ["7E8 10 3E 00 00 00 00 00 00"]

            .compactMap { $0.replacingOccurrences(of: " ", with: "") }
            .filter { $0.isHex }

        let frameType = FrameType.firstFrame
        let frame = Frame(raw: rawFrameString[0], idBits: 11)

        // Verify
        XCTAssertEqual(frame?.type, frameType)
    }

    func testMessageInitialization() {
        // Setup
        let rawFrameString = ["7E8 06 41 00 BE 3F A8 13 00"]
            .compactMap { $0.replacingOccurrences(of: " ", with: "") }
            .filter { $0.isHex }
        let frame = Frame(raw: rawFrameString[0], idBits: 11)
        let message = Message(frames: [frame!])

        // Verify
        XCTAssertNotNil(message)
        XCTAssertNotNil(message?.data)
    }
}
