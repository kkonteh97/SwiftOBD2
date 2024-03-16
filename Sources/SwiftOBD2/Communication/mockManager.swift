//
//  File.swift
//  
//
//  Created by kemo konteh on 3/16/24.
//

import Foundation

enum CommandAction {
    case setHeaderOn
    case setHeaderOff
    case echoOn
    case echoOff
}

struct MockECUSettings {
    var headerOn = false
    var echo = true
    var vinNumber = ""
}

class MOCKComm: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    var ecuSettings: MockECUSettings = .init()

    func sendCommand(_ command: String) async throws -> [String] {
        if let command = MockResponse(rawValue: command) {
            let response = command.response(ecuSettings: &ecuSettings)
            return [response]
        } else {
            return ["NO DATA"]
        }
    }

    func disconnectPeripheral() {
        connectionState = .disconnected
        obdDelegate?.connectionStateChanged(state: .disconnected)
    }

    func connectAsync() async throws {
        connectionState = .connectedToAdapter
        obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
    }
}

enum MockResponse: String, CaseIterable {
    case ATZ = "ATZ\r"
    case ATD = "ATD\r"
    case ATL0 = "ATL0\r"
    case ATE0 = "ATE0\r"
    case ATE1 = "ATE1\r"
    case ATH1 = "ATH1\r"
    case ATH0 = "ATH0\r"
    case ATAT1 = "ATAT1\r"
    case ATRV = "ATRV\r"
    case ATDPN = "ATDPN\r"
    case ATSP0 = "ATSP0\r"
    case ATSP6 = "ATSP6\r"
    case O100 = "0100\r"
    case O120 = "0120\r"
    case O140 = "0140\r"
    case O600 = "0600\r"
    case O620 = "0620\r"
    case O640 = "0640\r"
    case O660 = "0660\r"
    case O680 = "0680\r"
    case O6A0 = "06A0\r"
    case O900 = "0900\r"
    case O902 = "0902\r"
    case ATSH7E0 = "AT SH 7E0\r"

    func response(ecuSettings: inout MockECUSettings) -> String {
        var header = ""
        var echo = ""

        if ecuSettings.echo {
            echo = rawValue + "\r\n"
        }

        if ecuSettings.headerOn {
            header = "7E8 "
        }

        switch self {
        case .ATZ: return "ELM327 v1.5\r\n\r\n>"
        case .ATD, .ATL0, .ATAT1, .ATSP0, .ATSP6, .ATSH7E0: return echo + "OK\r\n>"
        case .ATH1:
            ecuSettings.headerOn = true
            return echo + "OK\r\n>"
        case .ATH0:
            ecuSettings.headerOn = false
            return echo + "OK\r\n>"
        case .ATE1:
            ecuSettings.echo = true
            return echo + "OK\r\n>"
        case .ATE0:
            ecuSettings.echo = false
            return echo + "OK\r\n>"

        case .ATRV: return "\(Double.random(in: 12.0 ... 14.0))\r\n>"
        case .ATDPN: return "06\r\n>"
        case .O100: return echo + header + "06 41 00 BE 3F A8 13 00\r\n\r\n>"
        case .O120: return echo + header + "06 41 20 90 07 E0 11 00\r\n\r\n>"
        case .O140: return echo + header + "06 41 40 FA DC 80 00 00\r\n\r\n>"
        case .O600: return echo + header + "06 46 00 C0 00 00 01 00\r\n\r\n>"
        case .O620: return echo + header + "06 46 00 C0 00 00 01 00\r\n\r\n>"
        case .O640: return echo + header + "06 46 40 C0 00 00 01 00\r\n\r\n>"
        case .O660: return echo + header + "06 46 60 00 00 00 01 00\r\n\r\n>"
        case .O680: return echo + header + "06 46 80 80 00 00 01 00\r\n\r\n>"
        case .O6A0: return echo + header + "06 46 A0 F8 00 00 00 00\r\n\r\n>"
        case .O900: return echo + header + "06 49 00 55 40 00 00 00\r\n\r\n>"
        case .O902: return echo + header + "10 14 49 02 01 31 4E 34 \r\n"
            + header + "21 41 4C 33 41 50 37 44 \r\n" + header + "22 43 31 39 39 35 38 33 \r\n\r\n>"
        }
    }

    var action: CommandAction? {
        switch self {
        case .ATH1: return .setHeaderOn
        case .ATH0: return .setHeaderOff
        case .ATE0: return .echoOff
        case .ATE1: return .echoOn
        default: return nil
        }
    }
}

extension OBDCommand {
    static func lookupCommand(forValue value: String) -> OBDCommand? {
        for command in General.allCases {
            if command.properties.command == value {
                return .general(command)
            }
        }

        for command in OBDCommand.Mode1.allCases {
            if command.properties.command == value {
                return .mode1(command)
            }
        }

        return nil
    }
}
