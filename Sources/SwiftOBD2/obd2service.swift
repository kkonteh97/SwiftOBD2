import Combine
import CoreBluetooth
import Foundation

public enum ConnectionType: String, CaseIterable {
    case bluetooth = "Bluetooth"
    case wifi = "Wi-Fi"
    case demo = "Demo"
}

public protocol OBDServiceDelegate: AnyObject {
    func connectionStateChanged(state: ConnectionState)
}

public class ConfigurationService {
    static var shared = ConfigurationService()
    var connectionType: ConnectionType {
        get {
            let rawValue = UserDefaults.standard.string(forKey: "connectionType") ?? "Bluetooth"
            return ConnectionType(rawValue: rawValue) ?? .bluetooth
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "connectionType")
        }
    }
}

/// A class that provides an interface to the ELM327 OBD2 adapter and the vehicle.
///
/// - Key Responsibilities:
///   - Establishing a connection to the adapter and the vehicle.
///   - Sending and receiving OBD2 commands.
///   - Providing information about the vehicle.
///   - Managing the connection state.
///
/// Reading data, diagnostics (trouble codes, freeze frames, monitors) and manufacturer specific
/// requests are grouped in extensions of this class.
public class OBDService: ObservableObject, OBDServiceDelegate {
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var connectedPeripheral: CBPeripheral?
    @Published public var connectionType: ConnectionType {
        didSet {
            switchConnectionType(connectionType)
            ConfigurationService.shared.connectionType = connectionType
        }
    }

    /// Adapter settings: Wi-Fi address, time-outs, polling optimisations.
    ///
    /// Changing the Wi-Fi address while the Wi-Fi connection type is selected closes the current connection.
    public var configuration: OBDConfiguration {
        didSet {
            let endpointChanged = oldValue.wifiHost != configuration.wifiHost || oldValue.wifiPort != configuration.wifiPort
            if endpointChanged, connectionType == .wifi {
                stopConnection()
                initializeELM327()
            } else {
                elm327.configuration = configuration
            }
        }
    }

    /// What was learnt about the vehicle during the last successful ``startConnection(preferedProtocol:timeout:)``.
    public private(set) var vehicleInfo: OBDInfo?

    /// The internal ELM327 object responsible for direct adapter interaction.
    var elm327: ELM327

    private let stateLock = NSLock()
    private var extraPIDs: [OBDCommand] = []
    private var excludedPIDs: Set<OBDCommand> = []
    /// Whether the vehicle answers several PIDs in a single request. Assumed until proven otherwise.
    private var groupedRequestsSupported = true

    /// Initializes the OBDService object.
    ///
    /// - Parameters:
    ///   - connectionType: The desired connection type (default is Bluetooth).
    ///   - configuration: Adapter settings, including the address of a Wi-Fi adapter.
    public init(connectionType: ConnectionType = .bluetooth, configuration: OBDConfiguration = OBDConfiguration()) {
        self.connectionType = connectionType
        self.configuration = configuration
        elm327 = ELM327(comm: OBDService.makeTransport(connectionType, configuration), configuration: configuration)
        elm327.obdDelegate = self
    }

    /// Creates a service talking to a Wi-Fi adapter at the given address.
    public convenience init(wifiHost: String, wifiPort: UInt16 = 35000) {
        self.init(connectionType: .wifi, configuration: OBDConfiguration(wifiHost: wifiHost, wifiPort: wifiPort))
    }

    /// Creates a service on top of an arbitrary transport (unit tests).
    init(comm: CommProtocol, configuration: OBDConfiguration = OBDConfiguration()) {
        connectionType = .demo
        self.configuration = configuration
        elm327 = ELM327(comm: comm, configuration: configuration)
        elm327.obdDelegate = self
    }

    private static func makeTransport(_ connectionType: ConnectionType, _ configuration: OBDConfiguration) -> CommProtocol {
        switch connectionType {
        case .bluetooth:
#if targetEnvironment(simulator)
            // The simulator has no Bluetooth radio.
            return MOCKComm()
#else
            return BLEManager()
#endif
        case .wifi:
            return WifiManager(host: configuration.wifiHost, port: configuration.wifiPort)
        case .demo:
            return MOCKComm()
        }
    }

    // MARK: - Connection Handling

    public func connectionStateChanged(state: ConnectionState) {
        DispatchQueue.main.async {
            let oldState = self.connectionState
            guard oldState != state else { return }
            self.connectionState = state
            OBDLogger.shared.logConnectionChange(from: oldState, to: state)
        }
    }

    /// Initiates the connection process to the OBD2 adapter and vehicle.
    ///
    /// - Parameters:
    ///   - preferedProtocol: The optional OBD2 protocol to try first. Giving the protocol the
    ///     vehicle is known to use makes the connection noticeably faster.
    ///   - timeout: How long to wait for the adapter itself (scan and connection).
    /// - Returns: Information about the connected vehicle (`OBDInfo`).
    /// - Throws: `OBDServiceError.adapterConnectionFailed` wrapping the reason of the failure.
    public func startConnection(preferedProtocol: PROTOCOL? = nil, timeout: TimeInterval = 7) async throws -> OBDInfo {
        let startTime = CFAbsoluteTimeGetCurrent()
        obdInfo("Starting connection with timeout: \(timeout)s", category: .connection)

        do {
            obdDebug("Connecting to adapter...", category: .connection)
            try await elm327.connectToAdapter(timeout: timeout)

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
        stateLock.sync { groupedRequestsSupported = true }
        vehicleInfo = obd2info
        return obd2info
    }

    /// Terminates the connection with the OBD2 adapter.
    public func stopConnection() {
        elm327.stopConnection()
    }

    /// Switches the active connection type (between Bluetooth and Wi-Fi).
    ///
    /// - Parameter connectionType: The new desired connection type.
    private func switchConnectionType(_: ConnectionType) {
        stopConnection()
        initializeELM327()
    }

    private func initializeELM327() {
        elm327 = ELM327(comm: OBDService.makeTransport(connectionType, configuration), configuration: configuration)
        elm327.obdDelegate = self
        vehicleInfo = nil
    }

    public func connectToPeripheral(peripheral: CBPeripheral) async throws {
        do {
            try await elm327.connectToAdapter(timeout: 5, peripheral: peripheral)
        } catch {
            throw OBDServiceError.adapterConnectionFailed(underlyingError: error)
        }
    }

    public func scanForPeripherals() async throws {
        await MainActor.run { self.isScanning = true }
        do {
            try await elm327.scanForPeripherals()
            await MainActor.run { self.isScanning = false }
        } catch {
            await MainActor.run { self.isScanning = false }
            throw OBDServiceError.scanFailed(underlyingError: error)
        }
    }

    // MARK: - Live data

    /// Polls a set of commands for as long as the returned stream is iterated.
    ///
    ///     for try await values in obdService.liveData([.mode1(.rpm), .mode1(.speed)]) {
    ///         print(values[.mode1(.rpm)]?.value ?? 0)
    ///     }
    ///
    /// Requests never overlap: a new round starts once the previous one is complete and `interval`
    /// has elapsed. Commands the vehicle does not answer are simply absent from the dictionary.
    /// The stream ends with an error when the connection is lost.
    ///
    /// - Parameters:
    ///   - commands: Built-in or custom commands producing a measurement.
    ///   - interval: Minimum time between two rounds, `0` to poll as fast as the vehicle allows.
    public func liveData(_ commands: [OBDCommand],
                         unit: MeasurementUnit = .metric,
                         interval: TimeInterval = 0.3) -> AsyncThrowingStream<[OBDCommand: MeasurementResult], Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                var consecutiveFailures = 0

                while !Task.isCancelled {
                    guard let self = self else { break }
                    let started = Date()
                    var pause = interval

                    do {
                        let values = try await self.requestPIDs(self.pollingList(commands), unit: unit)
                        consecutiveFailures = 0
                        continuation.yield(values)
                    } catch is CancellationError {
                        break
                    } catch {
                        consecutiveFailures += 1
                        if OBDService.isConnectionLost(error) || consecutiveFailures >= 5 {
                            continuation.finish(throwing: error)
                            return
                        }
                        // Give the bus some air before trying again.
                        pause = max(interval, 0.5)
                    }

                    let remaining = pause - Date().timeIntervalSince(started)
                    if remaining > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    } else {
                        await Task.yield()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Polls a set of commands and publishes the measurements on the main queue.
    ///
    /// Polling starts when the publisher is subscribed to and stops when the subscription is cancelled.
    /// - Parameter pids: The OBD2 commands to poll. See also ``addPID(_:)``.
    /// - Returns: A publisher with the measurement results. It fails when the connection is lost.
    public func startContinuousUpdates(_ pids: [OBDCommand], unit: MeasurementUnit = .metric, interval: TimeInterval = 0.3) -> AnyPublisher<[OBDCommand: MeasurementResult], Error> {
        Deferred { [weak self] () -> AnyPublisher<[OBDCommand: MeasurementResult], Error> in
            guard let self = self else {
                return Fail(error: OBDServiceError.notConnectedToVehicle).eraseToAnyPublisher()
            }
            let subject = PassthroughSubject<[OBDCommand: MeasurementResult], Error>()
            let stream = self.liveData(pids, unit: unit, interval: interval)
            let task = Task {
                do {
                    for try await values in stream {
                        subject.send(values)
                    }
                    subject.send(completion: .finished)
                } catch {
                    subject.send(completion: .failure(error))
                }
            }
            return subject
                .handleEvents(receiveCancel: { task.cancel() })
                .eraseToAnyPublisher()
        }
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }

    /// Adds an OBD2 command to the ones polled by the running continuous updates.
    public func addPID(_ pid: OBDCommand) {
        stateLock.lock()
        defer { stateLock.unlock() }
        excludedPIDs.remove(pid)
        if !extraPIDs.contains(pid) {
            extraPIDs.append(pid)
        }
    }

    /// Removes an OBD2 command from the ones polled by the running continuous updates.
    public func removePID(_ pid: OBDCommand) {
        stateLock.lock()
        defer { stateLock.unlock() }
        extraPIDs.removeAll { $0 == pid }
        excludedPIDs.insert(pid)
    }

    private func pollingList(_ commands: [OBDCommand]) -> [OBDCommand] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (commands + extraPIDs).filter { !excludedPIDs.contains($0) }
    }

    /// Reads the current value of several commands.
    ///
    /// On CAN vehicles the standard PIDs are grouped, up to six per request, which makes a round
    /// several times faster than asking for them one by one.
    ///
    /// - Parameter commands: Built-in or custom commands producing a measurement.
    /// - Returns: The measurements, keyed by command. Commands the vehicle does not support, or
    ///   whose answer is not a number, are absent.
    /// - Throws: `OBDServiceError.notConnectedToVehicle`, or the transport error when the link fails.
    public func requestPIDs(_ commands: [OBDCommand], unit: MeasurementUnit = .metric) async throws -> [OBDCommand: MeasurementResult] {
        var results: [OBDCommand: MeasurementResult] = [:]

        var seen: Set<OBDCommand> = []
        let unique = commands.filter { seen.insert($0).inserted && $0.service != nil }
        let isStandardPID: (OBDCommand) -> Bool = { $0.service == 0x01 && $0.target == nil && $0.properties.bytes > 0 }
        let standard = unique.filter(isStandardPID)
        // Grouping custom commands by ECU avoids switching the adapter back and forth.
        let others = unique.filter { !isStandardPID($0) }.sorted { ($0.target?.header ?? "") < ($1.target?.header ?? "") }

        let canGroup = stateLock.sync { groupedRequestsSupported }
        let groupSize = canGroup && elm327.obdProtocol?.isCAN == true ? min(max(configuration.maxPIDsPerRequest, 1), 6) : 1

        for group in standard.chunked(into: groupSize) {
            if group.count == 1 {
                results[group[0]] = try await requestMeasurement(group[0], unit: unit)
                continue
            }

            var values: [UInt8: Data] = [:]
            do {
                let request = "01" + group.flatMap(\.parameterBytes).hexString
                values = OBDService.splitService01(try await elm327.request(request))
            } catch {
                guard OBDService.isAnswerMissing(error) else { throw OBDService.translate(error) }
            }

            var missing: [OBDCommand] = []
            for command in group {
                if let pid = command.parameterBytes.first, let data = values[pid] {
                    results[command] = OBDService.measurement(command, data, unit)
                } else {
                    missing.append(command)
                }
            }

            // An ECU that understands grouped requests answers every PID it supports: PIDs missing
            // from a rich answer are unsupported. A poor answer may mean that grouping itself is
            // not supported: ask again one by one, and remember the outcome.
            if values.count < 2, !missing.isEmpty {
                var recovered = false
                for command in missing {
                    if let value = try await requestMeasurement(command, unit: unit) {
                        results[command] = value
                        recovered = true
                    }
                }
                if recovered {
                    obdInfo("Vehicle does not support grouped PID requests, falling back to single requests", category: .communication)
                    stateLock.sync { groupedRequestsSupported = false }
                }
            }
        }

        for command in others {
            results[command] = try await requestMeasurement(command, unit: unit)
        }
        return results
    }

    /// Reads one command and returns its value when it is a measurement.
    private func requestMeasurement(_ command: OBDCommand, unit: MeasurementUnit) async throws -> MeasurementResult? {
        do {
            // Only safe when the answer fits in a single frame.
            let singleFrame = configuration.stopsAfterFirstResponse && command.service == 0x01 && (1 ... 5).contains(command.properties.bytes)
            let messages = try await elm327.request(command.properties.command, target: command.target, singleResponse: singleFrame)
            for message in ELM327.engineFirst(messages) {
                if let data = OBDService.dataBytes(for: command, in: message) {
                    return OBDService.measurement(command, data, unit)
                }
            }
            return nil
        } catch {
            guard OBDService.isAnswerMissing(error) else { throw OBDService.translate(error) }
            return nil
        }
    }

    /// Sends an OBD2 command to the vehicle and returns the decoded response.
    ///  - Parameter command: The OBD2 command to send.
    ///  - Returns: The decoded response: a measurement, a status, a string, trouble codes or
    ///    monitor results depending on the command.
    ///  - Throws: `OBDServiceError.commandFailed` when the request could not be carried out.
    public func sendCommand(_ command: OBDCommand, unit: MeasurementUnit = .metric) async throws -> Result<DecodeResult, DecodeError> {
        do {
            guard command.service != nil else {
                // Adapter (AT) command: there is nothing to decode.
                let lines = try await elm327.sendCommand(command.properties.command)
                return .success(.stringResult(lines.joined(separator: "\n")))
            }

            let messages = try await elm327.request(command.properties.command, target: command.target, retries: 3)
            for message in ELM327.engineFirst(messages) {
                if let data = OBDService.dataBytes(for: command, in: message) {
                    return command.properties.decode(data: data, unit: unit)
                }
            }
            return .failure(.noData)
        } catch ELM327Error.noData {
            return .failure(.noData)
        } catch {
            throw OBDServiceError.commandFailed(command: command.properties.command, error: error)
        }
    }

    /// Returns the commands of the built-in catalog that the vehicle supports.
    public func getSupportedPIDs() async -> [OBDCommand] {
        await elm327.getSupportedPIDs()
    }

    /// Returns the vehicle's status.
    ///  - Returns: The readiness status (`DecodeResult.statusResult`).
    ///  - Throws: Errors that might occur during the request process.
    public func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        try await sendCommand(.mode1(.status))
    }

    /// Sends a raw command to the adapter and returns the lines it answered.
    /// - Parameter message: The raw command to send, AT command or hexadecimal OBD request.
    /// - Returns: The raw response lines.
    /// - Throws: `OBDServiceError.commandFailed` when the adapter reports an error instead of data.
    public func sendCommandInternal(_ message: String, retries: Int) async throws -> [String] {
        do {
            return try await elm327.sendCommand(message, retries: retries)
        } catch {
            throw OBDServiceError.commandFailed(command: message, error: error)
        }
    }

    // MARK: - Response helpers

    /// The data bytes of an answer to `command`: what follows the service byte and the echoed
    /// parameters. `nil` when the message answers something else.
    static func dataBytes(for command: OBDCommand, in message: Message) -> Data? {
        if case let .custom(custom) = command {
            return custom.dataBytes(in: message.payload)
        }
        guard let service = command.service, message.serviceID == service &+ 0x40 else { return nil }

        switch command.properties.decoder {
        case .dtc:
            return message.troubleCodeBytes
        case .monitor:
            // Monitor results repeat the monitor identifier in each record.
            return Data(message.payload.dropFirst())
        default:
            var bytes = [UInt8](message.payload.dropFirst())
            for echoed in command.parameterBytes {
                guard bytes.first == echoed else { return nil }
                bytes.removeFirst()
            }
            return Data(bytes)
        }
    }

    /// Splits answers to a grouped service 01 request (`41 0C 1A F8 0D 32…`) into the data bytes of each PID.
    static func splitService01(_ messages: [Message]) -> [UInt8: Data] {
        var values: [UInt8: Data] = [:]
        for message in ELM327.engineFirst(messages) {
            let bytes = [UInt8](message.payload)
            guard bytes.first == 0x41 else { continue }

            var index = 1
            while index < bytes.count {
                let pid = bytes[index]
                guard let length = OBDCommand.from(command: [0x01, pid].hexString)?.properties.bytes,
                      length > 0, index + length < bytes.count
                else { break }
                if values[pid] == nil {
                    values[pid] = Data(bytes[index + 1 ... index + length])
                }
                index += 1 + length
            }
        }
        return values
    }

    private static func measurement(_ command: OBDCommand, _ data: Data, _ unit: MeasurementUnit) -> MeasurementResult? {
        switch command.properties.decode(data: data, unit: unit) {
        case let .success(result):
            return result.measurementResult
        case let .failure(error):
            obdDebug("Failed to decode \(command.properties.command): \(error.localizedDescription) | Data: \(data.hexString)", category: .parsing)
            return nil
        }
    }

    /// `true` when the error only means that this particular request got no usable answer.
    static func isAnswerMissing(_ error: Error) -> Bool {
        guard let error = error as? ELM327Error else { return error is ParserError }
        switch error {
        case .noData, .negativeResponse, .invalidResponse, .busError, .bufferFull, .stopped, .unknownCommand:
            return true
        default:
            return false
        }
    }

    /// `true` when there is no point in trying again without reconnecting.
    static func isConnectionLost(_ error: Error) -> Bool {
        switch error {
        case OBDServiceError.notConnectedToVehicle, CommunicationError.notConnected, CommunicationError.disconnected:
            return true
        default:
            return false
        }
    }

    static func translate(_ error: Error) -> Error {
        if case ELM327Error.noProtocolFound = error {
            return OBDServiceError.notConnectedToVehicle
        }
        return error
    }
}

public enum OBDServiceError: Error, LocalizedError {
    case noAdapterFound
    case notConnectedToVehicle
    case adapterConnectionFailed(underlyingError: Error)
    case scanFailed(underlyingError: Error)
    case clearFailed(underlyingError: Error)
    case commandFailed(command: String, error: Error)
    /// The vehicle, or the protocol it uses, does not offer this feature.
    case notSupported(String)

    public var errorDescription: String? {
        switch self {
        case .noAdapterFound:
            return "No OBD adapter found."
        case .notConnectedToVehicle:
            return "Not connected to a vehicle."
        case let .adapterConnectionFailed(error):
            return "Connection failed: \(error.localizedDescription)"
        case let .scanFailed(error):
            return "Scan failed: \(error.localizedDescription)"
        case let .clearFailed(error):
            return "Could not clear the trouble codes: \(error.localizedDescription)"
        case let .commandFailed(command, error):
            return "Command \(command) failed: \(error.localizedDescription)"
        case let .notSupported(reason):
            return reason
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

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
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
}
