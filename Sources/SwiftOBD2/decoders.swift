//
//  decoders.swift
//  SmartOBD2
//
//  Created by kemo konteh on 9/18/23.
//

import Foundation

public enum DecodeError: Error, LocalizedError {
    case invalidData
    case noData
    case decodingFailed(reason: String)
    case unsupportedDecoder
    case insufficientData(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid data format received from OBD device"
        case .noData:
            return "No data available to decode"
        case .decodingFailed(let reason):
            return "Decoding failed: \(reason)"
        case .unsupportedDecoder:
            return "Unsupported decoder type"
        case .insufficientData(let expected, let got):
            return "Insufficient data: expected \(expected) bytes, got \(got) bytes"
        }
    }
}

public protocol OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult
}

// MARK: - Structured Data Models

public struct FuelSystemStatus: Codable {
    let system1: String?
    let system2: String?

    var description: String {
        switch (system1, system2) {
        case (let s1?, let s2?):
            return "System 1: \(s1), System 2: \(s2)"
        case (let s1?, nil):
            return "System 1: \(s1)"
        case (nil, let s2?):
            return "System 2: \(s2)"
        default:
            return "No fuel system status available"
        }
    }

    var isClosedLoop: Bool {
        let closedLoopPattern = "Closed loop"
        return (system1?.contains(closedLoopPattern) ?? false) ||
               (system2?.contains(closedLoopPattern) ?? false)
    }
}

public struct AirFlowStatus: Codable {
    let statusIndex: Int
    let statusDescription: String

    static let descriptions = [
        "Upstream of throttle",
        "Downstream of throttle",
        "Pressure sensor",
        "Off",
        "No flow",
        "Throttle position",
        "Engine off",
        "Error"
    ]

    init(index: Int) {
        self.statusIndex = index
        self.statusDescription = index < Self.descriptions.count ?
            Self.descriptions[index] : "Unknown status"
    }
}

public struct SupportedPIDs: Codable {
    let pids: Set<String>
    let range: String // e.g., "01-20", "21-40", etc.

    var description: String {
        let sortedPIDs = pids.sorted()
        return "Supported PIDs (\(range)): \(sortedPIDs.joined(separator: ", "))"
    }

    var count: Int {
        return pids.count
    }

    func isSupported(_ pid: String) -> Bool {
        return pids.contains(pid)
    }
}

public struct OBDCompliance: Codable {
    let code: UInt8
    let standard: String
    let description: String

    var isOBD2Compliant: Bool {
        return standard.contains("OBD-II") || standard.contains("OBD II")
    }

    var region: String? {
        if standard.contains("CARB") || standard.contains("EPA") {
            return "USA"
        } else if standard.contains("EOBD") {
            return "Europe"
        } else if standard.contains("JOBD") {
            return "Japan"
        } else if standard.contains("KOBD") {
            return "Korea"
        } else if standard.contains("IOBD") {
            return "India"
        } else if standard.contains("OBDBr") {
            return "Brazil"
        }
        return nil
    }
}

public struct FuelType: Codable {
    let code: UInt8
    let type: String

    var isAlternativeFuel: Bool {
        return type.contains("Electric") || type.contains("Hybrid") ||
               type.contains("CNG") || type.contains("LPG") ||
               type.contains("Propane") || type.contains("Methanol") ||
               type.contains("Ethanol")
    }

    var isHybrid: Bool {
        return type.contains("Hybrid") || type.contains("Bifuel")
    }
}

// MARK: - Updated DecodeResult Enum

public enum DecodeResult {
    case stringResult([String])  // Keep for backward compatibility
    case statusResult(Status)
    case measurementResult(MeasurementResult)
    case troubleCode([TroubleCode])
    case monitorResult(MonitorResult)
    case o2SensorStatus(O2SensorStatus)
    case supportedPIDs(SupportedPIDs)
    case fuelSystemStatus(FuelSystemStatus)
    case airFlowStatus(AirFlowStatus)
    case obdCompliance(OBDCompliance)
    case fuelType(FuelType)

    // Computed properties for accessing specific types
    var supportedPIDs: SupportedPIDs? {
        if case let .supportedPIDs(pids) = self { return pids }
        return nil
    }

    var fuelSystemStatus: FuelSystemStatus? {
        if case let .fuelSystemStatus(status) = self { return status }
        return nil
    }

    var airFlowStatus: AirFlowStatus? {
        if case let .airFlowStatus(status) = self { return status }
        return nil
    }

    var obdCompliance: OBDCompliance? {
        if case let .obdCompliance(compliance) = self { return compliance }
        return nil
    }

    var fuelType: FuelType? {
        if case let .fuelType(type) = self { return type }
        return nil
    }

    // Existing computed properties...
    var o2SensorStatus: O2SensorStatus? {
        if case let .o2SensorStatus(status) = self { return status }
        return nil
    }

    var statusResult: Status? {
        if case let .statusResult(res) = self { return res }
        return nil
    }

    var measurementResult: MeasurementResult? {
        if case let .measurementResult(res) = self { return res }
        return nil
    }

    var troubleCode: [TroubleCode]? {
        if case let .troubleCode(res) = self { return res }
        return nil
    }

    var monitorResult: MonitorResult? {
        if case let .monitorResult(res) = self { return res }
        return nil
    }

    var stringResult: [String]? {
        if case let .stringResult(res) = self { return res }
        return nil
    }
}


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
    case none

    private static var uasDecoders = [UInt8: UASDecoder]()

    private static let staticDecoders: [String: OBDDecoder] = [
        "pid" : PIDSupportDecoder(),
        "status" : StatusDecoder(),
        "temp" : TemperatureDecoder(),
        "percent" : PercentDecoder(),
        "percentCentered" : PercentCenteredDecoder(),
        "currentCentered" : CurrentCenteredDecoder(),
        "airStatus" : AirStatusDecoder(),
        "singleDTC" : SingleDTCDecoder(),
        "fuelStatus" : FuelStatusDecoder(),
        "fuelPressure" : FuelPressureDecoder(),
        "pressure" : PressureDecoder(),
        "timingAdvance" : TimingAdvanceDecoder(),
        "obdCompliance" : OBDComplianceDecoder(),
        "o2SensorsAlt" : O2SensorsAltDecoder(),
        "o2Sensors" : O2SensorsDecoder(),
        "sensorVoltage" : SensorVoltageDecoder(),
        "sensorVoltageBig" : SensorVoltageBigDecoder(),
        "evapPressure" : EvapPressureDecoder(),
        "absoluteLoad" : AbsoluteLoadDecoder(),
        "maxMaf" : MaxMafDecoder(),
        "fuelType" : FuelTypeDecoder(),
        "absEvapPressure" : AbsEvapPressureDecoder(),
        "evapPressureAlt" : EvapPressureAltDecoder(),
        "injectTiming" : InjectTimingDecoder(),
        "dtc" : DTCDecoder(),
        "fuelRate" : FuelRateDecoder(),
        "monitor" : MonitorDecoder(),
        "encoded_string" : StringDecoder()
    ]

    func getDecoder() -> OBDDecoder? {
            switch self {
            case .uas(let id):
                if Self.uasDecoders[id] == nil {
                    Self.uasDecoders[id] = UASDecoder(id: id)
                }
                return Self.uasDecoders[id]
            default:
                let key = String(describing: self).components(separatedBy: ".").last ?? ""
                return Self.staticDecoders[key]
            }
        }
}

struct PIDSupportDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let binaryData = BitArray(data: data.dropFirst()).binaryArray
        let supportedPids = extractSupportedPIDs(binaryData)
        return  .stringResult(Array(supportedPids))
    }

    func extractSupportedPIDs(_ binaryData: [Int]) -> Set<String> {
        var supportedPIDs: Set<String> = []

        for (index, value) in binaryData.enumerated() {
            if value == 1 {
                let pid = String(format: "%02X", index + 1)
                supportedPIDs.insert(pid)
            }
        }
        return supportedPIDs
    }
}

private var uasIDS: [UInt8: UAS] = {
    return [
    // Unsigned
    0x01: UAS(signed: false, scale: 1.0, unit: Unit.count),
    0x02: UAS(signed: false, scale: 0.1, unit: Unit.count),
    0x03: UAS(signed: false, scale: 0.01, unit: Unit.count),
    0x04: UAS(signed: false, scale: 0.001, unit: Unit.count),
    0x05: UAS(signed: false, scale: 0.0000305, unit: Unit.count),
    0x06: UAS(signed: false, scale: 0.000305, unit: Unit.count),
    0x07: UAS(signed: false, scale: 0.25, unit: Unit.rpm),
    0x09: UAS(signed: false, scale: 1, unit: UnitSpeed.kilometersPerHour),

    0x0A: UAS(signed: false, scale: 0.122, unit: UnitElectricPotentialDifference.millivolts),
    0x0B: UAS(signed: false, scale: 0.001, unit: UnitElectricPotentialDifference.volts),

    0x10: UAS(signed: false, scale: 1, unit: UnitDuration.milliseconds),
    0x11: UAS(signed: false, scale: 100, unit: UnitDuration.milliseconds),
    0x12: UAS(signed: false, scale: 1, unit: UnitDuration.seconds),
    0x13: UAS(signed: false, scale: 1, unit: UnitElectricResistance.microohms),
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
    // unit ratio
    0x1E: UAS(signed: false, scale: 0.0000305, unit: Unit.ratio),
    0x1F: UAS(signed: false, scale: 0.05, unit: Unit.ratio),
    0x20: UAS(signed: false, scale: 0.00390625, unit: Unit.ratio),
    0x21: UAS(signed: false, scale: 1, unit: UnitFrequency.millihertz),
    0x22: UAS(signed: false, scale: 1, unit: UnitFrequency.hertz),
    0x23: UAS(signed: false, scale: 1, unit: UnitFrequency.kilohertz),
    0x24: UAS(signed: false, scale: 1, unit: Unit.count),
    0x25: UAS(signed: false, scale: 1, unit: UnitLength.kilometers),

    0x27: UAS(signed: false, scale: 0.01, unit: Unit.gramsPerSecond),

    // Signed
    0x81: UAS(signed: true, scale: 1.0, unit: Unit.count),
    0x82: UAS(signed: true, scale: 0.1, unit: Unit.count),

    0x83: UAS(signed: true, scale: 0.01, unit: Unit.count),
    0x84: UAS(signed: true, scale: 0.001, unit: Unit.count),
    0x85: UAS(signed: true, scale: 0.0000305, unit: Unit.count),
    0x86: UAS(signed: true, scale: 0.000305, unit: Unit.count),
    0x87: UAS(signed: true, scale: 1, unit: Unit.ppm),
    //
    0x8A: UAS(signed: true, scale: 0.122, unit: UnitElectricPotentialDifference.millivolts),
    0x8B: UAS(signed: true, scale: 0.001, unit: UnitElectricPotentialDifference.volts),
    0x8C: UAS(signed: true, scale: 0.01, unit: UnitElectricPotentialDifference.volts),
    0x8D: UAS(signed: true, scale: 0.00390625, unit: UnitElectricCurrent.milliamperes),
    0x8E: UAS(signed: true, scale: 0.001, unit: UnitElectricCurrent.amperes),
    //
    0x90: UAS(signed: true, scale: 1, unit: UnitDuration.milliseconds),
    //
    0x96: UAS(signed: true, scale: 0.1, unit: UnitTemperature.celsius),

    0x99: UAS(signed: true, scale: 0.1, unit: UnitPressure.kilopascals),

    0xFC: UAS(signed: true, scale: 0.01, unit: UnitPressure.kilopascals),
    0xFD: UAS(signed: true, scale: 0.001, unit: UnitPressure.kilopascals),
    0xFE: UAS(signed: true, scale: 0.25, unit: Unit.Pascal)
]}()

public struct MonitorTest: Codable {
    let tid: UInt8
    let cid: UInt8  // Component/Scaling ID
    let name: String
    let description: String
    let value: Double
    let unit: String
    let min: Double
    let max: Double

    var passed: Bool {
        return value >= min && value <= max
    }

    var marginToMin: Double {
        return value - min
    }

    var marginToMax: Double {
        return max - value
    }

    var percentageWithinRange: Double? {
        guard max > min else { return nil }
        let range = max - min
        let position = value - min
        return (position / range) * 100
    }

    var status: TestStatus {
        if passed {
            let margin = Swift.min(marginToMin, marginToMax)
            let range = max - min
            if range > 0 {
                let marginPercent = (margin / range) * 100
                if marginPercent < 10 {
                    return .passedMarginal
                }
            }
            return .passed
        } else {
            return .failed
        }
    }

    enum TestStatus: String, Codable {
        case passed = "PASSED"
        case passedMarginal = "PASSED (MARGINAL)"
        case failed = "FAILED"

        var emoji: String {
            switch self {
            case .passed: return "✅"
            case .passedMarginal: return "⚠️"
            case .failed: return "❌"
            }
        }
    }

    var formattedValue: String {
        return String(format: "%.3f %@", value, unit)
    }

    var formattedRange: String {
        return String(format: "%.3f - %.3f %@", min, max, unit)
    }

    var summary: String {
        return "\(name): \(formattedValue) [\(formattedRange)] \(status.emoji) \(status.rawValue)"
    }
}

public struct MonitorResult: Codable {
    let tests: [MonitorTest]
    let timestamp: Date

    init(tests: [MonitorTest], timestamp: Date = Date()) {
        self.tests = tests
        self.timestamp = timestamp
    }

    // Categorized access
    var testsByCategory: [TestCategory: [MonitorTest]] {
        var categories: [TestCategory: [MonitorTest]] = [:]

        for test in tests {
            let category = TestCategory.fromTID(test.tid)
            categories[category, default: []].append(test)
        }

        return categories
    }

    var passedTests: [MonitorTest] {
        return tests.filter { $0.passed }
    }

    var failedTests: [MonitorTest] {
        return tests.filter { !$0.passed }
    }

    var marginalTests: [MonitorTest] {
        return tests.filter { $0.status == .passedMarginal }
    }

    var overallStatus: OverallStatus {
        if tests.isEmpty {
            return .noTests
        }
        if failedTests.isEmpty {
            if marginalTests.isEmpty {
                return .allPassed
            } else {
                return .passedWithWarnings
            }
        } else {
            return .hasFailed
        }
    }

    enum OverallStatus: String, Codable {
        case noTests = "No Tests Available"
        case allPassed = "All Tests Passed"
        case passedWithWarnings = "Passed with Warnings"
        case hasFailed = "Has Failed Tests"

        var emoji: String {
            switch self {
            case .noTests: return "📋"
            case .allPassed: return "✅"
            case .passedWithWarnings: return "⚠️"
            case .hasFailed: return "❌"
            }
        }
    }

    func testByTID(_ tid: UInt8) -> MonitorTest? {
        return tests.first { $0.tid == tid }
    }

    var summary: String {
        var result = "Monitor Test Results:\n"
        result += "Status: \(overallStatus.emoji) \(overallStatus.rawValue)\n"
        result += "Total Tests: \(tests.count)\n"
        result += "Passed: \(passedTests.count)\n"

        if !marginalTests.isEmpty {
            result += "Marginal: \(marginalTests.count)\n"
        }

        if !failedTests.isEmpty {
            result += "Failed: \(failedTests.count)\n"
        }

        return result
    }
}

public enum TestCategory: String, Codable, CaseIterable {
    case oxygenSensor = "Oxygen Sensor"
    case catalyst = "Catalyst"
    case evaporativeSystem = "Evaporative System"
    case egr = "EGR System"
    case vvt = "VVT System"
    case misfire = "Misfire"
    case fuelSystem = "Fuel System"
    case secondaryAir = "Secondary Air"
    case unknown = "Unknown"

    static func fromTID(_ tid: UInt8) -> TestCategory {
        switch tid {
        case 0x01...0x0A:
            return .oxygenSensor
        case 0x0B...0x0C:
            return .misfire
        case 0x21...0x30:
            return .catalyst
        case 0x31...0x3F:
            return .evaporativeSystem
        case 0x41...0x4F:
            return .egr
        case 0x51...0x5F:
            return .vvt
        case 0x61...0x6F:
            return .fuelSystem
        case 0x71...0x7F:
            return .secondaryAir
        default:
            return .unknown
        }
    }
}

struct MonitorDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        var databytes = Data(data)
        print("Raw data:", databytes.compactMap { String(format: "%02X", $0) }.joined(separator: " "))

        guard databytes.count >= 1, let pid = databytes.first else {
            throw DecodeError.insufficientData(expected: 1, got: databytes.count)
        }
        databytes = databytes.dropFirst()

        print("PID: \(String(format: "%02X", pid))")
        print("Test data:", databytes.compactMap { String(format: "%02X", $0) }.joined(separator: " "))

        // Ensure we have complete 8-byte blocks
        let extraBytes = databytes.count % 8
        if extraBytes != 0 {
            print("Warning: Dropping \(extraBytes) extra bytes")
            databytes = databytes.dropLast(extraBytes)
        }

        guard !databytes.isEmpty else {
            throw DecodeError.insufficientData(expected: 8, got: databytes.count)
        }

        var tests: [MonitorTest] = []

        // Convert to Array to avoid index issues
        let dataArray = Array(databytes)

        // Process each 8-byte block
        for i in stride(from: 0, to: dataArray.count, by: 8) {
            let endIndex = min(i + 8, dataArray.count)
            let subdata = Data(dataArray[i..<endIndex])

            print("Processing block \(i/8): \(subdata.map { String(format: "%02X", $0) }.joined(separator: " "))")

            if let test = parseMonitorTest(subdata, unit: unit) {
                tests.append(test)
            } else {
                print("Failed to parse test at index \(i)")
            }
        }

        guard !tests.isEmpty else {
            throw DecodeError.noData
        }

        let result = MonitorResult(tests: tests)
        return .monitorResult(result)
    }

    private func parseMonitorTest(_ data: Data, unit: MeasurementUnit) -> MonitorTest? {
         guard data.count >= 8 else {
             print("Insufficient data for test: \(data.count) bytes")
             return nil
         }

         let tid = data[0]
         let cid = data[1]

         print("Parsing - TID: \(String(format: "%02X", tid)), CID: \(String(format: "%02X", cid))")

         // Get test information
         let testInfo = TestIds[tid] ?? ("Unknown Test", "Unknown test with ID \(String(format: "%02X", tid))")

         // Get UAS decoder for scaling
         guard let uas = uasIDS[cid] else {
             obdWarning("Warning: Unknown Units and Scaling ID: \(String(format: "%02X", cid))")
             return nil
         }

         // Extract value ranges (2 bytes each)
         let valueData = data[2...3]
         let minData = data[4...5]
         let maxData = data[6...7]

         // Decode values using UAS
         let valueResult = uas.decode(bytes: valueData, unit)
         let minResult = uas.decode(bytes: minData, unit)
         let maxResult = uas.decode(bytes: maxData, unit)

         print("Decoded - Value: \(valueResult.value), Min: \(minResult.value), Max: \(maxResult.value) \(valueResult.unit.symbol)")

         return MonitorTest(
             tid: tid,
             cid: cid,
             name: testInfo.0,
             description: testInfo.1,
             value: valueResult.value,
             unit: valueResult.unit.symbol,
             min: minResult.value,
             max: maxResult.value
         )
     }
}

struct FuelRateDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let value = Double(bytesToInt(data)) * 0.05
        return  (.measurementResult(MeasurementResult(value: value, unit: UnitFuelEfficiency.litersPer100Kilometers)))
    }
}

struct DTCDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        // converts a frame of 2-byte DTCs into a list of DTCs
        let data = Data(data.dropFirst())
        var codes: [TroubleCode] = []
        // send data to parceDtc 2 byte at a time
        for n in stride(from: 0, to: data.count - 1, by: 2) {
            let endIndex = min(n + 1, data.count - 1)
            guard let dtc = parseDTC(data[n ... endIndex]) else {
                continue
            }
            codes.append(dtc)
        }
        return  .troubleCode(codes)
    }
}

struct InjectTimingDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let value = (Double(bytesToInt(data)) - 26880) / 128
        return  (.measurementResult(MeasurementResult(value: value, unit: UnitPressure.degrees)))
    }
}

struct EvapPressureAltDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let value = Double(bytesToInt(data)) - 32767
        return  (.measurementResult(MeasurementResult(value: value, unit: Unit.Pascal)))
    }
}

struct AbsEvapPressureDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let value = Double(bytesToInt(data)) / 200
        return  (.measurementResult(MeasurementResult(value: value, unit: UnitPressure.kilopascals)))
    }
}

struct FuelTypeDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        guard data.count > 0, let code = data.dropFirst().first else {
            throw DecodeError.invalidData
        }

        guard Int(code) < FuelTypes.count else {
            throw DecodeError.invalidData
        }

        let fuelTypeString = FuelTypes[Int(code)]
        let fuelType = FuelType(code: code, type: fuelTypeString)

        return .fuelType(fuelType)
    }
}

struct MaxMafDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        guard data.count > 0, let a = data.dropFirst().first else {
            throw DecodeError.invalidData
        }
        let value = Int(a) * 10
        return  (.measurementResult(MeasurementResult(value: Double(value), unit: Unit.gramsPerSecond)))
    }
}

struct AbsoluteLoadDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let value = (bytesToInt(data) * 100) / 255
        return  (.measurementResult(MeasurementResult(value: Double(value), unit: Unit.percent)))
    }
}


struct EvapPressureDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        guard data.count > 1 else {
            throw DecodeError.invalidData
        }
        guard data.count >= 2,
              let firstByte = data.dropFirst().first,
              let secondByte = data.dropFirst(2).first else {
            throw DecodeError.invalidData
        }

        let a = twosComp(Int(firstByte), length: 8)
        let b = twosComp(Int(secondByte), length: 8)

        let value = ((Double(a) * 256.0) + Double(b)) / 4.0
        return  .measurementResult(MeasurementResult(value: value, unit: UnitPressure.kilopascals))
    }
}

struct SensorVoltageBigDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        guard data.indices.contains(2) && data.indices.contains(3) else {
            throw DecodeError.invalidData
        }
        let value = bytesToInt(data[2 ..< 4])
        let voltage = (Double(value) * 8.0) / 65535
        return  .measurementResult(MeasurementResult(value: voltage, unit: UnitElectricPotentialDifference.volts))
    }
}

struct SensorVoltageDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        guard data.count == 3 else {
            let error = DecodeError.insufficientData(expected: 3, got: data.count)
            obdError("insufficient Data expected: 3, got: \(data.count)")
            throw error
        }
        let voltage = Double(data.dropFirst().first ?? 0) / 200
        return  .measurementResult(MeasurementResult(value: voltage, unit: UnitElectricPotentialDifference.volts))
    }
}

public struct O2SensorStatus: Codable {
    let bank1: [Int]  // Sensor positions that are present
    let bank2: [Int]

    var description: String {
        var desc = ""
        if !bank1.isEmpty {
            desc += "Bank 1: Sensors \(bank1.map { String($0) }.joined(separator: ", "))"
        }
        if !bank2.isEmpty {
            if !desc.isEmpty { desc += " | " }
            desc += "Bank 2: Sensors \(bank2.map { String($0) }.joined(separator: ", "))"
        }
        if desc.isEmpty {
            desc = "No O2 sensors detected"
        }
        return desc
    }

    var totalSensors: Int {
        return bank1.count + bank2.count
    }
}

struct O2SensorsDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let bits = BitArray(data: data.dropFirst())

        // For PID 0x13, the byte indicates which sensors are present
        // Bits 0-3: Bank 1, Sensors 1-4
        // Bits 4-7: Bank 2, Sensors 1-4

        var bank1Sensors: [Int] = []
        var bank2Sensors: [Int] = []

        // Check Bank 1 (first 4 bits)
        for i in 0..<4 {
            if bits.binaryArray[i] == 1 {
                bank1Sensors.append(i + 1)  // Sensor numbers are 1-based
            }
        }

        // Check Bank 2 (next 4 bits)
        for i in 4..<8 {
            if bits.binaryArray[i] == 1 {
                bank2Sensors.append(i - 3)  // Sensors 1-4 for bank 2
            }
        }

        let status = O2SensorStatus(bank1: bank1Sensors, bank2: bank2Sensors)

        return .o2SensorStatus(status)

    }
}

struct O2SensorsAltDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let bits = BitArray(data: data.dropFirst())

        // For PID 0x1D, the byte indicates which sensors are present
        // This PID supports up to 4 banks with 2 sensors each
        // Bits 0-1: Bank 1, Sensors 1-2
        // Bits 2-3: Bank 2, Sensors 1-2
        // Bits 4-5: Bank 3, Sensors 1-2
        // Bits 6-7: Bank 4, Sensors 1-2

        var banks: [String] = []

        // Bank 1
        var bank1Sensors: [Int] = []
        for i in 0..<2 {
            if bits.binaryArray[i] == 1 {
                bank1Sensors.append(i + 1)
            }
        }
        if !bank1Sensors.isEmpty {
            banks.append("Bank 1: Sensors \(bank1Sensors.map { String($0) }.joined(separator: ", "))")
        }

        // Bank 2
        var bank2Sensors: [Int] = []
        for i in 2..<4 {
            if bits.binaryArray[i] == 1 {
                bank2Sensors.append(i - 1)  // Sensors 1-2
            }
        }
        if !bank2Sensors.isEmpty {
            banks.append("Bank 2: Sensors \(bank2Sensors.map { String($0) }.joined(separator: ", "))")
        }

        // Bank 3
        var bank3Sensors: [Int] = []
        for i in 4..<6 {
            if bits.binaryArray[i] == 1 {
                bank3Sensors.append(i - 3)  // Sensors 1-2
            }
        }
        if !bank3Sensors.isEmpty {
            banks.append("Bank 3: Sensors \(bank3Sensors.map { String($0) }.joined(separator: ", "))")
        }

        // Bank 4
        var bank4Sensors: [Int] = []
        for i in 6..<8 {
            if bits.binaryArray[i] == 1 {
                bank4Sensors.append(i - 5)  // Sensors 1-2
            }
        }
        if !bank4Sensors.isEmpty {
            banks.append("Bank 4: Sensors \(bank4Sensors.map { String($0) }.joined(separator: ", "))")
        }

        let description = banks.isEmpty ? "No O2 sensors detected" : banks.joined(separator: " | ")
        return .stringResult([description])
    }
}

struct OBDComplianceDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        guard data.count > 0, let code = data.dropFirst().first else {
            throw DecodeError.invalidData
        }

        guard Int(code) < OBD_COMPLIANCE.count else {
            throw DecodeError.decodingFailed(reason: "Invalid OBD compliance code: \(code)")
        }

        let standard = OBD_COMPLIANCE[Int(code)]
        let compliance = OBDCompliance(
            code: code,
            standard: standard,
            description: getComplianceDescription(for: standard)
        )

        return .obdCompliance(compliance)
    }

    private func getComplianceDescription(for standard: String) -> String {
        if standard.contains("OBD-II") {
            return "Vehicle meets OBD-II standards for emissions monitoring"
        } else if standard.contains("EOBD") {
            return "Vehicle meets European On-Board Diagnostics standards"
        } else if standard.contains("HD OBD") {
            return "Vehicle meets Heavy Duty OBD standards"
        }
        return standard
    }
}

struct TimingAdvanceDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let value = Double(data.dropFirst().first ?? 0) / 2.0 - 64.0
        return  .measurementResult(MeasurementResult(value: value, unit: UnitAngle.degrees))
    }
}

struct PressureDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let value = data.dropFirst().first ?? 0
        return  .measurementResult(MeasurementResult(value: Double(value), unit: UnitPressure.kilopascals))
    }
}


struct FuelPressureDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        var value = Double(data.dropFirst().first ?? 0)
        value = value * 3
        return  .measurementResult(MeasurementResult(value: value, unit: UnitPressure.kilopascals))
    }
}

struct AirStatusDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let bits = BitArray(data: data.dropFirst()).binaryArray

        let numSet = bits.filter { $0 == 1 }.count
        if numSet == 1, let bitIndex = bits.firstIndex(of: 1) {
            let statusIndex = 7 - bitIndex
            let airStatus = AirFlowStatus(index: statusIndex)
            return .airFlowStatus(airStatus)
        }

        throw DecodeError.invalidData
    }
}

struct FuelStatusDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        guard data.count >= 2 else {
            throw DecodeError.invalidData
        }

        let bits = BitArray(data: data.dropFirst())
        var status1: String?
        var status2: String?

        let highBits = Array(bits.binaryArray[0..<8])
        let lowBits = Array(bits.binaryArray[8..<16])

        // Process first fuel system
        if highBits.filter({ $0 == 1 }).count == 1, let index = highBits.firstIndex(of: 1) {
            let statusIndex = 7 - index
            if statusIndex < FUEL_STATUS.count {
                status1 = FUEL_STATUS[statusIndex]
            }
        }

        // Process second fuel system
        if lowBits.filter({ $0 == 1 }).count == 1, let index = lowBits.firstIndex(of: 1) {
            let statusIndex = 7 - index
            if statusIndex < FUEL_STATUS.count {
                status2 = FUEL_STATUS[statusIndex]
            }
        }

        let fuelStatus = FuelSystemStatus(system1: status1, system2: status2)
        return .fuelSystemStatus(fuelStatus)
    }
}

struct SingleDTCDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let troubleCode = parseDTC(data.dropFirst())
        return  .troubleCode(troubleCode.map { [$0] } ?? [])
    }
}

struct CurrentCenteredDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        var value = Double(bytesToInt(data.dropFirst(2)))
        value = (value / 256.0) - 128.0
        return  .measurementResult(MeasurementResult(value: value, unit: UnitElectricCurrent.milliamperes))
    }
}

struct PercentCenteredDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        var value = Double(data.dropFirst().first ?? 0)
        value = (value - 128) * 100.0 / 128.0
        return  .measurementResult(MeasurementResult(value: value, unit: Unit.percent))
    }
}

struct PercentDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        var value = Double(data.dropFirst().first ?? 0)
        value = value * 100.0 / 255.0
        return  .measurementResult(MeasurementResult(value: value, unit: Unit.percent))
    }
}

struct TemperatureDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let value = Double(bytesToInt(data)) - 40.0
        return  .measurementResult(MeasurementResult(value: value, unit: UnitTemperature.celsius))
    }
}

struct StringDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        guard var string = String(bytes: data.dropFirst(), encoding: .utf8) else {
            throw  DecodeError.decodingFailed(reason: "Failed to decode string")
        }

        string = string
            .replacingOccurrences(of: "[^a-zA-Z0-9]",
                                  with: "",
                                  options: .regularExpression)

        return  .stringResult([string])
    }
}

struct UASDecoder: OBDDecoder {
    let id: UInt8

    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        guard let uas = uasIDS[id] else {
            throw DecodeError.invalidData
        }
        return  (.measurementResult(uas.decode(bytes: data, unit)))
    }
}

struct StatusDecoder: OBDDecoder {
    func decode(data: Data, unit: MeasurementUnit) throws -> DecodeResult {
        let IGNITIONTYPE = ["Spark", "Compression"]
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

        // convert to binaryarray
        let bits = BitArray(data: data.dropFirst())

        var output = Status()
        output.MIL = bits.binaryArray[0] == 1
        output.dtcCount = bits.value(at: 1 ..< 8)
        output.ignitionType = IGNITIONTYPE[bits.binaryArray[12]]

        // load the 3 base tests that are always present

        for (index, name) in baseTests.reversed().enumerated() {
            processBaseTest(name, index, bits, &output)
        }
        return  .statusResult(output)
    }

    func processBaseTest(_ testName: String, _ index: Int, _ bits: BitArray, _ output: inout Status) {
        let test = StatusTest(testName, bits.binaryArray[13 + index] != 0, bits.binaryArray[9 + index] == 0)
        switch testName {
        case "MISFIRE_MONITORING":
            output.misfireMonitoring = test
        case "FUEL_SYSTEM_MONITORING":
            output.fuelSystemMonitoring = test
        case "COMPONENT_MONITORING":
            output.componentMonitoring = test
        default:
            break
        }
    }
}

func parseDTC(_ data: Data) -> TroubleCode? {
    if (data.count != 2) || (data == Data([0x00, 0x00])) {
        return nil
    }
    guard let first = data.first, let second = data.last else { return nil }

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

public enum MeasurementUnit: String, Codable {
    case metric = "Metric"
    case imperial = "Imperial"

    public static var allCases: [MeasurementUnit] {
        [.metric, .imperial]
    }
}

public struct Status: Codable, Hashable {
    var MIL: Bool = false
    public var dtcCount: UInt8 = 0
    var ignitionType: String = ""

    var misfireMonitoring = StatusTest()
    var fuelSystemMonitoring = StatusTest()
    var componentMonitoring = StatusTest()
}

struct StatusTest: Codable, Hashable {
    var name: String = ""
    var supported: Bool = false
    var ready: Bool = false

    init(_ name: String = "", _ supported: Bool = false, _ ready: Bool = false) {
        self.name = name
        self.supported = supported
        self.ready = ready
    }
}

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
        var value: UInt8 = 0
        for bit in range {
            value = value << 1
            value = value | UInt8(binaryArray[bit])
        }
        return value
    }
}

extension Unit {
    static let percent = Unit(symbol: "%")
    static let count = Unit(symbol: "count")
//    static let celsius = Unit(symbol: "°C")
    static let degrees = Unit(symbol: "°")
    static let gramsPerSecond = Unit(symbol: "g/s")
    static let none = Unit(symbol: "")
    static let rpm = Unit(symbol: "rpm")
//    static let kph = Unit(symbol: "KP/H")
//    static let mph = Unit(symbol: "MP/H")

    static let Pascal = Unit(symbol: "Pa")
    static let bar = Unit(symbol: "bar")
    static let ppm = Unit(symbol: "ppm")
    static let ratio = Unit(symbol: "ratio")
}

let baseTests = [
    "MISFIRE_MONITORING",
    "FUEL_SYSTEM_MONITORING",
    "COMPONENT_MONITORING"
]

let sparkTests = [
    "CATALYST_MONITORING",
    "HEATED_CATALYST_MONITORING",
    "EVAPORATIVE_SYSTEM_MONITORING",
    "SECONDARY_AIR_SYSTEM_MONITORING",
    nil,
    "OXYGEN_SENSOR_MONITORING",
    "OXYGEN_SENSOR_HEATER_MONITORING",
    "EGR_VVT_SYSTEM_MONITORING"
]

let compressionTests = [
    "NMHC_CATALYST_MONITORING",
    "NOX_SCR_AFTERTREATMENT_MONITORING",
    nil,
    "BOOST_PRESSURE_MONITORING",
    nil,
    "EXHAUST_GAS_SENSOR_MONITORING",
    "PM_FILTER_MONITORING",
    "EGR_VVT_SYSTEM_MONITORING"
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

let TestIds: [UInt8: (String, String)] = [
    0x01: ("RTLThresholdVoltage", "The voltage at which the sensor switches from rich to lean"),
    0x02: ("LTRThresholdVoltage", "The voltage at which the sensor switches from lean to rich"),
    0x03: ("LowVoltageSwitchTime", "The time it takes for the sensor to switch from rich to lean"),
    0x04: ("HighVoltageSwitchTime", "The time it takes for the sensor to switch from lean to rich"),
    0x05: ("RTLSwitchTime", "The time it takes for the sensor to switch from rich to lean"),
    0x06: ("LTRSwitchTime", "The time it takes for the sensor to switch from lean to rich"),
    0x07: ("MINVoltage", "The minimum voltage the sensor can output"),
    0x08: ("MAXVoltage", "The maximum voltage the sensor can output"),
    0x09: ("TransitionTime", "The time it takes for the sensor to transition from one voltage to another"),
    0x0A: ("SensorPeriod", "The time between sensor readings"),
    0x0B: ("MisFireAverage", "The average number of misfires per 1000 revolutions"),
    0x0C: ("MisFireCount", "The number of misfires since the last reset")
]


fileprivate func bytesToInt(_ byteArray: Data) -> Int {
    let data = byteArray.dropFirst()
    var value = 0
    var power = 0

    for byte in  data.reversed() {
        value += Int(byte) << power
        power += 8
    }
    return value
}

class UAS {
    let signed: Bool
    let scale: Double
    var unit: Unit
    let offset: Double

    init(signed: Bool, scale: Double, unit: Unit, offset: Double = 0.0) {
        self.signed = signed
        self.scale = scale
        self.unit = unit
        self.offset = offset
    }

    func decode(bytes: Data, _ unit_: MeasurementUnit = .metric) -> MeasurementResult {
        var value = bytesToInt(bytes)

        if signed {
            value = twosComp(value, length: bytes.count * 8)
        }

        var scaledValue = Double(value) * scale + offset

        if unit_ == .imperial {
            scaledValue = convertToImperial(scaledValue, unitType: self.unit)
        }

        return MeasurementResult(value: scaledValue, unit: unit)
    }


    private func convertToImperial(_ value: Double, unitType: Unit) -> Double {
          switch unitType {
          case UnitTemperature.celsius:
              self.unit = UnitTemperature.fahrenheit
              return (value * 1.8) + 32 // Convert Celsius to Fahrenheit
          case UnitLength.kilometers:
                self.unit = UnitLength.miles
                return value * 0.621371 // Convert km to miles
          case UnitSpeed.kilometersPerHour:
              self.unit = UnitSpeed.milesPerHour
              return value * 0.621371 // Convert km/h to mph
          case UnitPressure.kilopascals:
              self.unit = UnitPressure.poundsForcePerSquareInch
                return value * 0.145038 // Convert kPa to psi
          case .gramsPerSecond:
              return value * 0.00220462 // Convert grams/sec to pounds/sec
            case .bar:
                self.unit = UnitPressure.poundsForcePerSquareInch
                return value * 14.5038 // Convert bar to psi
          default:
              return value // Other units remain unchanged
          }
      }
}

func twosComp(_ value: Int, length: Int) -> Int {
    let mask = (1 << length) - 1
    return value & mask
}
