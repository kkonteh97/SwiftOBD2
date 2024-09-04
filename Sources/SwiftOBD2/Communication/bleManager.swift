// MARK: - BLEManager Class Documentation

/// The BLEManager class is a wrapper around the CoreBluetooth framework. It is responsible for managing the connection to the OBD2 adapter,
/// scanning for peripherals, and handling the communication with the adapter.
///
/// **Key Responsibilities:**
/// - Scanning for peripherals
/// - Connecting to peripherals
/// - Managing the connection state
/// - Handling the communication with the adapter
/// - Processing the characteristics of the adapter
/// - Sending messages to the adapter
/// - Receiving messages from the adapter
/// - Parsing the received messages
/// - Handling errors

import Combine
import CoreBluetooth
import Foundation
import OSLog

public enum ConnectionState {
    case disconnected
    case connectedToAdapter
    case connectedToVehicle
}

class BLEManager: NSObject, CommProtocol {
    private let peripheralSubject = PassthroughSubject<CBPeripheral, Never>()

    var peripheralPublisher: AnyPublisher<CBPeripheral, Never> {
      return peripheralSubject.eraseToAnyPublisher()
    }

    static let services = [
        CBUUID(string: "FFE0"),
        CBUUID(string: "FFF0"),
        CBUUID(string: "18F0"), //e.g. VGate iCar Pro
    ]

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "BLEManager")

    static let RestoreIdentifierKey: String = "OBD2Adapter"

    // MARK: Properties

    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectedPeripheral: CBPeripheral?

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    private var centralManager: CBCentralManager!
    private var ecuReadCharacteristic: CBCharacteristic?
    private var ecuWriteCharacteristic: CBCharacteristic?

    private var buffer = Data()

    private var sendMessageCompletion: (([String]?, Error?) -> Void)?
    private var foundPeripheralCompletion: ((CBPeripheral?, Error?) -> Void)?
    private var connectionCompletion: ((CBPeripheral?, Error?) -> Void)?

    public weak var obdDelegate: OBDServiceDelegate?

    // MARK: - Initialization

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true,
                                                                                  CBCentralManagerOptionRestoreIdentifierKey: BLEManager.RestoreIdentifierKey])
    }

    // MARK: - Central Manager Control Methods

    func startScanning(_ serviceUUIDs: [CBUUID]?) {
        let scanOption = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        centralManager?.scanForPeripherals(withServices: serviceUUIDs, options: scanOption)
    }

    func stopScan() {
        centralManager?.stopScan()
    }

    func disconnectPeripheral() {
        guard let connectedPeripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(connectedPeripheral)
    }

    // MARK: - Central Manager Delegate Methods

    func didUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            #if DEBUG
                logger.debug("Bluetooth is On.")
            #endif
            guard let device = connectedPeripheral else {
                startScanning(Self.services)
                return
            }

            connect(to: device)
        case .poweredOff:
            logger.warning("Bluetooth is currently powered off.")
            connectedPeripheral = nil
            connectionState = .disconnected
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

    func didDiscover(_: CBCentralManager, peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
//        connect(to: peripheral)
        appendFoundPeripheral(peripheral: peripheral, advertisementData: advertisementData, rssi: rssi)
        if foundPeripheralCompletion != nil {
            foundPeripheralCompletion?(peripheral, nil)
        }
    }

    @Published var foundPeripherals: [CBPeripheral] = []

     func appendFoundPeripheral(peripheral: CBPeripheral, advertisementData: [String : Any], rssi: NSNumber) {
        if rssi.intValue >= 0 { return }
        if let index = foundPeripherals.firstIndex(where: { $0.identifier.uuidString == peripheral.identifier.uuidString }) {
            foundPeripherals[index] = peripheral
        } else {
            peripheralSubject.send(peripheral)
            foundPeripherals.append(peripheral)
        }
     }

    func connect(to peripheral: CBPeripheral) {
        logger.info("Connecting to: \(peripheral.name ?? "")")
        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        if centralManager.isScanning {
            centralManager.stopScan()
        }
    }

    func didConnect(_: CBCentralManager, peripheral: CBPeripheral) {
        logger.info("Connected to peripheral: \(peripheral.name ?? "Unnamed")")
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self
        connectedPeripheral?.discoverServices(Self.services)
        connectionState = .connectedToAdapter
        obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
    }

    func scanForPeripheralAsync(_ timeout: TimeInterval) async throws -> CBPeripheral? {
        // returns a single peripheral with the specified services
        return try await Timeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheral, Error>) in
                self.foundPeripheralCompletion = { peripheral, error in
                    if let peripheral = peripheral {
                        continuation.resume(returning: peripheral)
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    }
                    self.foundPeripheralCompletion = nil
                }
                self.startScanning(Self.services)
            }
        }
    }

    // MARK: - Peripheral Delegate Methods

    func didDiscoverServices(_ peripheral: CBPeripheral, error _: Error?) {
        for service in peripheral.services ?? [] {
            logger.info("Discovered service: \(service.uuid.uuidString)")
            switch service {
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
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error _: Error?) {
        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            return
        }

        for characteristic in characteristics {
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            switch characteristic.uuid.uuidString {
            case "FFE1": // for servcice FFE0
                ecuWriteCharacteristic = characteristic
                ecuReadCharacteristic = characteristic
            case "FFF1": // for servcice FFF0
                ecuReadCharacteristic = characteristic
            case "FFF2": // for servcice FFF0
                ecuWriteCharacteristic = characteristic
            case "2AF0": // for servcice 18F0
                ecuReadCharacteristic = characteristic
            case "2AF1": // for servcice 18F0
                ecuWriteCharacteristic = characteristic
            default:
                break
            }
        }

        if connectionCompletion != nil && ecuWriteCharacteristic != nil && ecuReadCharacteristic != nil {
            connectionCompletion?(peripheral, nil)
        }
    }

    func didUpdateValue(_: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
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
                if let responseString = String(data: characteristicValue, encoding: .utf8) {
                    logger.info("Unknown characteristic: \(characteristic)\nResponse: \(responseString)")
                }
        }
    }

    func didFailToConnect(_: CBCentralManager, peripheral: CBPeripheral, error _: Error?) {
        logger.error("Failed to connect to peripheral: \(peripheral.name ?? "Unnamed")")
        resetConfigure()
    }

    func didDisconnect(_: CBCentralManager, peripheral: CBPeripheral, error _: Error?) {
        logger.info("Disconnected from peripheral: \(peripheral.name ?? "Unnamed")")
        resetConfigure()
    }

    func willRestoreState(_: CBCentralManager, dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let peripheral = peripherals.first {
            logger.debug("Restoring peripheral: \(peripherals[0].name ?? "Unnamed")")
            connectedPeripheral = peripheral
            connectedPeripheral?.delegate = self
        }
    }

    func connectionEventDidOccur(_: CBCentralManager, event: CBConnectionEvent, peripheral _: CBPeripheral) {
        logger.error("Connection event occurred: \(event.rawValue)")
    }

    // MARK: - Async Methods

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        if connectionState != .disconnected {
            return
        }
        guard let peripheral = try await scanForPeripheralAsync(timeout) else {
            throw BLEManagerError.peripheralNotFound
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectionCompletion = { peripheral, error in
                if peripheral != nil {
                    continuation.resume()
                } else if let error = error {
                    continuation.resume(throwing: error)
                }

                self.connectionCompletion = nil
            }
            connect(to: peripheral)
        }
        self.connectionCompletion = nil
    }

    /// Sends a message to the connected peripheral and returns the response.
    /// - Parameter message: The message to send.
    /// - Returns: The response from the peripheral.
    /// - Throws:
    ///     `BLEManagerError.sendingMessagesInProgress` if a message is already being sent.
    ///     `BLEManagerError.missingPeripheralOrCharacteristic` if the peripheral or ecu characteristic is missing.
    ///     `BLEManagerError.incorrectDataConversion` if the data cannot be converted to ASCII.
    ///     `BLEManagerError.peripheralNotConnected` if the peripheral is not connected.
    ///     `BLEManagerError.timeout` if the operation times out.
    ///     `BLEManagerError.unknownError` if an unknown error occurs.
    func sendCommand(_ command: String, retries: Int = 3) async throws -> [String] {
        guard sendMessageCompletion == nil else {
            throw BLEManagerError.sendingMessagesInProgress
        }

        logger.info("Sending command: \(command)")

        guard let connectedPeripheral = connectedPeripheral,
              let characteristic = ecuWriteCharacteristic,
              let data = "\(command)\r".data(using: .ascii)
        else {
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
                    self.sendMessageCompletion = nil
                }
                connectedPeripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        }
    }

    /// Processes the received data from the peripheral.
    /// - Parameters:
    ///  - data: The data received from the peripheral.
    ///  - completion: The completion handler to call when the data has been processed.
    func processReceivedData(_ data: Data, completion _: (([String]?, Error?) -> Void)?) {
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
            #if DEBUG
                logger.debug("Response: \(lines)")
            #endif

            if sendMessageCompletion != nil {
                if lines[0].uppercased().contains("NO DATA") {
                    sendMessageCompletion?(nil, BLEManagerError.noData)
                } else {
                    sendMessageCompletion?(lines, nil)
                }
            }
            buffer.removeAll()
        }
    }

    func scanForPeripherals() async throws {
        startScanning(nil)
        try await Task.sleep(nanoseconds: 10_000_000_000)
        stopScan()
    }

    // MARK: - Utility Methods

    /// Cancels the current operation and throws a timeout error.
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

    private func resetConfigure() {
        ecuReadCharacteristic = nil
        ecuWriteCharacteristic = nil
        connectedPeripheral = nil
        connectionState = .disconnected
    }
}

// MARK: - CBCentralManagerDelegate, CBPeripheralDelegate

/// Extension to conform to CBCentralManagerDelegate and CBPeripheralDelegate
/// and handle the delegate methods.
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

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        willRestoreState(central, dict: dict)
    }
}

enum BLEManagerError: Error, CustomStringConvertible {
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
    case peripheralNotFound

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
        case .peripheralNotFound:
            return "Error: Peripheral not found"
        }
    }
}
