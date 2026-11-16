//
//  mockManager.swift
//
//
//  Created by kemo konteh on 3/16/24.
//
//  A simulated ELM327 plugged into a simulated CAN vehicle, used by the demo mode, the iOS
//  simulator and the unit tests. It answers with the exact text a real adapter would print.
//

import Combine
import CoreBluetooth
import Foundation

class MOCKComm: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    // MARK: Vehicle configuration

    /// The protocol the simulated vehicle speaks (one of the four ISO 15765-4 variants).
    var vehicleProtocol: PROTOCOL = .protocol6
    /// Time the "vehicle" takes to answer a request.
    var responseDelay: TimeInterval = 0.02
    /// Older ECUs only answer the first PID of a grouped request.
    var supportsGroupedRequests = true
    /// The byte ECUs use to fill unused positions of a CAN frame.
    var paddingByte: UInt8 = 0x00

    var storedCodes = ["P0104"]
    var pendingCodes = ["P0171"]
    var permanentCodes: [String] = []
    var transmissionCodes = ["U0207"]

    /// Extra data identifiers of the engine ECU: request in hexadecimal → data bytes of the answer.
    var customResponses: [String: [UInt8]] = [
        "221154": [0x7D], // "oil temperature", 85 °C with the formula A-40
    ]

    /// Every command received, in order (unit tests).
    private(set) var history: [String] = []

    // MARK: Adapter state

    private let lock = NSLock()
    private var echo = true
    private var spaces = true
    private var headers = false
    private var selectedProtocol = "0"
    private var isSearching = true
    private var header: String?
    private var priority = "18"

    private let vin = "1N4AL3AP7DC199583"

    // MARK: - CommProtocol

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        connectionState = .connectedToAdapter
    }

    func disconnectPeripheral() {
        if connectionState != .disconnected {
            connectionState = .disconnected
        }
    }

    func scanForPeripherals() async throws {}

    func sendCommand(_ command: String, timeout _: TimeInterval = 5) async throws -> [String] {
        guard connectionState != .disconnected else {
            throw CommunicationError.notConnected
        }
        let request = command.compactUppercased
        let isAdapterCommand = request.hasPrefix("AT")

        if !isAdapterCommand, responseDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(responseDelay * 1_000_000_000))
        }

        return lock.sync {
            history.append(request)
            let echoed = echo
            let lines = isAdapterCommand ? [adapterCommand(String(request.dropFirst(2)))] : vehicleRequest(request)
            return echoed ? [command] + lines : lines
        }
    }

    // MARK: - Adapter commands

    private func adapterCommand(_ command: String) -> String {
        switch command {
        case "Z", "WS":
            echo = true
            spaces = true
            headers = false
            header = nil
            priority = "18"
            return "ELM327 v1.5"
        case "I":
            return "ELM327 v1.5"
        case "D":
            header = nil
            priority = "18"
            return "OK"
        case "E0", "E1":
            echo = command == "E1"
            return "OK"
        case "S0", "S1":
            spaces = command == "S1"
            return "OK"
        case "H0", "H1":
            headers = command == "H1"
            return "OK"
        case "RV":
            return String(format: "%.1fV", 13.8 + sin(Date().timeIntervalSinceReferenceDate / 5) * 0.3)
        case "DPN":
            return selectedProtocol == "0" ? "A\(vehicleProtocol.rawValue)" : selectedProtocol
        case "DP":
            return selectedProtocol == "0" ? "AUTO, \(vehicleProtocol.description.dropFirst(3))" : (PROTOCOL(rawValue: selectedProtocol)?.description ?? "?")
        case "AR":
            return "OK"
        default:
            break
        }

        if command.hasPrefix("SP") || command.hasPrefix("TP") {
            let value = String(command.dropFirst(2))
            // "A6" means protocol 6 with automatic search as a fallback
            selectedProtocol = value.count == 2 && value.hasPrefix("A") ? "0" : value
            isSearching = selectedProtocol == "0"
            return selectedProtocol == "0" || PROTOCOL(rawValue: selectedProtocol) != nil ? "OK" : "?"
        }
        if command.hasPrefix("SH") {
            header = String(command.dropFirst(2))
            return "OK"
        }
        if command.hasPrefix("CP") {
            priority = String(command.dropFirst(2))
            return "OK"
        }
        // Settings the simulation accepts without modelling them.
        for prefix in ["L", "M", "AT", "ST", "CRA", "CF", "CM", "FC", "CAF", "SR", "AL", "NL", "SW", "WM", "IB", "KW", "PP", "CEA", "TA", "R", "V"] where command.hasPrefix(prefix) {
            return "OK"
        }
        return "?"
    }

    // MARK: - Vehicle

    private enum ECU: CaseIterable {
        case engine
        case transmission
    }

    private var isExtended: Bool {
        vehicleProtocol == .protocol7 || vehicleProtocol == .protocol9
    }

    private func identifier(of ecu: ECU) -> String {
        switch (ecu, isExtended) {
        case (.engine, false): return "7E8"
        case (.transmission, false): return "7E9"
        case (.engine, true): return "18DAF110"
        case (.transmission, true): return "18DAF118"
        }
    }

    /// The ECUs a request reaches with the current header, and whether it is addressed to one of them only.
    private var addressedECUs: (ecus: [ECU], isPhysical: Bool) {
        guard let header = header else { return (ECU.allCases, false) }
        switch isExtended ? priority + header.suffix(6) : header {
        case "7DF", "18DB33F1": return (ECU.allCases, false)
        case "7E0", "18DA10F1": return ([.engine], true)
        case "7E1", "18DA18F1": return ([.transmission], true)
        default: return ([], true)
        }
    }

    private func vehicleRequest(_ request: String) -> [String] {
        guard selectedProtocol == "0" || selectedProtocol == vehicleProtocol.rawValue else {
            return ["UNABLE TO CONNECT"]
        }

        // A trailing digit is the number of answers the adapter should wait for.
        let hex = request.count % 2 == 1 ? String(request.dropLast()) : request
        let bytes = hex.hexBytes
        guard hex.isHex, !bytes.isEmpty else { return ["?"] }

        var lines: [String] = []
        if isSearching {
            lines.append("SEARCHING...")
            isSearching = false
        }

        let (ecus, isPhysical) = addressedECUs
        for ecu in ecus {
            let payload: [UInt8]?
            switch ecu {
            case .engine: payload = engineResponse(to: bytes, isPhysical: isPhysical)
            case .transmission: payload = transmissionResponse(to: bytes, isPhysical: isPhysical)
            }
            if let payload = payload {
                lines.append(contentsOf: format(payload, from: identifier(of: ecu)))
            }
        }
        return lines.count > (lines.first == "SEARCHING..." ? 1 : 0) ? lines : lines + ["NO DATA"]
    }

    /// Segments a payload into CAN frames (ISO 15765-2) and prints them the way an ELM327 does.
    private func format(_ payload: [UInt8], from identifier: String) -> [String] {
        let separator = spaces ? " " : ""
        func line(_ bytes: [UInt8], prefix: String) -> String {
            let text = bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
            return prefix.isEmpty ? text : prefix + separator + text
        }
        func padded(_ bytes: [UInt8]) -> [UInt8] {
            bytes + [UInt8](repeating: paddingByte, count: max(0, 8 - bytes.count))
        }

        if payload.count <= 7 {
            return headers
                ? [line(padded([UInt8(payload.count)] + payload), prefix: identifier)]
                : [line(payload, prefix: "")]
        }

        var frames: [[UInt8]] = [[0x10 | UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload.prefix(6)]
        var sequence: UInt8 = 1
        for chunk in Array(payload.dropFirst(6)).chunked(into: 7) {
            frames.append(padded([0x20 | sequence] + chunk))
            sequence = (sequence + 1) & 0x0F
        }

        if headers {
            return frames.map { line($0, prefix: identifier) }
        }
        // Without headers the adapter prints the length, then numbered lines.
        return [String(format: "%03X", payload.count)] + frames.enumerated().map { index, frame in
            line(Array(frame.dropFirst(index == 0 ? 2 : 1)), prefix: "\(String(index % 16, radix: 16).uppercased()):")
        }
    }

    // MARK: Engine ECU

    private static let enginePIDs: Set<UInt8> = [
        0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x1C, 0x1F,
        0x21, 0x23, 0x2F, 0x30, 0x31, 0x33,
        0x41, 0x42, 0x46, 0x4D, 0x4E, 0x51, 0x5C, 0x5E,
    ]
    private static let freezeFramePIDs: Set<UInt8> = [0x02, 0x04, 0x05, 0x0B, 0x0C, 0x0D, 0x11]
    private static let monitorIDs: Set<UInt8> = [0x01, 0x21]
    private static let infoTypes: Set<UInt8> = [0x02, 0x04, 0x0A]

    private func engineResponse(to request: [UInt8], isPhysical: Bool) -> [UInt8]? {
        let service = request[0]
        let parameters = Array(request.dropFirst())

        switch service {
        case 0x01:
            var payload: [UInt8] = [0x41]
            for pid in supportsGroupedRequests ? parameters : Array(parameters.prefix(1)) {
                if let data = currentData(pid) {
                    payload += [pid] + data
                }
            }
            return payload.count > 1 ? payload : nil

        case 0x02:
            guard let pid = parameters.first else { return nil }
            let frame = parameters.count > 1 ? parameters[1] : 0
            if pid % 0x20 == 0 {
                return pid == 0 ? [0x42, pid, frame] + MOCKComm.bitmap(base: pid, MOCKComm.freezeFramePIDs) : nil
            }
            if pid == 0x02 {
                return [0x42, pid, frame] + (storedCodes.first.map(MOCKComm.encode) ?? [0x00, 0x00])
            }
            guard !storedCodes.isEmpty, MOCKComm.freezeFramePIDs.contains(pid), let data = MOCKComm.freezeFrame[pid] else { return nil }
            return [0x42, pid, frame] + data

        case 0x03:
            return [0x43, UInt8(storedCodes.count)] + storedCodes.flatMap(MOCKComm.encode)
        case 0x07:
            return [0x47, UInt8(pendingCodes.count)] + pendingCodes.flatMap(MOCKComm.encode)
        case 0x0A:
            return [0x4A, UInt8(permanentCodes.count)] + permanentCodes.flatMap(MOCKComm.encode)

        case 0x04:
            storedCodes = []
            pendingCodes = []
            return [0x44]

        case 0x06:
            guard let mid = parameters.first else { return nil }
            switch mid {
            case 0x00, 0x20:
                return [0x46, mid] + MOCKComm.bitmap(base: mid, MOCKComm.monitorIDs)
            case 0x01:
                // Oxygen sensor bank 1 sensor 1: threshold voltage and switch time
                return [0x46, 0x01, 0x01, 0x0A, 0x0B, 0xB0, 0x00, 0x00, 0xFF, 0xFF,
                        0x01, 0x05, 0x10, 0x00, 0x48, 0x00, 0x00, 0x00, 0x64]
            case 0x21:
                // Catalyst bank 1: manufacturer test, value above its limit (failed)
                return [0x46, 0x21, 0x80, 0x20, 0x00, 0x90, 0x00, 0x00, 0x00, 0x80]
            default:
                return nil
            }

        case 0x08:
            guard let tid = parameters.first else { return nil }
            return [0x48, tid, 0x00, 0x00, 0x00, 0x00, 0x00]

        case 0x09:
            guard let infoType = parameters.first else { return nil }
            switch infoType {
            case 0x00:
                return [0x49, 0x00] + MOCKComm.bitmap(base: 0, MOCKComm.infoTypes)
            case 0x02:
                return [0x49, 0x02, 0x01] + Array(vin.utf8)
            case 0x04:
                return [0x49, 0x04, 0x01] + MOCKComm.padded("SWIFTOBD2-CAL01", to: 16)
            case 0x0A:
                return [0x49, 0x0A, 0x01] + MOCKComm.padded("ECM-EngineControl", to: 20)
            default:
                return nil
            }

        case 0x22:
            let key = request.hexString
            if key == "22F190" {
                return [0x62, 0xF1, 0x90] + Array(vin.utf8)
            }
            if let data = customResponses[key] {
                return [0x62] + parameters + data
            }
            return isPhysical ? [0x7F, service, 0x31] : nil

        case 0x19:
            guard parameters.first == 0x02 else { return isPhysical ? [0x7F, service, 0x12] : nil }
            return [0x59, 0x02, 0xFF] + storedCodes.flatMap { MOCKComm.encode($0) + [0x00, 0x09] }
                + pendingCodes.flatMap { MOCKComm.encode($0) + [0x00, 0x04] }

        case 0x14:
            storedCodes = []
            pendingCodes = []
            return [0x54]

        default:
            return isPhysical ? [0x7F, service, 0x11] : nil
        }
    }

    // MARK: Transmission ECU

    private func transmissionResponse(to request: [UInt8], isPhysical: Bool) -> [UInt8]? {
        let service = request[0]
        let parameters = Array(request.dropFirst())

        switch service {
        case 0x01:
            var payload: [UInt8] = [0x41]
            for pid in supportsGroupedRequests ? parameters : Array(parameters.prefix(1)) {
                switch pid {
                case 0x00: payload += [pid] + MOCKComm.bitmap(base: 0, [0x01, 0x0D])
                case 0x01: payload += [pid, UInt8(transmissionCodes.count), 0x04, 0x00, 0x00]
                case 0x0D: payload += [pid] + (currentData(pid) ?? [0])
                default: break
                }
            }
            return payload.count > 1 ? payload : nil
        case 0x03:
            return [0x43, UInt8(transmissionCodes.count)] + transmissionCodes.flatMap(MOCKComm.encode)
        case 0x07:
            return [0x47, 0x00]
        case 0x04:
            transmissionCodes = []
            return [0x44]
        default:
            return isPhysical ? [0x7F, service, 0x11] : nil
        }
    }

    // MARK: Data

    /// Current value of a service 01 PID, as its data bytes. Values follow slow waves so that the
    /// demo mode shows believable gauges.
    private func currentData(_ pid: UInt8) -> [UInt8]? {
        if pid % 0x20 == 0 {
            // "Supported PIDs" bitmaps exist as long as there is something to list.
            guard pid == 0 || MOCKComm.enginePIDs.contains(where: { $0 > pid }) else { return nil }
            return MOCKComm.bitmap(base: pid, MOCKComm.enginePIDs)
        }
        guard MOCKComm.enginePIDs.contains(pid) else { return nil }

        let time = Date().timeIntervalSinceReferenceDate
        func wave(_ low: Double, _ high: Double, period: Double) -> Double {
            low + (high - low) * (0.5 + 0.5 * sin(time * 2 * .pi / period)) + Double.random(in: -0.01 ... 0.01) * (high - low)
        }
        func byte(_ value: Double) -> [UInt8] {
            [UInt8(max(0, min(255, value.rounded())))]
        }
        func word(_ value: Double) -> [UInt8] {
            let raw = UInt16(max(0, min(65535, value.rounded())))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        }

        switch pid {
        case 0x01:
            // MIL state and code count, spark ignition, every monitor supported, catalyst and EVAP incomplete
            let count = UInt8(storedCodes.count)
            return [(count > 0 ? 0x80 : 0x00) | count, 0x07, 0xE5, 0x05]
        case 0x41: return [0x00, 0x07, 0xE5, 0x05]
        case 0x03: return [0x02, 0x00] // closed loop
        case 0x04: return byte(wave(20, 80, period: 9) * 2.55) // engine load %
        case 0x05: return byte(wave(85, 95, period: 60) + 40) // coolant °C
        case 0x06: return byte(128 + wave(-4, 4, period: 4) * 1.28) // short term fuel trim %
        case 0x07: return byte(128 + wave(1, 3, period: 120) * 1.28) // long term fuel trim %
        case 0x0B: return byte(wave(30, 100, period: 9)) // intake pressure kPa
        case 0x0C: return word(wave(900, 3500, period: 12) * 4) // rpm
        case 0x0D: return byte(wave(0, 120, period: 40)) // speed km/h
        case 0x0E: return byte((wave(5, 25, period: 7) + 64) * 2) // timing advance °
        case 0x0F: return byte(wave(25, 35, period: 90) + 40) // intake temperature °C
        case 0x10: return word(wave(3, 60, period: 12) * 100) // air flow g/s
        case 0x11: return byte(wave(12, 70, period: 9) * 2.55) // throttle %
        case 0x13: return [0x03] // two oxygen sensors on bank 1
        case 0x1C: return [0x06] // EOBD
        case 0x1F: return word(time.truncatingRemainder(dividingBy: 3600)) // run time s
        case 0x21: return word(storedCodes.isEmpty ? 0 : 42) // distance with MIL km
        case 0x23: return word(wave(3000, 15000, period: 12) / 10) // fuel rail pressure kPa
        case 0x2F: return byte(62 * 2.55) // fuel level %
        case 0x30: return [storedCodes.isEmpty ? 0 : 12] // warm-ups since codes cleared
        case 0x31: return word(storedCodes.isEmpty ? 0 : 1250) // distance since codes cleared km
        case 0x33: return [101] // barometric pressure kPa
        case 0x42: return word(wave(13600, 14300, period: 5)) // control module voltage mV
        case 0x46: return byte(21 + 40) // ambient temperature °C
        case 0x4D: return word(storedCodes.isEmpty ? 0 : 35) // time with MIL min
        case 0x4E: return word(storedCodes.isEmpty ? 0 : 2100) // time since codes cleared min
        case 0x51: return [0x01] // gasoline
        case 0x5C: return byte(wave(90, 105, period: 80) + 40) // oil temperature °C
        case 0x5E: return word(wave(0.8, 12, period: 12) * 20) // fuel rate L/h
        default: return nil
        }
    }

    /// The conditions recorded when the first stored code was set.
    private static let freezeFrame: [UInt8: [UInt8]] = [
        0x04: [0x99], // engine load 60 %
        0x05: [0x7E], // coolant 86 °C
        0x0B: [0x55], // intake pressure 85 kPa
        0x0C: [0x25, 0x80], // 2400 rpm
        0x0D: [0x48], // 72 km/h
        0x11: [0x66], // throttle 40 %
    ]

    /// A 32 bit "supported identifiers" bitmap for the range starting after `base`.
    static func bitmap(base: UInt8, _ supported: Set<UInt8>) -> [UInt8] {
        var bytes: [UInt8] = [0, 0, 0, 0]
        for bit in 0 ..< 32 {
            let identifier = Int(base) + bit + 1
            let isLast = bit == 31
            // The last bit announces that a further bitmap exists.
            if supported.contains(where: { isLast ? Int($0) > identifier : Int($0) == identifier }) {
                bytes[bit / 8] |= 0x80 >> UInt8(bit % 8)
            }
        }
        return bytes
    }

    /// The two byte encoding of a trouble code (`P0104` → `01 04`).
    static func encode(_ code: String) -> [UInt8] {
        let characters = Array(code.uppercased())
        guard characters.count == 5,
              let system = ["P", "C", "B", "U"].firstIndex(of: String(characters[0])),
              let digits = UInt16(String(characters[1...]), radix: 16)
        else { return [0x00, 0x00] }
        let value = UInt16(system) << 14 | digits & 0x3FFF
        return [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func padded(_ text: String, to length: Int) -> [UInt8] {
        let bytes = Array(text.utf8.prefix(length))
        return bytes + [UInt8](repeating: 0x00, count: length - bytes.count)
    }
}
