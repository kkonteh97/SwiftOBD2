//
//  bleConnection.swift
//  Obd2Scanner
//
//  Created by kemo konteh on 8/3/23.
//

import Foundation
import CoreBluetooth
import Combine
import OSLog

public enum ConnectionState {
    case disconnected
    case connectedToAdapter
    case connectedToVehicle
}

class BLEManager: NSObject, ObservableObject, CBPeripheralProtocolDelegate, CBCentralManagerProtocolDelegate {
    let logger = Logger(subsystem: "com.kemo.SmartOBD2", category: "BLEManager")

    // MARK: Properties
    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectedPeripheral: CBPeripheralProtocol?
    @Published var foundPeripherals: [Peripheral] = []

    private var centralManager: CBCentralManagerProtocol!
    private(set) var ecuReadCharacteristic: CBCharacteristic?
    private(set) var ecuWriteCharacteristic: CBCharacteristic?
    private(set) var characteristics: [CBCharacteristic] = []

    static let RestoreIdentifierKey: String = "OBD2Adapter"

    var debug = true

    private var buffer = Data()

    private var sendMessageCompletion: (([String]?, Error?) -> Void)?
    private var foundPeripheralCompletion: ((CBPeripheralProtocol?, Error?) -> Void)?
    private var connectionCompletion: ((CBPeripheralProtocol?, Error?) -> Void)?
    private var charCompletion: ((CBCharacteristic?) -> Void)?

    // MARK: - Initialization
    override init() {
        super.init()
        #if targetEnvironment(simulator)
        self.centralManager = CBCentralManagerMock(delegate: self, queue: nil, options: nil)
        #else
        self.centralManager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true,
                                                                                   CBCentralManagerOptionRestoreIdentifierKey : BLEManager.RestoreIdentifierKey])
        #endif
    }

    func demoModeSwitch(_ isDemoMode: Bool) {
        // switch to mock manager in demo mode
        switch isDemoMode {
        case true:
            disconnectPeripheral()
            centralManager = CBCentralManagerMock(delegate: self, queue: nil)
        case false:
            centralManager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true,
                                                                                  CBCentralManagerOptionRestoreIdentifierKey : BLEManager.RestoreIdentifierKey])
        }
    }

    // MARK: - Central Manager Control Methods

    func startScanning(_ serviceUUIDs: [CBUUID]?) {
        let scanOption = [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        centralManager?.scanForPeripherals(withServices: serviceUUIDs, options: scanOption)
    }

    func stopScan(){
        centralManager?.stopScan()
    }

    func disconnectPeripheral() {
        guard let connectedPeripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(connectedPeripheral)
    }

    // MARK: - Central Manager Delegate Methods
    func didUpdateState(_ central: CBCentralManagerProtocol) {
        switch central.state {
        case .poweredOn:
            guard let device = connectedPeripheral else {
                startScanning([CBUUID(string: "FFE0"), CBUUID(string: "FFF0")])
                return
            }
            if debug {
                logger.debug("Bluetooth is On.")
            }
            connect(to: device)
        case .poweredOff:
            logger.warning("Bluetooth is currently powered off.")
            self.connectedPeripheral = nil
            self.connectionState = .disconnected
        case .unsupported:
            logger.error("This device does not support Bluetooth Low Energy.")
        case .unauthorized:
            logger.error("This app is not authorized to use Bluetooth Low Energy.")
        case .resetting:
            logger.warning("Bluetooth is resetting.")
        default:
            logger.error("Bluetooth is not powered on.")
            fatalError()
        }
    }

    func didDiscover(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol, advertisementData: [String : Any], rssi: NSNumber) {
        connect(to: peripheral)
        appendFoundPeripheral(peripheral: peripheral, advertisementData: advertisementData, rssi: rssi)
        if foundPeripheralCompletion != nil {
            foundPeripheralCompletion?(peripheral, nil)
        }
    }

    func connect(to peripheral: CBPeripheralProtocol) {
        if debug {
            logger.info("Connecting to: \(peripheral.name ?? "")")
        }
        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        if centralManager.isScanning {
            centralManager.stopScan()
        }
    }

    func didConnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol) {
        if debug {
            logger.info("Connected to peripheral: \(peripheral.name ?? "Unnamed")")
        }
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self
        connectedPeripheral?.discoverServices([CBUUID(string: "FFE0"), CBUUID(string: "FFF0")])
        connectionState = .connectedToAdapter
    }

    func appendFoundPeripheral(peripheral: CBPeripheralProtocol, advertisementData: [String : Any], rssi: NSNumber) {
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

    func scanForPeripheralAsync(timeout: TimeInterval) async throws -> CBPeripheralProtocol? {
        // returns a single peripheral with the specified services
        return try await Timeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheralProtocol, Error>) in
                self.foundPeripheralCompletion = { peripheral, error in
                    if let peripheral = peripheral {
                        continuation.resume(returning: peripheral)
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    }
                    self.foundPeripheralCompletion = nil
                }
                self.startScanning([CBUUID(string: "FFF0"), CBUUID(string: "FFE0")])
            }
        }
    }

    // MARK: - Peripheral Delegate Methods

    func didDiscoverServices(_ peripheral: CBPeripheralProtocol, error: Error?) {
        for service in peripheral.services ?? [] {
            if service.uuid == CBUUID(string: "FFE0") {
                peripheral.discoverCharacteristics([CBUUID(string: "FFE1")], for: service)
            } else if service.uuid == CBUUID(string: "FFF0") {
                peripheral.discoverCharacteristics([CBUUID(string: "FFF1"), CBUUID(string: "FFF2")], for: service)
            } else {
                if connectionCompletion != nil {
                    connectionCompletion?(peripheral, nil)
                }
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheralProtocol, service: CBService, error: Error?) {
        guard let newCharacteristics = service.characteristics, !newCharacteristics.isEmpty else {
            return
        }
        self.characteristics.append(contentsOf: newCharacteristics)

        for characteristic in newCharacteristics {
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if self.connectionCompletion != nil {
            self.connectionCompletion?(peripheral, nil)
        }

        // Process queued characteristics if not currently processing
        if self.characteristics.count == newCharacteristics.count {
            let backgroundQueue = DispatchQueue.global(qos: .background)
            backgroundQueue.async {
                Task {
                    await self.processCharacteristics()
                }
            }
        }
    }

    func processCharacteristics() async {
        guard !self.characteristics.isEmpty else {
            return
        }

        let characteristic = self.characteristics.removeFirst()
        print("Processing characteristic: \(characteristic.uuid.uuidString)")
        guard characteristic.properties.contains(.write), charCompletion == nil else {
            // check the remaining characteristics
            await processCharacteristics()
            return
        }

        guard let readCharacteristic = try? await testCharacteristic(characteristic: characteristic) else {
            print("Error getting read characteristic")
            await processCharacteristics()
            return
        }
        self.ecuWriteCharacteristic = characteristic
        self.ecuReadCharacteristic = readCharacteristic
            print("Found ECU Write Characteristic: \(characteristic.uuid.uuidString)")
            print("Found ECU Read Characteristic: \(readCharacteristic.uuid.uuidString)")
        return
    }

    func testCharacteristic(characteristic: CBCharacteristic) async throws -> CBCharacteristic? {
        guard let data = ("ATD\r").data(using: .ascii) else {
            throw BLEManagerError.incorrectDataConversion
        }

        guard let peripheral = self.connectedPeripheral else {
            throw BLEManagerError.peripheralNotConnected
        }
        return try await Timeout(seconds: 2) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBCharacteristic?, Error>) in
                self.charCompletion = { characteristic in
                    if let characteristic = characteristic {
                        continuation.resume(returning: characteristic)
                    }
                }
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        }
    }

    func didUpdateValue(_ peripheral: CBPeripheralProtocol, characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Error reading characteristic value: \(error.localizedDescription)")
            return
        }

        guard let characteristicValue = characteristic.value else {
            return
        }

        switch characteristic {
        case ecuReadCharacteristic:
            processReceivedData(characteristicValue, completion: sendMessageCompletion)

        default:
            guard let responseString = String(data: characteristicValue, encoding: .utf8) else {
                return
            }
            if charCompletion != nil  {
                if responseString.contains("OK") {
                    charCompletion?(characteristic)
                    charCompletion = nil
                }
            }
            logger.info("Unknown characteristic: \(characteristic)\nResponse: \(responseString)")
        }
    }

    func didFailToConnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol, error: Error?) {
        logger.error("Failed to connect to peripheral: \(peripheral.name ?? "Unnamed")")
        connectedPeripheral = nil
        disconnectPeripheral()
    }

    func didDisconnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol, error: Error?) {
        logger.info("Disconnected from peripheral: \(peripheral.name ?? "Unnamed")")
        resetConfigure()
    }

    func connectAsync(peripheral: CBPeripheralProtocol) async throws -> CBPeripheralProtocol {
        // ... (peripheral connection logic)
        let connectedPeripheral = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheralProtocol, Error>) in
            self.connectionCompletion = { peripheral, error in
                if let peripheral = peripheral {
                    continuation.resume(returning: peripheral)
                } else if let error = error {
                    continuation.resume(throwing: error)
                }
            }
            connect(to: peripheral)
        }
        connectionCompletion = nil
        return connectedPeripheral
    }

    func connectionEventDidOccur(_ central: CBCentralManagerProtocol, event: CBConnectionEvent, peripheral: CBPeripheralProtocol) {
        logger.error("Connection event occurred: \(event.rawValue)")
    }

    // MARK: - Sending Messages

    func sendMessageAsync(_ message: String) async throws -> [String] {
        // ... (sending message logic)
        if debug {
            logger.debug("Sending message: \(message)")
        }
        guard sendMessageCompletion == nil else {
            throw BLEManagerError.sendingMessagesInProgress
        }

        guard let connectedPeripheral = self.connectedPeripheral,
              let characteristic = self.ecuWriteCharacteristic,
              let data = ("\(message)\r").data(using: .ascii) else {
            logger.error("Error: Missing peripheral or ecu characteristic.")
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }
        return try await Timeout(seconds: 3) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
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
    }

    func willRestoreState(_ central: CBCentralManagerProtocol, dict: [String : Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            logger.debug("Restoring peripheral: \(peripherals[0].name ?? "Unnamed")")
            peripherals[0].delegate = self
            connectedPeripheral = peripherals[0]
        }
    }

    func processReceivedData(_ data: Data, completion: (([String]?, Error?) -> Void)?) {
        buffer.append(data)

        guard let string = String(data: buffer, encoding: .utf8) else {
            buffer.removeAll()
            return
        }

        if string.contains(">") {
            var lines = string
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            // remove the last line
            lines.removeLast()
            if debug {
                logger.info("Response: \(lines)")
            }

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

    func Timeout<R>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        return try await withThrowingTaskGroup(of: R.self) { group in
            // Start actual work.
            group.addTask {
                let result = try await operation()
                try Task.checkCancellation()
                return result
            }
            // Start timeout child task.
            group.addTask {
                if seconds > 0 {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
                try Task.checkCancellation()
                // We’ve reached the timeout.
                if self.foundPeripheralCompletion != nil {
                    self.foundPeripheralCompletion?(nil, BLEManagerError.scanTimeout)
                }
                throw BLEManagerError.timeout
            }
            // First finished child task wins, cancel the other task.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func resetConfigure() {
        ecuReadCharacteristic = nil
        connectedPeripheral = nil
        connectionState = .disconnected
    }
}

public enum BLEManagerError: Error, CustomStringConvertible {
    case missingPeripheralOrCharacteristic
    case unknownCharacteristic
    case scanTimeout
    case sendMessageTimeout
    case stringConversionFailed
    case noData
    case incorrectDataConversion
    case peripheralNotConnected
    case sendingMessagesInProgress
    case timeout

    public var description: String {
        switch self {
        case .missingPeripheralOrCharacteristic:
            return "Error: Device not connected. Make sure the device is correctly connected."
        case .scanTimeout:
            return "Error: Scan timed out. Please try to scan again or check the device's Bluetooth connection."
        case .sendMessageTimeout:
            return "Error: Send message timed out. Please try to send the message again or check the device's Bluetooth connection."
        case .stringConversionFailed:
            return "Error: Failed to convert string. Please make sure the string is in the correct format."
        case .noData:
            return "Error: No Data"
        case .unknownCharacteristic:
            return "Error: Unknown characteristic"
        case .incorrectDataConversion:
            return "Error: Incorrect data conversion"
        case .peripheralNotConnected:
            return "Error: Peripheral not connected"
        case .sendingMessagesInProgress:
            return "Error: Sending messages in progress"
        case .timeout:
            return "Error: Timeout"
        }
    }
}

extension BLEManager: CBCentralManagerDelegate, CBPeripheralDelegate {
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

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        willRestoreState(central, dict: dict)
    }
}
//    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
//        willRestoreState(central, dict: dict)
//    }
//    func didDiscoverCharacteristics(_ peripheral: CBPeripheralProtocol, service: CBService, error: Error?) {
//        guard let characteristics = service.characteristics else {
//            logger.error("No characteristics found")
//            return
//        }
//
//        for characteristic in characteristics {
//            self.connectedPeripheral = peripheral
//            if characteristic.properties.contains(.write) && characteristic.properties.contains(.read) {
//                let message = "ATZ\r"
//                let data = message.data(using: .ascii)!
//                peripheral.writeValue(data, for: characteristic, type: .withResponse)
//                peripheral.readValue(for: characteristic)
//                let response = characteristic.value
//                if let response = response {
//                    ecuCharacteristic = characteristic
//                    let responseString = String(data: response, encoding: .utf8)
//                    logger.info("response: \(responseString ?? "No Response")")
//                }
//            }
//            switch characteristic.uuid.uuidString {
//            case userDevice?.characteristicUUID:
//                logger.info("ecu \(characteristic)")
//                ecuCharacteristic = characteristic
//                peripheral.setNotifyValue(true, for: characteristic)
////                connectionCompletion?(peripheral)
//                logger.info("Adapter Ready")
//            default:
//                if debug {
//                    logger.info("Unhandled Characteristic UUID: \(characteristic)")
//                }
//                if characteristic.properties.contains(.notify) {
//                    peripheral.setNotifyValue(true, for: characteristic)
//                }
//            }
//        }
//    }
//        [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.RestoreIdentifierKey]

//    func willRestoreState(_ central: CBCentralManagerProtocol, dict: [String : Any]) {
//        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
//            logger.debug("Restoring \(peripherals.count) peripherals")
//            for peripheral in peripherals {
//                logger.debug("Restoring peripheral: \(peripheral.name ?? "Unnamed")")
//                peripheral.delegate = self
//                connectedPeripheral = peripheral
//                connectionState = .connectedToAdapter
//            }
//        }
//    }
