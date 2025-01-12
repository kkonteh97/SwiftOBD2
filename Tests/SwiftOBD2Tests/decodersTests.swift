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
        let tests = [Data([0x00, 0x00]): MeasurementResult(value: -210, unit: UnitPressure.degrees),
                     Data([0xFF, 0xFF]): MeasurementResult(value: 301, unit: UnitPressure.degrees)]
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
}
