import Combine
import CoreBluetooth
import Foundation
import OSLog

/// Protocol for BLE connection operations
protocol BLEConnectionProtocol {
    var connectionState: ConnectionState { get }
    var connectedPeripheral: CBPeripheral? { get }
    var connectedPeripheralPublisher: AnyPublisher<CBPeripheral?, Never> { get }
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { get }

    func connect(to peripheral: CBPeripheral, timeout: TimeInterval) async throws
    func disconnect()
    func isReady() -> Bool
}

/// Focused component responsible for BLE connection management and service discovery
class BLEConnection: NSObject, BLEConnectionProtocol {
    // MARK: - Properties

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.swiftobd2.app", category: "BLEConnection")

    private weak var centralManager: CBCentralManager?
    private let supportedServices: [CBUUID]

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var connectedPeripheral: CBPeripheral?

    // Characteristics for OBD communication
    var ecuReadCharacteristic: CBCharacteristic?
    var ecuWriteCharacteristic: CBCharacteristic?

    // Connection management
    private var connectionCompletion: ((CBPeripheral?, Error?) -> Void)?
    private var connectionTimeout: Task<Void, Never>?

    // MARK: - Publishers

    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    var connectedPeripheralPublisher: AnyPublisher<CBPeripheral?, Never> {
        $connectedPeripheral.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    init(centralManager: CBCentralManager, supportedServices: [CBUUID] = BLEConnection.defaultServices) {
        self.centralManager = centralManager
        self.supportedServices = supportedServices
        super.init()
        logger.debug("BLEConnection initialized with services: \(supportedServices.map(\.uuidString))")
    }

    static let defaultServices = [
        CBUUID(string: "FFE0"),
        CBUUID(string: "FFF0"),
        CBUUID(string: "18F0"), // e.g. VGate iCar Pro
    ]

    // MARK: - Connection Management

    func connect(to peripheral: CBPeripheral, timeout: TimeInterval = 10.0) async throws {
        guard let centralManager = centralManager else {
            throw BLEConnectionError.centralManagerNotAvailable
        }

        guard centralManager.state == .poweredOn else {
            throw BLEConnectionError.bluetoothNotPoweredOn
        }

        guard connectionState == .disconnected else {
            throw BLEConnectionError.alreadyConnected
        }

        logger.info("Attempting to connect to peripheral: \(peripheral.name ?? peripheral.identifier.uuidString) with timeout: \(timeout)s")

        return try await withTimeout(
            seconds: timeout,
            timeoutError: BLEConnectionError.connectionTimeout,
            onTimeout: { [weak self] in
                // Clean up on timeout - but don't call connectionCompletion as it will try to resume an already-handled continuation
                if let completion = self?.connectionCompletion {
                    completion(nil, BLEConnectionError.connectionTimeout)
                }
                self?.logger.error("Connection timed out after \(timeout) seconds")
                centralManager.cancelPeripheralConnection(peripheral)
                self?.resetConnectionState()
                // Clear the completion handler to prevent double-resuming
                self?.connectionCompletion = nil
            },
            operation: {
                // Main connection task
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    var hasResumed = false

                    self.connectionCompletion = { [weak self] connectedPeripheral, error in
                        // Ensure we only resume once
                        guard !hasResumed else {
                            self?.logger.debug("Connection completion called but continuation already resumed")
                            return
                        }
                        hasResumed = true

                        if let connectedPeripheral = connectedPeripheral {
                            self?.logger.info("Successfully connected and configured: \(connectedPeripheral.name ?? connectedPeripheral.identifier.uuidString)")
                            continuation.resume(returning: ())
                        } else if let error = error {
                            self?.logger.error("Connection failed: \(error.localizedDescription)")
                            self?.resetConnectionState()
                            continuation.resume(throwing: error)
                        } else {
                            self?.logger.error("Connection failed with unknown error")
                            self?.resetConnectionState()
                            continuation.resume(throwing: BLEConnectionError.connectionFailed)
                        }
                        self?.connectionCompletion = nil
                    }

                    // Start connection
                    peripheral.delegate = self
                    centralManager.connect(peripheral, options: [
                        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
                    ])

                    // Stop scanning to avoid interference
                    if centralManager.isScanning {
                        centralManager.stopScan()
                        self.logger.debug("Stopped scanning to focus on connection")
                    }
                }
            }
        )
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else {
            logger.debug("No peripheral connected to disconnect")
            return
        }

        logger.info("Disconnecting from peripheral: \(peripheral.name ?? peripheral.identifier.uuidString)")
        centralManager?.cancelPeripheralConnection(peripheral)
    }

    func isReady() -> Bool {
        let hasConnection = connectionState == .connectedToAdapter
        let hasReadChar = ecuReadCharacteristic != nil
        let hasWriteChar = ecuWriteCharacteristic != nil

        // Accept if we have at least one characteristic, or if read/write are the same (like FFE1)
        let hasCharacteristics = hasReadChar && (hasWriteChar || ecuReadCharacteristic == ecuWriteCharacteristic)

        logger.debug("isReady check - Connection: \(hasConnection), Read: \(hasReadChar), Write: \(hasWriteChar), Same: \(self.ecuReadCharacteristic == self.ecuWriteCharacteristic)")

        return hasConnection && hasCharacteristics
    }

    // MARK: - Internal Connection Handling

    func handleDidConnect(_ peripheral: CBPeripheral) {
        logger.info("Connected to peripheral: \(peripheral.name ?? "Unnamed")")
        connectedPeripheral = peripheral
        connectionState = .connectedToAdapter

        // Start service discovery with timeout
        peripheral.discoverServices(supportedServices)

//        // Set up a timeout for service discovery
//        connectionTimeout = Task { [weak self] in
//            try? await Task.sleep(nanoseconds: UInt64(5.0 * 1_000_000_000)) // 5 second timeout for service discovery
//            await MainActor.run {
//                if self?.connectionCompletion != nil {
//                    self?.logger.warning("Service discovery timed out, but connection may still be usable")
//                    // Complete connection even if not all characteristics found
//                    self?.connectionCompletion?(peripheral, nil)
//                }
//            }
//        }

        // Save last connected peripheral
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastConnectedPeripheral")
    }

    func handleDidDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            logger.warning("Disconnected from peripheral with error: \(error.localizedDescription)")
        } else {
            logger.info("Disconnected from peripheral: \(peripheral.name ?? "Unnamed")")
        }

        resetConnectionState()
    }

    func handleDidFailToConnect(_: CBPeripheral, error: Error?) {
        let errorMessage = error?.localizedDescription ?? "Unknown error"
        logger.error("Failed to connect to peripheral: \(errorMessage)")

        // Only call completion if it hasn't been cleared by timeout
        if let completion = connectionCompletion {
            completion(nil, error ?? BLEConnectionError.connectionFailed)
        } else {
            logger.debug("Connection failure handled but completion was already cleared (likely by timeout)")
        }
    }

    // MARK: - Service and Characteristic Discovery

    func handleDidDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            logger.error("Service discovery failed: \(error.localizedDescription)")
            connectionTimeout?.cancel()
            // Only call completion if it hasn't been cleared by timeout
            if let completion = connectionCompletion {
                completion(nil, error)
            } else {
                logger.debug("Service discovery failure handled but completion was already cleared (likely by timeout)")
            }
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            logger.error("No services found on peripheral")
            connectionTimeout?.cancel()
            // Only call completion if it hasn't been cleared by timeout
            if let completion = connectionCompletion {
                completion(nil, BLEConnectionError.noServicesFound)
            } else {
                logger.debug("No services found but completion was already cleared (likely by timeout)")
            }
            return
        }

        logger.info("Discovered \(services.count) services")
        var compatibleServices = 0

        for service in services {
            logger.info("Discovered service: \(service.uuid.uuidString)")
            if supportedServices.contains(service.uuid) {
                compatibleServices += 1
                discoverCharacteristicsForService(service, on: peripheral)
            } else {
                logger.debug("Service \(service.uuid.uuidString) not in supported list, skipping")
            }
        }

        if compatibleServices == 0 {
            logger.warning("No compatible services found, but continuing anyway")
            // Still try to discover characteristics for all services as fallback
            for service in services {
                discoverCharacteristicsForService(service, on: peripheral)
            }
        }
    }

    func handleDidDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        if let error = error {
            logger.error("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            logger.warning("No characteristics found for service: \(service.uuid.uuidString)")
            return
        }

        for characteristic in characteristics {
            configureCharacteristic(characteristic, on: peripheral)
        }

        // Check if we have required characteristics (more flexible approach)
        let hasReadCharacteristic = ecuReadCharacteristic != nil
        let hasWriteCharacteristic = ecuWriteCharacteristic != nil

        // For some adapters, the same characteristic handles both read/write (like FFE1)
        if hasReadCharacteristic && (hasWriteCharacteristic || ecuReadCharacteristic == ecuWriteCharacteristic) {
            logger.info("Required characteristics discovered and configured")
            connectionTimeout?.cancel() // Cancel timeout since we succeeded
            connectionTimeout = nil
            // Only call completion if it hasn't been cleared by timeout
            if let completion = connectionCompletion {
                completion(peripheral, nil)
            } else {
                logger.debug("Characteristics discovered but completion was already cleared (likely by timeout)")
            }
        } else {
            logger.debug("Still waiting for characteristics - Read: \(hasReadCharacteristic), Write: \(hasWriteCharacteristic)")
        }
    }

    // MARK: - Private Helper Methods

    private func discoverCharacteristicsForService(_ service: CBService, on peripheral: CBPeripheral) {
        let characteristicUUIDs: [CBUUID]

        switch service.uuid {
        case CBUUID(string: "FFE0"):
            characteristicUUIDs = [CBUUID(string: "FFE1")]
        case CBUUID(string: "FFF0"):
            characteristicUUIDs = [CBUUID(string: "FFF1"), CBUUID(string: "FFF2")]
        case CBUUID(string: "18F0"):
            characteristicUUIDs = [CBUUID(string: "2AF0"), CBUUID(string: "2AF1")]
        default:
            characteristicUUIDs = []
        }

        peripheral.discoverCharacteristics(characteristicUUIDs.isEmpty ? nil : characteristicUUIDs, for: service)
    }

    private func configureCharacteristic(_ characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        let uuid = characteristic.uuid.uuidString.uppercased()
        let properties = characteristic.properties

        logger.debug("Configuring characteristic \(uuid) with properties: \(String(describing: properties))")

        // Enable notifications if supported
        if properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
            logger.debug("Enabled notifications for characteristic: \(uuid)")
        }

        // Assign characteristics based on UUID and properties
        switch uuid {
        case "FFE1": // For service FFE0 - typically both read/write
            ecuWriteCharacteristic = characteristic
            ecuReadCharacteristic = characteristic
            logger.info("Configured FFE1 as both read and write characteristic")

        case "FFF1": // For service FFF0 - typically read
            if properties.contains(.read) || properties.contains(.notify) {
                ecuReadCharacteristic = characteristic
                logger.info("Configured FFF1 as read characteristic")
            }

        case "FFF2": // For service FFF0 - typically write
            if properties.contains(.write) || properties.contains(.writeWithoutResponse) {
                ecuWriteCharacteristic = characteristic
                logger.info("Configured FFF2 as write characteristic")
            }

        case "2AF0": // For service 18F0 - typically read
            ecuReadCharacteristic = characteristic
            logger.info("Configured 2AF0 as read characteristic")

        case "2AF1": // For service 18F0 - typically write
            ecuWriteCharacteristic = characteristic
            logger.info("Configured 2AF1 as write characteristic")

        default:
            logger.debug("Unknown characteristic \(uuid), attempting auto-assignment based on properties")

            // Fallback: auto-assign based on properties if we don't have characteristics yet
            if ecuReadCharacteristic == nil && (properties.contains(.read) || properties.contains(.notify)) {
                ecuReadCharacteristic = characteristic
                logger.info("Auto-assigned \(uuid) as read characteristic based on properties")
            }

            if ecuWriteCharacteristic == nil && (properties.contains(.write) || properties.contains(.writeWithoutResponse)) {
                ecuWriteCharacteristic = characteristic
                logger.info("Auto-assigned \(uuid) as write characteristic based on properties")
            }

            // If it supports both, assign as both (like FFE1)
            if properties.contains(.read) && properties.contains(.write) && ecuReadCharacteristic == nil && ecuWriteCharacteristic == nil {
                ecuReadCharacteristic = characteristic
                ecuWriteCharacteristic = characteristic
                logger.info("Auto-assigned \(uuid) as both read and write characteristic")
            }
        }
    }

    private func resetConnectionState() {
        ecuReadCharacteristic = nil
        ecuWriteCharacteristic = nil
        connectedPeripheral = nil
        connectionState = .disconnected
        connectionCompletion = nil
        connectionTimeout?.cancel()
        connectionTimeout = nil
    }

    // MARK: - Cleanup

    deinit {
        disconnect()
        connectionTimeout?.cancel()
        logger.debug("BLEConnection deinitialized")
    }
}

// MARK: - CBPeripheralDelegate

extension BLEConnection: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        handleDidDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        handleDidDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Forward data updates to the central manager's delegate (BLEManager)
        if let centralManager = centralManager, let delegate = centralManager.delegate as? CBPeripheralDelegate {
            delegate.peripheral?(peripheral, didUpdateValueFor: characteristic, error: error)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Forward write confirmations to the central manager's delegate (BLEManager)
        if let centralManager = centralManager, let delegate = centralManager.delegate as? CBPeripheralDelegate {
            delegate.peripheral?(peripheral, didWriteValueFor: characteristic, error: error)
        }
    }
}

// MARK: - Error Types

enum BLEConnectionError: Error, LocalizedError, Equatable {
    case centralManagerNotAvailable
    case bluetoothNotPoweredOn
    case alreadyConnected
    case connectionFailed
    case connectionTimeout
    case noServicesFound
    case requiredCharacteristicsNotFound

    var errorDescription: String? {
        switch self {
        case .centralManagerNotAvailable:
            return "Bluetooth Central Manager is not available"
        case .bluetoothNotPoweredOn:
            return "Bluetooth is not powered on"
        case .alreadyConnected:
            return "Already connected to a peripheral"
        case .connectionFailed:
            return "Failed to connect to BLE peripheral"
        case .connectionTimeout:
            return "Connection attempt timed out"
        case .noServicesFound:
            return "No compatible services found on peripheral"
        case .requiredCharacteristicsNotFound:
            return "Required characteristics not found on peripheral"
        }
    }
}
