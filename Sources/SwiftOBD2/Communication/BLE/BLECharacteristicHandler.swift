import CoreBluetooth
import Foundation

/// Finds the characteristics an adapter uses as its serial port and writes commands to them.
class BLECharacteristicHandler {
    private let lock = NSLock()
    private var ecuReadCharacteristic: CBCharacteristic?
    private var ecuWriteCharacteristic: CBCharacteristic?
    private let messageProcessor: BLEMessageProcessor

    var isReady: Bool {
        lock.sync { ecuReadCharacteristic != nil && ecuWriteCharacteristic != nil }
    }

    init(messageProcessor: BLEMessageProcessor) {
        self.messageProcessor = messageProcessor
    }

    func setupCharacteristics(_ characteristics: [CBCharacteristic], on peripheral: CBPeripheral) {
        for characteristic in characteristics {
            let properties = characteristic.properties
            let canNotify = properties.contains(.notify) || properties.contains(.indicate)
            // Cheap adapters often only offer "write without response".
            let canWrite = properties.contains(.write) || properties.contains(.writeWithoutResponse)

            // Set up notifications for characteristics that support it
            if canNotify {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            lock.sync {
                // Assign characteristics based on UUID and properties
                switch characteristic.uuid.uuidString.uppercased() {
                case "FFE1": // for service FFE0 (read and write)
                    if canWrite { ecuWriteCharacteristic = characteristic }
                    if canNotify { ecuReadCharacteristic = characteristic }

                case "FFF1", "2AF0": // for services FFF0 and 18F0 (read)
                    if canNotify { ecuReadCharacteristic = characteristic }

                case "FFF2", "2AF1": // for services FFF0 and 18F0 (write)
                    if canWrite { ecuWriteCharacteristic = characteristic }

                default:
                    // Unknown adapter: use the first characteristics that can play each role.
                    if ecuReadCharacteristic == nil, canNotify { ecuReadCharacteristic = characteristic }
                    if ecuWriteCharacteristic == nil, canWrite { ecuWriteCharacteristic = characteristic }
                }
            }
        }

        obdInfo("Characteristics setup - ready: \(isReady)", category: .bluetooth)
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
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func writeCommand(_ command: String, to peripheral: CBPeripheral) throws {
        guard let characteristic = lock.sync({ ecuWriteCharacteristic }),
              let data = "\(command)\r".data(using: .ascii)
        else {
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }
        guard peripheral.state == .connected else {
            throw CommunicationError.notConnected
        }

        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        // A write longer than the negotiated MTU is silently truncated: split it.
        let chunkSize = max(20, peripheral.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            peripheral.writeValue(data.subdata(in: offset ..< end), for: characteristic, type: type)
            offset = end
        }
    }

    func handleUpdatedValue(_ data: Data, from characteristic: CBCharacteristic) {
        guard characteristic == lock.sync({ ecuReadCharacteristic }) else {
            return
        }

        messageProcessor.processReceivedData(data)
    }

    func reset() {
        lock.sync {
            ecuReadCharacteristic = nil
            ecuWriteCharacteristic = nil
        }
        messageProcessor.reset()
    }
}
