//
//  OBDServiceTests.swift
//  SwiftOBD2Tests
//
//  End to end tests of the public API against the simulated vehicle.
//

import Combine
@testable import SwiftOBD2
import XCTest

final class OBDServiceTests: XCTestCase {
    // MARK: - Connection

    func testDemoConnection() async throws {
        let service = OBDService(connectionType: .demo)
        let info = try await service.startConnection()

        XCTAssertEqual(info.obdProtocol, .protocol6)
        XCTAssertEqual(info.vin, "1N4AL3AP7DC199583")
        XCTAssertEqual(service.vehicleInfo, info)

        // the published state is updated on the main queue
        let connected = expectation(description: "connected to vehicle")
        let cancellable = service.$connectionState.sink { if $0 == .connectedToVehicle { connected.fulfill() } }
        await fulfillment(of: [connected], timeout: 2)
        cancellable.cancel()

        service.stopConnection()
        await assertThrowsAsync(try await service.requestPIDs([.mode1(.rpm)]))
    }

    func testRequestsFailBeforeConnecting() async {
        let service = OBDService(connectionType: .demo)
        await assertThrowsAsync(try await service.requestPIDs([.mode1(.rpm)])) { error in
            guard case OBDServiceError.notConnectedToVehicle = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Live data

    func testRequestPIDsGroupsRequests() async throws {
        let (service, mock) = try await makeConnectedService()
        let before = mock.history.count
        let commands: [OBDCommand] = [
            .mode1(.rpm), .mode1(.speed), .mode1(.coolantTemp), .mode1(.fuelLevel),
            .mode1(.engineLoad), .mode1(.throttlePos), .mode1(.intakeTemp), .mode1(.controlModuleVoltage),
        ]

        let values = try await service.requestPIDs(commands)

        XCTAssertEqual(Set(values.keys), Set(commands))
        XCTAssertEqual(try XCTUnwrap(values[.mode1(.rpm)]).value, 2200, accuracy: 1400)
        XCTAssertEqual(values[.mode1(.rpm)]?.unit, Unit.rpm)
        XCTAssertEqual(try XCTUnwrap(values[.mode1(.coolantTemp)]).value, 90, accuracy: 6)
        XCTAssertEqual(values[.mode1(.coolantTemp)]?.unit, UnitTemperature.celsius)
        XCTAssertEqual(try XCTUnwrap(values[.mode1(.fuelLevel)]).value, 62, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(values[.mode1(.controlModuleVoltage)]).value, 14, accuracy: 0.5)

        // 8 PIDs → one request of 6 and one of 2
        XCTAssertEqual(Array(mock.history.dropFirst(before)), ["010C0D052F0411", "010F42"])
    }

    func testUnsupportedPIDsAreLeftOut() async throws {
        let (service, mock) = try await makeConnectedService()
        let before = mock.history.count

        let values = try await service.requestPIDs([.mode1(.rpm), .mode1(.fuelPressure), .mode1(.speed), .mode9(.VIN)])

        XCTAssertEqual(Set(values.keys), [.mode1(.rpm), .mode1(.speed)])
        XCTAssertEqual(mock.history.dropFirst(before).first, "010C0A0D")
        XCTAssertFalse(mock.history.dropFirst(before).contains("010A"), "a PID missing from a rich answer is unsupported")
    }

    func testFallbackWhenGroupedRequestsAreNotSupported() async throws {
        let (service, mock) = try await makeConnectedService { $0.supportsGroupedRequests = false }
        let commands: [OBDCommand] = [.mode1(.rpm), .mode1(.speed), .mode1(.coolantTemp)]

        let first = try await service.requestPIDs(commands)
        XCTAssertEqual(Set(first.keys), Set(commands))

        // once detected, the vehicle is no longer asked for several PIDs at once
        let before = mock.history.count
        let second = try await service.requestPIDs(commands)
        XCTAssertEqual(Set(second.keys), Set(commands))
        XCTAssertEqual(Array(mock.history.dropFirst(before)), ["010C", "010D", "0105"])
    }

    func testImperialUnits() async throws {
        let (service, _) = try await makeConnectedService()
        let values = try await service.requestPIDs([.mode1(.speed), .mode1(.coolantTemp), .mode1(.intakePressure)], unit: .imperial)

        XCTAssertEqual(values[.mode1(.speed)]?.unit, UnitSpeed.milesPerHour)
        XCTAssertEqual(values[.mode1(.coolantTemp)]?.unit, UnitTemperature.fahrenheit)
        XCTAssertEqual(try XCTUnwrap(values[.mode1(.coolantTemp)]).value, 194, accuracy: 11)
        XCTAssertEqual(values[.mode1(.intakePressure)]?.unit, UnitPressure.poundsForcePerSquareInch)
    }

    func testTwoECUsAnsweringTheSamePID() async throws {
        let (service, mock) = try await makeConnectedService()
        // Both the engine and the transmission report the vehicle speed.
        let messages = try await service.request("010D")
        XCTAssertEqual(messages.map(\.ecu), [.engine, .transmission])

        let values = try await service.requestPIDs([.mode1(.speed)])
        XCTAssertNotNil(values[.mode1(.speed)])
        XCTAssertEqual(mock.history.last, "010D")
    }

    func testSingleResponseOptimisation() async throws {
        let (service, mock) = try await makeConnectedService()
        service.configuration.stopsAfterFirstResponse = true
        service.configuration.maxPIDsPerRequest = 1

        let values = try await service.requestPIDs([.mode1(.rpm), .mode1(.speed)])
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(Array(mock.history.suffix(2)), ["010C1", "010D1"])
    }

    func testSendCommand() async throws {
        let (service, _) = try await makeConnectedService()

        let vin = try await service.decoded(.mode9(.VIN)).stringResult
        XCTAssertEqual(vin, "1N4AL3AP7DC199583")
        let calibration = try await service.decoded(.mode9(.CALIBRATION_ID)).stringResult
        XCTAssertEqual(calibration, "SWIFTOBD2-CAL01")
        let fuelType = try await service.decoded(.mode1(.fuelType)).stringResult
        XCTAssertEqual(fuelType, "Gasoline")
        let compliance = try await service.decoded(.mode1(.obdcompliance)).stringResult
        XCTAssertEqual(compliance, "EOBD (Europe)")
        let pressure = try await service.decoded(.mode1(.barometricPressure)).measurementResult
        XCTAssertEqual(pressure, MeasurementResult(value: 101, unit: UnitPressure.kilopascals))
        let codes = try await service.decoded(.mode3(.GET_DTC)).troubleCode
        XCTAssertEqual(codes?.map(\.code), ["P0104"])
        let voltage = try await service.decoded(.general(.ATRV)).stringResult
        XCTAssertEqual(voltage?.hasSuffix("V"), true)

        let monitor = try await service.decoded(.mode6(.MONITOR_O2_B1S1)).measurementMonitor
        XCTAssertEqual(monitor?.tests.count, 2)

        // unsupported by the vehicle
        let unsupported = try await service.sendCommand(.mode1(.fuelPressure))
        guard case .failure(.noData) = unsupported else {
            return XCTFail("Expected no data")
        }
    }

    func testLiveDataStream() async throws {
        let (service, _) = try await makeConnectedService()
        var rounds = 0

        for try await values in service.liveData([.mode1(.rpm), .mode1(.speed)], interval: 0.01) {
            XCTAssertEqual(values.count, 2)
            rounds += 1
            if rounds == 3 { break }
        }
        XCTAssertEqual(rounds, 3)
    }

    func testLiveDataEndsWhenTheConnectionIsLost() async throws {
        let (service, mock) = try await makeConnectedService()
        var rounds = 0

        do {
            for try await _ in service.liveData([.mode1(.rpm)], interval: 0.01) {
                rounds += 1
                if rounds == 2 { mock.disconnectPeripheral() }
            }
            XCTFail("The stream should have failed")
        } catch {
            XCTAssertTrue(OBDService.isConnectionLost(error), "\(error)")
        }
        XCTAssertGreaterThanOrEqual(rounds, 2)
    }

    func testContinuousUpdatesPublisher() async throws {
        let (service, mock) = try await makeConnectedService()
        let received = expectation(description: "three rounds, including the PID added on the fly")
        var rounds = 0
        var sawAddedPID = false

        let cancellable = service.startContinuousUpdates([.mode1(.rpm)], interval: 0.01)
            .sink(receiveCompletion: { _ in }, receiveValue: { values in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertNotNil(values[.mode1(.rpm)])
                rounds += 1
                if rounds == 1 { service.addPID(.mode1(.speed)) }
                if values[.mode1(.speed)] != nil { sawAddedPID = true }
                if rounds >= 3, sawAddedPID { received.fulfill() }
            })
        await fulfillment(of: [received], timeout: 5)

        // cancelling the subscription stops the polling
        cancellable.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = mock.history.count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mock.history.count, count)
    }

    // MARK: - Diagnostics

    func testTroubleCodes() async throws {
        let (service, _) = try await makeConnectedService()

        let stored = try await service.scanForTroubleCodes()
        XCTAssertEqual(stored[.engine], [TroubleCode(code: "P0104", description: "Mass or Volume Air Flow Circuit Intermittent")])
        XCTAssertEqual(stored[.transmission]?.map(\.code), ["U0207"])

        let pending = try await service.scanForTroubleCodes(.pending)
        XCTAssertEqual(pending[.engine]?.map(\.code), ["P0171"])
        XCTAssertEqual(pending[.engine]?.first?.kind, .pending)
        XCTAssertEqual(pending[.transmission], [])

        let permanent = try await service.scanForTroubleCodes(.permanent)
        XCTAssertEqual(permanent, [.engine: []])

        let all = try await service.scanForAllTroubleCodes()
        XCTAssertEqual(all[.engine]?.map(\.code), ["P0104", "P0171"])
        XCTAssertEqual(all[.engine]?.map(\.kind), [.stored, .pending])
    }

    func testTroubleCodesWithPaddedFrames() async throws {
        // ECUs padding with 0x55 must not produce phantom codes.
        let (service, _) = try await makeConnectedService { $0.paddingByte = 0x55 }
        let stored = try await service.scanForTroubleCodes()
        XCTAssertEqual(stored[.engine]?.map(\.code), ["P0104"])
    }

    func testClearTroubleCodes() async throws {
        let (service, _) = try await makeConnectedService()

        try await service.clearTroubleCodes()

        let stored = try await service.scanForTroubleCodes()
        XCTAssertEqual(stored, [.engine: [], .transmission: []])
        let status = try await service.decoded(.mode1(.status)).statusResult ?? Status()
        XCTAssertFalse(status.MIL)
        XCTAssertEqual(status.dtcCount, 0)
        let freezeFrame = try await service.getFreezeFrame()
        XCTAssertNil(freezeFrame)
    }

    func testStatusSinceDTCCleared() async throws {
        let (service, _) = try await makeConnectedService()
        let report = try await service.getStatusSinceDTCCleared()

        XCTAssertTrue(report.status.MIL)
        XCTAssertEqual(report.status.dtcCount, 1)
        XCTAssertEqual(report.status.ignitionType, "Spark")
        XCTAssertEqual(report.status.incompleteMonitors.map(\.name), ["CATALYST_MONITORING", "EVAPORATIVE_SYSTEM_MONITORING"])
        XCTAssertFalse(report.status.isReadyForInspection)
        XCTAssertEqual(report.driveCycleStatus?.MIL, false)
        XCTAssertEqual(report.warmUpsSinceCleared, 12)
        XCTAssertEqual(report.distanceSinceCleared, MeasurementResult(value: 1250, unit: UnitLength.kilometers))
        XCTAssertEqual(report.timeSinceCleared, MeasurementResult(value: 2100, unit: UnitDuration.minutes))
        XCTAssertEqual(report.distanceWithMIL?.value, 42)
        XCTAssertEqual(report.timeWithMIL?.value, 35)
    }

    func testFreezeFrame() async throws {
        let (service, _) = try await makeConnectedService()
        let stored = try await service.getFreezeFrame()
        let freezeFrame = try XCTUnwrap(stored)

        XCTAssertEqual(freezeFrame.troubleCode.code, "P0104")
        XCTAssertEqual(Set(freezeFrame.values.keys), [
            .mode1(.engineLoad), .mode1(.coolantTemp), .mode1(.intakePressure), .mode1(.rpm), .mode1(.speed), .mode1(.throttlePos),
        ])
        XCTAssertEqual(freezeFrame.values[.mode1(.rpm)]?.value, 2400)
        XCTAssertEqual(freezeFrame.values[.mode1(.speed)]?.value, 72)
        XCTAssertEqual(freezeFrame.values[.mode1(.coolantTemp)]?.value, 86)
        XCTAssertEqual(try XCTUnwrap(freezeFrame.values[.mode1(.engineLoad)]).value, 60, accuracy: 0.1)

        let subset = try await service.getFreezeFrame([.mode1(.rpm)], unit: .imperial)
        XCTAssertEqual(subset?.values.keys.map { $0 }, [.mode1(.rpm)])
    }

    func testMonitorTestResults() async throws {
        let (service, _) = try await makeConnectedService()
        let monitors = try await service.getMonitorTestResults()

        XCTAssertEqual(monitors.map(\.mid), [0x01, 0x21])

        let oxygenSensor = monitors[0]
        XCTAssertEqual(oxygenSensor.name, "O2 Sensor Monitor Bank 1 - Sensor 1")
        XCTAssertEqual(try XCTUnwrap(oxygenSensor.tests[0x01]?.value).value, 365, accuracy: 0.1)
        XCTAssertEqual(oxygenSensor.tests[0x01]?.value?.unit, UnitElectricPotentialDifference.millivolts)
        XCTAssertEqual(oxygenSensor.tests[0x05]?.value?.value, 72)
        XCTAssertEqual(oxygenSensor.tests[0x05]?.max, 100)
        XCTAssertTrue(oxygenSensor.passed)

        let catalyst = monitors[1]
        XCTAssertEqual(catalyst.name, "Catalyst Monitor Bank 1")
        XCTAssertEqual(try XCTUnwrap(catalyst.tests[0x80]?.value).value, 0.5625, accuracy: 0.0001)
        XCTAssertFalse(catalyst.passed)
    }

    func testOnBoardTestAndVoltage() async throws {
        let (service, mock) = try await makeConnectedService()

        let answer = try await service.requestOnBoardTest()
        XCTAssertEqual(answer, Data([0, 0, 0, 0, 0]))
        XCTAssertEqual(mock.history.last, "08010000000000")

        let voltage = try await service.getVoltage()
        XCTAssertEqual(voltage, 13.8, accuracy: 0.5)
    }

    // MARK: - Manufacturer specific

    func testCustomCommands() async throws {
        let (service, mock) = try await makeConnectedService()
        mock.customResponses["22115A"] = [0x01, 0x90]
        let oilTemperature = OBDCommand.custom(CustomCommand(name: "Oil temperature", request: "221154", formula: "A-40", unit: "°C", header: "7E0"))
        let boost = OBDCommand.custom(CustomCommand(name: "Boost", request: "22115A", formula: "(A*256+B)/10", unit: "kPa", header: "7E0"))
        let broadcast = OBDCommand.custom(CustomCommand(name: "Oil temperature (broadcast)", request: "221154", formula: "A-40"))
        let unknown = OBDCommand.custom(CustomCommand(name: "Unknown", request: "22FFFF", formula: "A", header: "7E0"))
        let before = mock.history.count

        let values = try await service.requestPIDs([oilTemperature, .mode1(.rpm), boost, unknown, broadcast])

        XCTAssertEqual(values[oilTemperature]?.value, 85)
        XCTAssertEqual(values[oilTemperature]?.unit.symbol, "°C")
        XCTAssertEqual(values[boost]?.value, 40)
        XCTAssertEqual(values[broadcast]?.value, 85)
        XCTAssertNotNil(values[.mode1(.rpm)])
        XCTAssertNil(values[unknown], "refused by the ECU")

        // standard PIDs first, then the custom ones grouped by ECU: the header is set only once
        let sent = Array(mock.history.dropFirst(before))
        XCTAssertEqual(sent.first, "010C")
        XCTAssertEqual(sent.filter { $0.hasPrefix("ATSH") }, ["ATSH7E0"])

        let single = try await service.decoded(oilTemperature).measurementResult
        XCTAssertEqual(single?.value, 85)
    }

    func testRawRequests() async throws {
        let (service, _) = try await makeConnectedService()

        let answers = try await service.request("22 F1 90", to: .engine)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers[0].hexString.prefix(8), "62 F1 90")
        XCTAssertEqual(String(decoding: answers[0].payload.dropFirst(3), as: UTF8.self), "1N4AL3AP7DC199583")

        await assertThrowsAsync(try await service.request("22FFFF", to: .engine)) { error in
            guard case let OBDServiceError.commandFailed(_, underlying) = error,
                  case let ELM327Error.negativeResponse(service, code) = underlying
            else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(service, 0x22)
            XCTAssertEqual(code, 0x31)
        }

        let lines = try await service.sendCommandInternal("ATDPN", retries: 1)
        XCTAssertEqual(lines, ["A6"], "found by the automatic search")
    }

    func testManufacturerTroubleCodes() async throws {
        let (service, _) = try await makeConnectedService()

        let codes = try await service.scanForTroubleCodes(on: .engine)
        XCTAssertEqual(codes.map(\.code), ["P0104", "P0171"])
        XCTAssertEqual(codes.map(\.kind), [.stored, .pending])
        XCTAssertEqual(codes.map(\.statusByte), [0x09, 0x04])
        XCTAssertEqual(codes.first?.failureType, 0x00)

        try await service.clearTroubleCodes(on: .engine)
        let remaining = try await service.scanForTroubleCodes(on: .engine)
        XCTAssertTrue(remaining.isEmpty)

        // the transmission of the simulated vehicle does not speak UDS
        await assertThrowsAsync(try await service.scanForTroubleCodes(on: .transmission))
    }

    // MARK: - Data logging

    func testDataLogger() async throws {
        let (service, _) = try await makeConnectedService()
        let fileURL = temporaryDirectory().appendingPathComponent("swiftobd2-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let boost = OBDCommand.custom(CustomCommand(name: "Oil, temperature", request: "221154", formula: "A-40", unit: "°C"))
        let logger = OBDDataLogger(service: service)
        let finished = expectation(description: "recording finished")
        logger.onFinish = { error in
            XCTAssertNil(error)
            finished.fulfill()
        }

        try logger.start([.mode1(.rpm), .mode1(.speed), boost, .mode1(.fuelPressure)], interval: 0.01, fileURL: fileURL)
        while logger.samples.count < 4 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        logger.stop()
        await fulfillment(of: [finished], timeout: 2)

        let samples = logger.samples
        XCTAssertGreaterThanOrEqual(samples.count, 4)
        XCTAssertEqual(samples.map(\.elapsed), samples.map(\.elapsed).sorted())
        XCTAssertEqual(samples[0].values[boost]?.value, 85)

        let rows = logger.csv().split(separator: "\n").map(String.init)
        XCTAssertEqual(rows[0], "timestamp,elapsed_s,RPM (rpm),Vehicle Speed (km/h),\"Oil, temperature (°C)\",Fuel Pressure")
        XCTAssertEqual(rows.count, samples.count + 1)
        let fields = rows[1].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, 6)
        XCTAssertEqual(fields[4], "85")
        XCTAssertEqual(fields[5], "", "unsupported PID: empty column")
        XCTAssertNotNil(Double(fields[2]))

        // the file was written as the samples came in
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), logger.csv())

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: logger.json()) as? [String: Any])
        XCTAssertEqual((json["columns"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual((json["samples"] as? [[String: Any]])?.count, samples.count)

        // a stopped logger no longer records
        let count = logger.samples.count
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(logger.samples.count, count)
        XCTAssertThrowsError(try OBDDataLogger(service: OBDService(connectionType: .demo)).start([.mode1(.rpm)]))
    }
}
