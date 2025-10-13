//
//  File.swift
//
//
//  Created by kemo konteh on 3/16/24.
//

import Foundation
import OSLog
import CoreBluetooth

enum CommandAction {
    case setHeaderOn
    case setHeaderOff
    case echoOn
    case echoOff
}

struct MockECUSettings {
    var headerOn = true
    var echo = false
    var vinNumber = ""
}

class MOCKComm: CommProtocol {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "MOCKComm")

    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    var ecuSettings: MockECUSettings = .init()

    func sendCommand(_ command: String, retries: Int = 3) async throws -> [String] {
        logger.info("Sending command: \(command)")
        var header = ""

        let prefix = String(command.prefix(2))
        if prefix == "01" || prefix == "06" || prefix == "09" {
            var response: String = ""
            if ecuSettings.headerOn {
                header = "7E8"
            }
            for i in stride(from: 2, to: command.count, by: 2) {
                let index = command.index(command.startIndex, offsetBy: i)
                let nextIndex = command.index(command.startIndex, offsetBy: i + 2)
                let subCommand = prefix + String(command[index..<nextIndex])
                guard let value = OBDCommand.mockResponse(forCommand: subCommand) else {
                    return ["No Data"]

                }
                response.append(value + " ")
            }
            guard var mode = Int(command.prefix(2)) else {
                return [""]
            }
            mode = mode + 40

            if response.count > 18 {
                var chunks = response.chunked(by: 15)

                var ff = chunks[0]

                var Totallength = 0

                let ffLength = ff.replacingOccurrences(of: " ", with: "").count / 2

                Totallength += ffLength

                var cf = Array(chunks.dropFirst())
                Totallength += cf.joined().replacingOccurrences(of: " ", with: "").count

                var lengthHex = String(format: "%02X", Totallength - 1)

                if lengthHex.count % 2 != 0 {
                    lengthHex = "0" + lengthHex
                }

                lengthHex = "10 " + lengthHex
                ff = lengthHex + " " + String(mode) + " " + ff

                var assembledFrame: [String] = [ff]
                var cfCount = 33
                for i in 0..<cf.count {
                    let length = String(format: "%02X", cfCount)
                    cfCount += 1
                    cf[i] = length + " " + cf[i]
                    assembledFrame.append(cf[i])
                }

                for i in 0..<assembledFrame.count {
                    assembledFrame[i] = header + " " + assembledFrame[i]
                    while assembledFrame[i].count < 28 {
                        assembledFrame[i].append("00 ")
                    }
                }

                if ecuSettings.echo {
                    assembledFrame.insert(" \(command)", at: 0)
                }
                return assembledFrame.map { String($0) }
            } else {
                let lengthHex = String(format: "%02X", response.count / 3)
                response = header + " " + lengthHex + " "  + String(mode) + " " + response
                while response.count < 28 {
                    response.append("00 ")
                }
                if ecuSettings.echo {
                    response = " \(command)" + response
                }
                return [response]
            }
        } else  if command.hasPrefix("AT") {
            let action = command.dropFirst(2)
            var response = {
                switch action {
                case " SH 7E0", "D", "L0", "AT1", "SP0", "SP6", "STFF", "S0":
                    return ["OK"]
                case "Z":
                    return ["ELM327 v1.5"]
                case "H1":
                    ecuSettings.headerOn = true
                    return ["OK"]
                case "H0":
                    ecuSettings.headerOn = false
                    return ["OK"]
                case "E1":
                    ecuSettings.echo = true
                    return ["OK"]
                case "E0":
                    ecuSettings.echo = false
                    return ["OK"]
                case "DPN":
                    return ["06"]
                case "RV":
                    return [String(Double.random(in: 12.0 ... 14.0))]
                default:
                    return ["NO DATA"]
                }
            }()
            if ecuSettings.echo {
                response .insert(command, at: 0)
            }
            return response

        } else if command == "03" {
            // 03 is a request for DTCs
            let dtcs = ["P0104", "U0207"]
            var response = ""
            // convert to hex
            for dtc in dtcs {
                var hexString = String(dtc.suffix(4))
                // 2 by 2
                hexString = hexString.chunked(by: 2).joined(separator: " ")
                response +=  hexString
                obdDebug("Generated DTC hex: \(hexString)", category: .communication)
            }
            if ecuSettings.headerOn {
                header = "7E8"
            }
            let mode = "43"
            response = mode + " " + response
            let length = String(format: "%02X", response.count / 3 + 1)
            response = header + " " + length + " " + response
            while response.count < 26 {
                response.append(" 00")
            }
            return [response]
        } else {
            guard var response = OBDCommand.mockResponse(forCommand: command) else {
                return ["No Data"]
            }
            response = command + response  + "\r\n\r\n>"
            var lines = response
                    .components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            lines.removeLast()
            return lines
        }
    }

    func disconnectPeripheral() {
        connectionState = .disconnected
        obdDelegate?.connectionStateChanged(state: .disconnected)
    }

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        connectionState = .connectedToAdapter
        obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
    }

    func scanForPeripherals() async throws {

    }
}

extension OBDCommand {
    static func mockResponse(forCommand command: String) -> String? {

        guard let obd2Command = self.from(command: command) else {
            obdWarning("Invalid mock command: \(command)", category: .communication)
            return "Invalid command"
        }

        switch obd2Command {
            case .mode1(let command):
             switch command {
                case .pidsA:
                    return "00 BE 3F A8 13 00"
                case .status:
                    return "01 12 34 56 78 00"
                case .pidsB:
                    return "20 90 07 E0 11 00"
                case .pidsC:
                    return "40 FA DC 80 00 00"
                case .rpm:
                    let desiredRPM = Int.random(in: 1000...3000)
                    let decimalRep = desiredRPM * 4

                    let A = decimalRep / 256
                    let B = decimalRep % 256

                    let hexA = String(format: "%02X", A)
                    let hexB = String(format: "%02X", B)

                    return "0C" + " " + hexA + " " + hexB
                case .speed:
                    let hexSpeed = String(format: "%02X", Int.random(in: 0...100))
                    return "0D" + " " + hexSpeed
                case .coolantTemp:
                  let temp = Int.random(in: 50...150) + 40
                 let hexTemp = String(format: "%02X", temp)
                 return "05" + " " + hexTemp
                case .maf:
                    let maf = Int.random(in: 0...655) * 100
                    let A = maf / 256
                    let B = maf % 256

                    let hexA = String(format: "%02X", A)
                    let hexB = String(format: "%02X", B)

                    return "10" + " " + hexA + " " + hexB
                case .engineLoad:
                    let load = Int.random(in: 0...100)
                    let hexLoad = String(format: "%02X", load)
                    return "04" + " " + hexLoad
                case .throttlePos:
                    let pos = Int.random(in: 0...100)
                    let hexPos = String(format: "%02X", pos)
                    return "11" + " " + hexPos
                case .fuelLevel:
                    let level = Int.random(in: 0...100)
                    let hexLevel = String(format: "%02X", Double(level) * 2.55)
                    return "2F" + " " + hexLevel
                case .fuelPressure:
                    let pressure = Int.random(in: 0...765)
                    let hexPressure = String(format: "%02X", pressure / 3)
                    return "0A" + " " + hexPressure
                case .intakeTemp:
                    let temp = Int.random(in: 0...100) + 40
                    let hexTemp = String(format: "%02X", temp)
                    return "0F" + " " + hexTemp
                case .timingAdvance:
                    let advance = Int.random(in: 0...100)
                    let hexAdvance = String(format: "%02X", advance / 2)
                    return "0E" + " " + hexAdvance
                case .intakePressure:
                    let pressure = Int.random(in: 0...255)
                    let hexPressure = String(format: "%02X", pressure)
                    return "0B" + " " + hexPressure
                case .barometricPressure:
                    let pressure = Int.random(in: 0...255)
                    let hexPressure = String(format: "%02X", pressure)
                    return "33" + " " + hexPressure
                case .fuelType:
                    return "01 01"
                case .fuelRailPressureDirect:
                    let pressure = Int.random(in: 0...65535)
                    let hexPressure = String(format: "%04X", pressure)
                    return "23" + " " + hexPressure
                case .ethanoPercent:
                    let fuel = Int.random(in: 0...100)
                    let hexFuel = String(format: "%02X", fuel)
                    return "52" + " " + hexFuel
                case .engineOilTemp:
                    let temp = Int.random(in: 0...100) + 40
                    let hexTemp = String(format: "%02X", temp)
                    return "5C" + " " + hexTemp
                case .fuelInjectionTiming:
                    let timing = Int.random(in: 0...65535)
                    let hexTiming = String(format: "%04X", timing)
                    return "5D" + " " + hexTiming
                case .fuelRate:
                    let rate = Int.random(in: 0...65535)
                    let hexRate = String(format: "%04X", rate)
                    return "5E" + " " + hexRate
                case .emissionsReq:
                    return "01 01"
                case .runTime:
                    let time = Int.random(in: 0...65535)
                    let hexTime = String(format: "%04X", time)
                    return "1F" + " " + hexTime
                case .distanceSinceDTCCleared:
                    let distance = Int.random(in: 0...65535)
                    let hexDistance = String(format: "%04X", distance)
                    return "31" + " " + hexDistance
                default:
                    return nil
            }
        case .mode6(let command):
            switch command {
                case .MIDS_A:
                    return "00 C0 00 00 01 00"
                case .MIDS_B:
                    return "02 C0 00 00 01 00"
                case .MIDS_C:
                    return "04 C0 00 00 01 00"
                case .MIDS_D:
                    return "06 C0 00 00 01 00"
                case .MIDS_E:
                    return "08 C0 00 00 01 00"
                case .MIDS_F:
                    return "0A C0 00 00 01 00"
                default:
                    return nil
            }
        case .mode9(let command):
            switch command {
            case .PIDS_9A:
                    return "00 55 40 00 00 00"
            case .VIN:
                return "02 01 31 4E 34 41 4C 33 41 50 37 44 43 31 39 39 35 38 33"
            default:
                return nil
            }
        default:
            obdDebug("No mock response for command: \(command)", category: .communication)
            return nil
        }
    }
}
//        case .O902: return  "10 14 49 02 01 31 4E 34 \r\n"
//            + header + "21 41 4C 33 41 50 37 44 \r\n" + header + "22 43 31 39 39 35 38 33 \r\n\r\n>"
extension String {
    func chunked(by chunkSize: Int) -> Array<String> {
        return stride(from: 0, to: self.count, by: chunkSize).map {
            String(self[self.index(self.startIndex, offsetBy: $0)..<self.index(self.startIndex, offsetBy: min($0 + chunkSize, self.count))])
        }
    }
}
