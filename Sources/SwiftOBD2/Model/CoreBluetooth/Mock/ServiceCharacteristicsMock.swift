import Foundation
import CoreBluetooth

class ServiceCharacteristicsMock {
    private var value: Data = Data([UInt8(0x01)])

    private let serviceUuid1: CBUUID = CBUUID(string: "00112233-4455-6677-8899-AABBCCDDEEFF")
    private let characteristicUuid1ForService1: CBUUID = CBUUID(string: "10112233-4455-6677-8899-AABBCCDDEEFF")
    //    private let characteristicUuid2ForService1: CBUUID = CBUUID(string: "10112233-4455-6677-8899-AABBCCDDEEFF")

    private let ecuServiceUuid: CBUUID = CBUUID(string: "FFE0")
    private let ecuCharacteristicUuid: CBUUID = CBUUID(string: "FFE1")


    public func service() -> [CBMutableService] {
        return [
            CBMutableService(type: serviceUuid1, primary: true),
            CBMutableService(type: ecuServiceUuid, primary: true),
        ]
    }

    public func characteristics(_ serviceUUID: CBUUID) -> [CBCharacteristic] {
        switch serviceUUID {
        case serviceUuid1:
            return [
                mutableCharacteristic(uuid: characteristicUuid1ForService1, properties: [.read])
                //                mutableCharacteristic(uuid: characteristicUuid2ForService1, properties: [.read]),
            ]
        case ecuServiceUuid:
            return [
                mutableCharacteristic(uuid: ecuCharacteristicUuid, properties: [.read, .write, .notify])
            ]
        default:
            return []
        }
    }

    private func mutableCharacteristic(uuid: CBUUID, properties: CBCharacteristicProperties) -> CBMutableCharacteristic {
        return CBMutableCharacteristic(type: uuid,
                                       properties: properties,
                                       value: nil,
                                       permissions: .readable)
    }

    public func value(uuid: CBUUID) -> Data {
        switch uuid {
        case characteristicUuid1ForService1:
            return value
        case ecuCharacteristicUuid:
            return value
        default:
            return Data()
        }
    }

    let header = "7E8"

    public func writeValue(uuid: CBUUID, writeValue: Data, delegate: CBPeripheralProtocolDelegate, ecuSettings: inout MockECUSettings) {
        guard let dataString = String(data: writeValue, encoding: .utf8) else {
            print("Could not convert data to string")
            return
        }
        switch uuid {
        case characteristicUuid1ForService1:
            value = writeValue

        case ecuCharacteristicUuid:
            if let command = MockResponse(rawValue: dataString) {
                let response = command.response(ecuSettings: &ecuSettings)

                guard let responseData = response.data(using: .utf8) else {
                    print("Could not convert response to data")
                    value = Data()
                    return
                }
                value = responseData
            } else {

            }
        default:
            break
        }
    }
}

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
            echo = self.rawValue + "\r\n"
        }

        if ecuSettings.headerOn {
            header = "7E8 "
        }

        switch self {
        case .ATZ: return "ELM327 v1.5\r\n\r\n>"
        case .ATD, .ATL0,  .ATAT1, .ATSP0, .ATSP6, .ATSH7E0:  return echo + "OK\r\n>"
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

        case .ATRV:  return "\(Double.random(in: 12.0...14.0))\r\n>"
        case .ATDPN: return "06\r\n>"
        case .O100:  return echo + header + "06 41 00 BE 3F A8 13 00\r\n\r\n>"
        case .O120:  return echo + header + "06 41 20 90 07 E0 11 00\r\n\r\n>"
        case .O140:  return echo + header + "06 41 40 FA DC 80 00 00\r\n\r\n>"
        case .O600:  return echo + header + "06 46 00 C0 00 00 01 00\r\n\r\n>"
        case .O620:  return echo + header + "06 46 00 C0 00 00 01 00\r\n\r\n>"
        case .O640:  return echo + header + "06 46 40 C0 00 00 01 00\r\n\r\n>"
        case .O660:  return echo + header + "06 46 60 00 00 00 01 00\r\n\r\n>"
        case .O680:  return echo + header + "06 46 80 80 00 00 01 00\r\n\r\n>"
        case .O6A0:  return echo + header + "06 46 A0 F8 00 00 00 00\r\n\r\n>"
        case .O900:  return echo + header + "06 49 00 55 40 00 00 00\r\n\r\n>"
        case .O902:  return echo + header + "10 14 49 02 01 31 4E 34 \r\n" + header + "21 41 4C 33 41 50 37 44 \r\n" + header + "22 43 31 39 39 35 38 33 \r\n\r\n>"
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
//switch dataString {
//    case "ATZ\r":
//        // Send back ElM327 V1.5 as data
//        let response = "ELM327 v1.5\r\n>".data(using: .utf8)!
//        value = response
//    case "ATD\r", "ATL0\r", "ATE0\r", "ATH1\r", "ATAT1\r", "ATSP0\r", "ATSP6\r":
//        // Send back ElM327 V1.5 as data
//        let response = "OK\r\n>".data(using: .utf8)!
//        value = response
//    case "ATRV\r":
//        // Send back ElM327 V1.5 as data
//        let voltage = Double.random(in: 12.0...14.0)
//        let response = "\(voltage)\r\n>".data(using: .utf8)!
//        value = response
//    case "ATDPN\r":
//        // Send back ElM327 V1.5 as data
//        let response = "06\r\n>".data(using: .utf8)!
//        value = response
//    case "0100\r":
//        // Send back ElM327 V1.5 as data
//        let response = "7E8 06 41 00 BE 3F A8 13 00\r\n>".data(using: .utf8)!
//        value = response
//    case "0120\r":
//        // Send back ElM327 V1.5 as data
//        let response = "7E8 06 41 20 12 34 56 78 00\r\n>".data(using: .utf8)!
//        value = response
//
//    case "0140\r":
//        // Send back ElM327 V1.5 as data
//        let response = "7E8 06 41 40 12 34 56 78 00\r\n>".data(using: .utf8)!
//        value = response
//
//    case "AT SH 7E0\r":
//        // Send back ElM327 V1.5 as data
//        let response = "OK\r\n>".data(using: .utf8)!
//        value = response
//    default:
//        print("default")
//}
