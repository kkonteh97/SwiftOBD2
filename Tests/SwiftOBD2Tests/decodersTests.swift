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
        XCTAssertEqual(percent(Data([0x00])), MeasurementResult(value: 0, unit: Unit.percent))
        XCTAssertEqual(percent(Data([0xFF])), MeasurementResult(value: 100, unit: Unit.percent))
    }

    func testPercentCentered() {
        XCTAssertEqual(percentCentered(Data([0x00])), MeasurementResult(value: -100, unit: Unit.percent))
        XCTAssertEqual(percentCentered(Data([0x80])), MeasurementResult(value: 0, unit: Unit.percent))
        XCTAssertEqual(percentCentered(Data([0xFF]))!.value, MeasurementResult(value: 100, unit: Unit.percent).value, accuracy: 1)
    }

    func testTemp() {
        XCTAssertEqual(decodeTemp(Data([0x00])), MeasurementResult(value: -40, unit: UnitTemperature.celsius))
        XCTAssertEqual(decodeTemp(Data([0xFF])), MeasurementResult(value: 215, unit: UnitTemperature.celsius))
        XCTAssertEqual(decodeTemp(Data([0x03, 0xE8])), MeasurementResult(value: 960, unit: UnitTemperature.celsius))
    }

    func testCurrentCentered() {
        XCTAssertEqual(currentCentered(Data([0x00, 0x00, 0x00, 0x00])), MeasurementResult(value: -128, unit: UnitElectricCurrent.milliamperes))
        XCTAssertEqual(currentCentered(Data([0x00, 0x00, 0x80, 0x00])), MeasurementResult(value: 0, unit: UnitElectricCurrent.milliamperes))
        XCTAssertEqual(currentCentered(Data([0x00, 0x00, 0xFF, 0xFF]))!.value, 128.0, accuracy: 0.01)
    }

    func testSensorVoltage() {
        XCTAssertEqual(sensorVoltage(Data([0x00, 0x00])), MeasurementResult(value: 0, unit: UnitElectricPotentialDifference.volts))
        XCTAssertEqual(sensorVoltage(Data([0xFF, 0xFF])), MeasurementResult(value: 1.275, unit: UnitElectricPotentialDifference.volts))
    }

    func testSensorVoltageBig() {
        XCTAssertEqual(sensorVoltageBig(Data([0x00, 0x00, 0x00, 0x00])), MeasurementResult(value: 0, unit: UnitElectricPotentialDifference.volts))
        XCTAssertEqual(sensorVoltageBig(Data([0x00, 0x00, 0x80, 0x00]))!.value, 4, accuracy: 0.01)
        XCTAssertEqual(sensorVoltageBig(Data([0x00, 0x00, 0xFF, 0xFF])), MeasurementResult(value: 8, unit: UnitElectricPotentialDifference.volts))
    }

    func testFuelPressure() {
        XCTAssertEqual(fuelPressure(Data([0x00])), MeasurementResult(value: 0, unit: UnitPressure.kilopascals))
        XCTAssertEqual(fuelPressure(Data([0x80])), MeasurementResult(value: 384, unit: UnitPressure.kilopascals))
        XCTAssertEqual(fuelPressure(Data([0xFF])), MeasurementResult(value: 765, unit: UnitPressure.kilopascals))
    }

    func testPressure() {
        XCTAssertEqual(pressure(Data([0x00])), MeasurementResult(value: 0, unit: UnitPressure.kilopascals))
    }

    func testAbsEvapPressure() {
        XCTAssertEqual(absEvapPressure(Data([0x00, 0x00])), MeasurementResult(value: 0, unit: UnitPressure.kilopascals))
        XCTAssertEqual(absEvapPressure(Data([0xFF, 0xFF])), MeasurementResult(value: 327.675, unit: UnitPressure.kilopascals))
    }

    func testEvapPressureAlt() {
        XCTAssertEqual(evapPressureAlt(Data([0x00, 0x00])), MeasurementResult(value: -32767, unit: Unit.Pascal))
        XCTAssertEqual(evapPressureAlt(Data([0x7F, 0xFF])), MeasurementResult(value: 0, unit: Unit.Pascal))
        XCTAssertEqual(evapPressureAlt(Data([0xFF, 0xFF])), MeasurementResult(value: 32768, unit: Unit.Pascal))
    }

    func testTimingAdvance() {
        XCTAssertEqual(timingAdvance(Data([0x00])), MeasurementResult(value: -64, unit: UnitAngle.degrees))
        XCTAssertEqual(timingAdvance(Data([0xFF])), MeasurementResult(value: 63.5, unit: UnitAngle.degrees))
    }

    func testInjectTiming() {
        XCTAssertEqual(injectTiming(Data([0x00, 0x00])), MeasurementResult(value: -210, unit: UnitPressure.degrees))
        XCTAssertEqual(injectTiming(Data([0xFF, 0xFF]))!.value, 301, accuracy: 1)
    }

    func testStatus() {
        let status = decodeStatus(Data([0x00, 0x83, 0x07, 0xFF, 0x00]))
        XCTAssertEqual(status.MIL, true)
        XCTAssertEqual(status.dtcCount, 3)
        XCTAssertEqual(status.ignitionType, "Spark")
    }

    func testSingleDtc() {
        XCTAssertEqual(singleDtc(Data([0x01, 0x04])), TroubleCode(code: "P0104", description: "Mass or Volume Air Flow Circuit Intermittent"))
        XCTAssertEqual(singleDtc(Data([0x41, 0x23])), TroubleCode(code: "C0123", description: "No description available."))
        XCTAssertEqual(singleDtc(Data([0x01])), nil)
        XCTAssertEqual(singleDtc(Data([0x01, 0x04, 0x00])), nil)
    }

    func testDtc() {
        XCTAssertEqual(dtc(Data([0x01, 0x04])), [TroubleCode(code: "P0104", description: "Mass or Volume Air Flow Circuit Intermittent")])
        XCTAssertEqual(dtc(Data([0x01, 0x04, 0x80, 0x03, 0x41, 0x23]))!, [
            TroubleCode(code: "P0104", description: "Mass or Volume Air Flow Circuit Intermittent"),
            TroubleCode(code: "B0003", description: "No description available."),
            TroubleCode(code: "C0123", description: "No description available.")
        ])

        XCTAssertEqual(dtc(Data([0x01, 0x04, 0x80, 0x03, 0x41])), [
            TroubleCode(code: "P0104", description: "Mass or Volume Air Flow Circuit Intermittent"),
            TroubleCode(code: "B0003", description: "No description available.")
        ])

        XCTAssertEqual(dtc(Data([0x00, 0x00, 0x01, 0x04, 0x00, 0x00])), [
            TroubleCode(code: "P0104", description: "Mass or Volume Air Flow Circuit Intermittent")
        ])
    }

    func testMonitor() {
        let monitor = decodeMonitor(Data([0x01, 0x01, 0x0A, 0x0B, 0xB0, 0x0B, 0xB0, 0x0B, 0xB0]))
        guard let tests = monitor?.tests else {
            XCTFail()
            return
        }
        XCTAssertEqual(tests.count, 1)
        XCTAssertEqual(tests[0x01]?.name, "RTLThresholdVoltage")
        XCTAssertEqual(tests[0x01]!.value!.value, 365.0, accuracy: 0.1)
        XCTAssertEqual(tests[0x01]!.value!.unit, UnitElectricPotentialDifference.millivolts)
//        01 01 0A 0B B0 0B B0 0B B0 0105100048 00 00 00 640185240096004BFFFF
        let monitor2 = decodeMonitor(Data([0x01, 0x01, 0x0A, 0x0B, 0xB0, 0x0B, 0xB0, 0x0B, 0xB0, 0x01, 0x05, 0x10, 0x00, 0x48, 0x00, 0x00, 0x00, 0x64, 0x01, 0x85, 0x24, 0x00, 0x96, 0x00, 0x4B, 0xFF, 0xFF]))
        guard let tests2 = monitor2?.tests else {
            XCTFail()
            return
        }
        XCTAssertEqual(tests2.count, 3)
        XCTAssertEqual(tests2[0x01]?.name, "RTLThresholdVoltage")

        XCTAssertEqual(tests2[0x01]!.value!.value, 365.0, accuracy: 0.1)
        XCTAssertEqual(tests2[0x01]!.value!.unit, UnitElectricPotentialDifference.millivolts)
        XCTAssertEqual(tests2[0x01]!.value!.value, 365.0, accuracy: 0.1)

        XCTAssertEqual(tests2[0x05]?.name, "RTLSwitchTime")
        XCTAssertEqual(tests2[0x05]!.value!.value, 72, accuracy: 0.1)
        XCTAssertEqual(tests2[0x05]!.value!.unit, UnitDuration.milliseconds)
    }
}
