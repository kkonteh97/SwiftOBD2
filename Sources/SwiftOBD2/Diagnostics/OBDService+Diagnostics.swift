//
//  OBDService+Diagnostics.swift
//  SwiftOBD2
//
//  Trouble codes, readiness, freeze frames, on-board monitor tests and manufacturer specific
//  (enhanced) diagnostics.
//

import Foundation

/// Everything the vehicle reports about its emission system since the trouble codes were last cleared.
public struct DiagnosticStatus {
    /// Malfunction lamp, number of codes and readiness of the monitors since the codes were cleared.
    public let status: Status
    /// Readiness of the monitors during the current drive cycle, when the vehicle reports it.
    public let driveCycleStatus: Status?
    public let warmUpsSinceCleared: Int?
    public let distanceSinceCleared: MeasurementResult?
    public let timeSinceCleared: MeasurementResult?
    /// Distance travelled with the malfunction lamp on.
    public let distanceWithMIL: MeasurementResult?
    /// Engine run time with the malfunction lamp on.
    public let timeWithMIL: MeasurementResult?
}

/// The operating conditions the ECU recorded when a fault was detected.
public struct FreezeFrame {
    /// The trouble code that caused the snapshot to be stored.
    public let troubleCode: TroubleCode
    /// The recorded values.
    public let values: [OBDCommand: MeasurementResult]
}

public extension OBDService {
    // MARK: - Status

    /// Retrieves the vehicle status since the trouble codes were cleared: malfunction lamp,
    /// readiness of the on-board monitors, and the distance, time and warm-up counters.
    func getStatusSinceDTCCleared(unit: MeasurementUnit = .metric) async throws -> DiagnosticStatus {
        guard let status = try await sendCommand(.mode1(.status)).get().statusResult else {
            throw OBDServiceError.commandFailed(command: "0101", error: DecodeError.invalidData)
        }

        let driveCycle = try? await sendCommand(.mode1(.statusDriveCycle)).get().statusResult
        let counters = try await requestPIDs([
            .mode1(.warmUpsSinceDTCCleared),
            .mode1(.distanceSinceDTCCleared),
            .mode1(.timeSinceDTCCleared),
            .mode1(.distanceWMIL),
            .mode1(.runTimeMIL),
        ], unit: unit)

        return DiagnosticStatus(
            status: status,
            driveCycleStatus: driveCycle ?? nil,
            warmUpsSinceCleared: counters[.mode1(.warmUpsSinceDTCCleared)].map { Int($0.value) },
            distanceSinceCleared: counters[.mode1(.distanceSinceDTCCleared)],
            timeSinceCleared: counters[.mode1(.timeSinceDTCCleared)],
            distanceWithMIL: counters[.mode1(.distanceWMIL)],
            timeWithMIL: counters[.mode1(.runTimeMIL)]
        )
    }

    /// Battery voltage measured by the adapter on the diagnostic connector.
    func getVoltage() async throws -> Double {
        do {
            return try await elm327.requestVoltage()
        } catch {
            throw OBDServiceError.commandFailed(command: "ATRV", error: error)
        }
    }

    // MARK: - Trouble codes

    /// Scans for trouble codes and returns them grouped by ECU.
    ///  - Parameter kind: `.stored` for confirmed codes (the default), `.pending` for the ones
    ///    detected during the current or last drive cycle, `.permanent` for the ones only the ECU
    ///    can erase.
    ///  - Returns: The trouble codes of each ECU that answered. An ECU without code has an empty list.
    ///  - Throws: `OBDServiceError.scanFailed` if the request could not be carried out.
    func scanForTroubleCodes(_ kind: TroubleCodeKind = .stored) async throws -> [ECUID: [TroubleCode]] {
        do {
            let messages = try await elm327.request(kind.service, retries: 2)

            var troubleCodes: [ECUID: [TroubleCode]] = [:]
            for message in messages {
                guard case let .success(.troubleCode(codes)) = DTCDecoder().decode(data: message.troubleCodeBytes, unit: .metric) else {
                    continue
                }
                // Several ECUs can share a role: merge instead of overwriting.
                var merged = troubleCodes[message.ecu] ?? []
                for var code in codes {
                    code.kind = kind
                    if !merged.contains(code) { merged.append(code) }
                }
                troubleCodes[message.ecu] = merged
            }
            return troubleCodes
        } catch ELM327Error.noData {
            // Some ECUs stay silent instead of reporting an empty list, and older vehicles do not
            // implement pending or permanent codes.
            return [:]
        } catch {
            throw OBDServiceError.scanFailed(underlyingError: OBDService.translate(error))
        }
    }

    /// Scans for stored, pending and permanent trouble codes in one go.
    ///  - Returns: The trouble codes of each ECU, each one tagged with its ``TroubleCodeKind``.
    func scanForAllTroubleCodes() async throws -> [ECUID: [TroubleCode]] {
        var troubleCodes = try await scanForTroubleCodes(.stored)
        for kind in [TroubleCodeKind.pending, .permanent] {
            guard let more = try? await scanForTroubleCodes(kind) else { continue }
            troubleCodes.merge(more) { $0 + $1 }
        }
        return troubleCodes
    }

    /// Clears the trouble codes found on the vehicle, along with the freeze frame, the readiness
    /// monitors and the "since cleared" counters. The ignition must be on and the engine stopped.
    ///  - Throws: `OBDServiceError.clearFailed` when the vehicle does not acknowledge the request.
    func clearTroubleCodes() async throws {
        do {
            _ = try await elm327.request("04")
        } catch {
            throw OBDServiceError.clearFailed(underlyingError: OBDService.translate(error))
        }
    }

    // MARK: - Freeze frame

    /// Reads the snapshot of operating conditions stored with a fault.
    ///  - Parameters:
    ///    - commands: The service 01 commands to read from the snapshot. By default, every live
    ///      value the vehicle recorded.
    ///    - frame: The frame number. `0` is the only one every vehicle implements.
    ///  - Returns: The snapshot, or `nil` when the vehicle has none stored.
    func getFreezeFrame(_ commands: [OBDCommand]? = nil, frame: UInt8 = 0, unit: MeasurementUnit = .metric) async throws -> FreezeFrame? {
        let frameHex = [frame].hexString
        do {
            // PID 02 holds the code that triggered the snapshot; 0000 means there is none.
            let trigger = try await elm327.request("0202" + frameHex)
            let triggerBytes = ELM327.engineFirst(trigger).first.map { Data($0.payload.dropFirst(3).prefix(2)) } ?? Data()
            guard let troubleCode = parseDTC(triggerBytes) else { return nil }

            let requested: [OBDCommand]
            if let commands = commands {
                requested = commands
            } else {
                let supported = await elm327.supportedIdentifiers(service: 0x02, suffix: frameHex)
                requested = supported.sorted().compactMap { OBDCommand.from(command: [0x01, $0].hexString) }
                    .filter { $0.properties.live }
            }

            var values: [OBDCommand: MeasurementResult] = [:]
            for command in requested where command.service == 0x01 {
                guard let pid = command.parameterBytes.first,
                      let messages = try? await elm327.request([0x02, pid].hexString + frameHex)
                else { continue }

                for message in ELM327.engineFirst(messages) {
                    // 42 <PID> <frame> <data…>
                    let bytes = [UInt8](message.payload)
                    guard bytes.count > 3, bytes[1] == pid else { continue }
                    if let value = try? command.properties.decode(data: Data(bytes[3...]), unit: unit).get().measurementResult {
                        values[command] = value
                        break
                    }
                }
            }
            return FreezeFrame(troubleCode: troubleCode, values: values)
        } catch ELM327Error.noData {
            return nil
        } catch {
            throw OBDServiceError.commandFailed(command: "02", error: OBDService.translate(error))
        }
    }

    // MARK: - On-board tests

    /// Retrieves the results of the tests the vehicle runs on its own emission components
    /// (catalyst, oxygen sensors, EGR, evaporative system, misfires…), with their limits.
    ///
    /// Available on CAN vehicles only (service 06).
    ///  - Returns: One ``Monitor`` per monitored component, each with its test results.
    func getMonitorTestResults(unit: MeasurementUnit = .metric) async throws -> [Monitor] {
        guard let obdProtocol = elm327.obdProtocol else {
            throw OBDServiceError.notConnectedToVehicle
        }
        guard obdProtocol.isCAN else {
            throw OBDServiceError.notSupported("On-board monitor test results are only available on CAN vehicles.")
        }

        var monitors: [Monitor] = []
        let identifiers = await elm327.supportedIdentifiers(service: 0x06).filter { $0 % 0x20 != 0 }

        for identifier in identifiers.sorted() {
            let request = [0x06, identifier].hexString
            do {
                for message in try await elm327.request(request) {
                    let result = MonitorDecoder().decode(data: Data(message.payload.dropFirst()), unit: unit)
                    guard let monitor = try? result.get().measurementMonitor, !monitor.tests.isEmpty else { continue }
                    monitor.mid = identifier
                    monitor.name = OBDCommand.from(command: request)?.properties.description
                    monitors.append(monitor)
                }
            } catch {
                guard OBDService.isAnswerMissing(error) else {
                    throw OBDServiceError.commandFailed(command: request, error: OBDService.translate(error))
                }
            }
        }
        return monitors
    }

    /// Asks the vehicle to run one of its on-board tests or to operate a component (service 08).
    ///
    /// The only test defined by the standard is `0x01`, the evaporative system leak test: it seals
    /// the system so that an external leak check can be performed. Others are manufacturer defined.
    ///  - Parameters:
    ///    - testID: The identifier of the test.
    ///    - data: The five data bytes of the request, zeroes when the test takes no parameter.
    ///  - Returns: The data bytes of the vehicle's answer.
    @discardableResult
    func requestOnBoardTest(_ testID: UInt8 = 0x01, data: [UInt8] = [0, 0, 0, 0, 0]) async throws -> Data {
        let request = ([0x08, testID] + data).hexString
        do {
            let messages = try await elm327.request(request)
            return ELM327.engineFirst(messages).first.map { Data($0.payload.dropFirst(2)) } ?? Data()
        } catch {
            throw OBDServiceError.commandFailed(command: request, error: OBDService.translate(error))
        }
    }

    // MARK: - Manufacturer specific diagnostics

    /// Sends an arbitrary diagnostic request and returns the positive answers.
    ///
    /// This is the entry point for everything the standard OBD-II services do not cover: UDS
    /// (ISO 14229) or KWP2000 services, manufacturer data identifiers, actuator tests…
    ///
    ///     // UDS ReadDataByIdentifier 0xF190 (VIN) on the engine ECU
    ///     let answers = try await obdService.request("22F190", to: .engine)
    ///
    ///  - Parameters:
    ///    - request: The request bytes in hexadecimal (service first).
    ///    - target: The ECU to address, `nil` to broadcast with the OBD-II header.
    ///  - Returns: One message per ECU that answered; its `payload` starts with the response service byte.
    ///  - Throws: `OBDServiceError.commandFailed`; the underlying `ELM327Error.negativeResponse`
    ///    tells why an ECU refused the request.
    func request(_ request: String, to target: ECUTarget? = nil) async throws -> [Message] {
        do {
            return try await elm327.request(request, target: target)
        } catch {
            throw OBDServiceError.commandFailed(command: request, error: OBDService.translate(error))
        }
    }

    /// Reads the trouble codes of one specific ECU with the UDS service 19 (ReadDTCInformation).
    ///
    /// Unlike the OBD-II services, which only cover emission related faults, this reaches any
    /// module that speaks UDS: ABS, airbag, body computer, gearbox…
    ///  - Parameters:
    ///    - target: The ECU to query.
    ///    - statusMask: Which codes to report. The default selects the failed, pending and confirmed ones.
    ///  - Returns: The codes, with their failure type and status bytes. Descriptions are only
    ///    available for the generic (SAE) codes.
    func scanForTroubleCodes(on target: ECUTarget, statusMask: UInt8 = 0x0D) async throws -> [TroubleCode] {
        do {
            let messages = try await elm327.request([0x19, 0x02, statusMask].hexString, target: target)
            var troubleCodes: [TroubleCode] = []

            for message in messages {
                // 59 02 <availability mask> then 4 bytes per code: DTC high, DTC low, failure type, status
                let records = [UInt8](message.payload.dropFirst(3))
                for start in stride(from: 0, to: records.count - 3, by: 4) {
                    guard var code = parseDTC(Data(records[start ... start + 1])) else { continue }
                    let status = records[start + 3]
                    code.failureType = records[start + 2]
                    code.statusByte = status
                    code.kind = status & 0x08 != 0 ? .stored : .pending
                    if !troubleCodes.contains(code) { troubleCodes.append(code) }
                }
            }
            return troubleCodes
        } catch ELM327Error.noData {
            return []
        } catch {
            throw OBDServiceError.scanFailed(underlyingError: OBDService.translate(error))
        }
    }

    /// Clears the trouble codes of one specific ECU with the UDS service 14 (ClearDiagnosticInformation).
    func clearTroubleCodes(on target: ECUTarget) async throws {
        do {
            _ = try await elm327.request("14FFFFFF", target: target)
        } catch {
            throw OBDServiceError.clearFailed(underlyingError: OBDService.translate(error))
        }
    }
}
