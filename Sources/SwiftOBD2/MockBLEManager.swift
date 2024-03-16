//
//  File.swift
//  
//
//  Created by kemo konteh on 3/3/24.
//

import Foundation
import CoreBluetooth

protocol BLEManagerProtocol {
    var connectionState: ConnectionState { get }
    var connectedPeripheral: CBPeripheralProtocol? { get }
    var foundPeripherals: [Peripheral] { get }

    func disconnectPeripheral()
    func sendMessageAsync(_ message: String) async throws -> [String]
}

class MockBLEManager: NSObject, ObservableObject, CBPeripheralProtocolDelegate, CBCentralManagerProtocolDelegate, BLEManagerProtocol {
    @Published var connectedPeripheral: CBPeripheralProtocol?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var foundPeripherals: [Peripheral] = []

    private(set) var characteristics: [CBCharacteristic] = []

    private var ecuReadCharacteristic: CBCharacteristic? = CBMutableCharacteristic(type: CBUUID(string: "FFE1"),
                                                                                   properties: [.read, .write, .notify],
                                                                                   value: nil,
                                                                                   permissions: .readable)
    private var ecuWriteCharacteristic: CBCharacteristic?  = CBMutableCharacteristic(type: CBUUID(string: "FFE1"),
                                                                                     properties: [.read, .write, .notify],
                                                                                     value: nil,
                                                                                     permissions: .readable)

    private var charCompletion: ((CBCharacteristic?) -> Void)?
    private var sendMessageCompletion: (([String]?, Error?) -> Void)?
    private var connectionCompletion: ((CBPeripheralProtocol?, Error?) -> Void)?
    private var foundPeripheralCompletion: ((CBPeripheralProtocol?, Error?) -> Void)?

    private var centralManager: CBCentralManagerProtocol!

    private var buffer = Data()

    override init() {
        super.init()
        self.centralManager = CBCentralManagerMock(delegate: self, queue: nil, options: nil)
        connectedPeripheral = CBPeripheralMock(identifier: UUID(uuidString: "5B6EE3F4-2FCA-CE45-6AE7-8D7390E64A34") ?? UUID(),
                                               name: "MockOBD",
                                               manager: centralManager as! CBCentralManagerMock)
        connectionState = .connectedToAdapter
        connectedPeripheral?.delegate = self
    }

    // MARK: - Central Manager Control Methods

    func startScanning() {
        let scanOption = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        centralManager?.scanForPeripherals(withServices: nil, options: scanOption)
    }

    func stopScan() {
        centralManager?.stopScan()
    }

    func didDiscover(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol, advertisementData: [String: Any], rssi: NSNumber) {
//        connect(to: peripheral)
        appendFoundPeripheral(peripheral: peripheral, advertisementData: advertisementData, rssi: rssi)
        if foundPeripheralCompletion != nil {
            foundPeripheralCompletion?(peripheral, nil)
        }
    }

    func appendFoundPeripheral(peripheral: CBPeripheralProtocol, advertisementData: [String: Any], rssi: NSNumber) {
        if rssi.intValue >= 0 { return }
        let peripheralName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? nil
        var _name = "NoName"

        if peripheralName != nil {
            _name = String(peripheralName!)
        } else if peripheral.name != nil {
            _name = String(peripheral.name!)
        }

        let foundPeripheral: Peripheral = Peripheral(_peripheral: peripheral,
                                                     _name: _name,
                                                     _advData: advertisementData,
                                                     _rssi: rssi,
                                                     _discoverCount: 0)

        if let index = foundPeripherals.firstIndex(where: { $0.peripheral.identifier.uuidString == peripheral.identifier.uuidString }) {
            if foundPeripherals[index].discoverCount % 50 == 0 {
                foundPeripherals[index].name = _name
                foundPeripherals[index].rssi = rssi.intValue
                foundPeripherals[index].discoverCount += 1
            } else {
                foundPeripherals[index].discoverCount += 1
            }
        } else {
            foundPeripherals.append(foundPeripheral)
        }
    }

    func connect(to peripheral: CBPeripheralProtocol) {
        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        stopScan()
    }

    func didConnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol) {
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self
        connectedPeripheral?.discoverServices([CBUUID(string: "FFE0"), CBUUID(string: "FFF0")])
        connectionState = .connectedToAdapter
    }

    func disconnectPeripheral() {
        guard let connectedPeripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(connectedPeripheral)
    }

    func didDiscoverServices(_ peripheral: CBPeripheralProtocol, error: Error?) {
        for service in peripheral.services ?? [] {
            if service.uuid == CBUUID(string: "FFE0") {
                    peripheral.discoverCharacteristics([CBUUID(string: "FFE1"), CBUUID(string: "FFF1"), CBUUID(string: "FFF2")], for: service)
                } else if service.uuid == CBUUID(string: "FFF0") {
                    peripheral.discoverCharacteristics([CBUUID(string: "FFF1"), CBUUID(string: "FFF2")], for: service)
                } else  {
                    peripheral.discoverServices(nil)
            }
        }
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheralProtocol, service: CBService, error: Error?) {
        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            return
        }
        self.characteristics.append(contentsOf: characteristics)
        for characteristic in characteristics {
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if self.connectionCompletion != nil {
            self.connectionCompletion?(peripheral, nil)
        }
    }

    func sendMessageAsync(_ message: String) async throws -> [String] {
        // ... (sending message logic)
        guard sendMessageCompletion == nil else {
            throw BLEManagerError.sendingMessagesInProgress
        }

        guard let connectedPeripheral = self.connectedPeripheral,
              let characteristic = self.ecuWriteCharacteristic,
              let data = ("\(message)\r").data(using: .ascii) else {
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            // Set up a timeout timer
            self.sendMessageCompletion = { response, error in
                if let response = response {
                    continuation.resume(returning: response)

                } else if let error = error {
                    continuation.resume(throwing: error)
                }
            }
            connectedPeripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    func didUpdateValue(_ peripheral: CBPeripheralProtocol, characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error reading characteristic value: \(error.localizedDescription)")
            return
        }

        guard let characteristicValue = characteristic.value else {
            return
        }

        switch characteristic.uuid {
        case ecuReadCharacteristic?.uuid:
            processReceivedData(characteristicValue)

        default:
            if let responseString = String(data: characteristicValue, encoding: .utf8) {
                if charCompletion != nil {
                    if responseString.contains("OK") {
                        charCompletion?(characteristic)
                        charCompletion = nil
                    } else {
                        charCompletion?(nil)
                        charCompletion = nil
                    }
                }
            }
        }
    }

    func willRestoreState(_ central: CBCentralManagerProtocol, dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            peripherals[0].delegate = self
            connectedPeripheral = peripherals[0]
        }
    }

    func didUpdateState(_ central: CBCentralManagerProtocol) {
        switch central.state {
        case .poweredOn:
            guard let device = connectedPeripheral else {
                centralManager.scanForPeripherals(withServices: [CBUUID(string: "FFE0"), CBUUID(string: "FFF0")], options: nil)
                return
            }
            connect(to: device)
        case .poweredOff:
            self.connectedPeripheral = nil
            self.connectionState = .disconnected
        case .unsupported:
            print("This device does not support Bluetooth Low Energy.")
        case .unauthorized:
            print("This app is not authorized to use Bluetooth Low Energy.")
        case .resetting:
            print("Bluetooth is resetting.")
        default:
            print("Bluetooth is not powered on.")
            fatalError()
        }
    }

    func didFailToConnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol, error: Error?) {
        connectedPeripheral = nil
        disconnectPeripheral()
    }

    func didDisconnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol, error: Error?) {
        connectedPeripheral = nil
        connectionState = .disconnected
        resetConfigure()
    }

    func processReceivedData(_ data: Data) {
        buffer.append(data)

        guard let string = String(data: buffer, encoding: .utf8) else {
            buffer.removeAll()
            return
        }

        if string.contains(">") {
            var lines = string
                .replacingOccurrences(of: "\u{00}", with: "")
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            // remove the last line
            lines.removeLast()
            if sendMessageCompletion != nil {
                if lines[0].uppercased().contains("NO DATA") {
                    sendMessageCompletion?(nil, BLEManagerError.noData)
                } else {
                    sendMessageCompletion?(lines, nil)
                }
            }
            sendMessageCompletion = nil
            buffer.removeAll()
        }
    }

    func connectionEventDidOccur(_ central: CBCentralManagerProtocol, event: CBConnectionEvent, peripheral: CBPeripheralProtocol) {

    }

    func resetConfigure() {
        ecuReadCharacteristic = nil
        connectedPeripheral = nil
    }
}

extension MockBLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        didDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        didDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateValue(peripheral, characteristic: characteristic, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        didDiscover(central, peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        didConnect(central, peripheral: peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        didUpdateState(central)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        didFailToConnect(central, peripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        didDisconnect(central, peripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        willRestoreState(central, dict: dict)
    }
}
