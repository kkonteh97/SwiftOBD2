//
//  decoders.swift
//  SmartOBD2
//
//  Created by kemo konteh on 9/18/23.
//
//  Every decoder receives the data bytes of a response (A, B, C… in SAE J1979 notation), that is
//  the payload without the service and PID bytes.
//

import Foundation

/// The unit system used to decode measurements.
public enum MeasurementUnit: String, Codable {
    /// Metric units (km/h, °C, kPa…).
    case metric = "Metric"
    /// Imperial units (mph, °F, psi…).
    case imperial = "Imperial"

    /// Both unit systems.
    public static var allCases: [MeasurementUnit] {
        [.metric, .imperial]
    }
}

// MARK: - Readiness status

/// The answer to PID 01 (status since the trouble codes were cleared) or PID 41 (status for the
/// current drive cycle).
public struct Status: Codable, Hashable {
    /// `true` when the malfunction indicator lamp ("check engine") is commanded on.
    public var MIL: Bool = false
    /// Number of confirmed emission related trouble codes.
    public var dtcCount: UInt8 = 0
    /// `"Spark"` (petrol) or `"Compression"` (diesel).
    public var ignitionType: String = ""

    /// The misfire monitor.
    public var misfireMonitoring = StatusTest()
    /// The fuel system monitor.
    public var fuelSystemMonitoring = StatusTest()
    /// The comprehensive components monitor.
    public var componentMonitoring = StatusTest()

    /// Every monitor defined for this type of engine, continuous ones first.
    public var monitors: [StatusTest] = []

    /// An empty status.
    public init() {}

    /// The monitors the vehicle supports but that have not completed yet.
    public var incompleteMonitors: [StatusTest] {
        monitors.filter { $0.supported && !$0.ready }
    }

    /// `true` when the lamp is off and every supported monitor has run to completion: the usual
    /// prerequisite for an emissions inspection.
    public var isReadyForInspection: Bool {
        !MIL && incompleteMonitors.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case MIL, dtcCount, ignitionType, misfireMonitoring, fuelSystemMonitoring, componentMonitoring, monitors
    }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        MIL = try container.decodeIfPresent(Bool.self, forKey: .MIL) ?? false
        dtcCount = try container.decodeIfPresent(UInt8.self, forKey: .dtcCount) ?? 0
        ignitionType = try container.decodeIfPresent(String.self, forKey: .ignitionType) ?? ""
        misfireMonitoring = try container.decodeIfPresent(StatusTest.self, forKey: .misfireMonitoring) ?? StatusTest()
        fuelSystemMonitoring = try container.decodeIfPresent(StatusTest.self, forKey: .fuelSystemMonitoring) ?? StatusTest()
        componentMonitoring = try container.decodeIfPresent(StatusTest.self, forKey: .componentMonitoring) ?? StatusTest()
        monitors = try container.decodeIfPresent([StatusTest].self, forKey: .monitors) ?? []
    }
}

/// One on-board readiness monitor.
public struct StatusTest: Codable, Hashable {
    /// Identifier of the monitor, e.g. `CATALYST_MONITORING`.
    public var name: String = ""
    /// The vehicle implements this monitor.
    public var supported: Bool = false
    /// The monitor has run to completion.
    public var ready: Bool = false

    public init(_ name: String = "", _ supported: Bool = false, _ ready: Bool = false) {
        self.name = name
        self.supported = supported
        self.ready = ready
    }

    /// A human readable version of ``name`` ("Catalyst monitoring").
    public var title: String {
        name.replacingOccurrences(of: "_", with: " ").capitalized(with: nil)
    }
}

// MARK: - Bits

struct BitArray {
    let data: Data
    var binaryArray: [Int] {
        // Convert Data to binary array representation
        var result = [Int]()
        for byte in data {
            for i in 0 ..< 8 {
                // Extract each bit of the byte
                let bit = (byte >> (7 - i)) & 1
                result.append(Int(bit))
            }
        }
        return result
    }

    func index(of value: Int) -> Int? {
        // Find the index of the given value (1 or 0)
        return binaryArray.firstIndex(of: value)
    }

    func value(at range: Range<Int>) -> UInt8 {
        let bits = binaryArray
        var value: UInt8 = 0
        for bit in range where bit < bits.count {
            value = value << 1
            value = value | UInt8(bits[bit])
        }
        return value
    }
}

// MARK: - Units

extension Unit {
    static let percent = Unit(symbol: "%")
    static let count = Unit(symbol: "count")
    static let degrees = Unit(symbol: "°")
    static let gramsPerSecond = Unit(symbol: "g/s")
    static let poundsPerMinute = Unit(symbol: "lb/min")
    static let none = Unit(symbol: "")
    static let rpm = Unit(symbol: "rpm")

    static let Pascal = Unit(symbol: "Pa")
    static let bar = Unit(symbol: "bar")
    static let ppm = Unit(symbol: "ppm")
    static let ratio = Unit(symbol: "ratio")
    static let litersPerHour = Unit(symbol: "L/h")
    static let gallonsPerHour = Unit(symbol: "gal/h")
    static let newtonMeters = Unit(symbol: "Nm")
    static let poundFeet = Unit(symbol: "lb·ft")
}

public extension MeasurementResult {
    /// The same measurement expressed in the given unit system. Units without an imperial
    /// counterpart are returned unchanged.
    func converted(to system: MeasurementUnit) -> MeasurementResult {
        guard system == .imperial else { return self }
        switch unit {
        case UnitTemperature.celsius:
            return MeasurementResult(value: value * 1.8 + 32, unit: UnitTemperature.fahrenheit)
        case UnitLength.kilometers:
            return MeasurementResult(value: value * 0.621371, unit: UnitLength.miles)
        case UnitSpeed.kilometersPerHour:
            return MeasurementResult(value: value * 0.621371, unit: UnitSpeed.milesPerHour)
        case UnitPressure.kilopascals:
            return MeasurementResult(value: value * 0.145038, unit: UnitPressure.poundsForcePerSquareInch)
        case Unit.bar:
            return MeasurementResult(value: value * 14.5038, unit: UnitPressure.poundsForcePerSquareInch)
        case Unit.gramsPerSecond:
            return MeasurementResult(value: value * 0.132277, unit: Unit.poundsPerMinute)
        case Unit.litersPerHour:
            return MeasurementResult(value: value * 0.264172, unit: Unit.gallonsPerHour)
        case Unit.newtonMeters:
            return MeasurementResult(value: value * 0.737562, unit: Unit.poundFeet)
        default:
            return self
        }
    }
}

// MARK: - Units and scaling (SAE J1979 appendix E)

/// A "Unit And Scaling" identifier: how to turn raw bytes into a physical value.
struct UAS {
    let signed: Bool
    let scale: Double
    let unit: Unit
    let offset: Double

    init(signed: Bool, scale: Double, unit: Unit, offset: Double = 0.0) {
        self.signed = signed
        self.scale = scale
        self.unit = unit
        self.offset = offset
    }

    func decode(bytes: Data, _ system: MeasurementUnit = .metric) -> MeasurementResult {
        var value = bytesToInt(bytes)

        if signed {
            value = twosComp(value, length: bytes.count * 8)
        }

        return MeasurementResult(value: Double(value) * scale + offset, unit: unit).converted(to: system)
    }
}

let uasIDS: [UInt8: UAS] = [
    // Unsigned
    0x01: UAS(signed: false, scale: 1.0, unit: Unit.count),
    0x02: UAS(signed: false, scale: 0.1, unit: Unit.count),
    0x03: UAS(signed: false, scale: 0.01, unit: Unit.count),
    0x04: UAS(signed: false, scale: 0.001, unit: Unit.count),
    0x05: UAS(signed: false, scale: 0.0000305, unit: Unit.count),
    0x06: UAS(signed: false, scale: 0.000305, unit: Unit.count),
    0x07: UAS(signed: false, scale: 0.25, unit: Unit.rpm),
    0x08: UAS(signed: false, scale: 0.01, unit: UnitSpeed.kilometersPerHour),
    0x09: UAS(signed: false, scale: 1, unit: UnitSpeed.kilometersPerHour),
    0x0A: UAS(signed: false, scale: 0.122, unit: UnitElectricPotentialDifference.millivolts),
    0x0B: UAS(signed: false, scale: 0.001, unit: UnitElectricPotentialDifference.volts),
    0x0C: UAS(signed: false, scale: 0.01, unit: UnitElectricPotentialDifference.volts),
    0x0D: UAS(signed: false, scale: 0.00390625, unit: UnitElectricCurrent.milliamperes),
    0x0E: UAS(signed: false, scale: 0.001, unit: UnitElectricCurrent.amperes),
    0x0F: UAS(signed: false, scale: 0.01, unit: UnitElectricCurrent.amperes),
    0x10: UAS(signed: false, scale: 1, unit: UnitDuration.milliseconds),
    0x11: UAS(signed: false, scale: 100, unit: UnitDuration.milliseconds),
    0x12: UAS(signed: false, scale: 1, unit: UnitDuration.seconds),
    0x13: UAS(signed: false, scale: 1, unit: UnitElectricResistance.milliohms),
    0x14: UAS(signed: false, scale: 1, unit: UnitElectricResistance.ohms),
    0x15: UAS(signed: false, scale: 1, unit: UnitElectricResistance.kiloohms),
    0x16: UAS(signed: false, scale: 0.1, unit: UnitTemperature.celsius, offset: -40.0),
    0x17: UAS(signed: false, scale: 0.01, unit: UnitPressure.kilopascals),
    0x18: UAS(signed: false, scale: 0.0117, unit: UnitPressure.kilopascals),
    0x19: UAS(signed: false, scale: 0.079, unit: UnitPressure.kilopascals),
    0x1A: UAS(signed: false, scale: 1, unit: UnitPressure.kilopascals),
    0x1B: UAS(signed: false, scale: 10, unit: UnitPressure.kilopascals),
    0x1C: UAS(signed: false, scale: 0.01, unit: UnitAngle.degrees),
    0x1D: UAS(signed: false, scale: 0.5, unit: UnitAngle.degrees),
    0x1E: UAS(signed: false, scale: 0.0000305, unit: Unit.ratio),
    0x1F: UAS(signed: false, scale: 0.05, unit: Unit.ratio),
    0x20: UAS(signed: false, scale: 0.00390625, unit: Unit.ratio),
    0x21: UAS(signed: false, scale: 1, unit: UnitFrequency.millihertz),
    0x22: UAS(signed: false, scale: 1, unit: UnitFrequency.hertz),
    0x23: UAS(signed: false, scale: 1, unit: UnitFrequency.kilohertz),
    0x24: UAS(signed: false, scale: 1, unit: Unit.count),
    0x25: UAS(signed: false, scale: 1, unit: UnitLength.kilometers),
    0x26: UAS(signed: false, scale: 0.1, unit: Unit(symbol: "mV/ms")),
    0x27: UAS(signed: false, scale: 0.01, unit: Unit.gramsPerSecond),
    0x28: UAS(signed: false, scale: 1, unit: Unit.gramsPerSecond),
    0x29: UAS(signed: false, scale: 0.25, unit: Unit(symbol: "Pa/s")),
    0x2A: UAS(signed: false, scale: 0.001, unit: Unit(symbol: "kg/h")),
    0x2B: UAS(signed: false, scale: 1, unit: Unit.count),
    0x2C: UAS(signed: false, scale: 0.01, unit: Unit(symbol: "g/cyl")),
    0x2D: UAS(signed: false, scale: 0.01, unit: Unit(symbol: "mg/stroke")),
    0x2E: UAS(signed: false, scale: 1, unit: Unit.count),
    0x2F: UAS(signed: false, scale: 0.01, unit: Unit.percent),
    0x30: UAS(signed: false, scale: 0.001526, unit: Unit.percent),
    0x31: UAS(signed: false, scale: 0.001, unit: UnitVolume.liters),
    0x32: UAS(signed: false, scale: 0.0000305, unit: UnitLength.inches),
    0x33: UAS(signed: false, scale: 0.00024414, unit: Unit.ratio),
    0x34: UAS(signed: false, scale: 1, unit: UnitDuration.minutes),
    0x35: UAS(signed: false, scale: 10, unit: UnitDuration.milliseconds),
    0x36: UAS(signed: false, scale: 0.01, unit: UnitMass.grams),
    0x37: UAS(signed: false, scale: 0.1, unit: UnitMass.grams),
    0x38: UAS(signed: false, scale: 1, unit: UnitMass.grams),
    0x39: UAS(signed: false, scale: 0.01, unit: Unit.percent, offset: -327.68),
    0x3A: UAS(signed: false, scale: 0.001, unit: UnitMass.grams),
    0x3B: UAS(signed: false, scale: 0.0001, unit: UnitMass.grams),
    0x3C: UAS(signed: false, scale: 0.1, unit: UnitDuration.microseconds),
    0x3D: UAS(signed: false, scale: 0.01, unit: UnitElectricCurrent.milliamperes),
    0x3E: UAS(signed: false, scale: 0.00006103516, unit: UnitArea.squareMillimeters),
    0x3F: UAS(signed: false, scale: 0.01, unit: UnitVolume.liters),
    0x40: UAS(signed: false, scale: 1, unit: Unit.ppm),
    0x41: UAS(signed: false, scale: 0.01, unit: UnitElectricCurrent.microamperes),

    // Signed
    0x81: UAS(signed: true, scale: 1.0, unit: Unit.count),
    0x82: UAS(signed: true, scale: 0.1, unit: Unit.count),
    0x83: UAS(signed: true, scale: 0.01, unit: Unit.count),
    0x84: UAS(signed: true, scale: 0.001, unit: Unit.count),
    0x85: UAS(signed: true, scale: 0.0000305, unit: Unit.count),
    0x86: UAS(signed: true, scale: 0.000305, unit: Unit.count),
    0x87: UAS(signed: true, scale: 1, unit: Unit.ppm),
    0x8A: UAS(signed: true, scale: 0.122, unit: UnitElectricPotentialDifference.millivolts),
    0x8B: UAS(signed: true, scale: 0.001, unit: UnitElectricPotentialDifference.volts),
    0x8C: UAS(signed: true, scale: 0.01, unit: UnitElectricPotentialDifference.volts),
    0x8D: UAS(signed: true, scale: 0.00390625, unit: UnitElectricCurrent.milliamperes),
    0x8E: UAS(signed: true, scale: 0.001, unit: UnitElectricCurrent.amperes),
    0x90: UAS(signed: true, scale: 1, unit: UnitDuration.milliseconds),
    0x96: UAS(signed: true, scale: 0.1, unit: UnitTemperature.celsius),
    0x99: UAS(signed: true, scale: 0.1, unit: UnitPressure.kilopascals),
    0x9C: UAS(signed: true, scale: 0.01, unit: UnitAngle.degrees),
    0x9D: UAS(signed: true, scale: 0.5, unit: UnitAngle.degrees),
    0xA8: UAS(signed: true, scale: 1, unit: Unit.gramsPerSecond),
    0xA9: UAS(signed: true, scale: 0.25, unit: Unit(symbol: "Pa/s")),
    0xAD: UAS(signed: true, scale: 0.01, unit: Unit(symbol: "mg/stroke")),
    0xAE: UAS(signed: true, scale: 0.1, unit: Unit(symbol: "mg/stroke")),
    0xAF: UAS(signed: true, scale: 0.01, unit: Unit.percent),
    0xB0: UAS(signed: true, scale: 0.003052, unit: Unit.percent),
    0xB1: UAS(signed: true, scale: 2, unit: Unit(symbol: "mV/s")),
    0xFC: UAS(signed: true, scale: 0.01, unit: UnitPressure.kilopascals),
    0xFD: UAS(signed: true, scale: 0.001, unit: UnitPressure.kilopascals),
    0xFE: UAS(signed: true, scale: 0.25, unit: Unit.Pascal),
]

// MARK: - Decoding API

/// Errors thrown while decoding a response.
public enum DecodeError: Error, LocalizedError {
    /// The response does not have the expected format.
    case invalidData
    /// The vehicle returned no data.
    case noData
    /// Decoding failed for the given reason.
    case decodingFailed(reason: String)
    /// The command has no decoder.
    case unsupportedDecoder

    public var errorDescription: String? {
        switch self {
        case .invalidData: return "The response does not have the expected format."
        case .noData: return "The vehicle returned no data."
        case let .decodingFailed(reason): return "Decoding failed: \(reason)"
        case .unsupportedDecoder: return "This command has no decoder."
        }
    }
}

protocol Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError>
}

/// A decoded response. Use the helpers of the extension (`measurementResult`, `troubleCode`…) to read it.
public enum DecodeResult {
    /// Text (VIN, calibration ID…).
    case stringResult(String)
    /// A readiness status.
    case statusResult(Status)
    /// A numeric value.
    case measurementResult(MeasurementResult)
    /// Trouble codes.
    case troubleCode([TroubleCode])
    /// On-board monitor test results.
    case measurementMonitor(Monitor)
}

/// How the data bytes of a command are turned into a value.
public enum Decoders: Equatable, Encodable {
    case pid
    case status
    case singleDTC
    case fuelStatus
    case percent
    case temp
    case percentCentered
    case fuelPressure
    case pressure
    case timingAdvance
    case uas(UInt8)
    case airStatus
    case o2Sensors
    case sensorVoltage
    case obdCompliance
    case o2SensorsAlt
    case auxInputStatus
    case evapPressure
    case sensorVoltageBig
    case currentCentered
    case absoluteLoad
    case maxMaf
    case fuelType
    case absEvapPressure
    case evapPressureAlt
    case injectTiming
    case dtc
    case fuelRate
    case monitor
    case count
    case cvn
    case encoded_string
    case torquePercent
    case odometer
    /// A user supplied expression, see ``CustomCommand``.
    case formula(expression: String, unit: String)
    case none

    func getDecoder() -> Decoder? {
        switch self {
        case .status:
            return StatusDecoder()
        case .temp:
            return TemperatureDecoder()
        case .percent:
            return PercentDecoder()
        case .percentCentered:
            return PercentCenteredDecoder()
        case .currentCentered:
            return CurrentCenteredDecoder()
        case .airStatus:
            return AirStatusDecoder()
        case .singleDTC:
            return SingleDTCDecoder()
        case .fuelStatus:
            return FuelStatusDecoder()
        case .fuelPressure:
            return FuelPressureDecoder()
        case .pressure:
            return PressureDecoder()
        case .timingAdvance:
            return TimingAdvanceDecoder()
        case .obdCompliance:
            return OBDComplianceDecoder()
        case .o2SensorsAlt:
            return O2SensorsAltDecoder()
        case .o2Sensors:
            return O2SensorsDecoder()
        case .auxInputStatus:
            return AuxInputStatusDecoder()
        case .sensorVoltage:
            return SensorVoltageDecoder()
        case .sensorVoltageBig:
            return SensorVoltageBigDecoder()
        case .evapPressure:
            return EvapPressureDecoder()
        case .absoluteLoad:
            return AbsoluteLoadDecoder()
        case .maxMaf:
            return MaxMafDecoder()
        case .fuelType:
            return FuelTypeDecoder()
        case .absEvapPressure:
            return AbsEvapPressureDecoder()
        case .evapPressureAlt:
            return EvapPressureAltDecoder()
        case .injectTiming:
            return InjectTimingDecoder()
        case .dtc:
            return DTCDecoder()
        case .fuelRate:
            return FuelRateDecoder()
        case .monitor:
            return MonitorDecoder()
        case .encoded_string:
            return StringDecoder()
        case .count:
            return CountDecoder()
        case .torquePercent:
            return TorquePercentDecoder()
        case .odometer:
            return OdometerDecoder()
        case let .uas(id):
            return UASDecoder(id: id)
        case let .formula(expression, unit):
            return FormulaDecoder(expression: expression, unitSymbol: unit)
        case .pid, .cvn, .none:
            return HexDecoder()
        }
    }
}

/// Builds a successful measurement, converted to the requested unit system.
private func measurement(_ value: Double, _ unit: Unit, _ system: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
    .success(.measurementResult(MeasurementResult(value: value, unit: unit).converted(to: system)))
}

// MARK: - Decoders

struct MonitorDecoder: Decoder {
    /// Decodes a service 06 answer: a sequence of nine byte records
    /// `MID TID UASID value(2) min(2) max(2)`.
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        var bytes = [UInt8](data)
        let monitor = Monitor()

        // test that we got the right number of bytes
        let extraBytes = bytes.count % 9
        if extraBytes != 0 {
            bytes.removeLast(extraBytes)
        }

        // look at data in blocks of 9 bytes (one test result)
        for start in stride(from: 0, to: bytes.count, by: 9) {
            if let test = parseMonitorTest(Array(bytes[start ..< start + 9]), unit: unit), let tid = test.tid {
                monitor.mid = monitor.mid ?? test.mid
                monitor.tests[tid] = test
            }
        }
        return .success(.measurementMonitor(monitor))
    }

    func parseMonitorTest(_ record: [UInt8], unit: MeasurementUnit) -> MonitorTest? {
        guard record.count == 9 else { return nil }
        var test = MonitorTest()

        let tid = record[1]
        let uasID = record[2]

        if let testInfo = TestIds[tid] {
            test.name = testInfo.0
            test.desc = testInfo.1
        } else {
            // Test identifiers above 0x80 are manufacturer defined.
            test.name = "TID: $\(String(format: "%02X", tid)) UAS: $\(String(format: "%02X", uasID))"
            test.desc = "Manufacturer defined test"
        }

        guard let uas = uasIDS[uasID] else {
            obdWarning("Unknown Units and Scaling ID: \(String(format: "%02X", uasID))", category: .parsing)
            return nil
        }

        test.mid = record[0]
        test.tid = tid
        test.value = uas.decode(bytes: Data(record[3 ... 4]), unit)
        test.min = uas.decode(bytes: Data(record[5 ... 6]), unit).value
        test.max = uas.decode(bytes: Data(record[7 ... 8]), unit).value
        return test
    }
}

struct FuelRateDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard data.count >= 2 else { return .failure(.invalidData) }
        return measurement(Double(bytesToInt(data.prefix(2))) * 0.05, Unit.litersPerHour, unit)
    }
}

struct DTCDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        // converts a frame of 2-byte DTCs into a list of DTCs
        let bytes = [UInt8](data)
        var codes: [TroubleCode] = []
        for index in stride(from: 0, to: bytes.count - 1, by: 2) {
            if let dtc = parseDTC(Data(bytes[index ... index + 1])) {
                codes.append(dtc)
            }
        }
        return .success(.troubleCode(codes))
    }
}

struct InjectTimingDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard data.count >= 2 else { return .failure(.invalidData) }
        return measurement((Double(bytesToInt(data.prefix(2))) - 26880) / 128, UnitAngle.degrees, unit)
    }
}

struct EvapPressureAltDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard data.count >= 2 else { return .failure(.invalidData) }
        return measurement(Double(bytesToInt(data.prefix(2))) - 32767, Unit.Pascal, unit)
    }
}

struct AbsEvapPressureDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard data.count >= 2 else { return .failure(.invalidData) }
        return measurement(Double(bytesToInt(data.prefix(2))) / 200, UnitPressure.kilopascals, unit)
    }
}

struct FuelTypeDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let index = data.first.map(Int.init), index < FuelTypes.count else {
            return .failure(.invalidData)
        }
        return .success(.stringResult(FuelTypes[index]))
    }
}

struct MaxMafDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let first = data.first else { return .failure(.invalidData) }
        return measurement(Double(first) * 10, Unit.gramsPerSecond, unit)
    }
}

struct AbsoluteLoadDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard data.count >= 2 else { return .failure(.invalidData) }
        return measurement(Double(bytesToInt(data.prefix(2))) * 100 / 255, Unit.percent, unit)
    }
}

struct EvapPressureDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard data.count >= 2 else { return .failure(.invalidData) }
        // Signed 16 bit value, a quarter of a pascal per bit.
        let raw = twosComp(bytesToInt(data.prefix(2)), length: 16)
        return measurement(Double(raw) / 4.0, Unit.Pascal, unit)
    }
}

struct SensorVoltageBigDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return .failure(.invalidData) }
        let value = Int(bytes[2]) << 8 | Int(bytes[3])
        return measurement(Double(value) * 8.0 / 65535, UnitElectricPotentialDifference.volts, unit)
    }
}

struct SensorVoltageDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard data.count == 2, let first = data.first else { return .failure(.invalidData) }
        return measurement(Double(first) / 200, UnitElectricPotentialDifference.volts, unit)
    }
}

struct O2SensorsDecoder: Decoder {
    /// PID 13: bits 0-3 are the sensors of bank 1, bits 4-7 those of bank 2.
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let byte = data.first else { return .failure(.invalidData) }
        let bits = BitArray(data: Data([byte])).binaryArray
        let bank1 = Array(bits[4 ..< 8].reversed())
        let bank2 = Array(bits[0 ..< 4].reversed())

        return .success(.stringResult("\(bank1), \(bank2)"))
    }
}

struct O2SensorsAltDecoder: Decoder {
    /// PID 1D: two sensors per bank, bank 1 in the lowest bits.
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let byte = data.first else { return .failure(.invalidData) }
        let bits = BitArray(data: Data([byte])).binaryArray
        let bank1 = Array(bits[6 ..< 8].reversed())
        let bank2 = Array(bits[4 ..< 6].reversed())
        let bank3 = Array(bits[2 ..< 4].reversed())
        let bank4 = Array(bits[0 ..< 2].reversed())

        return .success(.stringResult("\(bank1), \(bank2), \(bank3), \(bank4)"))
    }
}

struct AuxInputStatusDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let byte = data.first else { return .failure(.invalidData) }
        return .success(.stringResult(byte & 0x01 != 0 ? "Power take off active" : "Power take off inactive"))
    }
}

struct OBDComplianceDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let index = data.first.map(Int.init) else { return .failure(.invalidData) }

        if index < OBD_COMPLIANCE.count {
            return .success(.stringResult(OBD_COMPLIANCE[index]))
        } else {
            return .failure(.decodingFailed(reason: "Invalid response for OBD compliance (no table entry)"))
        }
    }
}

struct TimingAdvanceDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let first = data.first else { return .failure(.invalidData) }
        return measurement(Double(first) / 2.0 - 64.0, UnitAngle.degrees, unit)
    }
}

struct PressureDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let first = data.first else { return .failure(.invalidData) }
        return measurement(Double(first), UnitPressure.kilopascals, unit)
    }
}

struct FuelPressureDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let first = data.first else { return .failure(.invalidData) }
        return measurement(Double(first) * 3, UnitPressure.kilopascals, unit)
    }
}

struct AirStatusDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let byte = data.first, byte.nonzeroBitCount == 1 else { return .failure(.invalidData) }
        let index = byte.trailingZeroBitCount
        guard index < AIR_STATUS.count else { return .failure(.invalidData) }
        return .success(.stringResult(AIR_STATUS[index]))
    }
}

struct FuelStatusDecoder: Decoder {
    /// PID 03: one byte per fuel system, exactly one bit set in each.
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        let statuses: [String] = data.prefix(2).compactMap { byte in
            guard byte.nonzeroBitCount == 1, byte.trailingZeroBitCount < FUEL_STATUS.count else { return nil }
            return FUEL_STATUS[byte.trailingZeroBitCount]
        }

        switch statuses.count {
        case 2:
            return .success(.stringResult("Status 1: \(statuses[0]), Status 2: \(statuses[1])"))
        case 1:
            return .success(.stringResult("Status: \(statuses[0])"))
        default:
            return .failure(.decodingFailed(reason: "No valid status found."))
        }
    }
}

struct SingleDTCDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        let troubleCode = parseDTC(data)
        return .success(.troubleCode(troubleCode.map { [$0] } ?? []))
    }
}

struct CurrentCenteredDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return .failure(.invalidData) }
        let value = Double(Int(bytes[2]) << 8 | Int(bytes[3]))
        return measurement(value / 256.0 - 128.0, UnitElectricCurrent.milliamperes, unit)
    }
}

struct PercentCenteredDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let first = data.first else { return .failure(.invalidData) }
        return measurement((Double(first) - 128) * 100.0 / 128.0, Unit.percent, unit)
    }
}

struct PercentDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let first = data.first else { return .failure(.invalidData) }
        return measurement(Double(first) * 100.0 / 255.0, Unit.percent, unit)
    }
}

struct TorquePercentDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let first = data.first else { return .failure(.invalidData) }
        return measurement(Double(first) - 125, Unit.percent, unit)
    }
}

struct OdometerDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard data.count >= 4 else { return .failure(.invalidData) }
        return measurement(Double(bytesToInt(data.prefix(4))) / 10, UnitLength.kilometers, unit)
    }
}

struct TemperatureDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard !data.isEmpty else { return .failure(.invalidData) }
        return measurement(Double(bytesToInt(data)) - 40.0, UnitTemperature.celsius, unit)
    }
}

struct CountDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let first = data.first else { return .failure(.invalidData) }
        return measurement(Double(first), Unit.count, unit)
    }
}

struct StringDecoder: Decoder {
    /// Keeps the printable ASCII characters: vehicle information strings are padded with zeroes
    /// and prefixed with item counters.
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        let printable = data.filter { (0x20 ... 0x7E).contains($0) }
        let string = String(decoding: printable, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard !string.isEmpty else {
            return .failure(.decodingFailed(reason: "Failed to decode string"))
        }
        return .success(.stringResult(string))
    }
}

struct HexDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard !data.isEmpty else { return .failure(.noData) }
        return .success(.stringResult(data.hexString))
    }
}

struct UASDecoder: Decoder {
    let id: UInt8

    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        guard let uas = uasIDS[id], !data.isEmpty else {
            return .failure(.invalidData)
        }
        return .success(.measurementResult(uas.decode(bytes: data, unit)))
    }
}

struct FormulaDecoder: Decoder {
    let expression: String
    let unitSymbol: String

    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        do {
            let value = try Formula.cached(expression).evaluate([UInt8](data))
            return .success(.measurementResult(MeasurementResult(value: value, unit: Unit(symbol: unitSymbol))))
        } catch {
            return .failure(.decodingFailed(reason: error.localizedDescription))
        }
    }
}

struct StatusDecoder: Decoder {
    func decode(data: Data, unit: MeasurementUnit) -> Result<DecodeResult, DecodeError> {
        //            ┌Components not ready
        //            |┌Fuel not ready
        //            ||┌Misfire not ready
        //            |||┌Spark vs. Compression
        //            ||||┌Components supported
        //            |||||┌Fuel supported
        //  ┌MIL      ||||||┌Misfire supported
        //  |         |||||||
        //  10000011 00000111 11111111 00000000
        //  00000000 00000111 11100101 00000000
        //  10111110 00011111 10101000 00010011
        //   [# DTC] X        [supprt] [~ready]
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return .failure(.invalidData) }
        let (a, b, c, d) = (bytes[0], bytes[1], bytes[2], bytes[3])

        var output = Status()
        output.MIL = a & 0x80 != 0
        output.dtcCount = a & 0x7F
        let isCompression = b & 0x08 != 0
        output.ignitionType = isCompression ? "Compression" : "Spark"

        // the 3 continuous monitors that are always present
        output.misfireMonitoring = StatusTest(baseTests[0], b & 0x01 != 0, b & 0x10 == 0)
        output.fuelSystemMonitoring = StatusTest(baseTests[1], b & 0x02 != 0, b & 0x20 == 0)
        output.componentMonitoring = StatusTest(baseTests[2], b & 0x04 != 0, b & 0x40 == 0)
        output.monitors = [output.misfireMonitoring, output.fuelSystemMonitoring, output.componentMonitoring]

        // the monitors that depend on the type of engine
        for (bit, name) in (isCompression ? compressionTests : sparkTests).enumerated() {
            guard let name = name else { continue }
            let mask = UInt8(1) << UInt8(bit)
            output.monitors.append(StatusTest(name, c & mask != 0, d & mask == 0))
        }
        return .success(.statusResult(output))
    }
}

func parseDTC(_ data: Data) -> TroubleCode? {
    let bytes = [UInt8](data)
    if bytes.count != 2 || bytes == [0x00, 0x00] {
        return nil
    }
    let first = bytes[0], second = bytes[1]

    // BYTES: (16,      35      )
    // HEX:    4   1    2   3
    // BIN:    01000001 00100011
    //         [][][  in hex   ]
    //         | / /
    // DTC:    C0123
    var dtc = ["P", "C", "B", "U"][Int(first) >> 6] // the last 2 bits of the first byte
    dtc += String((first >> 4) & 0b0011) // the next pair of 2 bits. Mask off the bits we read above
    dtc += String(format: "%04X", (UInt16(first) & 0x3F) << 8 | UInt16(second)).dropFirst()
    // pull description from the DTCs array

    return TroubleCode(code: dtc, description: codes[dtc] ?? "No description available.")
}

// MARK: - On-board monitoring (service 06)

/// The results of one on-board diagnostic monitor (catalyst, oxygen sensor, misfire…).
public class Monitor {
    /// The monitor identifier (`0x01` oxygen sensor bank 1 sensor 1, `0x21` catalyst bank 1…).
    public internal(set) var mid: UInt8?
    /// A description of the monitor, when it is a standard one.
    public internal(set) var name: String?
    /// The test results, indexed by test identifier.
    public var tests: [UInt8: MonitorTest] = [:]

    public init() {}

    /// `true` when every test of the monitor is within its limits.
    public var passed: Bool {
        tests.values.allSatisfy(\.passed)
    }
}

/// One test of an on-board monitor, with its value and limits.
public struct MonitorTest {
    public internal(set) var mid: UInt8?
    /// The test identifier.
    public internal(set) var tid: UInt8?
    public internal(set) var name: String?
    /// A description of the test.
    public internal(set) var desc: String?
    /// The measured value.
    public internal(set) var value: MeasurementResult?
    /// The lowest value allowed for the test to pass.
    public internal(set) var min: Double?
    /// The highest value allowed for the test to pass.
    public internal(set) var max: Double?

    public var passed: Bool {
        guard let value = value, let min = min, let max = max else {
            return false
        }
        return value.value >= min && value.value <= max
    }

    public var isNull: Bool {
        return tid == nil || value == nil || min == nil || max == nil
    }

    public var description: String {
        return "\(desc ?? "") : \(value?.value ?? 0) [\(passed ? "PASSED" : "FAILED")]"
    }
}

// MARK: - Tables

let baseTests = [
    "MISFIRE_MONITORING",
    "FUEL_SYSTEM_MONITORING",
    "COMPONENT_MONITORING"
]

/// Non continuous monitors of a spark ignition engine, indexed by bit number.
let sparkTests: [String?] = [
    "CATALYST_MONITORING",
    "HEATED_CATALYST_MONITORING",
    "EVAPORATIVE_SYSTEM_MONITORING",
    "SECONDARY_AIR_SYSTEM_MONITORING",
    nil,
    "OXYGEN_SENSOR_MONITORING",
    "OXYGEN_SENSOR_HEATER_MONITORING",
    "EGR_VVT_SYSTEM_MONITORING"
]

/// Non continuous monitors of a compression ignition engine, indexed by bit number.
let compressionTests: [String?] = [
    "NMHC_CATALYST_MONITORING",
    "NOX_SCR_AFTERTREATMENT_MONITORING",
    nil,
    "BOOST_PRESSURE_MONITORING",
    nil,
    "EXHAUST_GAS_SENSOR_MONITORING",
    "PM_FILTER_MONITORING",
    "EGR_VVT_SYSTEM_MONITORING"
]

let AIR_STATUS = [
    "Upstream",
    "Downstream of catalytic converter",
    "From the outside atmosphere or off",
    "Pump commanded on for diagnostics"
]

let FUEL_STATUS = [
    "Open loop due to insufficient engine temperature",
    "Closed loop, using oxygen sensor feedback to determine fuel mix",
    "Open loop due to engine load OR fuel cut due to deceleration",
    "Open loop due to system failure",
    "Closed loop, using at least one oxygen sensor but there is a fault in the feedback system"
]

let FuelTypes = [
    "Not available",
    "Gasoline",
    "Methanol",
    "Ethanol",
    "Diesel",
    "LPG",
    "CNG",
    "Propane",
    "Electric",
    "Bifuel running Gasoline",
    "Bifuel running Methanol",
    "Bifuel running Ethanol",
    "Bifuel running LPG",
    "Bifuel running CNG",
    "Bifuel running Propane",
    "Bifuel running Electricity",
    "Bifuel running electric and combustion engine",
    "Hybrid gasoline",
    "Hybrid Ethanol",
    "Hybrid Diesel",
    "Hybrid Electric",
    "Hybrid running electric and combustion engine",
    "Hybrid Regenerative",
    "Bifuel running diesel"
]

let OBD_COMPLIANCE = [
    "Undefined",
    "OBD-II as defined by the CARB",
    "OBD as defined by the EPA",
    "OBD and OBD-II",
    "OBD-I",
    "Not OBD compliant",
    "EOBD (Europe)",
    "EOBD and OBD-II",
    "EOBD and OBD",
    "EOBD, OBD and OBD II",
    "JOBD (Japan)",
    "JOBD and OBD II",
    "JOBD and EOBD",
    "JOBD, EOBD, and OBD II",
    "Reserved",
    "Reserved",
    "Reserved",
    "Engine Manufacturer Diagnostics (EMD)",
    "Engine Manufacturer Diagnostics Enhanced (EMD+)",
    "Heavy Duty On-Board Diagnostics (Child/Partial) (HD OBD-C)",
    "Heavy Duty On-Board Diagnostics (HD OBD)",
    "World Wide Harmonized OBD (WWH OBD)",
    "Reserved",
    "Heavy Duty Euro OBD Stage I without NOx control (HD EOBD-I)",
    "Heavy Duty Euro OBD Stage I with NOx control (HD EOBD-I N)",
    "Heavy Duty Euro OBD Stage II without NOx control (HD EOBD-II)",
    "Heavy Duty Euro OBD Stage II with NOx control (HD EOBD-II N)",
    "Reserved",
    "Brazil OBD Phase 1 (OBDBr-1)",
    "Brazil OBD Phase 2 (OBDBr-2)",
    "Korean OBD (KOBD)",
    "India OBD I (IOBD I)",
    "India OBD II (IOBD II)",
    "Heavy Duty Euro OBD Stage VI (HD EOBD-IV)"
]

/// Standard test identifiers of service 06 (SAE J1979). Identifiers from 0x80 are manufacturer defined.
let TestIds: [UInt8: (String, String)] = [
    0x01: ("RTLThresholdVoltage", "Rich to lean sensor threshold voltage"),
    0x02: ("LTRThresholdVoltage", "Lean to rich sensor threshold voltage"),
    0x03: ("LowVoltageSwitchTime", "Low sensor voltage for switch time calculation"),
    0x04: ("HighVoltageSwitchTime", "High sensor voltage for switch time calculation"),
    0x05: ("RTLSwitchTime", "Rich to lean sensor switch time"),
    0x06: ("LTRSwitchTime", "Lean to rich sensor switch time"),
    0x07: ("MINVoltage", "Minimum sensor voltage for test cycle"),
    0x08: ("MAXVoltage", "Maximum sensor voltage for test cycle"),
    0x09: ("TransitionTime", "Time between sensor transitions"),
    0x0A: ("SensorPeriod", "Sensor period"),
    0x0B: ("MisFireAverage", "Average misfire counts for the last ten driving cycles"),
    0x0C: ("MisFireCount", "Misfire counts for the last or current driving cycle")
]
