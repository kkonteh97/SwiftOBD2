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
    var mockcomm: MOCKComm!

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        self.mockcomm = MOCKComm()

        sut = ELM327(comm: mockcomm)
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        sut = nil
    }

    func testCommandPropertyPerformance() throws {
        // Method 1: OBDCommand
        self.measure {
            for _ in 0..<1000 {
                let command = OBDCommand.mode1(.rpm)
                _ = command.properties.command
            }
        }
    }

    func testStandardCommandPropertyPerformance() throws {
        // Method 2: StandardOBDCommand
        self.measure {
            for _ in 0..<1000 {
                let command = StandardOBDCommand.mode01(.rpm)
                _ = command.command.id
            }
        }
    }

    func testBothCommandPerformances() throws {
        let iterations = 10000

        print("\n=== Running Performance Tests ===")

        // Test multiple commands to get a broader picture
        let testCases: [(OBDCommand, StandardOBDCommand)] = [
            (.mode1(.rpm), .mode01(.rpm)),
            (.mode1(.speed), .mode01(.speed)),
            (.mode1(.coolantTemp), .mode01(.coolantTemp)),
            (.mode1(.engineLoad), .mode01(.engineLoad))
        ]

        var totalOBDTime: Double = 0
        var totalStandardTime: Double = 0

        for (obdCmd, stdCmd) in testCases {
            // OBDCommand timing
            let start1 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<iterations {
                _ = obdCmd.properties.command
            }
            let time1 = CFAbsoluteTimeGetCurrent() - start1
            totalOBDTime += time1

            // StandardOBDCommand timing
            let start2 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<iterations {
                _ = stdCmd.command.id
            }
            let time2 = CFAbsoluteTimeGetCurrent() - start2
            totalStandardTime += time2

            print("\nCommand: \(obdCmd)")
            print("  OBDCommand: \((time1 / Double(iterations)) * 1_000_000) μs per call")
            print("  StandardOBDCommand: \((time2 / Double(iterations)) * 1_000_000) μs per call")
        }

        print("\n=== Overall Results ===")
        print("Total OBDCommand time: \(totalOBDTime * 1000) ms")
        print("Total StandardOBDCommand time: \(totalStandardTime * 1000) ms")

        if totalOBDTime < totalStandardTime {
            print("✅ OBDCommand is \(String(format: "%.2f", totalStandardTime/totalOBDTime))x faster overall")
        } else {
            print("✅ StandardOBDCommand is \(String(format: "%.2f", totalOBDTime/totalStandardTime))x faster overall")
        }
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
                let obdInfo = try await sut.setupVehicle(preferredProtocol: nil)
                XCTAssertEqual(obdInfo.obdProtocol, .protocol6, "Expected obdProtocol to be .protocol6 but got \(String(describing: obdInfo.obdProtocol))")
//                XCTAssertEqual(sut.obdProtocol, .protocol6, "Expected obdProtocol to be .protocol6 but got \(String(describing: sut.obdProtocol))")
                let command = OBDCommand.mode1(.rpm)
                let command2 = StandardOBDCommand.mode01(.rpm)

                print(command2.id)
                print(command.properties.command)

                print(command.id)
                let res = try await sut.sendCommand(command.properties.command)
                print("response" ,res)
                guard let parsed = try sut.canProtocol?.parse(res).first?.data else {
                    XCTFail("ops")
                    return
                }
                let decoded = try command.properties.decode(data: parsed, unit: .imperial)
                print(decoded)

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
        Task {
            
            let response = ["86 F1 10 41 00 BF 9F E8 91 9F ", "86 F1 1A 41 00 88 18 80 10 02 "]
            guard let data = try? ISO_14230_4_KWP_Fast().parse(response).first?.data else {
                XCTFail("Expected data to be not nil")
                return
            }
            let commands = await sut?.getSupportedPIDs()
//            print(commands!)
            //        let binaryData = BitArray(data: data.dropFirst()).binaryArray
            //
            //        guard let supportedPIDs = sut?.extractSupportedPIDs(binaryData) else {
            //            XCTFail("Expected supportedPIDs to be not nil")
            //            return
            //        }
            //        let supportedCommands = OBDCommand.allCommands
            //            .filter { supportedPIDs.contains(String($0.properties.command.dropFirst(2))) }
            //            .map { $0 }
            //        print(supportedCommands)
        }
    }
}
