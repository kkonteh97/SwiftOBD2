//
//  decodersTests.swift
//
//
//  Created by kemo konteh on 2/28/24.
//

@testable import SwiftOBD2
import XCTest

final class decodersTests: XCTestCase {
    func testPercent() {
        let tests = [Data([0x00]): MeasurementResult(value: 0, unit: Unit.percent),
                     Data([0xFF]): MeasurementResult(value: 100, unit: Unit.percent)]
        for (data, expected) in tests {
            switch PercentDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 1)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPercentCentered() {
        let tests = [Data([0x00]): MeasurementResult(value: -100, unit: Unit.percent),
                     Data([0x80]): MeasurementResult(value: 0, unit: Unit.percent),
                     Data([0xFF]): MeasurementResult(value: 100, unit: Unit.percent)]
        for (data, expected) in tests {
            switch PercentCenteredDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 1)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTemp() {
        let tests = [Data([0x00]): MeasurementResult(value: -40, unit: UnitTemperature.celsius),
                     Data([0xFF]): MeasurementResult(value: 215, unit: UnitTemperature.celsius),
                     Data([0x03, 0xE8]): MeasurementResult(value: 960, unit: UnitTemperature.celsius)]
        for (data, expected) in tests {
            switch TemperatureDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 0.01)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCurrentCentered() {
        let tests = [Data([0x00, 0x00, 0x00, 0x00]): MeasurementResult(value: -128, unit: UnitElectricCurrent.milliamperes),
                     Data([0x00, 0x00, 0x80, 0x00]): MeasurementResult(value: 0, unit: UnitElectricCurrent.milliamperes),
                     Data([0xFF, 0x00, 0xFF, 0xFF]): MeasurementResult(value: 128, unit: UnitElectricCurrent.milliamperes)]
        for (data, expected) in tests {
            switch CurrentCenteredDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 0.01)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSensorVoltage() {
        let tests = [Data([0x00, 0x00]): MeasurementResult(value: 0, unit: UnitElectricPotentialDifference.volts),
                     Data([0xFF, 0xFF]): MeasurementResult(value: 1.275, unit: UnitElectricPotentialDifference.volts)]
        for (data, expected) in tests {
            switch SensorVoltageDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 0.01)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSensorVoltageBig() {
        let tests = [Data([0x00, 0x00, 0x00, 0x00]): MeasurementResult(value: 0, unit: UnitElectricPotentialDifference.volts),
                     Data([0x00, 0x00, 0x80, 0x00]): MeasurementResult(value: 4, unit: UnitElectricPotentialDifference.volts),
                     Data([0x00, 0x00, 0xFF, 0xFF]): MeasurementResult(value: 8, unit: UnitElectricPotentialDifference.volts)]
        for (data, expected) in tests {
            switch SensorVoltageBigDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 0.01)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFuelPressure() {
        let tests = [Data([0x00]): MeasurementResult(value: 0, unit: UnitPressure.kilopascals),
                     Data([0x80]): MeasurementResult(value: 384, unit: UnitPressure.kilopascals),
                     Data([0xFF]): MeasurementResult(value: 765, unit: UnitPressure.kilopascals)]
        for (data, expected) in tests {
            switch FuelPressureDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 0.01)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
//
    func testPressure() {
        let tests = [Data([0x00]): MeasurementResult(value: 0, unit: UnitPressure.kilopascals),
//                     Data([0x80]): MeasurementResult(value: 0.5, unit: UnitPressure.kilopascals),
//                     Data([0xFF]): MeasurementResult(value: 1, unit: UnitPressure.kilopascals)
        ]
        for (data, expected) in tests {
            switch PressureDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 0.01)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAbsEvapPressure() {
        let tests = [Data([0x00, 0x00]): MeasurementResult(value: 0, unit: UnitPressure.kilopascals),
                     Data([0xFF, 0xFF]): MeasurementResult(value: 327.675, unit: UnitPressure.kilopascals)]
        for (data, expected) in tests {
            switch AbsEvapPressureDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 0.01)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
//
    func testEvapPressureAlt() {
        let tests = [Data([0x00, 0x00]): MeasurementResult(value: -32767, unit: Unit.Pascal),
                     Data([0x7F, 0xFF]): MeasurementResult(value: 0, unit: Unit.Pascal),
                     Data([0xFF, 0xFF]): MeasurementResult(value: 32768, unit: Unit.Pascal)]
        for (data, expected) in tests {
            switch EvapPressureAltDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 1)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTimingAdvance() {
        let tests = [Data([0x00]): MeasurementResult(value: -64, unit: UnitAngle.degrees),
                     Data([0xFF]): MeasurementResult(value: 63.5, unit: UnitAngle.degrees)]
        for (data, expected) in tests {
            switch TimingAdvanceDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 1)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInjectTiming() {
        let tests = [Data([0x00, 0x00]): MeasurementResult(value: -210, unit: UnitAngle.degrees),
                     Data([0xFF, 0xFF]): MeasurementResult(value: 301, unit: UnitAngle.degrees)]
        for (data, expected) in tests {
            switch InjectTimingDecoder().decode(data: data, unit: .metric) {
            case let .success(result):
                XCTAssertEqual(result.measurementResult!.value, expected.value, accuracy: 1)
                XCTAssertEqual(result.measurementResult!.unit, expected.unit)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStatus() {
        let statusResult = StatusDecoder().decode(data: Data([0x00, 0x83, 0x07, 0xFF, 0x00]), unit: .metric)
        switch statusResult {
        case let .success(status):
            XCTAssertEqual(status.statusResult?.MIL, false)
            XCTAssertEqual(status.statusResult?.dtcCount, 0)
            XCTAssertEqual(status.statusResult?.ignitionType, "Spark")
        case let .failure(error):
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSingleDtc() {
        let tests = [Data([0x01, 0x04]): TroubleCode(code: "P0104", description: "Mass or Volume Air Flow Circuit Intermittent"),
                     Data([0x41, 0x23]): TroubleCode(code: "C0123", description: "No description available."),
                     Data([0x01]): nil,
                     Data([0x01, 0x04, 0x00]): nil]

        for (data, expected) in tests {
            let result = SingleDTCDecoder().decode(data: data, unit: .metric)
            switch result {
            case let .success(dtc):
                XCTAssertEqual(dtc.troubleCode?.first, expected)
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDtc() {
        let tests = [
            Data([0x01, 0x04]):
                [
                    TroubleCode(code: "P0104", description: "Mass or Volume Air Flow Circuit Intermittent"),
                ],
            Data([0x01, 0x04, 0x80, 0x03, 0x41, 0x23]):
                [
                    TroubleCode(code: "P0104", description: "Mass or Volume Air Flow Circuit Intermittent"),
                    TroubleCode(code: "B0003", description: "No description available."),
                    TroubleCode(code: "C0123", description: "No description available."),
                ],
            Data([0x01, 0x04, 0x80, 0x03, 0x41]):
                [
                    TroubleCode(code: "P0104", description: "Mass or Volume Air Flow Circuit Intermittent"),
                    TroubleCode(code: "B0003", description: "No description available."),
                ],
            Data([0x00, 0x00, 0x01, 0x04, 0x00, 0x00]):
                [
                    TroubleCode(code: "P0104", description: "Mass or Volume Air Flow Circuit Intermittent"),
                ],
        ]

        for test in tests {
            let result = DTCDecoder().decode(data: test.key, unit: .metric)
            switch result {
            case let .success(troubleCodes):
                XCTAssertEqual(troubleCodes.troubleCode, test.value)
            case .failure:
                XCTFail()
            }
        }
    }

    func testMonitor() {
        let monitorResult = MonitorDecoder().decode(data: Data([0x01, 0x01, 0x0A, 0x0B, 0xB0, 0x0B, 0xB0, 0x0B, 0xB0]), unit: .metric)
        switch monitorResult {
        case let .success(monitor):
            guard let tests = monitor.measurementMonitor?.tests else {
                XCTFail()
                return
            }
            XCTAssertEqual(tests.count, 1)
            XCTAssertEqual(tests[0x01]?.name, "RTLThresholdVoltage")
            XCTAssertEqual(tests[0x01]!.value!.value, 365.0, accuracy: 0.1)
            XCTAssertEqual(tests[0x01]!.value!.unit, UnitElectricPotentialDifference.millivolts)
        default:
            XCTFail("Monitor decoding failed")
        }

//        01 01 0A 0B B0 0B B0 0B B0 0105100048 00 00 00 640185240096004BFFFF
        let monitorResult2 = MonitorDecoder().decode(data: Data([0x01, 0x01, 0x0A, 0x0B, 0xB0, 0x0B, 0xB0, 0x0B, 0xB0, 0x01, 0x05, 0x10, 0x00, 0x48, 0x00, 0x00, 0x00, 0x64, 0x01, 0x85, 0x24, 0x00, 0x96, 0x00, 0x4B, 0xFF, 0xFF]),  unit: .metric)

        switch monitorResult2 {
        case let .success(monitor):
            guard let tests = monitor.measurementMonitor?.tests else {
                XCTFail()
                return
            }
            XCTAssertEqual(tests.count, 3)
            XCTAssertEqual(tests[0x01]?.name, "RTLThresholdVoltage")
            XCTAssertEqual(tests[0x01]!.value!.value, 365.0, accuracy: 0.1)
            XCTAssertEqual(tests[0x01]!.value!.unit, UnitElectricPotentialDifference.millivolts)
            XCTAssertEqual(tests[0x01]!.value!.value, 365.0, accuracy: 0.1)
            XCTAssertEqual(tests[0x05]?.name, "RTLSwitchTime")
            XCTAssertEqual(tests[0x05]!.value!.value, 72, accuracy: 0.1)
            XCTAssertEqual(tests[0x05]!.value!.unit, UnitDuration.milliseconds)
        default:
            XCTFail("Monitor decoding failed")
        }
    }

    // MARK: - Readiness

    func testStatusMonitors() throws {
        // MIL on, 3 codes, spark ignition; catalyst and EVAP monitors incomplete
        let status = try XCTUnwrap(StatusDecoder().decode(data: Data([0x83, 0x07, 0xE5, 0x05]), unit: .metric).get().statusResult)

        XCTAssertTrue(status.MIL)
        XCTAssertEqual(status.dtcCount, 3)
        XCTAssertEqual(status.ignitionType, "Spark")
        XCTAssertTrue(status.misfireMonitoring.supported)
        XCTAssertTrue(status.misfireMonitoring.ready)
        XCTAssertEqual(status.monitors.count, 10)
        XCTAssertEqual(status.incompleteMonitors.map(\.name), ["CATALYST_MONITORING", "EVAPORATIVE_SYSTEM_MONITORING"])
        XCTAssertFalse(status.isReadyForInspection)
        XCTAssertEqual(status.monitors.first { $0.name == "SECONDARY_AIR_SYSTEM_MONITORING" }?.supported, false)
        XCTAssertEqual(status.monitors[3].title, "Catalyst Monitoring")
    }

    func testStatusCompressionIgnition() throws {
        // Diesel: fuel system monitor incomplete, particulate filter supported and complete
        let status = try XCTUnwrap(StatusDecoder().decode(data: Data([0x00, 0x2F, 0x40, 0x00]), unit: .metric).get().statusResult)

        XCTAssertFalse(status.MIL)
        XCTAssertEqual(status.ignitionType, "Compression")
        XCTAssertFalse(status.fuelSystemMonitoring.ready)
        XCTAssertEqual(status.monitors.filter(\.supported).map(\.name),
                       ["MISFIRE_MONITORING", "FUEL_SYSTEM_MONITORING", "COMPONENT_MONITORING", "PM_FILTER_MONITORING"])
        XCTAssertEqual(status.incompleteMonitors.map(\.name), ["FUEL_SYSTEM_MONITORING"])
    }

    func testStatusSurvivesOldArchives() throws {
        // Vehicles saved by earlier versions do not have the `monitors` key.
        let json = #"{"MIL":true,"dtcCount":2,"ignitionType":"Spark","misfireMonitoring":{"name":"MISFIRE_MONITORING","supported":true,"ready":true},"fuelSystemMonitoring":{"name":"","supported":false,"ready":false},"componentMonitoring":{"name":"","supported":false,"ready":false}}"#
        let status = try JSONDecoder().decode(Status.self, from: Data(json.utf8))
        XCTAssertTrue(status.MIL)
        XCTAssertEqual(status.dtcCount, 2)
        XCTAssertTrue(status.monitors.isEmpty)

        let code = try JSONDecoder().decode(TroubleCode.self, from: Data(#"{"code":"P0104","description":"x"}"#.utf8))
        XCTAssertEqual(code.kind, .stored)
    }

    func testShortDataNeverCrashes() {
        let decoders: [Decoders] = [
            .status, .temp, .percent, .percentCentered, .currentCentered, .airStatus, .singleDTC, .fuelStatus,
            .fuelPressure, .pressure, .timingAdvance, .obdCompliance, .o2SensorsAlt, .o2Sensors, .auxInputStatus,
            .sensorVoltage, .sensorVoltageBig, .evapPressure, .absoluteLoad, .maxMaf, .fuelType, .absEvapPressure,
            .evapPressureAlt, .injectTiming, .dtc, .fuelRate, .monitor, .encoded_string, .count, .torquePercent,
            .odometer, .uas(0x07), .uas(0xEE), .formula(expression: "A*256+B", unit: ""), .pid, .cvn, .none,
        ]
        for decoder in decoders {
            for data in [Data(), Data([0xFF]), Data([0xFF, 0xFF, 0xFF])] {
                // Slices keep the indices of their parent: a classic source of out-of-bounds accesses.
                _ = decoder.getDecoder()?.decode(data: data, unit: .metric)
                _ = decoder.getDecoder()?.decode(data: (Data([0x00, 0x00]) + data).dropFirst(2), unit: .imperial)
            }
        }
    }

    // MARK: - Scaling

    func testSignedValues() throws {
        // UAS 0x96: signed, 0.1 °C per bit
        let cold = try XCTUnwrap(UASDecoder(id: 0x96).decode(data: Data([0xFF, 0x9C]), unit: .metric).get().measurementResult)
        XCTAssertEqual(cold.value, -10, accuracy: 0.001)
        XCTAssertEqual(cold.unit, UnitTemperature.celsius)

        // PID 32: signed, a quarter of a pascal per bit
        let vacuum = try XCTUnwrap(EvapPressureDecoder().decode(data: Data([0xFF, 0xFC]), unit: .metric).get().measurementResult)
        XCTAssertEqual(vacuum.value, -1, accuracy: 0.001)
        XCTAssertEqual(vacuum.unit, Unit.Pascal)

        XCTAssertEqual(twosComp(0x7F, length: 8), 127)
        XCTAssertEqual(twosComp(0x80, length: 8), -128)
        XCTAssertEqual(twosComp(0xFFFF, length: 16), -1)
    }

    func testImperialConversionIsRepeatable() throws {
        let decoder = UASDecoder(id: 0x09) // vehicle speed, km/h
        for _ in 0 ..< 3 {
            let imperial = try XCTUnwrap(decoder.decode(data: Data([100]), unit: .imperial).get().measurementResult)
            XCTAssertEqual(imperial.value, 62.1371, accuracy: 0.001)
            XCTAssertEqual(imperial.unit, UnitSpeed.milesPerHour)

            let metric = try XCTUnwrap(decoder.decode(data: Data([100]), unit: .metric).get().measurementResult)
            XCTAssertEqual(metric.value, 100)
            XCTAssertEqual(metric.unit, UnitSpeed.kilometersPerHour)
        }

        let temperature = try XCTUnwrap(TemperatureDecoder().decode(data: Data([140]), unit: .imperial).get().measurementResult)
        XCTAssertEqual(temperature.value, 212, accuracy: 0.001)
        XCTAssertEqual(temperature.unit, UnitTemperature.fahrenheit)
    }

    func testMiscellaneousPIDs() throws {
        func value(_ command: OBDCommand.Mode1, _ bytes: [UInt8]) throws -> Double {
            try XCTUnwrap(command.properties.decode(data: Data(bytes)).get().measurementResult).value
        }
        func string(_ command: OBDCommand.Mode1, _ bytes: [UInt8]) throws -> String {
            try XCTUnwrap(command.properties.decode(data: Data(bytes)).get().stringResult)
        }

        XCTAssertEqual(try value(.rpm, [0x1A, 0xF8]), 1726)
        XCTAssertEqual(try value(.maxMAF, [0xFF, 0, 0, 0]), 2550)
        XCTAssertEqual(try value(.absoluteLoad, [0x00, 0xFF]), 100, accuracy: 0.001)
        XCTAssertEqual(try value(.fuelRate, [0x00, 0xC8]), 10, accuracy: 0.001)
        XCTAssertEqual(try value(.timeSinceDTCCleared, [0x08, 0x34]), 2100)
        XCTAssertEqual(try value(.demandTorque, [0x7D + 40]), 40)
        XCTAssertEqual(try value(.referenceTorque, [0x01, 0x90]), 400)
        XCTAssertEqual(try value(.odometer, [0x00, 0x01, 0x86, 0xA0]), 10000)
        XCTAssertEqual(try value(.commandedEquivRatio, [0x80, 0x00]), 1, accuracy: 0.001)
        XCTAssertEqual(try value(.evapVaporPressureAbs, [0x4E, 0x20]), 100, accuracy: 0.001)

        XCTAssertEqual(try string(.fuelType, [0x04]), "Diesel")
        XCTAssertEqual(try string(.obdcompliance, [0x06]), "EOBD (Europe)")
        XCTAssertEqual(try string(.fuelStatus, [0x02, 0x00]), "Status: Closed loop, using oxygen sensor feedback to determine fuel mix")
        XCTAssertEqual(try string(.airStatus, [0x04]), "From the outside atmosphere or off")
        XCTAssertEqual(try string(.O2Sensor, [0x03]), "[1, 1, 0, 0], [0, 0, 0, 0]")
        XCTAssertEqual(try string(.pidsA, [0xBE, 0x3F, 0xA8, 0x13]), "BE3FA813")
    }

    func testEveryStandardPIDHasALength() {
        for command in OBDCommand.Mode1.allCases {
            XCTAssertGreaterThan(command.properties.bytes, 0, command.properties.command)
        }
        XCTAssertEqual(OBDCommand.from(command: "010c"), .mode1(.rpm))
        XCTAssertEqual(OBDCommand.mode1(.rpm).service, 0x01)
        XCTAssertNil(OBDCommand.general(.ATZ).service)
    }

    func testTroubleCodeClassification() {
        XCTAssertEqual(TroubleCode(code: "P0301").description, "Cylinder 1 Misfire Detected")
        XCTAssertFalse(TroubleCode(code: "P0301").isManufacturerSpecific)
        XCTAssertTrue(TroubleCode(code: "P1234").isManufacturerSpecific)
        XCTAssertTrue(TroubleCode(code: "U2100").isManufacturerSpecific)
        XCTAssertFalse(TroubleCode(code: "P2096").isManufacturerSpecific)
    }
}
