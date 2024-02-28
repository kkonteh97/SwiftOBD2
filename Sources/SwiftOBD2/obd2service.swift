// MARK: - OBDService Documentation
/// A class that provides an interface to the ELM327 OBD2 adapter and the vehicle.
///
/// **Key Responsibilities:**
/// - Establishing a connection to the adapter and the vehicle.
/// - Sending and receiving OBD2 commands.
/// - Providing information about the vehicle.
/// - Managing the connection state.

import Foundation
import Combine

public enum connectionType {
    case bluetooth
    case wifi
}

public class OBDService: ObservableObject {
    @Published var connectedPeripheral: CBPeripheralProtocol? = nil
    var elm327: ELM327

    public var connectionState: ConnectionState {
        return elm327.connectionState
    }

    public init(connectionType: connectionType = .bluetooth) {
        switch connectionType {
        case .bluetooth:
            self.elm327 = ELM327(comm: BLEManager())
        case .wifi:
            self.elm327 = ELM327(comm: WifiManager())
        }
    }
    // MARK: - Connection Handling

     public func startConnection(_ preferedProtocol: PROTOCOL?) async throws -> (OBDProtocol: PROTOCOL, VIN: String?) {
        try await initializeAdapter()
        return try await initializeVehicle(preferedProtocol)
    }

    public func initializeAdapter(timeout: TimeInterval = 7) async throws {
        try await elm327.connectToAdapter()
        try await elm327.adapterInitialization()
    }

    public func initializeVehicle(_ preferedProtocol: PROTOCOL?) async throws -> (OBDProtocol: PROTOCOL, VIN: String?) {
        let obd2info = try await elm327.setupVehicle(preferedProtocol: preferedProtocol)
        return obd2info
    }

    public func stopConnection() {
        self.elm327.stopConnection()
    }

    public func switchConnectionType(_ connectionType: connectionType) {
        switch connectionType {
        case .bluetooth:
            self.elm327 = ELM327(comm: BLEManager())
        case .wifi:
            self.elm327 = ELM327(comm: WifiManager())
        }
    }

    // MARK: - Request Handling

    public func requestPIDs(_ commands: [OBDCommand]) async throws -> [Message] {
        return try await elm327.requestPIDs(commands)
    }

    public func getSupportedPIDs() async -> [OBDCommand] {
        return await elm327.getSupportedPIDs()
    }

    public func scanForTroubleCodes() async throws -> [String: String]? {
        guard self.connectionState == .connectedToVehicle else {
            throw OBDServiceError.notConnectedToVehicle
        }
        return try await elm327.scanForTroubleCodes()
    }

    public func clearTroubleCodes() async throws {
        guard self.connectionState == .connectedToVehicle else {
            throw OBDServiceError.notConnectedToVehicle
        }
        try await elm327.clearTroubleCodes()
    }

    public func getStatus() async throws -> Status? {
        return try await elm327.getStatus()
    }

    public func switchToDemoMode(_ isDemoMode: Bool) {
        elm327.switchToDemoMode(isDemoMode)
    }

    public func sendCommand(_ message: String, withTimeoutSecs: TimeInterval = 5) async throws -> [String] {
        return try await elm327.sendCommand(message)
    }
}

enum OBDServiceError: Error, CustomStringConvertible {
    case noAdapterFound
    case notConnectedToVehicle
    var description: String {
        switch self {
        case .noAdapterFound: return "No adapter found"
        case .notConnectedToVehicle: return "Not connected to vehicle"
        }
    }
}
