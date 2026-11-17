import Foundation
import CoreBluetooth

class BLECharacteristicHandler {
    private var ecuReadCharacteristic: CBCharacteristic?
    private var ecuWriteCharacteristic: CBCharacteristic?
    private let messageProcessor: BLEMessageProcessor

    // Device Information Service (0x180A) — Bluetooth SIG standard, all readable UTF-8 strings
    // except 2A23 (System ID, 8-byte binary) and 2A2A (IEEE cert, binary).
    private static let deviceInfoLabels: [String: String] = [
        "2A29": "Manufacturer",
        "2A24": "Model",
        "2A25": "Serial Number",
        "2A27": "Hardware Revision",
        "2A26": "Firmware Revision",
        "2A28": "Software Revision",
        "2A23": "System ID",
        "2A2A": "IEEE Certification",
    ]

    // ISSC/Microchip Transparent UART (service 49535343-FE7D-4AE5-8FA9-9FAFD205E455)
    // Alternative ELM327 channel found on RN4870/ISP1807 modules — FFF0 is preferred.
    private static let isscUUIDs: Set<String> = [
        "49535343-6DAA-4D02-ABF6-19569ACA69FE",  // TX / Notify
        "49535343-ACA3-481C-91EC-D85E28A60318",  // RX / Write Without Response
    ]

    private(set) var deviceInfo: [String: String] = [:]
    var onDeviceInfoUpdated: (([String: String]) -> Void)?

    var isReady: Bool {
        ecuReadCharacteristic != nil && ecuWriteCharacteristic != nil
    }

    init(messageProcessor: BLEMessageProcessor) {
        self.messageProcessor = messageProcessor
    }

    func setupCharacteristics(_ characteristics: [CBCharacteristic], on peripheral: CBPeripheral) {
        for characteristic in characteristics {
            let uuid = characteristic.uuid.uuidString.uppercased()

            // Device Information Service — read and store, don't treat as OBD channel
            if Self.deviceInfoLabels[uuid] != nil {
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
                continue
            }

            // ISSC UART — recognised, not used (FFF0 preferred)
            if Self.isscUUIDs.contains(uuid) {
                obdDebug("ISSC UART characteristic recognised (unused): \(uuid)", category: .bluetooth)
                continue
            }

            // OBD characteristics — subscribe to notify where supported
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            switch uuid {
            case "FFE1": // FFE0 service — single characteristic handles both read and write
                if characteristic.properties.contains(.write) {
                    ecuWriteCharacteristic = characteristic
                }
                if characteristic.properties.contains(.read) || characteristic.properties.contains(.notify) {
                    ecuReadCharacteristic = characteristic
                }

            case "FFF1": // FFF0 service — notify (read)
                if characteristic.properties.contains(.read) || characteristic.properties.contains(.notify) {
                    ecuReadCharacteristic = characteristic
                }

            case "FFF2": // FFF0 service — write
                if characteristic.properties.contains(.write) {
                    ecuWriteCharacteristic = characteristic
                }

            case "2AF0": // 18F0 service — read
                ecuReadCharacteristic = characteristic

            case "2AF1": // 18F0 service — write
                ecuWriteCharacteristic = characteristic

            default:
                obdInfo("Unknown characteristic: \(uuid) — properties: \(characteristic.properties.rawValue)", category: .bluetooth)
            }
        }

        obdInfo("Characteristics setup — Read: \(self.ecuReadCharacteristic != nil), Write: \(self.ecuWriteCharacteristic != nil)", category: .bluetooth)
    }

    func discoverCharacteristics(for service: CBService, on peripheral: CBPeripheral) {
        switch service.uuid {
        case CBUUID(string: "FFE0"):
            peripheral.discoverCharacteristics([CBUUID(string: "FFE1")], for: service)
        case CBUUID(string: "FFF0"):
            peripheral.discoverCharacteristics([CBUUID(string: "FFF1"), CBUUID(string: "FFF2")], for: service)
        case CBUUID(string: "18F0"):
            peripheral.discoverCharacteristics([CBUUID(string: "2AF0"), CBUUID(string: "2AF1")], for: service)
        default:
            // Discover all characteristics for unknown services (Device Info, ISSC, etc.)
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func writeCommand(_ command: String, to peripheral: CBPeripheral) throws {
        guard let characteristic = ecuWriteCharacteristic,
              let data = "\(command)\r".data(using: .ascii) else {
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        // Routed through OBDLogger so the consuming app's log-level preference
        // can silence this per-command line (a raw os.Logger call can't be gated).
        obdDebug("Sent command: \(command)", category: .communication)
    }

    func handleUpdatedValue(_ data: Data, from characteristic: CBCharacteristic) {
        let uuid = characteristic.uuid.uuidString.uppercased()

        // Device info read response
        if let label = Self.deviceInfoLabels[uuid] {
            let decoded = Self.decodeDeviceInfoValue(data: data, uuid: uuid)
            if !decoded.isEmpty {
                deviceInfo[label] = decoded
                onDeviceInfoUpdated?(deviceInfo)
            }
            return
        }

        guard characteristic == ecuReadCharacteristic else {
            // A characteristic we don't handle produced a notification — log and ignore
            if let text = String(data: data, encoding: .utf8) {
                obdDebug("Unhandled notification from \(uuid): \(text)", category: .bluetooth)
            } else {
                obdDebug("Unhandled notification from \(uuid): \(data.map { String(format: "%02X", $0) }.joined(separator: " "))", category: .bluetooth)
            }
            return
        }

        messageProcessor.processReceivedData(data)
    }

    func reset() {
        ecuReadCharacteristic = nil
        ecuWriteCharacteristic = nil
        deviceInfo = [:]
    }

    // MARK: - Decoding

    private static func decodeDeviceInfoValue(data: Data, uuid: String) -> String {
        guard !data.isEmpty else { return "" }
        switch uuid {
        case "2A23": // System ID — 8-byte manufacturer-assigned binary identifier
            return data.map { String(format: "%02X", $0) }.joined(separator: ":")
        case "2A2A": // IEEE 11073 Regulatory Certification — binary, show as hex
            return data.map { String(format: "%02X", $0) }.joined(separator: " ")
        default: // All others are UTF-8 strings
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}
