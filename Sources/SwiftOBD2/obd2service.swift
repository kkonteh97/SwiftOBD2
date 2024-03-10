import Foundation
import Combine

public enum connectionType {
    case bluetooth
    case wifi
}

public protocol OBDServiceDelegate: AnyObject {
    func connectionStateChanged(state: ConnectionState)
}

/// A class that provides an interface to the ELM327 OBD2 adapter and the vehicle.
///
/// - Key Responsibilities:
///   - Establishing a connection to the adapter and the vehicle.
///   - Sending and receiving OBD2 commands.
///   - Providing information about the vehicle.
///   - Managing the connection state.
public class OBDService: ObservableObject {
    /// A weak reference to the service's delegate, used for communication.
    public weak var delegate: OBDServiceDelegate? {
        didSet {
            elm327.obdDelegate = delegate
        }
    }

    /// The internal ELM327 object responsible for direct adapter interaction.
    private var elm327: ELM327

    public var connectionState: ConnectionState {
        return elm327.connectionState
    }

    /// Initializes the OBDService object.
    ///
    /// - Parameter connectionType: The desired connection type (default is Bluetooth).
    public init(connectionType: connectionType = .bluetooth) {
        switch connectionType {
        case .bluetooth:
            self.elm327 = ELM327(comm: BLEManager())
        case .wifi:
            self.elm327 = ELM327(comm: WifiManager())
        }
    }

    // MARK: - Connection Handling

    /// Initiates the connection process to the OBD2 adapter and vehicle.
    ///
    /// - Parameter preferedProtocol: The optional OBD2 protocol to use (if supported).
    /// - Returns: Information about the connected vehicle (`OBDInfo`).
    /// - Throws: Errors that might occur during the connection process.
    public func startConnection(preferedProtocol: PROTOCOL? = nil) async throws -> OBDInfo {
       do {
           try await elm327.connectToAdapter()
           try await elm327.adapterInitialization()
           delegate?.connectionStateChanged(state: .connectedToAdapter)
           let obdInfo = try await self.initializeVehicle(preferedProtocol)
           return obdInfo
       } catch {
           throw OBDServiceError.adapterConnectionFailed(underlyingError: error) // Propagate
       }
   }

    /// Initializes communication with the vehicle and retrieves vehicle information.
    ///
    /// - Parameter preferedProtocol: The optional OBD2 protocol to use (if supported).
    /// - Returns: Information about the connected vehicle (`OBDInfo`).
    /// - Throws: Errors if the vehicle initialization process fails.
    func initializeVehicle(_ preferedProtocol: PROTOCOL?) async throws -> OBDInfo {
        let obd2info = try await elm327.setupVehicle(preferedProtocol: preferedProtocol)
        delegate?.connectionStateChanged(state: .connectedToVehicle)
        return obd2info
    }

    /// Terminates the connection with the OBD2 adapter.
    public func stopConnection() {
        self.elm327.stopConnection()
    }

    /// Switches the active connection type (between Bluetooth and Wi-Fi).
    ///
    /// - Parameter connectionType: The new desired connection type.
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

    /// Sends an OBD2 command to the vehicle and returns a publisher with the result.
    /// - Parameter command: The OBD2 command to send.
    /// - Returns: A publisher with the measurement result.
    /// - Throws: Errors that might occur during the request process.
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

    public func removePID(_ pid: OBDCommand) {
        self.pidList.removeAll { $0 == pid }
    }

    /// Sends an OBD2 command to the vehicle and returns the raw response.
    /// - Parameter command: The OBD2 command to send.
    /// - Returns: measurement result
    /// - Throws: Errors that might occur during the request process.
    private func requestPIDs(_ commands: [OBDCommand]) async throws -> [OBDCommand: MeasurementResult] {
        let response = try await sendCommand("01" + commands.compactMap { $0.properties.command.dropFirst(2) }.joined())
        let messages  = OBDParcer(response, idBits: elm327.obdProtocol.idBits)?.messages
        guard let responseData = messages?.first?.data else { return [:] }
        var batchedResponse = BatchedResponse(response: responseData)

        var results: [OBDCommand: MeasurementResult] = [:]
        for command in commands {
            let result = batchedResponse.extractValue(command)
            results[command] = result
        }
        return results
    }

    public func sendCommand(_ command: OBDCommand) async throws -> DecodeResult? {
        do {
            let response = try await sendCommand(command.properties.command)
            let messages  = OBDParcer(response, idBits: elm327.obdProtocol.idBits)?.messages
            guard let responseData = messages?.first?.data else { return nil }
            return command.properties.decode(data: responseData.dropFirst())
        } catch {
            throw OBDServiceError.commandFailed(command: command.properties.command, error: error)
        }
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
        guard self.connectionState == .connectedToVehicle else {
            throw OBDServiceError.notConnectedToVehicle
        }
        return try await elm327.getStatus()
    }

    public func switchToDemoMode(_ isDemoMode: Bool) {
        elm327.switchToDemoMode(isDemoMode)
    }

    public func sendCommand(_ message: String, withTimeoutSecs: TimeInterval = 5) async throws -> [String] {
        return try await elm327.sendCommand(message)
    }
}

public struct MeasurementResult: Equatable {
    public let value: Double
    public let unit: Unit
}

enum OBDServiceError: Error {
    case noAdapterFound
    case notConnectedToVehicle
    case adapterConnectionFailed(underlyingError: Error)
    case commandFailed(command: String, error: Error)
}

public func getVINInfo(vin: String) async throws -> VINResults {
    let endpoint = "https://vpic.nhtsa.dot.gov/api/vehicles/decodevinvalues/\(vin)?format=json"

    guard let url = URL(string: endpoint) else {
        throw URLError(.badURL)
    }

    let (data, response) = try await URLSession.shared.data(from: url)

    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(VINResults.self, from: data)
    return decoded
}

public struct VINResults: Codable {
    public let Results: [VINInfo]
}

public struct VINInfo: Codable, Hashable {
    public let Make: String
    public let Model: String
    public let ModelYear: String
    public let EngineCylinders: String
}
