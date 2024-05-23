//
//  elm327Test.swift
//  SMARTOBD2Tests
//
//  Created by kemo konteh on 1/31/24.
//

@testable import SwiftOBD2
import XCTest

final class ELM327Test: XCTestCase {
    // System under test
    var sut: ELM327?

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        let comm = MOCKComm()

        sut = ELM327(comm: comm)
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        sut = nil
    }

    func testSetupVehicle() {
        // Given
        guard let sut = sut else {
            XCTFail("Expected sut to be not nil")
            return
        }

        let exp = expectation(description: "Expected setupVehicle to return after setting obdProtocol to .protocol6")
        Task {
            // When
            do {
                let obdInfo = try await sut.setupVehicle(preferedProtocol: nil)
                XCTAssertEqual(obdInfo.obdProtocol, .protocol6, "Expected obdProtocol to be .protocol6 but got \(String(describing: obdInfo.obdProtocol))")
//                XCTAssertEqual(sut.obdProtocol, .protocol6, "Expected obdProtocol to be .protocol6 but got \(String(describing: sut.obdProtocol))")
                exp.fulfill()
            } catch {
                print(error.localizedDescription)
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 30)
        // Then
    }

    func testPIDExtractor() {
        let response = ["86 F1 10 41 00 BF 9F E8 91 9F ", "86 F1 1A 41 00 88 18 80 10 02 "]
        guard let data = ISO_14230_4_KWP_Fast().parce(response).first?.data else {
            XCTFail("Expected data to be not nil")
            return
        }
        let binaryData = BitArray(data: data.dropFirst()).binaryArray

        guard let supportedPIDs = sut?.extractSupportedPIDs(binaryData) else {
            XCTFail("Expected supportedPIDs to be not nil")
            return
        }
        let supportedCommands = OBDCommand.allCommands
            .filter { supportedPIDs.contains(String($0.properties.command.dropFirst(2))) }
            .map { $0 }
        print(supportedCommands)
    }
}
