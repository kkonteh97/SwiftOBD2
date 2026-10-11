import Combine
import CoreBluetooth
import Foundation

/// Protocol for BLE scanning operations
protocol BLEScannerProtocol {
    var foundPeripherals: [CBPeripheral] { get }
    var peripheralPublisher: AnyPublisher<CBPeripheral, Never> { get }

    func startScanning(services: [CBUUID]?) async throws
    func stopScanning()
    func scanForPeripheralAsync(services: [CBUUID]?, timeout: TimeInterval) async throws -> CBPeripheral?
}

/// Focused component responsible for BLE device discovery and peripheral management
class BLEPeripheralScanner: ObservableObject {
    @Published var foundPeripherals: [CBPeripheral] = []

    private let peripheralSubject = PassthroughSubject<CBPeripheral, Never>()


    var peripheralPublisher: AnyPublisher<CBPeripheral, Never> {
        peripheralSubject.eraseToAnyPublisher()
    }

    static let supportedServices = [
        CBUUID(string: "FFE0"),
        CBUUID(string: "FFF0"),
        CBUUID(string: "18F0"), // e.g. VGate iCar Pro
    ]

    // Resumed from the CB queue (discovery), reset() on an arbitrary thread
    // (disconnect), or the cancellation handler — take-once so those racing
    // paths can never double-resume the waiting continuation.
    private let foundPeripheralCompletion = TakeOnceCompletion<CBPeripheral>()

    func addDiscoveredPeripheral(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        // Filter out peripherals with invalid RSSI
        guard rssi.intValue < 0 else { return }

        if let index = foundPeripherals.firstIndex(where: { $0.identifier == peripheral.identifier }) {
            foundPeripherals[index] = peripheral
        } else {
            foundPeripherals.append(peripheral)
            peripheralSubject.send(peripheral)
            obdInfo("Found new peripheral: \(peripheral.name ?? "Unnamed") - RSSI: \(rssi)", category: .bluetooth)
        }

        // Complete waiting continuation if exists
        foundPeripheralCompletion.take()?(peripheral, nil)
    }

    func waitForFirstPeripheral(timeout: TimeInterval) async throws -> CBPeripheral {
        // If we already have peripherals, return the first one
        if let first = foundPeripherals.first {
            return first
        }

        // Otherwise wait for discovery
        return try await withTimeout(seconds: timeout, timeoutError: BLEScannerError.scanTimeout) { [self] in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheral, Error>) in
                    let claimed = foundPeripheralCompletion.set { peripheral, error in
                        if let peripheral = peripheral {
                            continuation.resume(returning: peripheral)
                        } else if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(throwing: BLEScannerError.peripheralNotFound)
                        }
                    }
                    if !claimed {
                        continuation.resume(throwing: BLEScannerError.peripheralNotFound)
                    } else if let first = foundPeripherals.first {
                        // A discovery that landed between the early-return check
                        // and set() found no waiter to resume — claim our own
                        // slot rather than hanging until the timeout.
                        foundPeripheralCompletion.take()?(first, nil)
                    }
                }
            } onCancel: { [self] in
                foundPeripheralCompletion.take()?(nil, CancellationError())
            }
        }
    }

    func reset() {
        foundPeripherals.removeAll()
        foundPeripheralCompletion.take()?(nil, BLEScannerError.scanTimeout)
    }
}
// MARK: - CBPeripheralDelegate

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

/// Cancels the current operation and throws a timeout error.
func withTimeout<R>(
    seconds: TimeInterval,
    timeoutError: Error = BLEManagerError.timeout,
    onTimeout: (() -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> R
) async throws -> R {
    // .infinity = no deadline (pending-connect mode): run the operation bare —
    // the nanosecond conversion below would trap on a non-finite value, and a
    // timeout child that never fires is pointless.
    guard seconds.isFinite else {
        return try await operation()
    }
    return try await withThrowingTaskGroup(of: R.self) { group in
        group.addTask {
            let result = try await operation()
            try Task.checkCancellation()
            return result
        }

        group.addTask {
            if seconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            try Task.checkCancellation()

            // Call cleanup handler if provided
            onTimeout?()
            throw timeoutError
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
