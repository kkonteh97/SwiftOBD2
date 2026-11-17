import Combine
import CoreBluetooth
import Foundation

/// Focused component responsible for BLE device discovery and peripheral management
class BLEPeripheralScanner: ObservableObject {
    private let lock = NSLock()
    private var peripherals: [CBPeripheral] = []
    private var foundPeripheralCompletion: ((Result<CBPeripheral, Error>) -> Void)?

    private let peripheralSubject = PassthroughSubject<CBPeripheral, Never>()

    /// The peripherals discovered so far, in order of discovery.
    var foundPeripherals: [CBPeripheral] {
        lock.sync { peripherals }
    }

    var peripheralPublisher: AnyPublisher<CBPeripheral, Never> {
        peripheralSubject.eraseToAnyPublisher()
    }

    /// The services ELM327 adapters expose their serial port on.
    static let supportedServices = [
        CBUUID(string: "FFE0"),
        CBUUID(string: "FFF0"),
        CBUUID(string: "18F0"), // e.g. VGate iCar Pro
    ]

    func addDiscoveredPeripheral(_ peripheral: CBPeripheral, advertisementData _: [String: Any], rssi: NSNumber) {
        // Filter out peripherals with invalid RSSI
        guard rssi.intValue < 0 else { return }

        let (isNew, completion): (Bool, ((Result<CBPeripheral, Error>) -> Void)?) = lock.sync {
            let isNew: Bool
            if let index = peripherals.firstIndex(where: { $0.identifier == peripheral.identifier }) {
                peripherals[index] = peripheral
                isNew = false
            } else {
                peripherals.append(peripheral)
                isNew = true
            }
            defer { foundPeripheralCompletion = nil }
            return (isNew, foundPeripheralCompletion)
        }

        if isNew {
            peripheralSubject.send(peripheral)
            obdInfo("Found new peripheral: \(peripheral.name ?? "Unnamed") - RSSI: \(rssi)", category: .bluetooth)
        }

        // Complete waiting continuation if exists
        completion?(.success(peripheral))
    }

    func waitForFirstPeripheral(timeout: TimeInterval) async throws -> CBPeripheral {
        try await withTimeout(seconds: timeout, timeoutError: BLEScannerError.scanTimeout, onTimeout: { [weak self] in
            self?.finishWaiting(.failure(BLEScannerError.scanTimeout))
        }, operation: { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheral, Error>) in
                // If we already have peripherals, return the first one
                let known: CBPeripheral? = lock.sync {
                    if let first = peripherals.first { return first }
                    foundPeripheralCompletion = { continuation.resume(with: $0) }
                    return nil
                }
                if let known = known {
                    continuation.resume(returning: known)
                }
            }
        })
    }

    private func finishWaiting(_ result: Result<CBPeripheral, Error>) {
        let completion: ((Result<CBPeripheral, Error>) -> Void)? = lock.sync {
            defer { foundPeripheralCompletion = nil }
            return foundPeripheralCompletion
        }
        completion?(result)
    }
}

// MARK: - Error Types

enum BLEScannerError: Error, LocalizedError {
    case centralManagerNotAvailable
    case bluetoothNotPoweredOn
    case scanTimeout
    case peripheralNotFound

    var errorDescription: String? {
        switch self {
        case .centralManagerNotAvailable:
            return "Bluetooth Central Manager is not available"
        case .bluetoothNotPoweredOn:
            return "Bluetooth is not powered on"
        case .scanTimeout:
            return "BLE scanning timed out"
        case .peripheralNotFound:
            return "No compatible BLE peripheral found"
        }
    }
}
