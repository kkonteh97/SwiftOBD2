import Combine
import CoreBluetooth
import Foundation

protocol BLEPeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: BLEPeripheralManager, didSetupCharacteristics peripheral: CBPeripheral)
}

/// Owns the connected peripheral and walks through its services until the serial characteristics are found.
class BLEPeripheralManager: NSObject, ObservableObject {
    @Published var connectedPeripheral: CBPeripheral?
    private let characteristicHandler: BLECharacteristicHandler

    weak var delegate: BLEPeripheralManagerDelegate?

    private let lock = NSLock()
    private var setupCompletion: ((Result<Void, Error>) -> Void)?

    init(characteristicHandler: BLECharacteristicHandler) {
        self.characteristicHandler = characteristicHandler
        super.init()
    }

    func setPeripheral(_ peripheral: CBPeripheral?) {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self

        if let peripheral = peripheral {
            // Ask for every service: adapters that do not use one of the usual serial services are
            // handled by looking at the properties of their characteristics.
            peripheral.discoverServices(nil)
        }
    }

    /// Runs `start` (which initiates the connection) and waits until the characteristics are ready.
    func waitForCharacteristicsSetup(timeout: TimeInterval, start: @escaping () -> Void) async throws {
        try await withTimeout(seconds: timeout, timeoutError: BLEManagerError.timeout, onTimeout: { [weak self] in
            self?.finishSetup(.failure(BLEManagerError.timeout))
        }, operation: { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Registered before the connection starts so that a fast peripheral cannot be missed.
                lock.sync {
                    setupCompletion = { continuation.resume(with: $0) }
                }
                start()
            }
        })
    }

    /// Ends the pending ``waitForCharacteristicsSetup(timeout:start:)``, if any.
    func finishSetup(_ result: Result<Void, Error>) {
        let completion: ((Result<Void, Error>) -> Void)? = lock.sync {
            defer { setupCompletion = nil }
            return setupCompletion
        }
        completion?(result)
    }

    func didDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            obdError("Error discovering services: \(error.localizedDescription)", category: .bluetooth)
            finishSetup(.failure(error))
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            finishSetup(.failure(BLEManagerError.unknownCharacteristic))
            return
        }
        for service in services {
            obdDebug("Discovered service: \(service.uuid.uuidString)", category: .bluetooth)
            characteristicHandler.discoverCharacteristics(for: service, on: peripheral)
        }
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        if let error = error {
            // Another service may still provide what we need: let the time-out decide.
            obdWarning("Error discovering characteristics of \(service.uuid.uuidString): \(error.localizedDescription)", category: .bluetooth)
            return
        }

        guard let characteristics = service.characteristics else { return }
        let wasReady = characteristicHandler.isReady

        characteristicHandler.setupCharacteristics(characteristics, on: peripheral)

        // Check if all required characteristics are set up
        if characteristicHandler.isReady, !wasReady {
            // Notify delegate
            delegate?.peripheralManager(self, didSetupCharacteristics: peripheral)
            finishSetup(.success(()))
        }
    }

    func didUpdateValue(_: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            obdError("Error reading characteristic value: \(error.localizedDescription)", category: .bluetooth)
            return
        }

        guard let data = characteristic.value else { return }
        characteristicHandler.handleUpdatedValue(data, from: characteristic)
    }
}

extension BLEPeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        didDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        didDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateValue(peripheral, characteristic: characteristic, error: error)
    }
}
