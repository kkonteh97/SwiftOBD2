//
//  elm327Test.swift
//  SMARTOBD2Tests
//
//  Created by kemo konteh on 1/31/24.
//

@testable import SwiftOBD2
import XCTest

final class ELM327Test: XCTestCase {
    private func makeAdapter(configure: (MOCKComm) -> Void = { _ in }) async throws -> (ELM327, MOCKComm) {
        let comm = MOCKComm()
        comm.responseDelay = 0
        configure(comm)
        let adapter = ELM327(comm: comm)
        try await adapter.connectToAdapter(timeout: 1)
        try await adapter.adapterInitialization()
        return (adapter, comm)
    }

    // MARK: - Setup

    func testSetupVehicle() async throws {
        let (sut, _) = try await makeAdapter()
        let info = try await sut.setupVehicle(preferredProtocol: nil)

        XCTAssertEqual(info.obdProtocol, .protocol6)
        XCTAssertEqual(info.vin, "1N4AL3AP7DC199583")
        XCTAssertEqual(info.ecuMap, [0xE8: .engine, 0xE9: .transmission])
        XCTAssertEqual(info.adapter, "ELM327 v1.5")
        XCTAssertEqual(try XCTUnwrap(info.voltage), 13.8, accuracy: 0.5)
        XCTAssertEqual(sut.connectionState, .connectedToVehicle)
    }

    func testSupportedPIDsUseTheRightRange() async throws {
        let (sut, _) = try await makeAdapter()
        let info = try await sut.setupVehicle(preferredProtocol: nil)
        let supported = try XCTUnwrap(info.supportedPIDs)

        // one PID from each bitmap: 01-20, 21-40, 41-60
        for command in [OBDCommand.mode1(.rpm), .mode1(.fuelLevel), .mode1(.controlModuleVoltage), .mode1(.engineOilTemp)] {
            XCTAssertTrue(supported.contains(command), command.properties.description)
        }
        // not implemented by the simulated vehicle
        XCTAssertFalse(supported.contains(.mode1(.fuelPressure)))
        XCTAssertFalse(supported.contains(.mode1(.odometer)))
        // other services are reported by their own bitmaps, not by the one of service 01
        XCTAssertTrue(supported.contains(.mode9(.VIN)))
        XCTAssertFalse(supported.contains(.mode9(.CVN)))
        XCTAssertTrue(supported.contains(.mode6(.MONITOR_O2_B1S1)))
        XCTAssertTrue(supported.contains(.mode6(.MONITOR_CATALYST_B1)))
        XCTAssertFalse(supported.contains(.mode6(.MONITOR_O2_B1S2)))
        // the bitmaps themselves are not data
        XCTAssertFalse(supported.contains { $0.isSupportQuery })
        XCTAssertEqual(supported, supported.sorted())
    }

    func testPreferredProtocolIsTriedFirst() async throws {
        let (sut, comm) = try await makeAdapter()
        let info = try await sut.setupVehicle(preferredProtocol: .protocol6)

        XCTAssertEqual(info.obdProtocol, .protocol6)
        XCTAssertTrue(comm.history.contains("ATSP6"))
        XCTAssertFalse(comm.history.contains("ATSP0"), "no search needed when the preferred protocol answers")
    }

    func testWrongPreferredProtocolFallsBackToSearch() async throws {
        let (sut, comm) = try await makeAdapter()
        let info = try await sut.setupVehicle(preferredProtocol: .protocol3)

        XCTAssertEqual(info.obdProtocol, .protocol6)
        XCTAssertTrue(comm.history.contains("ATSP3"))
        XCTAssertTrue(comm.history.contains("ATSP0"))
    }

    func test29BitVehicle() async throws {
        let (sut, _) = try await makeAdapter { $0.vehicleProtocol = .protocol7 }
        let info = try await sut.setupVehicle(preferredProtocol: nil)

        XCTAssertEqual(info.obdProtocol, .protocol7)
        XCTAssertEqual(info.vin, "1N4AL3AP7DC199583")
        XCTAssertEqual(info.ecuMap, [0x10: .engine, 0x18: .transmission])
    }

    func testManualSearchWhenTheAdapterCannotSearchItself() async throws {
        // A clone whose automatic search fails, on a 250 kbit/s CAN vehicle.
        var selected = "0"
        let comm = ScriptedComm { command in
            if command.hasPrefix("ATSP") || command.hasPrefix("ATTP") {
                selected = String(command.dropFirst(4))
                return ["OK"]
            }
            if let answer = ScriptedComm.adapterAnswer(command, protocolNumber: selected) { return answer }
            guard selected == "8" else { return ["UNABLE TO CONNECT"] }
            return command == "0100" ? ["7E8 06 41 00 98 18 00 00"] : ["NO DATA"]
        }
        let sut = ELM327(comm: comm)
        try await sut.adapterInitialization()
        let info = try await sut.setupVehicle(preferredProtocol: nil)

        XCTAssertEqual(info.obdProtocol, .protocol8)
        XCTAssertEqual(comm.sent.filter { $0.hasPrefix("ATTP") }, ["ATTP6", "ATTP7", "ATTP8"])
        XCTAssertEqual(info.ecuMap, [0xE8: .engine])
        XCTAssertNil(info.vin)
    }

    func testNoProtocolFound() async throws {
        let comm = ScriptedComm { command in
            ScriptedComm.adapterAnswer(command, protocolNumber: "0") ?? ["UNABLE TO CONNECT"]
        }
        let sut = ELM327(comm: comm)
        try await sut.adapterInitialization()

        await assertThrowsAsync(try await sut.setupVehicle(preferredProtocol: nil)) { error in
            guard case ELM327Error.noProtocolFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNotEqual(sut.connectionState, .connectedToVehicle)
    }

    func testLegacyVehicle() async throws {
        // ISO 9141-2: three byte headers, checksums, no multi-PID requests, sequence numbered VIN.
        let comm = ScriptedComm { command in
            if let answer = ScriptedComm.adapterAnswer(command, protocolNumber: "A3") { return answer }
            switch command {
            case "0100": return ["BUS INIT: OK", "48 6B 10 41 00 BE 3F B8 11 C8"]
            case "0120": return ["48 6B 10 41 20 80 00 00 00 A4"]
            case "0900": return ["48 6B 10 49 00 01 40 00 00 00 4D"]
            case "0902": return ["48 6B 10 49 02 01 00 00 00 31 37",
                                 "48 6B 10 49 02 02 4E 34 41 4C 19",
                                 "48 6B 10 49 02 03 33 41 50 37 FF",
                                 "48 6B 10 49 02 04 44 43 31 39 FF",
                                 "48 6B 10 49 02 05 39 35 38 33 FF"]
            case "010C": return ["48 6B 10 41 0C 1A F8 22"]
            case "010D": return ["48 6B 10 41 0D 32 43"]
            case "03": return ["48 6B 10 43 01 04 01 71 00 00 6F"]
            case "07": return ["NO DATA"]
            default: return ["NO DATA"]
            }
        }
        let service = OBDService(comm: comm)
        let info = try await service.startConnection()

        XCTAssertEqual(info.obdProtocol, .protocol3)
        XCTAssertEqual(info.vin, "1N4AL3AP7DC199583")
        XCTAssertEqual(info.ecuMap, [0x10: .engine])
        let supported = try XCTUnwrap(info.supportedPIDs)
        XCTAssertTrue(supported.contains(.mode1(.rpm)))
        XCTAssertTrue(supported.contains(.mode1(.distanceWMIL)), "PID 21 comes from the second bitmap")
        XCTAssertTrue(supported.contains(.mode9(.VIN)))
        XCTAssertFalse(comm.sent.contains("0600"), "service 06 bitmaps only exist on CAN")

        let values = try await service.requestPIDs([.mode1(.rpm), .mode1(.speed)])
        XCTAssertEqual(values[.mode1(.rpm)]?.value, 1726)
        XCTAssertEqual(values[.mode1(.speed)]?.value, 50)
        XCTAssertFalse(comm.sent.contains("010C0D"), "the legacy protocols take one PID per request")

        let codes = try await service.scanForTroubleCodes()
        XCTAssertEqual(codes[.engine]?.map(\.code), ["P0104", "P0171"])
        let pending = try await service.scanForTroubleCodes(.pending)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Adapter answers

    func testValidateRemovesNoise() throws {
        XCTAssertEqual(try ELM327.validate(["0100", "SEARCHING...", "7E8 06 41 00 BE 3F A8 13"], command: "0100"),
                       ["7E8 06 41 00 BE 3F A8 13"])
        XCTAssertEqual(try ELM327.validate(["BUS INIT: OK", "48 6B 10 41 00 BE 3F B8 11 C8"], command: "0100").count, 1)
        XCTAssertEqual(try ELM327.validate(["AT E0", "OK"], command: "ATE0"), ["OK"])
        // one ECU answered, another one did not
        XCTAssertEqual(try ELM327.validate(["7E8 03 41 0D 32", "NO DATA"], command: "010D"), ["7E8 03 41 0D 32"])
    }

    func testValidateReportsAdapterErrors() {
        func error(_ lines: [String]) -> ELM327Error? {
            do {
                _ = try ELM327.validate(lines, command: "0100")
                return nil
            } catch {
                return error as? ELM327Error
            }
        }

        if case .noData = error(["NO DATA"]) {} else { XCTFail("NO DATA") }
        if case .noData = error([]) {} else { XCTFail("empty answer") }
        if case .unableToConnect = error(["SEARCHING...", "UNABLE TO CONNECT"]) {} else { XCTFail("UNABLE TO CONNECT") }
        if case .unableToConnect = error(["BUS INIT: ...ERROR"]) {} else { XCTFail("BUS INIT") }
        if case .unknownCommand = error(["?"]) {} else { XCTFail("?") }
        if case .bufferFull = error(["7E8 10 14 49 02 01 31 4E 34", "BUFFER FULL"]) {} else { XCTFail("BUFFER FULL") }
        if case .stopped = error(["STOPPED"]) {} else { XCTFail("STOPPED") }
        if case .busError = error(["CAN ERROR"]) {} else { XCTFail("CAN ERROR") }
        if case .busError = error(["7E8 06 41 00 BE 3F <DATA ERROR"]) {} else { XCTFail("DATA ERROR") }
        if case .busError = error(["ERR94"]) {} else { XCTFail("ERR94") }

        XCTAssertEqual(error(["CAN ERROR"])?.isTransient, true)
        XCTAssertEqual(error(["NO DATA"])?.isTransient, false)
    }

    func testInterpret() throws {
        let parser = ISO_15765_4_11bit_500k()

        // "response pending" is followed by the real answer
        let answers = try ELM327.interpret(["7E8 03 7F 22 78", "7E8 04 62 11 54 7D"], request: "221154", parser: parser)
        XCTAssertEqual(answers.map(\.payload), [Data([0x62, 0x11, 0x54, 0x7D])])

        XCTAssertThrowsError(try ELM327.interpret(["7E8 03 7F 22 31"], request: "221154", parser: parser)) { error in
            guard case let ELM327Error.negativeResponse(service, code) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(service, 0x22)
            XCTAssertEqual(code, 0x31)
            XCTAssertTrue(error.localizedDescription.contains("request out of range"))
        }

        // an answer to something else is not an answer
        XCTAssertThrowsError(try ELM327.interpret(["7E8 03 41 0D 32"], request: "221154", parser: parser))
        XCTAssertThrowsError(try ELM327.interpret(["OK"], request: "0100", parser: parser)) { error in
            guard case ELM327Error.noData = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testTransientErrorsAreRetried() async throws {
        var attempts = 0
        let comm = ScriptedComm { command in
            if let answer = ScriptedComm.adapterAnswer(command, protocolNumber: "6") { return answer }
            if command == "0100" { return ["7E8 06 41 00 98 18 00 00"] }
            if command == "010D" {
                attempts += 1
                return attempts < 3 ? ["BUS BUSY"] : ["7E8 03 41 0D 32"]
            }
            return ["NO DATA"]
        }
        let sut = ELM327(comm: comm)
        try await sut.adapterInitialization()
        _ = try await sut.setupVehicle(preferredProtocol: .protocol6)

        let messages = try await sut.request("010D", retries: 3)
        XCTAssertEqual(messages.first?.payload, Data([0x41, 0x0D, 0x32]))
        XCTAssertEqual(attempts, 3)
    }

    // MARK: - Addressing

    func testTargetedRequestSetsAndRestoresTheHeader() async throws {
        let (sut, comm) = try await makeAdapter()
        _ = try await sut.setupVehicle(preferredProtocol: .protocol6)
        let before = comm.history.count

        let target = ECUTarget(header: "7e0")
        let answers = try await sut.request("221154", target: target)
        XCTAssertEqual(answers.first?.payload, Data([0x62, 0x11, 0x54, 0x7D]))
        XCTAssertEqual(answers.first?.ecu, .engine)

        // staying on the same ECU costs nothing
        _ = try await sut.request("221154", target: target)
        _ = try await sut.request("010C")

        XCTAssertEqual(Array(comm.history.dropFirst(before)), [
            "ATSH7E0", "ATCRA7E8", "ATFCSH7E0", "ATFCSD300000", "ATFCSM1", "221154",
            "221154",
            "ATSH7DF", "ATFCSM0", "ATAR", "010C",
        ])
    }

    func testTargetOn29BitBus() async throws {
        let (sut, comm) = try await makeAdapter { $0.vehicleProtocol = .protocol7 }
        _ = try await sut.setupVehicle(preferredProtocol: nil)
        let before = comm.history.count

        let answers = try await sut.request("22F190", target: ECUTarget(header: "18DA10F1"))
        XCTAssertEqual(answers.first?.payload.prefix(3), Data([0x62, 0xF1, 0x90]))
        XCTAssertEqual(Array(comm.history.dropFirst(before).prefix(3)), ["ATCP18", "ATSHDA10F1", "ATCRA18DAF110"])
    }

    func testReceiveAddressDerivation() {
        XCTAssertEqual(ECUTarget(header: "7E0").canReceiveAddress, "7E8")
        XCTAssertEqual(ECUTarget(header: "760").canReceiveAddress, "768")
        XCTAssertEqual(ECUTarget(header: "18DA10F1").canReceiveAddress, "18DAF110")
        XCTAssertEqual(ECUTarget(header: "6F1", receiveAddress: "612").canReceiveAddress, "612")
        XCTAssertNil(ECUTarget(header: "8110F1").canReceiveAddress)
    }

    func testRequestsAreSerialised() async throws {
        let (sut, _) = try await makeAdapter { $0.responseDelay = 0.005 }
        _ = try await sut.setupVehicle(preferredProtocol: .protocol6)

        // Concurrent callers must each get the answer to their own request.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 30 {
                group.addTask {
                    let pid: UInt8 = index % 2 == 0 ? 0x0C : 0x0D
                    let messages = try await sut.request([0x01, pid].hexString)
                    XCTAssertEqual(ELM327.engineFirst(messages).first?.payload[1], pid)
                }
            }
            try await group.waitForAll()
        }
    }

    func testPIDExtractor() {
        let response = ["86 F1 10 41 00 BF 9F E8 91 9F ", "86 F1 1A 41 00 88 18 80 10 02 "]
        guard let data = try? ISO_14230_4_KWP_Fast().parse(response).first?.data else {
            XCTFail("Expected data to be not nil")
            return
        }
        let binaryData = BitArray(data: data.dropFirst()).binaryArray
        let sut = ELM327(comm: MOCKComm())

        XCTAssertEqual(sut.extractSupportedPIDs(binaryData).contains("0C"), true)
        XCTAssertEqual(sut.extractSupportedPIDs(binaryData).contains("02"), false)
        XCTAssertEqual(sut.extractSupportedPIDs(binaryData, offset: 0x20).contains("2C"), true)
    }
}
