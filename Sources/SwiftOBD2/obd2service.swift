import Combine
import CoreBluetooth
import Foundation

public enum ConnectionType: String, CaseIterable {
    case bluetooth = "Bluetooth"
    case wifi = "Wi-Fi"
    case serial = "USB Serial"
}

public protocol OBDServiceDelegate: AnyObject {
    func connectionStateChanged(state: ConnectionState)
    func peripheralsUpdated(_ peripherals: [CBPeripheral])
    func adapterInfoUpdated(_ info: [String: String])
    func logMessage(_ message: String)
}

extension OBDServiceDelegate {
    public func peripheralsUpdated(_ peripherals: [CBPeripheral]) {}
    public func adapterInfoUpdated(_ info: [String: String]) {}
    public func logMessage(_ message: String) {}
}

struct Command: Codable {
    var bytes: Int
    var command: String
    var decoder: String
    var description: String
    var live: Bool
    var maxValue: Int
    var minValue: Int
}

public class ConfigurationService: @unchecked Sendable {
    public static let shared = ConfigurationService()
    public var connectionType: ConnectionType {
        get {
            let rawValue = UserDefaults.standard.string(forKey: "connectionType") ?? "Bluetooth"
            return ConnectionType(rawValue: rawValue) ?? .bluetooth
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "connectionType")
        }
    }
    public var wifiHost: String {
        get { UserDefaults.standard.string(forKey: "wifiHost") ?? "192.168.0.10" }
        set { UserDefaults.standard.set(newValue, forKey: "wifiHost") }
    }
    public var wifiPort: String {
        get { UserDefaults.standard.string(forKey: "wifiPort") ?? "35000" }
        set { UserDefaults.standard.set(newValue, forKey: "wifiPort") }
    }
    public var serialPath: String {
        get { UserDefaults.standard.string(forKey: "serialPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "serialPath") }
    }
    public var serialVerboseLogging: Bool {
        get { UserDefaults.standard.bool(forKey: "serialVerboseLogging") }
        set { UserDefaults.standard.set(newValue, forKey: "serialVerboseLogging") }
    }
    public var obdCommandLogging: Bool {
        get { UserDefaults.standard.bool(forKey: "obdCommandLogging") }
        set { UserDefaults.standard.set(newValue, forKey: "obdCommandLogging") }
    }
}

/// A class that provides an interface to the ELM327 OBD2 adapter and the vehicle.
///
/// - Key Responsibilities:
///   - Establishing a connection to the adapter and the vehicle.
///   - Sending and receiving OBD2 commands.
///   - Providing information about the vehicle.
///   - Managing the connection state.
public class OBDService: ObservableObject, OBDServiceDelegate, @unchecked Sendable {
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var connectedPeripheral: CBPeripheral?
    @Published public private(set) var peripherals: [CBPeripheral] = []
    @Published public private(set) var adapterInfo: [String: String] = [:]

    // Plain Swift callbacks — consumed by the app layer without Combine.
    public var onConnectionStateChanged: ((ConnectionState) -> Void)?
    public var onPeripheralsUpdated: (([CBPeripheral]) -> Void)?
    public var onScanningChanged: ((Bool) -> Void)?
    public var onAdapterInfoUpdated: (([String: String]) -> Void)?
    public var onLog: ((String) -> Void)?
    @Published public var connectionType: ConnectionType {
        didSet {
            switchConnectionType(connectionType)
            ConfigurationService.shared.connectionType = connectionType
        }
    }

    /// The internal ELM327 object responsible for direct adapter interaction.
    private var elm327: ELM327

    private var cancellables = Set<AnyCancellable>()

    /// Initializes the OBDService object.
    ///
    /// - Parameter connectionType: The desired connection type (default is Bluetooth).
    ///
    ///
    public init(connectionType: ConnectionType = .bluetooth) {
        self.connectionType = connectionType
#if targetEnvironment(simulator)
        elm327 = ELM327(comm: MOCKComm())
#else
        switch connectionType {
        case .bluetooth:
            let bleManager = BLEManager()
            elm327 = ELM327(comm: bleManager)
        case .wifi:
            let config = ConfigurationService.shared
            elm327 = ELM327(comm: WifiManager(host: config.wifiHost, port: config.wifiPort))
        case .serial:
            #if os(iOS)
            elm327 = ELM327(comm: SerialManager())
            #else
            elm327 = ELM327(comm: MacSerialManager())
            #endif
        }
#endif
        elm327.obdDelegate = self
    }

    // MARK: - Connection Handling

    public func connectionStateChanged(state: ConnectionState) {
        DispatchQueue.main.async {
            let oldState = self.connectionState
            // The transport layers can still deliver the same state twice
            // (e.g. a manual stop followed by the publisher's .disconnected);
            // consumers must only see genuine transitions.
            guard oldState != state else { return }
            self.connectionState = state
            OBDLogger.shared.logConnectionChange(from: oldState, to: state)
            self.onConnectionStateChanged?(state)
        }
    }

    public func peripheralsUpdated(_ peripherals: [CBPeripheral]) {
        DispatchQueue.main.async {
            self.peripherals = peripherals
            self.onPeripheralsUpdated?(peripherals)
        }
    }

    public func adapterInfoUpdated(_ info: [String: String]) {
        DispatchQueue.main.async {
            self.adapterInfo = info
            self.onAdapterInfoUpdated?(info)
        }
    }

    public func logMessage(_ message: String) {
        DispatchQueue.main.async {
            self.onLog?(message)
        }
    }

    /// Initiates the connection process to the OBD2 adapter and vehicle.
    ///
    /// - Parameter preferedProtocol: The optional OBD2 protocol to use (if supported).
    /// - Returns: Information about the connected vehicle (`OBDInfo`).
    /// - Throws: Errors that might occur during the connection process.
    public func startConnection(preferedProtocol: PROTOCOL? = nil, timeout: TimeInterval = 7, peripheral: CBPeripheral? = nil) async throws -> OBDInfo {
        do {
            return try await attemptConnection(preferedProtocol: preferedProtocol, timeout: timeout, peripheral: peripheral)
        } catch OBDServiceError.adapterConnectionFailed(let underlying) where Self.isWorthRetrying(underlying) {
            // A transient link drop mid-handshake (the adapter/port still settling
            // right after open) is common on the very first connect and otherwise
            // forces the user to manually retry — one clean retry here covers it.
            obdWarning("Connection attempt failed — retrying once", category: .connection)
            elm327.stopConnection()
            return try await attemptConnection(preferedProtocol: preferedProtocol, timeout: timeout, peripheral: peripheral)
        }
        // .noAdapterFound already waited out a full BLE scan timeout — retrying
        // immediately would just double that wait for no benefit, so it propagates as-is.
    }

    /// Which handshake failures are worth one immediate retry.
    ///
    /// A transport that dropped while the adapter or port was still settling usually
    /// succeeds on the second try and costs a second or two to find out. A vehicle-level
    /// failure does not: `noProtocolFound` has already paid for the ELM327's own ATSP0
    /// auto-search *plus* a full 12-protocol manual sweep, each miss costing `ATSPn` +
    /// `0100` + a full command timeout. Repeating that doubles a wait the user is already
    /// sitting through and ends with the same answer — and because a consuming app may
    /// well retry on top of this one, a retry here is never as cheap as it looks.
    private static func isWorthRetrying(_ error: Error) -> Bool {
        guard let elmError = error as? ELM327Error else {
            // Transport-level errors (BLE/WiFi/serial) are the transient case this exists for.
            return true
        }
        switch elmError {
        case .noProtocolFound, .invalidProtocol, .ignitionOff, .invalidResponse:
            // The vehicle answered (or definitively didn't) — asking again changes nothing.
            return false
        case .adapterInitializationFailed, .connectionFailed, .timeout, .unknownError:
            // The link itself faltered; this is the drop a second attempt recovers from.
            return true
        }
    }

    private func attemptConnection(preferedProtocol: PROTOCOL?, timeout: TimeInterval, peripheral: CBPeripheral?) async throws -> OBDInfo {
        let startTime = CFAbsoluteTimeGetCurrent()
        obdInfo("Starting connection with timeout: \(timeout)s", category: .connection)

        do {
            obdDebug("Connecting to adapter...", category: .connection)
            try await elm327.connectToAdapter(timeout: timeout, peripheral: peripheral)

            obdDebug("Initializing adapter...", category: .connection)
            try await elm327.adapterInitialization()

            obdDebug("Initializing vehicle connection...", category: .connection)
            let vehicleInfo = try await initializeVehicle(preferedProtocol)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            OBDLogger.shared.logPerformance("Connection established", duration: duration, success: true)
            obdInfo("Successfully connected to vehicle: \(vehicleInfo.vin ?? "Unknown")", category: .connection)

            return vehicleInfo
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            OBDLogger.shared.logPerformance("Connection failed", duration: duration, success: false)
            obdError("Connection failed: \(error.localizedDescription)", category: .connection)

            if let bleError = error as? BLEManagerError {
                if bleError == .peripheralNotFound || bleError == .scanTimeout {
                    throw OBDServiceError.noAdapterFound
                }
            } else if let scanError = error as? BLEScannerError {
                if scanError == .peripheralNotFound || scanError == .scanTimeout {
                    throw OBDServiceError.noAdapterFound
                }
            }

            throw OBDServiceError.adapterConnectionFailed(underlyingError: error) // Propagate
        }
    }

    /// Initializes communication with the vehicle and retrieves vehicle information.
    ///
    /// - Parameter preferedProtocol: The optional OBD2 protocol to use (if supported).
    /// - Returns: Information about the connected vehicle (`OBDInfo`).
    /// - Throws: Errors if the vehicle initialization process fails.
    func initializeVehicle(_ preferedProtocol: PROTOCOL?) async throws -> OBDInfo {
        let obd2info = try await elm327.setupVehicle(preferredProtocol: preferedProtocol)
        return obd2info
    }

    /// Terminates the connection with the OBD2 adapter.
    public func stopConnection() {
        elm327.stopConnection()
    }

    /// Looks up a previously connected BLE peripheral by its system identifier
    /// so the caller can start a no-scan pending connect
    /// (`startConnection(timeout: .infinity, peripheral:)` waits until the
    /// dongle comes in range). Nil on non-BLE transports or when the system
    /// no longer knows the identifier.
    public func retrievePeripheral(identifier: UUID) async -> CBPeripheral? {
        await elm327.retrievePeripheral(withIdentifier: identifier)
    }

    /// Switches the dongle to a different CAN protocol without dropping the BT/Serial connection.
    public func switchProtocol(_ proto: PROTOCOL) async throws {
        try await elm327.switchProtocol(proto)
    }

    /// Switches the active connection type (between Bluetooth and Wi-Fi).
    ///
    /// - Parameter connectionType: The new desired connection type.
    private func switchConnectionType(_ connectionType: ConnectionType) {
        stopConnection()
        initializeELM327()
    }

    private func initializeELM327() {
        switch connectionType {
        case .bluetooth:
            let bleManager = BLEManager()
            elm327 = ELM327(comm: bleManager)
        case .wifi:
            let config = ConfigurationService.shared
            elm327 = ELM327(comm: WifiManager(host: config.wifiHost, port: config.wifiPort))
        case .serial:
            #if os(iOS)
            elm327 = ELM327(comm: SerialManager())
            #else
            elm327 = ELM327(comm: MacSerialManager())
            #endif
        }
        elm327.obdDelegate = self
    }

    // MARK: - Request Handling

    var pidList: [OBDCommand] = []

    /// Sends an OBD2 command to the vehicle and returns a publisher with the result.
    /// - Parameter command: The OBD2 command to send.
    /// - Returns: A publisher with the measurement result.
    /// - Throws: Errors that might occur during the request process.
    public func startContinuousUpdates(_ pids: [OBDCommand], unit: MeasurementUnit = .metric, interval: TimeInterval = 0.3) -> AnyPublisher<[OBDCommand: MeasurementResult], Error> {
        Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .flatMap { [weak self] _ -> Future<[OBDCommand: MeasurementResult], Error> in
                Future { promise in
                    guard let self = self else {
                        promise(.failure(OBDServiceError.notConnectedToVehicle))
                        return
                    }
                    Task(priority: .userInitiated) {
                        do {
                            let results = try await self.requestPIDs(pids, unit: unit)
                            promise(.success(results))
                        } catch {
                            promise(.failure(error))
                        }
                    }
                }
            }
            .eraseToAnyPublisher()
    }

    /// Adds an OBD2 command to the list of commands to be requested.
    public func addPID(_ pid: OBDCommand) {
        pidList.append(pid)
    }

    /// Removes an OBD2 command from the list of commands to be requested.
    public func removePID(_ pid: OBDCommand) {
        pidList.removeAll { $0 == pid }
    }

    /// Sends an OBD2 command to the vehicle and returns the raw response.
    /// - Parameter command: The OBD2 command to send.
    /// - Returns: measurement result
    /// - Throws: Errors that might occur during the request process.
    public func requestPIDs(_ commands: [OBDCommand], unit: MeasurementUnit) async throws -> [OBDCommand: MeasurementResult] {
        let response = try await sendCommandInternal("01" + commands.compactMap { $0.properties.command.dropFirst(2) }.joined(), retries: 10)

        guard let responseData = try elm327.canProtocol?.parse(response).first?.data else { return [:] }

        var batchedResponse = BatchedResponse(response: responseData, unit)

        let results: [OBDCommand: MeasurementResult] = commands.reduce(into: [:]) { result, command in
            let measurement = batchedResponse.extractValue(command)
            result[command] = measurement
        }

        return results
    }

    /// Sends an OBD2 command to the vehicle and returns the raw response.
    ///  - Parameter command: The OBD2 command to send.
    ///  - Returns: The raw response from the vehicle.
    ///  - Throws: Errors that might occur during the request process.
    public func sendCommand(_ command: OBDCommand) async throws -> Result<DecodeResult, DecodeError> {
        do {
            let response = try await sendCommandInternal(command.properties.command, retries: 3)
            guard let messages = try elm327.canProtocol?.parse(response), !messages.isEmpty else {
                return .failure(.noData)
            }
            // This is the app's per-PID live-sensor read path — on a two-ECU vehicle the
            // old Dictionary-order `.first` picked a different module from one poll to
            // the next, making values flicker between two sources. Prefer the response
            // that echoes the requested PID, from the primary (lowest-address) ECM.
            let pidEcho = UInt8(command.properties.command.dropFirst(2).prefix(2), radix: 16)
            guard let responseData = preferredECUMessage(messages, pidEcho: pidEcho)?.data else {
                return .failure(.noData)
            }
            return command.properties.decode(data: responseData.dropFirst())
        } catch {
            throw OBDServiceError.commandFailed(command: command.properties.command, error: error)
        }
    }

    /// Sends an OBD2 command to the vehicle and returns the raw response.
    ///   - Parameter command: The OBD2 command to send.
    ///   - Returns: The raw response from the vehicle.
    public func getSupportedPIDs() async -> [OBDCommand] {
        await elm327.getSupportedPIDs()
    }

    /// Mode 02 — the freeze frame: the snapshot of live values the ECU stored at the
    /// moment an emissions DTC set. It stays stored (frame 00) until codes are cleared,
    /// so this works for codes already in memory, not just ones that appear while
    /// connected. Which DTC owns the stored frame is a separate read: Mode 01 PID 02
    /// (`OBDCommand.Mode1.freezeDTC`).
    ///
    /// Request format is `02 <PID> <frame#>`; the response payload is laid out like the
    /// Mode 01 equivalent with one extra frame-number byte after the PID echo, so each
    /// PID's own Mode 01 decoder applies to the payload after dropping [PID][frame#].
    /// PIDs the vehicle didn't capture answer NO DATA and are simply omitted.
    public func requestFreezeFrame(_ pids: [OBDCommand.Mode1], frame: UInt8 = 0) async -> [OBDCommand.Mode1: MeasurementResult] {
        var snapshot: [OBDCommand.Mode1: MeasurementResult] = [:]
        for pid in pids {
            let mode1Command = OBDCommand.mode1(pid)
            let pidHex = String(mode1Command.properties.command.dropFirst(2))
            let command = String(format: "02%@%02X", pidHex, frame)
            guard let response = try? await elm327.sendCommand(command, retries: 1),
                  let messages = try? elm327.canProtocol?.parse(response),
                  let data = preferredECUMessage(messages, pidEcho: UInt8(pidHex, radix: 16))?.data,
                  data.count > 2
            else { continue }
            // message.data has already dropped the mode echo (0x42); what remains is
            // [PID echo][frame #][payload...] — the Mode 01 decoder wants just payload.
            if case let .success(decoded) = mode1Command.properties.decode(data: data.dropFirst(2)),
               let measurement = decoded.measurementResult {
                snapshot[pid] = measurement
            }
        }
        return snapshot
    }

    ///  Scans for trouble codes and returns the result.
    ///  - Returns: The trouble codes found on the vehicle.
    ///  - Throws: Errors that might occur during the request process.
    public func scanForTroubleCodes() async throws -> [ECUID: [TroubleCode]] {
        do {
            return try await elm327.scanForTroubleCodes()
        } catch {
            throw OBDServiceError.scanFailed(underlyingError: error)
        }
    }

    /// Scans a specific ECU for DTCs using UDS Service $19 (readDTCByStatusMask).
    public func scanForUDSDTCs(header: String) async throws -> [TroubleCode] {
        do {
            return try await elm327.scanForUDSDTCs(header: header)
        } catch {
            throw OBDServiceError.scanFailed(underlyingError: error)
        }
    }

    /// Clears the trouble codes found on the vehicle.
    ///  - Throws: Errors that might occur during the request process.
    ///     - `OBDServiceError.notConnectedToVehicle` if the adapter is not connected to a vehicle.
    public func clearTroubleCodes() async throws {
        do {
            try await elm327.clearTroubleCodes()
        } catch {
            throw OBDServiceError.clearFailed(underlyingError: error)
        }
    }

    /// Returns the vehicle's status.
    ///  - Returns: The vehicle's status.
    ///  - Throws: Errors that might occur during the request process.
    public func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        do {
            return try await elm327.getStatus()
        } catch {
            throw error
        }
    }

    //    public func switchToDemoMode(_ isDemoMode: Bool) {
    //        elm327.switchToDemoMode(isDemoMode)
    //    }

    /// Sends a raw command to the vehicle and returns the raw response.
    /// - Parameter message: The raw command to send.
    /// - Returns: The raw response from the vehicle.
    /// - Throws: Errors that might occur during the request process.
    public func sendCommandInternal(_ message: String, retries: Int) async throws -> [String] {
        do {
            return try await elm327.sendCommand(message, retries: retries)
        } catch {
            throw OBDServiceError.commandFailed(command: message, error: error)
        }
    }

    public func sendMonitorCommandInternal(_ command: String, duration: TimeInterval) async throws -> [String] {
        do {
            return try await elm327.sendMonitorCommand(command, duration: duration)
        } catch {
            throw OBDServiceError.commandFailed(command: command, error: error)
        }
    }

    public func connectToPeripheral(peripheral: CBPeripheral) async throws {
        do {
            try await elm327.connectToAdapter(timeout: 5, peripheral: peripheral)
        } catch {
            throw OBDServiceError.adapterConnectionFailed(underlyingError: error)
        }
    }

    public func scanForPeripherals() async throws {
        do {
            self.isScanning = true
            onScanningChanged?(true)
            try await elm327.scanForPeripherals()
            self.isScanning = false
            onScanningChanged?(false)
        } catch {
            self.isScanning = false
            onScanningChanged?(false)
            throw OBDServiceError.scanFailed(underlyingError: error)
        }
    }

//    public func test() {
//        if let resourcePath = Bundle.module.resourcePath {
//               print("Bundle resources path: \(resourcePath)")
//               let files = try? FileManager.default.contentsOfDirectory(atPath: resourcePath)
//               print("Files in bundle: \(files ?? [])")
//           }
//        // Get the path for the JSON file within the app's bundle
//        guard let path = Bundle.module.path(forResource: "commands", ofType: "json") else {
//            print("Error: commands.json file not found in the bundle.")
//            return
//        }
//
//        // Load the file data
//        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
//            print("Error: Unable to load data from commands.json.")
//            return
//        }
//
//        do {
//                // Load the JSON
//                let data = try Data(contentsOf: URL(fileURLWithPath: path))
//
//                // Decode the JSON into an array of dictionaries to handle flexible structures
//                guard var rawCommands = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
//                    print("Error: Invalid JSON format.")
//                    return
//                }
//
//                // Edit the `decoder` field
//                rawCommands = rawCommands.map { command in
//                    var updatedCommand = command
//                    if let decoder = command["decoder"] as? [String: Any], let firstKey = decoder.keys.first {
//                        updatedCommand["decoder"] = firstKey // Set the first key as the string value
//                    } else {
//                        updatedCommand["decoder"] = "none" // Default to "none" if no keys exist
//                    }
//                    return updatedCommand
//                }
//
//                // Convert back to JSON data
//                let updatedData = try JSONSerialization.data(withJSONObject: rawCommands, options: .prettyPrinted)
//
//                // Save the updated JSON to a file
//                let outputPath = FileManager.default.temporaryDirectory.appendingPathComponent("commands_updated.json")
//                try updatedData.write(to: outputPath)
//
//                print("Modified commands.json saved to: \(outputPath.path)")
//            } catch {
//                print("Error processing commands.json: \(error)")
//            }
//    }

}

public enum OBDServiceError: Error {
    case noAdapterFound
    case notConnectedToVehicle
    case adapterConnectionFailed(underlyingError: Error)
    case scanFailed(underlyingError: Error)
    case clearFailed(underlyingError: Error)
    case commandFailed(command: String, error: Error)
}

extension OBDServiceError: LocalizedError {
    // Without this, every consumer's `.localizedDescription` produced the useless generic
    // "OBDServiceError error N." — every case here wraps a real underlying transport/parse
    // error (BLEManagerError, ELM327Error, ParserError, ...) that already describes itself
    // properly; this was the one place in the chain that discarded it.
    public var errorDescription: String? {
        switch self {
        case .noAdapterFound:
            return "No OBD adapter found."
        case .notConnectedToVehicle:
            return "Connected to the adapter, but not to the vehicle."
        case .adapterConnectionFailed(let underlying):
            return "Adapter connection failed: \(underlying.localizedDescription)"
        case .scanFailed(let underlying):
            return "Trouble-code scan failed: \(underlying.localizedDescription)"
        case .clearFailed(let underlying):
            return "Clearing trouble codes failed: \(underlying.localizedDescription)"
        case .commandFailed(let command, let underlying):
            return "Command '\(command)' failed: \(underlying.localizedDescription)"
        }
    }
}

public struct MeasurementResult: Equatable {
    public var value: Double
    public let unit: Unit
	
	public init(value: Double, unit: Unit) {
		self.value = value
		self.unit = unit
	}
}

public extension MeasurementResult {
	static func mock(_ value: Double = 125, _ suffix: String = "km/h") -> MeasurementResult {
		.init(value: value, unit: .init(symbol: suffix))
	}
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
    public let Trim: String?
}
