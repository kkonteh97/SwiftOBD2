//
//  commands.swift
//  SmartOBD2
//
//  Created by kemo konteh on 9/14/23.
//

import Foundation

public extension DecodeResult {
//    var stringResult: String? {
//        if case let .stringResult(res) = self { return res as String }
//        return nil
//    }

    var statusResult: Status? {
        if case let .statusResult(res) = self { return res as Status }
        return nil
    }

    var measurementResult: MeasurementResult? {
        if case let .measurementResult(res) = self { return res as MeasurementResult }
        return nil
    }

    var troubleCode: [TroubleCode]? {
        if case let .troubleCode(res) = self { return res as [TroubleCode] }
        return nil
    }

    var measurementMonitor: Monitor? {
        if case let .measurementMonitor(res) = self { return res as Monitor }
        return nil
    }
}

public struct CommandProperties: Encodable {
    public let command: String
    public let description: String
    let bytes: Int
    let decoder: Decoders
    public let live: Bool
    public let maxValue: Double
    public let minValue: Double

    public init(_ command: String,
                _ description: String,
                _ bytes: Int,
                _ decoder: Decoders,
                _ live: Bool = false,
                maxValue: Double = 100,
                minValue: Double = 0) {
        self.command = command
        self.description = description
        self.bytes = bytes
        self.decoder = decoder
        self.live = live
        self.maxValue = maxValue
        self.minValue = minValue
    }

//    public func decode(data: Data, unit: MeasurementUnit = .metric) -> Result<DecodeResult, DecodeError> {
//        return decoder.performDecode(data: data.dropFirst(), unit: unit)
//    }

    func decode(data: Data, unit: MeasurementUnit = .metric) -> Result<DecodeResult, DecodeError> {
        guard let decoderInstance = decoder.getDecoder() else {
            return .failure(.unsupportedDecoder)
        }
        return decoderInstance.decode(data: data.dropFirst(), unit: unit)
    }
}

public enum OBDCommand: Codable, Hashable, Comparable {
    case general(General)
    case mode1(Mode1)
    case mode3(Mode3)
    case mode6(Mode6)
    case mode9(Mode9)
    case protocols(Protocols)

    public var properties: CommandProperties {
        switch self {
        case let .general(command):
            return command.properties
        case let .mode1(command):
            return command.properties
        case let .mode9(command):
            return command.properties
        case let .mode6(command):
            return command.properties
        case let .mode3(command):
            return command.properties
        case let .protocols(command):
            return command.properties
        }
    }

    public enum General: CaseIterable, Codable, Comparable {
        case ATD
        case ATZ
        case ATRV
        case ATL0
        case ATE0
        case ATH1
        case ATH0
        case ATAT1
        case ATSTFF
        case ATDPN
    }

    public enum Protocols: CaseIterable, Codable, Comparable {
        case ATSP0
        case ATSP6
        public var properties: CommandProperties {
            switch self {
            case .ATSP0: return CommandProperties("ATSP0", "Auto protocol", 0, .none)
            case .ATSP6: return CommandProperties("ATSP6", "Auto protocol", 0, .none)

            }
        }
    }

    public enum Mode1: CaseIterable, Codable, Comparable {
        case pidsA
        case status
        case freezeDTC
        case fuelStatus
        case engineLoad
        case coolantTemp
        case shortFuelTrim1
        case longFuelTrim1
        case shortFuelTrim2
        case longFuelTrim2
        case fuelPressure
        case intakePressure
        case rpm
        case speed
        case timingAdvance
        case intakeTemp
        case maf
        case throttlePos
        case airStatus
        case O2Sensor
        case O2Bank1Sensor1
        case O2Bank1Sensor2
        case O2Bank1Sensor3
        case O2Bank1Sensor4
        case O2Bank2Sensor1
        case O2Bank2Sensor2
        case O2Bank2Sensor3
        case O2Bank2Sensor4
        case obdcompliance
        case O2SensorsALT
        case auxInputStatus
        case runTime
        case pidsB
        case distanceWMIL
        case fuelRailPressureVac
        case fuelRailPressureDirect
        case O2Sensor1WRVolatage
        case O2Sensor2WRVolatage
        case O2Sensor3WRVolatage
        case O2Sensor4WRVolatage
        case O2Sensor5WRVolatage
        case O2Sensor6WRVolatage
        case O2Sensor7WRVolatage
        case O2Sensor8WRVolatage
        case commandedEGR
        case EGRError
        case evaporativePurge
        case fuelLevel
        case warmUpsSinceDTCCleared
        case distanceSinceDTCCleared
        case evapVaporPressure
        case barometricPressure
        case O2Sensor1WRCurrent
        case O2Sensor2WRCurrent
        case O2Sensor3WRCurrent
        case O2Sensor4WRCurrent
        case O2Sensor5WRCurrent
        case O2Sensor6WRCurrent
        case O2Sensor7WRCurrent
        case O2Sensor8WRCurrent
        case catalystTempB1S1
        case catalystTempB2S1
        case catalystTempB1S2
        case catalystTempB2S2
        case pidsC
        case statusDriveCycle
        case controlModuleVoltage
        case absoluteLoad
        case commandedEquivRatio
        case relativeThrottlePos
        case ambientAirTemp
        case throttlePosB
        case throttlePosC
        case throttlePosD
        case throttlePosE
        case throttlePosF
        case throttleActuator
        case runTimeMIL
        case timeSinceDTCCleared
        case maxValues
        case maxMAF
        case fuelType
        case ethanoPercent
        case evapVaporPressureAbs
        case evapVaporPressureAlt
        case shortO2TrimB1
        case longO2TrimB1
        case shortO2TrimB2
        case longO2TrimB2
        case fuelRailPressureAbs
        case relativeAccelPos
        case hybridBatteryLife
        case engineOilTemp
        case fuelInjectionTiming
        case fuelRate
        case emissionsReq
    }

    public enum Mode3: CaseIterable, Codable, Comparable {
        case GET_DTC
        var properties: CommandProperties {
            switch self {
            case .GET_DTC: return CommandProperties("03", "Get DTCs", 0, .dtc)
            }
        }
    }

    public enum Mode4: CaseIterable, Codable, Comparable {
        case CLEAR_DTC
        var properties: CommandProperties {
            switch self {
            case .CLEAR_DTC: return CommandProperties("04", "Clear DTCs and freeze data", 0, .none)
            }
        }
    }

    public enum Mode6: CaseIterable, Codable, Comparable {
        case MIDS_A
        case MONITOR_O2_B1S1
        case MONITOR_O2_B1S2
        case MONITOR_O2_B1S3
        case MONITOR_O2_B1S4
        case MONITOR_O2_B2S1
        case MONITOR_O2_B2S2
        case MONITOR_O2_B2S3
        case MONITOR_O2_B2S4
        case MONITOR_O2_B3S1
        case MONITOR_O2_B3S2
        case MONITOR_O2_B3S3
        case MONITOR_O2_B3S4
        case MONITOR_O2_B4S1
        case MONITOR_O2_B4S2
        case MONITOR_O2_B4S3
        case MONITOR_O2_B4S4
        case MIDS_B
        case MONITOR_CATALYST_B1
        case MONITOR_CATALYST_B2
        case MONITOR_CATALYST_B3
        case MONITOR_CATALYST_B4
        case MONITOR_EGR_B1
        case MONITOR_EGR_B2
        case MONITOR_EGR_B3
        case MONITOR_EGR_B4
        case MONITOR_VVT_B1
        case MONITOR_VVT_B2
        case MONITOR_VVT_B3
        case MONITOR_VVT_B4
        case MONITOR_EVAP_150
        case MONITOR_EVAP_090
        case MONITOR_EVAP_040
        case MONITOR_EVAP_020
        case MONITOR_PURGE_FLOW
        case MIDS_C
        case MONITOR_O2_HEATER_B1S1
        case MONITOR_O2_HEATER_B1S2
        case MONITOR_O2_HEATER_B1S3
        case MONITOR_O2_HEATER_B1S4
        case MONITOR_O2_HEATER_B2S1
        case MONITOR_O2_HEATER_B2S2
        case MONITOR_O2_HEATER_B2S3
        case MONITOR_O2_HEATER_B2S4
        case MONITOR_O2_HEATER_B3S1
        case MONITOR_O2_HEATER_B3S2
        case MONITOR_O2_HEATER_B3S3
        case MONITOR_O2_HEATER_B3S4
        case MONITOR_O2_HEATER_B4S1
        case MONITOR_O2_HEATER_B4S2
        case MONITOR_O2_HEATER_B4S3
        case MONITOR_O2_HEATER_B4S4
        case MIDS_D
        case MONITOR_HEATED_CATALYST_B1
        case MONITOR_HEATED_CATALYST_B2
        case MONITOR_HEATED_CATALYST_B3
        case MONITOR_HEATED_CATALYST_B4
        case MONITOR_SECONDARY_AIR_1
        case MONITOR_SECONDARY_AIR_2
        case MONITOR_SECONDARY_AIR_3
        case MONITOR_SECONDARY_AIR_4
        case MIDS_E
        case MONITOR_FUEL_SYSTEM_B1
        case MONITOR_FUEL_SYSTEM_B2
        case MONITOR_FUEL_SYSTEM_B3
        case MONITOR_FUEL_SYSTEM_B4
        case MONITOR_BOOST_PRESSURE_B1
        case MONITOR_BOOST_PRESSURE_B2
        case MONITOR_NOX_ABSORBER_B1
        case MONITOR_NOX_ABSORBER_B2
        case MONITOR_NOX_CATALYST_B1
        case MONITOR_NOX_CATALYST_B2
        case MIDS_F
        case MONITOR_MISFIRE_GENERAL
        case MONITOR_MISFIRE_CYLINDER_1
        case MONITOR_MISFIRE_CYLINDER_2
        case MONITOR_MISFIRE_CYLINDER_3
        case MONITOR_MISFIRE_CYLINDER_4
        case MONITOR_MISFIRE_CYLINDER_5
        case MONITOR_MISFIRE_CYLINDER_6
        case MONITOR_MISFIRE_CYLINDER_7
        case MONITOR_MISFIRE_CYLINDER_8
        case MONITOR_MISFIRE_CYLINDER_9
        case MONITOR_MISFIRE_CYLINDER_10
        case MONITOR_MISFIRE_CYLINDER_11
        case MONITOR_MISFIRE_CYLINDER_12
        case MONITOR_PM_FILTER_B1
        case MONITOR_PM_FILTER_B2
    }

    public enum Mode9: CaseIterable, Codable, Comparable {
        case PIDS_9A
        case VIN_MESSAGE_COUNT
        case VIN
        case CALIBRATION_ID_MESSAGE_COUNT
        case CALIBRATION_ID
        case CVN_MESSAGE_COUNT
        case CVN
        var properties: CommandProperties {
            switch self {
            case .PIDS_9A: return CommandProperties("0900", "Supported PIDs [01-20]", 7, .pid)
            case .VIN_MESSAGE_COUNT: return CommandProperties("0901", "VIN Message Count", 3, .count)
            case .VIN: return CommandProperties("0902", "Vehicle Identification Number", 22, .encoded_string)
            case .CALIBRATION_ID_MESSAGE_COUNT: return CommandProperties("0903", "Calibration ID message count for PID 04", 3, .count)
            case .CALIBRATION_ID: return CommandProperties("0904", "Calibration ID", 18, .encoded_string)
            case .CVN_MESSAGE_COUNT: return CommandProperties("0905", "CVN Message Count for PID 06", 3, .count)
            case .CVN: return CommandProperties("0906", "Calibration Verification Numbers", 10, .cvn)
            }
        }
    }

    static var pidGetters: [OBDCommand] = {
        var getters: [OBDCommand] = []
        for command in OBDCommand.Mode1.allCases {
            if command.properties.decoder == .pid {
                getters.append(.mode1(command))
            }
        }

        for command in OBDCommand.Mode6.allCases {
            if command.properties.decoder == .pid {
                getters.append(.mode6(command))
            }
        }

        for command in OBDCommand.Mode9.allCases {
            if command.properties.decoder == .pid {
                getters.append(.mode9(command))
            }
        }
        return getters
    }()

    static public var allCommands: [OBDCommand] = {
        var commands: [OBDCommand] = []
        for command in OBDCommand.General.allCases {
            commands.append(.general(command))
        }

        for command in OBDCommand.Mode1.allCases {
            commands.append(.mode1(command))
        }

        for command in OBDCommand.Mode3.allCases {
            commands.append(.mode3(command))
        }

        for command in OBDCommand.Mode6.allCases {
            commands.append(.mode6(command))
        }

        for command in OBDCommand.Mode9.allCases {
            commands.append(.mode9(command))
        }
        for command in OBDCommand.Protocols.allCases {
            commands.append(.protocols(command))
        }
        return commands
    }()
}

extension OBDCommand.General {
    public var properties: CommandProperties {
        switch self {
        case .ATD: return CommandProperties("ATD", "Set to default", 5, .none)
        case .ATZ: return CommandProperties("ATZ", "Reset", 5, .none)
        case .ATRV: return CommandProperties("ATRV", "Voltage", 5, .none)
        case .ATL0: return CommandProperties("ATL0", "Linefeeds Off", 5, .none)
        case .ATE0: return CommandProperties("ATE0", "Echo Off", 5, .none)
        case .ATH1: return CommandProperties("ATH1", "Headers On", 5, .none)
        case .ATH0: return CommandProperties("ATH0", "Headers Off", 5, .none)
        case .ATAT1: return CommandProperties("ATAT1", "Adaptive Timing On", 5, .none)
        case .ATSTFF: return CommandProperties("ATSTFF", "Set Time to Fast", 5, .none)
        case .ATDPN: return CommandProperties("ATDPN", "Describe Protocol Number", 5, .none)
        }
    }
}

extension OBDCommand.Mode1 {
    var properties: CommandProperties {
        switch self {
        case .pidsA: return CommandProperties("0100", "Supported PIDs [01-20]", 5, .pid)
        case .status: return CommandProperties("0101", "Status since DTCs cleared", 5, .status)
        case .freezeDTC: return CommandProperties("0102", "DTC that triggered the freeze frame", 5, .singleDTC)
        case .fuelStatus: return CommandProperties("0103", "Fuel System Status", 5, .fuelStatus)
        case .engineLoad: return CommandProperties("0104", "Calculated Engine Load", 2, .percent, true)
        case .coolantTemp: return CommandProperties("0105", "Coolant temperature", 2, .temp, true, maxValue: 215, minValue: -40)
        case .shortFuelTrim1: return CommandProperties("0106", "Short Term Fuel Trim - Bank 1", 2, .percentCentered, true)
        case .longFuelTrim1: return CommandProperties("0107", "Long Term Fuel Trim - Bank 1", 2, .percentCentered, true)
        case .shortFuelTrim2: return CommandProperties("0108", "Short Term Fuel Trim - Bank 2", 2, .percentCentered, true)
        case .longFuelTrim2: return CommandProperties("0109", "Long Term Fuel Trim - Bank 2", 2, .percentCentered, true)
        case .fuelPressure: return CommandProperties("010A", "Fuel Pressure", 2, .fuelPressure, true, maxValue: 765)
        case .intakePressure: return CommandProperties("010B", "Intake Manifold Pressure", 3, .pressure, true, maxValue: 255)
        case .rpm: return CommandProperties("010C", "RPM", 3, .uas(0x07), true, maxValue: 8000)
        case .speed: return CommandProperties("010D", "Vehicle Speed", 2, .uas(0x09), true, maxValue: 280)
        case .timingAdvance: return CommandProperties("010E", "Timing Advance", 2, .timingAdvance, true, maxValue: 64, minValue: -64)
        case .intakeTemp: return CommandProperties("010F", "Intake Air Temp", 2, .temp, true)
        case .maf: return CommandProperties("0110", "Air Flow Rate (MAF)", 3, .uas(0x27), true)
        case .throttlePos: return CommandProperties("0111", "Throttle Position", 2, .percent, true)
        case .airStatus: return CommandProperties("0112", "Secondary Air Status", 2, .airStatus)
        case .O2Sensor: return CommandProperties("0113", "O2 Sensors Present", 2, .o2Sensors)
        case .O2Bank1Sensor1: return CommandProperties("0114", "O2: Bank 1 - Sensor 1 Voltage", 3, .sensorVoltage, true, maxValue: 1.275)
        case .O2Bank1Sensor2: return CommandProperties("0115", "O2: Bank 1 - Sensor 2 Voltage", 3, .sensorVoltage, true, maxValue: 1.275)
        case .O2Bank1Sensor3: return CommandProperties("0116", "O2: Bank 1 - Sensor 3 Voltage", 3, .sensorVoltage, true, maxValue: 1.275)
        case .O2Bank1Sensor4: return CommandProperties("0117", "O2: Bank 1 - Sensor 4 Voltage", 3, .sensorVoltage, true, maxValue: 1.275)
        case .O2Bank2Sensor1: return CommandProperties("0118", "O2: Bank 2 - Sensor 1 Voltage", 3, .sensorVoltage, true, maxValue: 1.275)
        case .O2Bank2Sensor2: return CommandProperties("0119", "O2: Bank 2 - Sensor 2 Voltage", 3, .sensorVoltage, true, maxValue: 1.275)
        case .O2Bank2Sensor3: return CommandProperties("011A", "O2: Bank 2 - Sensor 3 Voltage", 3, .sensorVoltage, true, maxValue: 1.275)
        case .O2Bank2Sensor4: return CommandProperties("011B", "O2: Bank 2 - Sensor 4 Voltage", 3, .sensorVoltage, true, maxValue: 1.275)
        case .obdcompliance: return CommandProperties("011C", "OBD Standards Compliance", 2, .obdCompliance)
        case .O2SensorsALT: return CommandProperties("011D", "O2 Sensors Present (alternate)", 2, .o2SensorsAlt)
        case .auxInputStatus: return CommandProperties("011E", "Auxiliary input status (power take off)", 2, .auxInputStatus)
        case .runTime: return CommandProperties("011F", "Engine Run Time", 3, .uas(0x12), true)
        case .pidsB: return CommandProperties("0120", "Supported PIDs [21-40]", 5, .pid)
        case .distanceWMIL: return CommandProperties("0121", "Distance Traveled with MIL on", 4, .uas(0x25), true)
        case .fuelRailPressureVac: return CommandProperties("0122", "Fuel Rail Pressure (relative to vacuum)", 4, .uas(0x19), true)
        case .fuelRailPressureDirect: return CommandProperties("0123", "Fuel Rail Pressure (direct inject)", 4, .uas(0x1B), true)
        case .O2Sensor1WRVolatage: return CommandProperties("0124", "02 Sensor 1 WR Lambda Voltage", 6, .sensorVoltageBig, true, maxValue: 8.192)
        case .O2Sensor2WRVolatage: return CommandProperties("0125", "02 Sensor 2 WR Lambda Voltage", 6, .sensorVoltageBig, true, maxValue: 8.192)
        case .O2Sensor3WRVolatage: return CommandProperties("0126", "02 Sensor 3 WR Lambda Voltage", 6, .sensorVoltageBig, true, maxValue: 8.192)
        case .O2Sensor4WRVolatage: return CommandProperties("0127", "02 Sensor 4 WR Lambda Voltage", 6, .sensorVoltageBig, true, maxValue: 8.192)
        case .O2Sensor5WRVolatage: return CommandProperties("0128", "02 Sensor 5 WR Lambda Voltage", 6, .sensorVoltageBig, true, maxValue: 8.192)
        case .O2Sensor6WRVolatage: return CommandProperties("0129", "02 Sensor 6 WR Lambda Voltage", 6, .sensorVoltageBig, true, maxValue: 8.192)
        case .O2Sensor7WRVolatage: return CommandProperties("012A", "02 Sensor 7 WR Lambda Voltage", 6, .sensorVoltageBig, true, maxValue: 8.192)
        case .O2Sensor8WRVolatage: return CommandProperties("012B", "02 Sensor 8 WR Lambda Voltage", 6, .sensorVoltageBig, true, maxValue: 8.192)
        case .commandedEGR: return CommandProperties("012C", "Commanded EGR", 4, .percent, true)
        case .EGRError: return CommandProperties("012D", "EGR Error", 4, .percentCentered, true)
        case .evaporativePurge: return CommandProperties("012E", "Commanded Evaporative Purge", 4, .percent, true)
        case .fuelLevel: return CommandProperties("012F", "Fuel Tank Level Input", 4, .percent, true)
        case .warmUpsSinceDTCCleared: return CommandProperties("0130", "Number of warm-ups since codes cleared", 4, .uas(0x01), true)
        case .distanceSinceDTCCleared: return CommandProperties("0131", "Distance traveled since codes cleared", 4, .uas(0x25), true, maxValue: 65535.0)
        case .evapVaporPressure: return CommandProperties("0132", "Evaporative system vapor pressure", 4, .evapPressure, true)
        case .barometricPressure: return CommandProperties("0133", "Barometric Pressure", 4, .pressure, true, maxValue: 255.0)
        case .O2Sensor1WRCurrent: return CommandProperties("0134", "02 Sensor 1 WR Lambda Current", 4, .currentCentered, true, maxValue: 128, minValue: -128)
        case .O2Sensor2WRCurrent: return CommandProperties("0135", "02 Sensor 2 WR Lambda Current", 4, .currentCentered, true, maxValue: 128, minValue: -128)
        case .O2Sensor3WRCurrent: return CommandProperties("0136", "02 Sensor 3 WR Lambda Current", 4, .currentCentered, true, maxValue: 128, minValue: -128)
        case .O2Sensor4WRCurrent: return CommandProperties("0137", "02 Sensor 4 WR Lambda Current", 4, .currentCentered, true, maxValue: 128, minValue: -128)
        case .O2Sensor5WRCurrent: return CommandProperties("0138", "02 Sensor 5 WR Lambda Current", 4, .currentCentered, true, maxValue: 128, minValue: -128)
        case .O2Sensor6WRCurrent: return CommandProperties("0139", "02 Sensor 6 WR Lambda Current", 4, .currentCentered, true, maxValue: 128, minValue: -128)
        case .O2Sensor7WRCurrent: return CommandProperties("013A", "02 Sensor 7 WR Lambda Current", 4, .currentCentered, true, maxValue: 128, minValue: -128)
        case .O2Sensor8WRCurrent: return CommandProperties("013B", "02 Sensor 8 WR Lambda Current", 4, .currentCentered, true, maxValue: 128, minValue: -128)
        case .catalystTempB1S1: return CommandProperties("013C", "Catalyst Temperature: Bank 1 - Sensor 1", 4, .uas(0x16), true)
        case .catalystTempB2S1: return CommandProperties("013D", "Catalyst Temperature: Bank 2 - Sensor 1", 4, .uas(0x16), true)
        case .catalystTempB1S2: return CommandProperties("013E", "Catalyst Temperature: Bank 1 - Sensor 2", 4, .uas(0x16), true)
        case .catalystTempB2S2: return CommandProperties("013F", "Catalyst Temperature: Bank 1 - Sensor 2", 4, .uas(0x16), true)
        case .pidsC: return CommandProperties("0140", "Supported PIDs [41-60]", 6, .pid)
        case .statusDriveCycle: return CommandProperties("0141", "Monitor status this drive cycle", 6, .status)
        case .controlModuleVoltage: return CommandProperties("0142", "Control module voltage", 4, .uas(0x0B), true)
        case .absoluteLoad: return CommandProperties("0143", "Absolute load value", 4, .percent, true)
        case .commandedEquivRatio: return CommandProperties("0144", "Commanded equivalence ratio", 4, .uas(0x1E), true)
        case .relativeThrottlePos: return CommandProperties("0145", "Relative throttle position", 4, .percent, true)
        case .ambientAirTemp: return CommandProperties("0146", "Ambient air temperature", 4, .temp, true)
        case .throttlePosB: return CommandProperties("0147", "Absolute throttle position B", 4, .percent, true)
        case .throttlePosC: return CommandProperties("0148", "Absolute throttle position C", 4, .percent, true)
        case .throttlePosD: return CommandProperties("0149", "Absolute throttle position D", 4, .percent, true)
        case .throttlePosE: return CommandProperties("014A", "Absolute throttle position E", 4, .percent, true)
        case .throttlePosF: return CommandProperties("014B", "Absolute throttle position F", 4, .percent, true)
        case .throttleActuator: return CommandProperties("014C", "Commanded throttle actuator", 4, .percent, true)
        case .runTimeMIL: return CommandProperties("014D", "Time run with MIL on", 4, .uas(0x34), true)
        case .timeSinceDTCCleared: return CommandProperties("014E", "Time since trouble codes cleared", 4, .uas(0x34), true)
        case .maxValues: return CommandProperties("014F", "Maximum value for various values", 6, .none)
        case .maxMAF: return CommandProperties("0150", "Maximum value for air flow rate from mass air flow sensor", 4, .maxMaf, true)
        case .fuelType: return CommandProperties("0151", "Fuel Type", 2, .fuelType)
        case .ethanoPercent: return CommandProperties("0152", "Ethanol fuel %", 2, .percent)
        case .evapVaporPressureAbs: return CommandProperties("0153", "Absolute Evap system vapor pressure", 4, .evapPressureAlt, true)
        case .evapVaporPressureAlt: return CommandProperties("0154", "Evap system vapor pressure", 4, .evapPressureAlt, true)
        case .shortO2TrimB1: return CommandProperties("0155", "Short term secondary O2 trim - Bank 1", 4, .percentCentered, true)
        case .longO2TrimB1: return CommandProperties("0156", "Long term secondary O2 trim - Bank 1", 4, .percentCentered, true)
        case .shortO2TrimB2: return CommandProperties("0157", "Short term secondary O2 trim - Bank 2", 4, .percentCentered, true)
        case .longO2TrimB2: return CommandProperties("0158", "Long term secondary O2 trim - Bank 2", 4, .percentCentered, true)
        case .fuelRailPressureAbs: return CommandProperties("0159", "Fuel rail pressure (absolute)", 4, .uas(0x1B), true)
        case .relativeAccelPos: return CommandProperties("015A", "Relative accelerator pedal position", 3, .percent, true)
        case .hybridBatteryLife: return CommandProperties("015B", "Hybrid battery pack remaining life", 3, .percent)
        case .engineOilTemp: return CommandProperties("015C", "Engine oil temperature", 3, .temp, true)
        case .fuelInjectionTiming: return CommandProperties("015D", "Fuel injection timing", 4, .injectTiming, true)
        case .fuelRate: return CommandProperties("015E", "Engine fuel rate", 4, .fuelRate, true)
        case .emissionsReq: return CommandProperties("015F", "Designed emission requirements", 3, .none)
        }
    }
}

extension OBDCommand.Mode6 {
    var properties: CommandProperties {
        switch self {
        case .MIDS_A: return CommandProperties("0600", "Supported MIDs [01-20]", 0, .pid)
        case .MONITOR_O2_B1S1: return CommandProperties("0601", "O2 Sensor Monitor Bank 1 - Sensor 1", 0, .monitor)
        case .MONITOR_O2_B1S2: return CommandProperties("0602", "O2 Sensor Monitor Bank 1 - Sensor 2", 0, .monitor)
        case .MONITOR_O2_B1S3: return CommandProperties("0603", "O2 Sensor Monitor Bank 1 - Sensor 3", 0, .monitor)
        case .MONITOR_O2_B1S4: return CommandProperties("0604", "O2 Sensor Monitor Bank 1 - Sensor 4", 0, .monitor)
        case .MONITOR_O2_B2S1: return CommandProperties("0605", "O2 Sensor Monitor Bank 2 - Sensor 1", 0, .monitor)
        case .MONITOR_O2_B2S2: return CommandProperties("0606", "O2 Sensor Monitor Bank 2 - Sensor 2", 0, .monitor)
        case .MONITOR_O2_B2S3: return CommandProperties("0607", "O2 Sensor Monitor Bank 2 - Sensor 3", 0, .monitor)
        case .MONITOR_O2_B2S4: return CommandProperties("0608", "O2 Sensor Monitor Bank 2 - Sensor 4", 0, .monitor)
        case .MONITOR_O2_B3S1: return CommandProperties("0609", "O2 Sensor Monitor Bank 3 - Sensor 1", 0, .monitor)
        case .MONITOR_O2_B3S2: return CommandProperties("060A", "O2 Sensor Monitor Bank 3 - Sensor 2", 0, .monitor)
        case .MONITOR_O2_B3S3: return CommandProperties("060B", "O2 Sensor Monitor Bank 3 - Sensor 3", 0, .monitor)
        case .MONITOR_O2_B3S4: return CommandProperties("060C", "O2 Sensor Monitor Bank 3 - Sensor 4", 0, .monitor)
        case .MONITOR_O2_B4S1: return CommandProperties("060D", "O2 Sensor Monitor Bank 4 - Sensor 1", 0, .monitor)
        case .MONITOR_O2_B4S2: return CommandProperties("060E", "O2 Sensor Monitor Bank 4 - Sensor 2", 0, .monitor)
        case .MONITOR_O2_B4S3: return CommandProperties("060F", "O2 Sensor Monitor Bank 4 - Sensor 3", 0, .monitor)
        case .MONITOR_O2_B4S4: return CommandProperties("0610", "O2 Sensor Monitor Bank 4 - Sensor 4", 0, .monitor)
        case .MIDS_B: return CommandProperties("0620", "Supported MIDs [21-40]", 0, .pid)
        case .MONITOR_CATALYST_B1: return CommandProperties("0621", "Catalyst Monitor Bank 1", 0, .monitor)
        case .MONITOR_CATALYST_B2: return CommandProperties("0622", "Catalyst Monitor Bank 2", 0, .monitor)
        case .MONITOR_CATALYST_B3: return CommandProperties("0623", "Catalyst Monitor Bank 3", 0, .monitor)
        case .MONITOR_CATALYST_B4: return CommandProperties("0624", "Catalyst Monitor Bank 4", 0, .monitor)
        case .MONITOR_EGR_B1: return CommandProperties("0631", "EGR Monitor Bank 1", 0, .monitor)
        case .MONITOR_EGR_B2: return CommandProperties("0632", "EGR Monitor Bank 2", 0, .monitor)
        case .MONITOR_EGR_B3: return CommandProperties("0633", "EGR Monitor Bank 3", 0, .monitor)
        case .MONITOR_EGR_B4: return CommandProperties("0634", "EGR Monitor Bank 4", 0, .monitor)
        case .MONITOR_VVT_B1: return CommandProperties("0635", "VVT Monitor Bank 1", 0, .monitor)
        case .MONITOR_VVT_B2: return CommandProperties("0636", "VVT Monitor Bank 2", 0, .monitor)
        case .MONITOR_VVT_B3: return CommandProperties("0637", "VVT Monitor Bank 3", 0, .monitor)
        case .MONITOR_VVT_B4: return CommandProperties("0638", "VVT Monitor Bank 4", 0, .monitor)
        case .MONITOR_EVAP_150: return CommandProperties("0639", "EVAP Monitor (Cap Off / 0.150\")", 0, .monitor)
        case .MONITOR_EVAP_090: return CommandProperties("063A", "EVAP Monitor (0.090\")", 0, .monitor)
        case .MONITOR_EVAP_040: return CommandProperties("063B", "EVAP Monitor (0.040\")", 0, .monitor)
        case .MONITOR_EVAP_020: return CommandProperties("063C", "EVAP Monitor (0.020\")", 0, .monitor)
        case .MONITOR_PURGE_FLOW: return CommandProperties("063D", "Purge Flow Monitor", 0, .monitor)
        case .MIDS_C: return CommandProperties("0640", "Supported MIDs [41-60]", 0, .pid)
        case .MONITOR_O2_HEATER_B1S1: return CommandProperties("0641", "O2 Sensor Heater Monitor Bank 1 - Sensor 1", 0, .monitor)
        case .MONITOR_O2_HEATER_B1S2: return CommandProperties("0642", "O2 Sensor Heater Monitor Bank 1 - Sensor 2", 0, .monitor)
        case .MONITOR_O2_HEATER_B1S3: return CommandProperties("0643", "O2 Sensor Heater Monitor Bank 1 - Sensor 3", 0, .monitor)
        case .MONITOR_O2_HEATER_B1S4: return CommandProperties("0644", "O2 Sensor Heater Monitor Bank 1 - Sensor 4", 0, .monitor)
        case .MONITOR_O2_HEATER_B2S1: return CommandProperties("0645", "O2 Sensor Heater Monitor Bank 2 - Sensor 1", 0, .monitor)
        case .MONITOR_O2_HEATER_B2S2: return CommandProperties("0646", "O2 Sensor Heater Monitor Bank 2 - Sensor 2", 0, .monitor)
        case .MONITOR_O2_HEATER_B2S3: return CommandProperties("0647", "O2 Sensor Heater Monitor Bank 2 - Sensor 3", 0, .monitor)
        case .MONITOR_O2_HEATER_B2S4: return CommandProperties("0648", "O2 Sensor Heater Monitor Bank 2 - Sensor 4", 0, .monitor)
        case .MONITOR_O2_HEATER_B3S1: return CommandProperties("0649", "O2 Sensor Heater Monitor Bank 3 - Sensor 1", 0, .monitor)
        case .MONITOR_O2_HEATER_B3S2: return CommandProperties("064A", "O2 Sensor Heater Monitor Bank 3 - Sensor 2", 0, .monitor)
        case .MONITOR_O2_HEATER_B3S3: return CommandProperties("064B", "O2 Sensor Heater Monitor Bank 3 - Sensor 3", 0, .monitor)
        case .MONITOR_O2_HEATER_B3S4: return CommandProperties("064C", "O2 Sensor Heater Monitor Bank 3 - Sensor 4", 0, .monitor)
        case .MONITOR_O2_HEATER_B4S1: return CommandProperties("064D", "O2 Sensor Heater Monitor Bank 4 - Sensor 1", 0, .monitor)
        case .MONITOR_O2_HEATER_B4S2: return CommandProperties("064E", "O2 Sensor Heater Monitor Bank 4 - Sensor 2", 0, .monitor)
        case .MONITOR_O2_HEATER_B4S3: return CommandProperties("064F", "O2 Sensor Heater Monitor Bank 4 - Sensor 3", 0, .monitor)
        case .MONITOR_O2_HEATER_B4S4: return CommandProperties("0650", "O2 Sensor Heater Monitor Bank 4 - Sensor 4", 0, .monitor)
        case .MIDS_D: return CommandProperties("0660", "Supported MIDs [61-80]", 0, .pid)
        case .MONITOR_HEATED_CATALYST_B1: return CommandProperties("0661", "Heated Catalyst Monitor Bank 1", 0, .monitor)
        case .MONITOR_HEATED_CATALYST_B2: return CommandProperties("0662", "Heated Catalyst Monitor Bank 2", 0, .monitor)
        case .MONITOR_HEATED_CATALYST_B3: return CommandProperties("0663", "Heated Catalyst Monitor Bank 3", 0, .monitor)
        case .MONITOR_HEATED_CATALYST_B4: return CommandProperties("0664", "Heated Catalyst Monitor Bank 4", 0, .monitor)
        case .MONITOR_SECONDARY_AIR_1: return CommandProperties("0671", "Secondary Air Monitor 1", 0, .monitor)
        case .MONITOR_SECONDARY_AIR_2: return CommandProperties("0672", "Secondary Air Monitor 2", 0, .monitor)
        case .MONITOR_SECONDARY_AIR_3: return CommandProperties("0673", "Secondary Air Monitor 3", 0, .monitor)
        case .MONITOR_SECONDARY_AIR_4: return CommandProperties("0674", "Secondary Air Monitor 4", 0, .monitor)
        case .MIDS_E: return CommandProperties("0680", "Supported MIDs [81-A0]", 0, .pid)
        case .MONITOR_FUEL_SYSTEM_B1: return CommandProperties("0681", "Fuel System Monitor Bank 1", 0, .monitor)
        case .MONITOR_FUEL_SYSTEM_B2: return CommandProperties("0682", "Fuel System Monitor Bank 2", 0, .monitor)
        case .MONITOR_FUEL_SYSTEM_B3: return CommandProperties("0683", "Fuel System Monitor Bank 3", 0, .monitor)
        case .MONITOR_FUEL_SYSTEM_B4: return CommandProperties("0684", "Fuel System Monitor Bank 4", 0, .monitor)
        case .MONITOR_BOOST_PRESSURE_B1: return CommandProperties("0685", "Boost Pressure Control Monitor Bank 1", 0, .monitor)
        case .MONITOR_BOOST_PRESSURE_B2: return CommandProperties("0686", "Boost Pressure Control Monitor Bank 1", 0, .monitor)
        case .MONITOR_NOX_ABSORBER_B1: return CommandProperties("0690", "NOx Absorber Monitor Bank 1", 0, .monitor)
        case .MONITOR_NOX_ABSORBER_B2: return CommandProperties("0691", "NOx Absorber Monitor Bank 2", 0, .monitor)
        case .MONITOR_NOX_CATALYST_B1: return CommandProperties("0698", "NOx Catalyst Monitor Bank 1", 0, .monitor)
        case .MONITOR_NOX_CATALYST_B2: return CommandProperties("0699", "NOx Catalyst Monitor Bank 2", 0, .monitor)
        case .MIDS_F: return CommandProperties("06A0", "Supported MIDs [A1-C0]", 0, .pid)
        case .MONITOR_MISFIRE_GENERAL: return CommandProperties("06A1", "Misfire Monitor General Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_1: return CommandProperties("06A2", "Misfire Cylinder 1 Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_2: return CommandProperties("06A3", "Misfire Cylinder 2 Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_3: return CommandProperties("06A4", "Misfire Cylinder 3 Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_4: return CommandProperties("06A5", "Misfire Cylinder 4 Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_5: return CommandProperties("06A6", "Misfire Cylinder 5 Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_6: return CommandProperties("06A7", "Misfire Cylinder 6 Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_7: return CommandProperties("06A8", "Misfire Cylinder 7 Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_8: return CommandProperties("06A9", "Misfire Cylinder 8 Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_9: return CommandProperties("06AA", "Misfire Cylinder 9 Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_10: return CommandProperties("06AB", "Misfire Cylinder 10 Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_11: return CommandProperties("06AC", "Misfire Cylinder 11 Data", 0, .monitor)
        case .MONITOR_MISFIRE_CYLINDER_12: return CommandProperties("06AD", "Misfire Cylinder 12 Data", 0, .monitor)
        case .MONITOR_PM_FILTER_B1: return CommandProperties("06B0", "PM Filter Monitor Bank 1", 0, .monitor)
        case .MONITOR_PM_FILTER_B2: return CommandProperties("06B1", "PM Filter Monitor Bank 2", 0, .monitor)
        }
    }
}

extension OBDCommand {
    static public func from(command: String) -> OBDCommand? {
        return OBDCommand.allCommands.first(where: { $0.properties.command == command })
    }
}
