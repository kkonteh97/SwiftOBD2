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

public protocol OBDServiceDelegate: AnyObject {
    func connectionStateChanged(state: ConnectionState)
}

public class OBDService {
    public weak var delegate: OBDServiceDelegate? {
        didSet {
            elm327.obdDelegate = delegate
        }
    }

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

    public func startConnection(preferedProtocol: PROTOCOL?) async throws -> OBDInfo {
         try await self.initializeAdapter()
         return try await self.initializeVehicle(preferedProtocol)
    }

    public func initializeAdapter(timeout: TimeInterval = 7) async throws {
        try await elm327.connectToAdapter()
        delegate?.connectionStateChanged(state: .connectedToAdapter)
        try await elm327.adapterInitialization()
    }

    public func initializeVehicle(_ preferedProtocol: PROTOCOL?) async throws -> OBDInfo {
        let obd2info = try await elm327.setupVehicle(preferedProtocol: preferedProtocol)
        delegate?.connectionStateChanged(state: .connectedToVehicle)
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
    var pidList: [OBDCommand] = []

    public func startContinuousUpdates(_ pids: [OBDCommand], interval: TimeInterval = 0.3) -> AnyPublisher<[OBDCommand: MeasurementResult], Error> {
        self.pidList = pids
        return Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .flatMap { [weak self] _ in
                return Future<[OBDCommand: MeasurementResult], Error> { promise in
                    guard let self = self else {
                        promise(.failure(OBDServiceError.notConnectedToVehicle))
                        return
                    }

                    Task.init(priority: .userInitiated) {
                        do {
                            let results = try await self.requestPIDs(self.pidList)
                            DispatchQueue.main.async {
                                promise(.success(results))
                            }
                        } catch {
                            promise(.failure(error))
                        }
                    }
                }
            }
            .eraseToAnyPublisher()
    }

    public func addPID(_ pid: OBDCommand) {
        self.pidList.append(pid)
    }

    public func requestPIDs(_ commands: [OBDCommand]) async throws -> [OBDCommand: MeasurementResult] {
        print("Requesting PIDs: \(commands.map { $0.properties.description })")
        let response = try await sendCommand("01" + commands.compactMap { $0.properties.command.dropFirst(2) }.joined())
        let messages  = try OBDParcer(response, idBits: elm327.obdProtocol.idBits).messages
        guard let responseData = messages.first?.data else { return [:] }
        var batchedResponse = BatchedResponse(response: responseData)

        var results: [OBDCommand: MeasurementResult] = [:]
        for command in commands {
            let result = try batchedResponse.extractValue(command)
            results[command] = result
        }
        return results
    }

    public func requestPID(_ command: OBDCommand) async throws -> DecodeResult? {
        print("Requesting PID: \(command)")
        let response = try await sendCommand(command.properties.command)
        let messages  = try OBDParcer(response, idBits: elm327.obdProtocol.idBits).messages
        guard let responseData = messages.first?.data else { return nil }
        return command.properties.decode(data: responseData.dropFirst())
    }

    public func getSupportedPIDs() async -> [OBDCommand] {
        return await elm327.getSupportedPIDs()
    }

    public func scanForTroubleCodes() async throws -> [TroubleCode] {
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

public struct MeasurementResult {
    public let value: Double
    public let unit: Unit
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
