import CoreBluetooth
import Foundation

// MARK: - Shared transport protocol

/// Implemented by every OBD transport backend (BLE, WiFi TCP, USB serial).
protocol CommProtocol {
    func sendCommand(_ command: String, retries: Int) async throws -> [String]
    func sendMonitorCommand(_ command: String, duration: TimeInterval) async throws -> [String]
    func disconnectPeripheral()
    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?) async throws
    func scanForPeripherals() async throws
    func reset()
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
    var obdDelegate: OBDServiceDelegate? { get set }
    /// Looks up a previously connected peripheral by system identifier for a
    /// no-scan pending connect. Only meaningful for BLE transports.
    func retrievePeripheral(withIdentifier identifier: UUID) async -> CBPeripheral?
}

extension CommProtocol {
    // Non-BLE transports (WiFi, serial, mock) have no peripheral registry.
    func retrievePeripheral(withIdentifier identifier: UUID) async -> CBPeripheral? { nil }
}

// MARK: - Transport-layer errors

enum CommunicationError: Error, LocalizedError {
    case invalidData
    case errorOccurred(Error)
    /// The connect attempt exceeded the caller's timeout without reaching `.ready`.
    case timeout
    /// The connection was cancelled (e.g. user disconnect or app-side timeout) before it was established.
    case cancelled
    /// The TCP connection reached EOF mid-response — the peer closed the socket before
    /// sending the ELM327 '>' prompt, so whatever bytes arrived are a truncated fragment,
    /// not a complete reply.
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .invalidData: return "Invalid data received from the adapter."
        case .errorOccurred(let underlying): return underlying.localizedDescription
        case .timeout: return "The connection attempt timed out."
        case .cancelled: return "The connection attempt was cancelled."
        case .connectionClosed: return "The connection closed before the adapter finished responding."
        }
    }
}
