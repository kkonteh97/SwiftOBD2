//
//  ELM327Test.swift
//  SMARTOBD2Tests
//
//  Created by kemo konteh on 1/31/24.
//

import XCTest
@testable import SwiftOBD2

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

    func testSetupVehicle()  {
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
                XCTAssertEqual(sut.obdProtocol, .protocol6, "Expected obdProtocol to be .protocol6 but got \(String(describing: sut.obdProtocol))")
                exp.fulfill()
            } catch {
                print(error.localizedDescription)
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 30)
        // Then
    }
}
