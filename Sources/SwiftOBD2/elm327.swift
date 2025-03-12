// MARK: - ELM327 Class Documentation

/// `Author`: Kemo Konteh
/// The `ELM327` class provides a comprehensive interface for interacting with an ELM327-compatible
/// OBD-II adapter. It handles adapter setup, vehicle connection, protocol detection, and
/// communication with the vehicle's ECU.
///
/// **Key Responsibilities:**
/// * Manages communication with a BLE OBD-II adapter
/// * Automatically detects and establishes the appropriate OBD-II protocol
/// * Sends commands to the vehicle's ECU
/// * Parses and decodes responses from the ECU
/// * Retrieves vehicle information (e.g., VIN)
/// * Monitors vehicle status and retrieves diagnostic trouble codes (DTCs)

import Combine
import CoreBluetooth
import Foundation
import OSLog

enum ELM327Error: Error, LocalizedError {
    case noProtocolFound
    case invalidResponse(message: String)
    case adapterInitializationFailed
    case ignitionOff
    case invalidProtocol
    case timeout
    case connectionFailed(reason: String)
    case unknownError

    var errorDescription: String? {
        switch self {
        case .noProtocolFound:
            return "No compatible OBD protocol found."
        case let .invalidResponse(message):
            return "Invalid response received: \(message)"
        case .adapterInitializationFailed:
            return "Failed to initialize adapter."
        case .ignitionOff:
            return "Vehicle ignition is off."
        case .invalidProtocol:
            return "Invalid or unsupported OBD protocol."
        case .timeout:
            return "Operation timed out."
        case let .connectionFailed(reason):
            return "Connection failed: \(reason)"
        case .unknownError:
            return "An unknown error occurred."
        }
    }
}

class ELM327 {
    //    private var obdProtocol: PROTOCOL = .NONE
    var canProtocol: CANProtocol?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.com", category: "ELM327")
    private var comm: CommProtocol

    private var cancellables = Set<AnyCancellable>()

    weak var obdDelegate: OBDServiceDelegate? {
        didSet {
            comm.obdDelegate = obdDelegate
        }
    }

    private var r100: [String] = []

    var connectionState: ConnectionState = .disconnected {
        didSet {
            obdDelegate?.connectionStateChanged(state: connectionState)
        }
    }

    init(comm: CommProtocol) {
        self.comm = comm
        setupConnectionStateSubscriber()
    }

    private func setupConnectionStateSubscriber() {
        comm.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.obdDelegate?.connectionStateChanged(state: state)
                self?.logger.debug("Connection state updated: \(state.hashValue)")
            }
            .store(in: &cancellables)
    }

    // MARK: - Adapter and Vehicle Setup

    /// Sets up the vehicle connection, including automatic protocol detection.
    /// - Parameter preferedProtocol: An optional preferred protocol to attempt first.
    /// - Returns: A tuple containing the established OBD protocol and the vehicle's VIN (if available).
    /// - Throws:
    ///     - `SetupError.noECUCharacteristic` if the required OBD characteristic is not found.
    ///     - `SetupError.invalidResponse(message: String)` if the adapter's response is unexpected.
    ///     - `SetupError.noProtocolFound` if no compatible protocol can be established.
    ///     - `SetupError.adapterInitFailed` if initialization of adapter failed.
    ///     - `SetupError.timeout` if a response times out.
    ///     - `SetupError.peripheralNotFound` if the peripheral could not be found.
    ///     - `SetupError.ignitionOff` if the vehicle's ignition is not on.
    ///     - `SetupError.invalidProtocol` if the protocol is not recognized.
    func setupVehicle(preferredProtocol: PROTOCOL?) async throws -> OBDInfo {
        //        var obdProtocol: PROTOCOL?
        let detectedProtocol = try await detectProtocol(preferredProtocol: preferredProtocol)

        //        guard let obdProtocol = detectedProtocol else {
        //            throw SetupError.noProtocolFound
        //        }

        //        self.obdProtocol = obdProtocol
        canProtocol = protocols[detectedProtocol]

        let vin = await requestVin()

        //        try await setHeader(header: "7E0")

        let supportedPIDs = await getSupportedPIDs()

        guard let messages = try canProtocol?.parse(r100) else {
            throw ELM327Error.invalidResponse(message: "Invalid response to 0100")
        }

        let ecuMap = populateECUMap(messages)

        connectionState = .connectedToVehicle
        return OBDInfo(vin: vin, supportedPIDs: supportedPIDs, obdProtocol: detectedProtocol, ecuMap: ecuMap)
    }

    // MARK: - Protocol Selection

    /// Detects the appropriate OBD protocol by attempting preferred and fallback protocols.
    /// - Parameter preferredProtocol: An optional preferred protocol to attempt first.
    /// - Returns: The detected `PROTOCOL`.
    /// - Throws: `ELM327Error` if detection fails.
    private func detectProtocol(preferredProtocol: PROTOCOL? = nil) async throws -> PROTOCOL {
        logger.info("Starting protocol detection...")

        if let protocolToTest = preferredProtocol {
            logger.info("Attempting preferred protocol: \(protocolToTest.description)")
            if await testProtocol(protocolToTest) {
                return protocolToTest
            } else {
                logger.warning("Preferred protocol \(protocolToTest.description) failed. Falling back to automatic detection.")
            }
        } else {
            do {
                return try await detectProtocolAutomatically()
            } catch {
                return try await detectProtocolManually()
            }
        }

        logger.error("Failed to detect a compatible OBD protocol.")
        throw ELM327Error.noProtocolFound
    }

    /// Attempts to detect the OBD protocol automatically.
    /// - Returns: The detected protocol, or nil if none could be found.
    /// - Throws: Various setup-related errors.
    private func detectProtocolAutomatically() async throws -> PROTOCOL {
        _ = try await okResponse("ATSP0")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        _ = try await sendCommand("0100")

        let obdProtocolNumber = try await sendCommand("ATDPN")

        guard let obdProtocol = PROTOCOL(rawValue: String(obdProtocolNumber[0].dropFirst())) else {
            throw ELM327Error.invalidResponse(message: "Invalid protocol number: \(obdProtocolNumber)")
        }

        _ = await testProtocol(obdProtocol)

        return obdProtocol
    }

    /// Attempts to detect the OBD protocol manually.
    /// - Parameter desiredProtocol: An optional preferred protocol to attempt first.
    /// - Returns: The detected protocol, or nil if none could be found.
    /// - Throws: Various setup-related errors.
    private func detectProtocolManually() async throws -> PROTOCOL {
        for protocolOption in PROTOCOL.allCases where protocolOption != .NONE {
            self.logger.info("Testing protocol: \(protocolOption.description)")
            _ = try await okResponse(protocolOption.cmd)
            if await testProtocol(protocolOption) {
                return protocolOption
            }
        }
        /// If we reach this point, no protocol was found
        logger.error("No protocol found")
        throw ELM327Error.noProtocolFound
    }

    // MARK: - Protocol Testing

    /// Tests a given protocol by sending a 0100 command and checking for a valid response.
    /// - Parameter obdProtocol: The protocol to test.
    /// - Throws: Various setup-related errors.
    private func testProtocol(_ obdProtocol: PROTOCOL) async -> Bool {
        // test protocol by sending 0100 and checking for 41 00 response
        let response = try? await sendCommand("0100", retries: 3)

        if let response = response,
           response.contains(where: { $0.range(of: #"41\s*00"#, options: .regularExpression) != nil }) {
            logger.info("Protocol \(obdProtocol.description) is valid.")
            r100 = response
            return true
        } else {
            logger.warning("Protocol \(obdProtocol.rawValue) did not return valid 0100 response.")
            return false
        }
    }

    // MARK: - Adapter Initialization

    func connectToAdapter(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        try await comm.connectAsync(timeout: timeout, peripheral: peripheral)
    }

    /// Initializes the adapter by sending a series of commands.
    /// - Parameter setupOrder: A list of commands to send in order.
    /// - Throws: Various setup-related errors.
    func adapterInitialization() async throws {
        //        [.ATZ, .ATD, .ATL0, .ATE0, .ATH1, .ATAT1, .ATRV, .ATDPN]
        logger.info("Initializing ELM327 adapter...")
        do {
            _ = try await sendCommand("ATZ") // Reset adapter
            _ = try await okResponse("ATE0") // Echo off
            _ = try await okResponse("ATL0") // Linefeeds off
            _ = try await okResponse("ATS0") // Spaces off
            _ = try await okResponse("ATH1") // Headers off
            _ = try await okResponse("ATSP0") // Set protocol to automatic
            logger.info("ELM327 adapter initialized successfully.")
        } catch {
            logger.error("Adapter initialization failed: \(error.localizedDescription)")
            throw ELM327Error.adapterInitializationFailed
        }
    }

    private func setHeader(header: String) async throws {
        _ = try await okResponse("AT SH " + header)
    }

    func stopConnection() {
        comm.disconnectPeripheral()
        connectionState = .disconnected
    }

    // MARK: - Message Sending

    func sendCommand(_ message: String, retries: Int = 1) async throws -> [String] {
        try await comm.sendCommand(message, retries: retries)
    }

    private func okResponse(_ message: String) async throws -> [String] {
        let response = try await sendCommand(message)
        if response.contains("OK") {
            return response
        } else {
            logger.error("Invalid response: \(response)")
            throw ELM327Error.invalidResponse(message: "message: \(message), \(String(describing: response.first))")
        }
    }

    func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        logger.info("Getting status")
        let statusCommand = OBDCommand.Mode1.status
        let statusResponse = try await sendCommand(statusCommand.properties.command)
        logger.debug("Status response: \(statusResponse)")
        guard let statusData = try canProtocol?.parse(statusResponse).first?.data else {
            return .failure(.noData)
        }
        return statusCommand.properties.decode(data: statusData)
    }

    func scanForTroubleCodes() async throws -> [ECUID: [TroubleCode]] {
        var dtcs: [ECUID: [TroubleCode]] = [:]
        logger.info("Scanning for trouble codes")
        let dtcCommand = OBDCommand.Mode3.GET_DTC
        let dtcResponse = try await sendCommand(dtcCommand.properties.command)

        guard let messages = try canProtocol?.parse(dtcResponse) else {
            return [:]
        }
        for message in messages {
            guard let dtcData = message.data else {
                continue
            }
            let decodedResult = dtcCommand.properties.decode(data: dtcData)

            let ecuId = message.ecu
            switch decodedResult {
            case let .success(result):
                dtcs[ecuId] = result.troubleCode

            case let .failure(error):
                logger.error("Failed to decode DTC: \(error)")
            }
        }

        return dtcs
    }

    func clearTroubleCodes() async throws {
        let command = OBDCommand.Mode4.CLEAR_DTC
        _ = try await sendCommand(command.properties.command)
    }

    func scanForPeripherals() async throws {
        try await comm.scanForPeripherals()
    }

    func requestVin() async -> String? {
        let command = OBDCommand.Mode9.VIN
        guard let vinResponse = try? await sendCommand(command.properties.command) else {
            return nil
        }

        guard let data = try? canProtocol?.parse(vinResponse).first?.data,
              var vinString = String(bytes: data, encoding: .utf8)
        else {
            return nil
        }

        vinString = vinString
            .replacingOccurrences(of: "[^a-zA-Z0-9]",
                                  with: "",
                                  options: .regularExpression)

        return vinString
    }
}

extension ELM327 {
    private func populateECUMap(_ messages: [MessageProtocol]) -> [UInt8: ECUID]? {
        let engineTXID = 0
        let transmissionTXID = 1
        var ecuMap: [UInt8: ECUID] = [:]

        // If there are no messages, return an empty map
        guard !messages.isEmpty else {
            return nil
        }

        // If there is only one message, assume it's from the engine
        if messages.count == 1 {
            ecuMap[messages.first?.ecu.rawValue ?? 0] = .engine
            return ecuMap
        }

        // Find the engine and transmission ECU based on TXID
        var foundEngine = false

        for message in messages {
            let txID = message.ecu.rawValue

            if txID == engineTXID {
                ecuMap[txID] = .engine
                foundEngine = true
            } else if txID == transmissionTXID {
                ecuMap[txID] = .transmission
            }
        }

        // If engine ECU is not found, choose the one with the most bits
        if !foundEngine {
            var bestBits = 0
            var bestTXID: UInt8?

            for message in messages {
                guard let bits = message.data?.bitCount() else {
                    logger.error("parse_frame failed to extract data")
                    continue
                }
                if bits > bestBits {
                    bestBits = bits
                    bestTXID = message.ecu.rawValue
                }
            }

            if let bestTXID = bestTXID {
                ecuMap[bestTXID] = .engine
            }
        }

        // Assign transmission ECU to messages without an ECU assignment
        for message in messages where ecuMap[message.ecu.rawValue] == nil {
            ecuMap[message.ecu.rawValue] = .transmission
        }

        return ecuMap
    }
}

extension ELM327 {
    /// Get the supported PIDs
    /// - Returns: Array of supported PIDs
    func getSupportedPIDs() async -> [OBDCommand] {
        let pidGetters = OBDCommand.pidGetters
        var supportedPIDs: [OBDCommand] = []

        for pidGetter in pidGetters {
            do {
                logger.info("Getting supported PIDs for \(pidGetter.properties.command)")
                let response = try await sendCommand(pidGetter.properties.command)
                // find first instance of 41 plus command sent, from there we determine the position of everything else
                // Ex.
                //        || ||
                // 7E8 06 41 00 BE 7F B8 13
                guard let supportedPidsByECU = parseResponse(response) else {
                    continue
                }

                let supportedCommands = OBDCommand.allCommands
                    .filter { supportedPidsByECU.contains(String($0.properties.command.dropFirst(2))) }
                    .map { $0 }

                supportedPIDs.append(contentsOf: supportedCommands)
            } catch {
                logger.error("\(error.localizedDescription)")
            }
        }
        // filter out pidGetters
        supportedPIDs = supportedPIDs.filter { !pidGetters.contains($0) }

        // remove duplicates
        return Array(Set(supportedPIDs))
    }

    private func parseResponse(_ response: [String]) -> Set<String>? {
        guard let ecuData = try? canProtocol?.parse(response).first?.data else {
            return nil
        }
        let binaryData = BitArray(data: ecuData.dropFirst()).binaryArray
        return extractSupportedPIDs(binaryData)
    }

    func extractSupportedPIDs(_ binaryData: [Int]) -> Set<String> {
        var supportedPIDs: Set<String> = []

        for (index, value) in binaryData.enumerated() {
            if value == 1 {
                let pid = String(format: "%02X", index + 1)
                supportedPIDs.insert(pid)
            }
        }
        return supportedPIDs
    }
}

struct BatchedResponse {
    private var response: Data
    private var unit: MeasurementUnit
    init(response: Data, _ unit: MeasurementUnit) {
        self.response = response
        self.unit = unit
    }

    mutating func extractValue(_ cmd: OBDCommand) -> MeasurementResult? {
        let properties = cmd.properties
        let size = properties.bytes
        guard response.count >= size else { return nil }
        let valueData = response.prefix(size)

        response.removeFirst(size)
        //        print("Buffer: \(buffer.compactMap { String(format: "%02X ", $0) }.joined())")
        let result = cmd.properties.decode(data: valueData, unit: unit)

        

        switch result {
        case let .success(measurementResult):
            return measurementResult.measurementResult
        case let .failure(error):
            print("Failed to decode \(cmd.properties.command): \(error.localizedDescription)")
            return nil
        }
    }
}

extension String {
    var hexBytes: [UInt8] {
        var position = startIndex
        return (0 ..< count / 2).compactMap { _ in
            defer { position = index(position, offsetBy: 2) }
            return UInt8(self[position ... index(after: position)], radix: 16)
        }
    }

    var isHex: Bool {
        !isEmpty && allSatisfy(\.isHexDigit)
    }
}

extension Data {
    func bitCount() -> Int {
        count * 8
    }
}

enum ECUHeader {
    static let ENGINE = "7E0"
}

// Possible setup errors
// enum SetupError: Error {
//    case noECUCharacteristic
//    case invalidResponse(message: String)
//    case noProtocolFound
//    case adapterInitFailed
//    case timeout
//    case peripheralNotFound
//    case ignitionOff
//    case invalidProtocol
// }

public struct OBDInfo: Codable, Hashable {
    public var vin: String?
    public var supportedPIDs: [OBDCommand]?
    public var obdProtocol: PROTOCOL?
    public var ecuMap: [UInt8: ECUID]?
}
