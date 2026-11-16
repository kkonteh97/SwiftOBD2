// MARK: - ELM327 Class Documentation

/// `Author`: Kemo Konteh
/// The `ELM327` class drives an ELM327-compatible OBD-II adapter, whatever the transport used to
/// reach it (Bluetooth LE, Wi-Fi, mock).
///
/// **Key Responsibilities:**
/// * Initialises the adapter and keeps track of its settings (headers, addressing, timing)
/// * Detects and establishes the appropriate OBD-II protocol
/// * Serialises the commands: one request at a time, multi-step exchanges are atomic
/// * Turns the adapter's textual answers into typed errors or ECU messages
/// * Retrieves the identity of the vehicle (VIN, ECUs, supported PIDs)

import Combine
import CoreBluetooth
import Foundation

public enum ELM327Error: Error, LocalizedError {
    case noProtocolFound
    case invalidResponse(message: String)
    case adapterInitializationFailed
    case ignitionOff
    case invalidProtocol
    case timeout
    case connectionFailed(reason: String)
    case unknownError
    /// The vehicle did not answer the request (`NO DATA`): usually an unsupported PID.
    case noData
    /// The adapter could not open the bus (`UNABLE TO CONNECT`, `BUS INIT: ERROR`): ignition off
    /// or protocol not supported by the vehicle.
    case unableToConnect
    /// A bus level problem reported by the adapter (`CAN ERROR`, `BUS BUSY`, `DATA ERROR`…).
    case busError(String)
    /// The answer was longer than the adapter's buffer (`BUFFER FULL`).
    case bufferFull
    /// The adapter was interrupted while working (`STOPPED`).
    case stopped
    /// The adapter does not understand the command (`?`).
    case unknownCommand(String)
    /// The ECU refused the request (`7F <service> <code>`).
    case negativeResponse(service: UInt8, code: UInt8)

    public var errorDescription: String? {
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
        case .noData:
            return "The vehicle returned no data."
        case .unableToConnect:
            return "The adapter is unable to connect to the vehicle. Check that the ignition is on."
        case let .busError(message):
            return "Bus error: \(message)"
        case .bufferFull:
            return "The adapter buffer overflowed."
        case .stopped:
            return "The adapter was interrupted."
        case let .unknownCommand(command):
            return "The adapter does not support the command \(command)."
        case let .negativeResponse(service, code):
            return "The ECU rejected service \(String(format: "%02X", service)): \(ELM327Error.negativeResponseDescription(code))"
        }
    }

    /// Worth trying again: the failure comes from the state of the bus, not from the request.
    var isTransient: Bool {
        switch self {
        case .busError, .bufferFull, .stopped: return true
        default: return false
        }
    }

    /// The meaning of the most common negative response codes (ISO 14229).
    public static func negativeResponseDescription(_ code: UInt8) -> String {
        switch code {
        case 0x10: return "general reject"
        case 0x11: return "service not supported"
        case 0x12: return "sub-function not supported"
        case 0x13: return "incorrect message length or invalid format"
        case 0x14: return "response too long"
        case 0x21: return "busy, repeat request"
        case 0x22: return "conditions not correct"
        case 0x24: return "request sequence error"
        case 0x31: return "request out of range"
        case 0x33: return "security access denied"
        case 0x35: return "invalid key"
        case 0x36: return "exceeded number of attempts"
        case 0x37: return "required time delay not expired"
        case 0x78: return "response pending"
        case 0x7E: return "sub-function not supported in active session"
        case 0x7F: return "service not supported in active session"
        default: return "code \(String(format: "%02X", code))"
        }
    }
}

/// Tunes how the library talks to the adapter.
public struct OBDConfiguration {
    /// How aggressively the adapter shortens the time it waits for ECUs to answer (`AT AT`).
    public enum AdaptiveTiming: Int {
        case off = 0
        case normal = 1
        case aggressive = 2
    }

    /// Address of a Wi-Fi adapter. Most of them use `192.168.0.10`.
    public var wifiHost: String = "192.168.0.10"
    /// TCP port of a Wi-Fi adapter. Most of them use `35000`.
    public var wifiPort: UInt16 = 35000
    /// Longest time to wait for the answer to a command.
    public var commandTimeout: TimeInterval = 5
    /// Longest time to wait while the adapter searches for the vehicle protocol (slow initialisation
    /// of ISO 9141 / KWP2000 alone takes several seconds).
    public var protocolDetectionTimeout: TimeInterval = 20
    public var adaptiveTiming: AdaptiveTiming = .normal
    /// How many PIDs to ask for in a single request on CAN vehicles (1 to 6). The library falls
    /// back to one PID per request when the vehicle does not support grouping.
    public var maxPIDsPerRequest: Int = 6
    /// Tells the adapter to stop listening after the first answer to a single PID request instead
    /// of waiting for its time-out. Roughly doubles the polling rate, but answers from a second
    /// ECU are lost: leave it off unless a single ECU answers the PIDs you poll.
    public var stopsAfterFirstResponse: Bool = false

    public init() {}

    public init(wifiHost: String, wifiPort: UInt16 = 35000) {
        self.wifiHost = wifiHost
        self.wifiPort = wifiPort
    }
}

class ELM327 {
    private let comm: CommProtocol
    /// Serialises every exchange with the adapter.
    private let gate = AsyncLock()
    private let stateLock = NSLock()
    private var cancellables = Set<AnyCancellable>()

    var configuration: OBDConfiguration

    weak var obdDelegate: OBDServiceDelegate?

    private var storedConnectionState: ConnectionState = .disconnected

    var connectionState: ConnectionState {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedConnectionState
        }
        set {
            stateLock.lock()
            let changed = storedConnectionState != newValue
            storedConnectionState = newValue
            stateLock.unlock()
            if changed {
                obdDelegate?.connectionStateChanged(state: newValue)
            }
        }
    }

    // MARK: Session state (only touched while holding `gate`)

    /// The protocol negotiated with the vehicle.
    private(set) var obdProtocol: PROTOCOL?
    /// What the adapter says about itself (`ELM327 v1.5`…).
    private(set) var adapterIdentifier: String?
    /// Battery voltage measured by the adapter during its initialisation.
    private(set) var adapterVoltage: Double?
    /// Answers to the first `0100`, kept to identify the ECUs and their supported PIDs.
    private var initialResponse: [Message] = []
    private var ecuRoles: [UInt32: ECUID] = [:]
    /// The ECU the adapter is currently addressing, `nil` for the OBD-II broadcast address.
    private var currentTarget: ECUTarget?
    /// Set when the addressing of the adapter may not match `currentTarget` any more.
    private var addressingIsDirty = false
    private var usesCustomFlowControl = false

    var canProtocol: CANProtocol? {
        obdProtocol?.parser
    }

    init(comm: CommProtocol, configuration: OBDConfiguration = OBDConfiguration()) {
        self.comm = comm
        self.configuration = configuration
        setupConnectionStateSubscriber()
    }

    private func setupConnectionStateSubscriber() {
        comm.connectionStatePublisher
            .sink { [weak self] state in
                guard let self = self else { return }
                // The transport only knows about the adapter: do not let it downgrade a
                // connection that already reached the vehicle.
                if state == .connectedToAdapter, self.connectionState == .connectedToVehicle { return }
                self.connectionState = state
            }
            .store(in: &cancellables)
    }

    // MARK: - Adapter and Vehicle Setup

    func connectToAdapter(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        try await comm.connectAsync(timeout: timeout, peripheral: peripheral)
    }

    /// Resets the adapter and configures the way it formats its answers.
    func adapterInitialization() async throws {
        obdInfo("Initializing ELM327 adapter...", category: .connection)
        try await gate.withLock {
            resetSession()
            do {
                // A full reset takes about a second and some clones answer it with garbage, or
                // not at all: carry on as long as the adapter obeys the next command.
                let reset = try? await transact("ATZ", timeout: max(configuration.commandTimeout, 6))

                // Echo off first, so that later answers do not start with the command itself.
                do {
                    try await at("ATE0")
                } catch let error as CommunicationError {
                    throw error
                } catch {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    try await at("ATE0")
                }
                try await at("ATL0") // Linefeeds off
                try await at("ATS0") // Spaces off
                try await at("ATH1") // Headers on: needed to tell the ECUs apart
                _ = try? await at("ATAT\(configuration.adaptiveTiming.rawValue)")

                let isIdentity: (String) -> Bool = { line in
                    let upper = line.uppercased()
                    return upper.contains("ELM") || upper.contains("STN") || upper.contains("OBD")
                }
                if let identity = reset?.first(where: isIdentity) {
                    adapterIdentifier = identity
                } else {
                    adapterIdentifier = (try? await transact("ATI"))?.first
                }
                adapterVoltage = try? await readVoltage()
                obdInfo("Adapter initialized: \(adapterIdentifier ?? "unknown")", category: .connection)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                obdError("Adapter initialization failed: \(error.localizedDescription)", category: .connection)
                throw ELM327Error.adapterInitializationFailed
            }
        }
    }

    /// Sets up the vehicle connection, including automatic protocol detection.
    /// - Parameter preferredProtocol: An optional protocol to attempt first.
    /// - Returns: What is known about the vehicle: protocol, VIN, ECUs and supported commands.
    /// - Throws: `ELM327Error.noProtocolFound` if no protocol gets an answer from the vehicle.
    func setupVehicle(preferredProtocol: PROTOCOL?) async throws -> OBDInfo {
        let detectedProtocol = try await gate.withLock {
            try await detectProtocol(preferredProtocol: preferredProtocol)
        }

        let vin = await requestVin()
        let supportedPIDs = await getSupportedPIDs()
        let ecuMap = await gate.withLock {
            Dictionary(ecuRoles.map { (UInt8(truncatingIfNeeded: $0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        }

        connectionState = .connectedToVehicle
        return OBDInfo(vin: vin,
                       supportedPIDs: supportedPIDs,
                       obdProtocol: detectedProtocol,
                       ecuMap: ecuMap.isEmpty ? nil : ecuMap,
                       adapter: adapterIdentifier,
                       voltage: adapterVoltage)
    }

    func stopConnection() {
        comm.disconnectPeripheral()
        connectionState = .disconnected
    }

    func scanForPeripherals() async throws {
        try await comm.scanForPeripherals()
    }

    private func resetSession() {
        obdProtocol = nil
        initialResponse = []
        ecuRoles = [:]
        currentTarget = nil
        addressingIsDirty = false
        usesCustomFlowControl = false
    }

    // MARK: - Protocol Selection

    /// The order in which protocols are tried when the adapter's own search fails: CAN first, it
    /// equips every car sold since 2008.
    static let searchOrder: [PROTOCOL] = [
        .protocol6, .protocol7, .protocol8, .protocol9,
        .protocol5, .protocol4, .protocol3, .protocol2, .protocol1,
        .protocolB, .protocolC,
    ]

    /// Detects the appropriate OBD protocol: the preferred one, then the adapter's automatic
    /// search, then each protocol in turn.
    private func detectProtocol(preferredProtocol: PROTOCOL? = nil) async throws -> PROTOCOL {
        obdInfo("Starting protocol detection...", category: .protocol)

        if let preferred = preferredProtocol, preferred != .NONE {
            if try await probe(preferred, selectingWith: "ATSP\(preferred.rawValue)") {
                return preferred
            }
            obdWarning("Preferred protocol \(preferred.description) failed. Falling back to automatic detection.", category: .protocol)
        }

        if let detected = try await detectProtocolAutomatically() {
            return detected
        }

        for candidate in ELM327.searchOrder where candidate != preferredProtocol {
            if try await probe(candidate, selectingWith: "ATTP\(candidate.rawValue)") {
                return candidate
            }
        }

        obdError("Failed to detect a compatible OBD protocol.", category: .protocol)
        throw ELM327Error.noProtocolFound
    }

    /// Lets the adapter search for the protocol by itself, then asks which one it settled on.
    private func detectProtocolAutomatically() async throws -> PROTOCOL? {
        do {
            try await at("ATSP0")
            let lines = try await transact("0100", timeout: configuration.protocolDetectionTimeout)
            let answer = try await transact("ATDPN")

            // "A6" when found by the automatic search, "6" otherwise
            var number = answer.first?.compactUppercased ?? ""
            if number.count > 1, number.hasPrefix("A") { number.removeFirst() }
            guard let detected = PROTOCOL(rawValue: number), detected != .NONE else {
                obdWarning("Unexpected protocol number: \(answer)", category: .protocol)
                return nil
            }
            return adopt(detected, answerTo0100: lines) ? detected : nil
        } catch let error as ELM327Error {
            obdDebug("Automatic protocol detection failed: \(error.localizedDescription)", category: .protocol)
            return nil
        }
    }

    /// Selects a protocol and checks that the vehicle answers on it.
    private func probe(_ candidate: PROTOCOL, selectingWith command: String) async throws -> Bool {
        obdDebug("Testing protocol: \(candidate.description)", category: .protocol)
        do {
            try await at(command)
            let lines = try await transact("0100", timeout: configuration.protocolDetectionTimeout)
            return adopt(candidate, answerTo0100: lines)
        } catch let error as ELM327Error {
            obdDebug("Protocol \(candidate.rawValue) did not answer: \(error.localizedDescription)", category: .protocol)
            return false
        }
    }

    /// Makes `candidate` the session protocol if `lines` holds a valid answer to `0100`.
    private func adopt(_ candidate: PROTOCOL, answerTo0100 lines: [String]) -> Bool {
        guard let parser = candidate.parser,
              let messages = try? parser.parse(lines)
        else { return false }

        let answers = messages.filter { $0.payload.starts(with: [0x41, 0x00]) }
        guard !answers.isEmpty else { return false }

        obdProtocol = candidate
        ecuRoles = ELM327.assignRoles(answers)
        initialResponse = answers.map(withRole)
        currentTarget = nil
        addressingIsDirty = false
        OBDLogger.shared.logProtocolEvent("Protocol established", protocol: candidate.description, details: "\(answers.count) ECU(s)")
        return true
    }

    /// Decides which ECU is the engine, from the answers to `0100`.
    static func assignRoles(_ messages: [Message]) -> [UInt32: ECUID] {
        var roles: [UInt32: ECUID] = [:]
        for message in messages {
            roles[message.address] = message.ecu
        }

        if messages.count == 1, let only = messages.first {
            // A single ECU answering emission related requests is the engine.
            roles[only.address] = .engine
        } else if !roles.values.contains(.engine),
                  let richest = messages.max(by: { $0.payload.dropFirst(2).bitCount() < $1.payload.dropFirst(2).bitCount() }) {
            // No conventional engine address: pick the ECU supporting the most PIDs.
            roles[richest.address] = .engine
        }
        return roles
    }

    private func withRole(_ message: Message) -> Message {
        var message = message
        if let role = ecuRoles[message.address] {
            message.ecu = role
        }
        return message
    }

    // MARK: - Message Sending

    /// Sends a raw command (AT or OBD) and returns the lines answered by the adapter.
    /// - Throws: `ELM327Error` when the adapter reports a problem instead of data.
    func sendCommand(_ message: String, retries: Int = 1) async throws -> [String] {
        try await gate.withLock {
            let command = message.compactUppercased
            // A manual change of addressing invalidates what we believe the adapter is set to.
            if ["ATSH", "ATCRA", "ATAR", "ATCP", "ATFC", "ATSP", "ATTP", "ATD", "ATZ", "ATWS", "ATSR"].contains(where: command.hasPrefix) {
                addressingIsDirty = true
            }
            return try await transact(message, retries: retries)
        }
    }

    /// Sends an OBD request and returns the positive answers of the ECUs.
    /// - Parameters:
    ///   - command: the request bytes in hexadecimal, e.g. `010C` or `22F190`.
    ///   - target: the ECU to address, `nil` to broadcast.
    ///   - singleResponse: ask the adapter to return as soon as one frame is received.
    /// - Throws: `ELM327Error.noData` when nothing answers, `.negativeResponse` when the request is
    ///   refused, transport errors when the link fails.
    func request(_ command: String,
                 target: ECUTarget? = nil,
                 retries: Int = 1,
                 singleResponse: Bool = false) async throws -> [Message] {
        try await gate.withLock {
            guard let obdProtocol = obdProtocol, let parser = obdProtocol.parser else {
                throw ELM327Error.noProtocolFound
            }
            try await select(target)

            let request = command.compactUppercased
            guard request.isHex, request.count % 2 == 0 else {
                throw ELM327Error.invalidResponse(message: "\"\(command)\" is not a valid request")
            }
            let hint = singleResponse && obdProtocol.isCAN ? "1" : ""
            let lines = try await transact(request + hint, retries: retries)
            return try ELM327.interpret(lines, request: request, parser: parser).map(withRole)
        }
    }

    /// Extracts the positive answers to `request` from the lines printed by the adapter.
    static func interpret(_ lines: [String], request: String, parser: CANProtocol) throws -> [Message] {
        var messages = try parser.parse(lines)
        // "Response pending" only announces that the real answer follows.
        messages.removeAll(where: \.isResponsePending)

        let expectedService = request.hexBytes.first.map { $0 &+ 0x40 }
        let positives = messages.filter { !$0.isNegativeResponse && $0.serviceID == expectedService }
        guard positives.isEmpty else { return positives }

        if let refusal = messages.first(where: \.isNegativeResponse) {
            throw ELM327Error.negativeResponse(service: refusal.payload[1], code: refusal.payload[2])
        }
        throw messages.isEmpty
            ? ELM327Error.noData
            : ELM327Error.invalidResponse(message: lines.joined(separator: " | "))
    }

    /// Sends one command, retrying when the failure is transient.
    private func transact(_ command: String, retries: Int = 1, timeout: TimeInterval? = nil) async throws -> [String] {
        let attempts = max(1, retries)
        var lastError: Error = ELM327Error.noData

        for attempt in 1 ... attempts {
            do {
                let started = CFAbsoluteTimeGetCurrent()
                let lines = try await comm.sendCommand(command, timeout: timeout ?? configuration.commandTimeout)
                let duration = CFAbsoluteTimeGetCurrent() - started
                obdDebug("\(command) → \(lines.joined(separator: " | ")) (\(String(format: "%.0f", duration * 1000)) ms)", category: .communication)
                return try ELM327.validate(lines, command: command)
            } catch let error as ELM327Error where error.isTransient {
                lastError = error
            } catch CommunicationError.timeout {
                lastError = ELM327Error.timeout
                await resynchronize()
            }

            if attempt < attempts {
                obdDebug("Retrying \(command) (\(attempt + 1)/\(attempts))", category: .communication)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw lastError
    }

    /// After a time-out the adapter may still be printing the answer to the previous command.
    /// Any character interrupts what it is doing: send a harmless command and let the line settle
    /// so that leftovers are not mistaken for the answer to the next request.
    private func resynchronize() async {
        _ = try? await comm.sendCommand("ATI", timeout: 1.5)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Sends an AT command that must be acknowledged with `OK`.
    @discardableResult
    private func at(_ command: String) async throws -> [String] {
        let response = try await transact(command)
        guard response.contains(where: { $0.uppercased().contains("OK") }) else {
            throw ELM327Error.invalidResponse(message: "\(command): \(response.first ?? "no answer")")
        }
        return response
    }

    /// Strips the informative lines of an answer and turns the adapter's error messages into errors.
    static func validate(_ lines: [String], command: String) throws -> [String] {
        let sent = command.compactUppercased
        var result: [String] = []
        var failure: ELM327Error?

        for line in lines {
            let upper = line.uppercased()

            if upper.filter({ !$0.isWhitespace }) == sent { continue } // echo
            if upper.hasPrefix("SEARCHING") { continue }
            if upper.contains("ACT ALERT") || upper.contains("LP ALERT") { continue }
            if upper.hasPrefix("BUS INIT") {
                // "BUS INIT: OK" or "BUS INIT: ...ERROR"
                if upper.contains("ERROR") { failure = failure ?? .unableToConnect }
                continue
            }

            if let error = adapterError(in: upper, command: command) {
                failure = failure ?? error
                continue
            }
            result.append(line)
        }

        if let failure = failure {
            // "NO DATA" next to actual data only means that one more ECU stayed silent.
            if case .noData = failure, !result.isEmpty { return result }
            throw failure
        }
        guard !result.isEmpty else { throw ELM327Error.noData }
        return result
    }

    private static func adapterError(in line: String, command: String) -> ELM327Error? {
        if line == "?" { return .unknownCommand(command) }
        if line.contains("NO DATA") { return .noData }
        if line.contains("UNABLE TO CONNECT") { return .unableToConnect }
        if line.contains("BUFFER FULL") { return .bufferFull }
        if line.contains("STOPPED") { return .stopped }
        for marker in ["CAN ERROR", "BUS BUSY", "BUS ERROR", "FB ERROR", "DATA ERROR", "RX ERROR", "LV RESET"] where line.contains(marker) {
            return .busError(marker)
        }
        if line.range(of: #"^ERR\d\d"#, options: .regularExpression) != nil { return .busError(line) }
        return nil
    }

    // MARK: - Addressing

    /// Points the adapter at one ECU, or back at the OBD-II broadcast address.
    private func select(_ target: ECUTarget?) async throws {
        guard target != currentTarget || addressingIsDirty else { return }
        guard let obdProtocol = obdProtocol else { throw ELM327Error.noProtocolFound }

        // If anything fails half-way, the next request starts over.
        addressingIsDirty = true

        if let previous = currentTarget, previous != target {
            for command in previous.teardownCommands {
                _ = try? await transact(command)
            }
        }

        if let target = target {
            try await setHeader(target.header)
            if obdProtocol.isCAN {
                if let receiveAddress = target.canReceiveAddress {
                    try await at("ATCRA\(receiveAddress)")
                } else {
                    _ = try? await at("ATAR")
                }
                // Long answers are segmented: the flow control frame that lets the ECU go on has
                // to come from the address the request was sent from.
                let flowControlHeader = target.header.count == 6 ? "18" + target.header : target.header
                if (try? await at("ATFCSH\(flowControlHeader)")) != nil,
                   (try? await at("ATFCSD300000")) != nil,
                   (try? await at("ATFCSM1")) != nil {
                    usesCustomFlowControl = true
                }
            } else if let receiveAddress = target.receiveAddress, !receiveAddress.isEmpty {
                _ = try? await at("ATSR\(receiveAddress)")
            }
            for command in target.setupCommands {
                _ = try await transact(command)
            }
        } else {
            if let header = obdProtocol.defaultHeader {
                try await setHeader(header)
            }
            if usesCustomFlowControl {
                _ = try? await at("ATFCSM0")
                usesCustomFlowControl = false
            }
            _ = try? await at("ATAR")
        }

        currentTarget = target
        addressingIsDirty = false
    }

    private func setHeader(_ header: String) async throws {
        if header.count == 8 {
            // 29 bit identifier: the first byte is the priority, set separately.
            try await at("ATCP\(header.prefix(2))")
            try await at("ATSH\(header.suffix(6))")
        } else {
            try await at("ATSH\(header)")
        }
    }

    // MARK: - Vehicle identity

    /// Battery voltage as measured by the adapter on the diagnostic connector.
    func requestVoltage() async throws -> Double {
        try await gate.withLock { try await readVoltage() }
    }

    private func readVoltage() async throws -> Double {
        let response = try await transact("ATRV")
        let digits = (response.first ?? "").filter { $0.isNumber || $0 == "." }
        guard let voltage = Double(digits) else {
            throw ELM327Error.invalidResponse(message: "ATRV: \(response)")
        }
        return voltage
    }

    func requestVin() async -> String? {
        guard let messages = try? await request("0902") else {
            return nil
        }

        for message in ELM327.engineFirst(messages) {
            // The identifier is surrounded by counters and padding bytes: keep what can be part of it.
            let characters = message.payload.dropFirst(2).filter {
                (0x30 ... 0x39).contains($0) || (0x41 ... 0x5A).contains($0) || (0x61 ... 0x7A).contains($0)
            }
            let vin = String(decoding: characters, as: UTF8.self)
            if !vin.isEmpty {
                return String(vin.suffix(17))
            }
        }
        return nil
    }

    /// Orders messages so that the engine ECU, the reference for vehicle data, comes first.
    static func engineFirst(_ messages: [Message]) -> [Message] {
        messages.filter { $0.ecu == .engine } + messages.filter { $0.ecu != .engine }
    }
}

extension ELM327 {
    /// Get the supported PIDs
    /// - Returns: The commands of the catalog that the vehicle supports, in catalog order.
    func getSupportedPIDs() async -> [OBDCommand] {
        var supported: Set<OBDCommand> = []

        // Service 01 (live data), 09 (vehicle information) and, on CAN, 06 (monitor results).
        var services: [UInt8] = [0x01, 0x09]
        if await gate.withLock({ obdProtocol?.isCAN == true }) {
            services.append(0x06)
        }

        for service in services {
            for identifier in await supportedIdentifiers(service: service) {
                if let command = OBDCommand.from(command: [service, identifier].hexString), !command.isSupportQuery {
                    supported.insert(command)
                }
            }
        }
        return supported.sorted()
    }

    /// Walks the "supported identifiers" bitmaps of a service. Each bitmap covers 32 identifiers
    /// and its last bit tells whether the next bitmap exists.
    /// - Parameter suffix: extra request bytes, e.g. the frame number of service 02.
    func supportedIdentifiers(service: UInt8, suffix: String = "") async -> Set<UInt8> {
        var supported: Set<UInt8> = []
        var base: UInt8 = 0x00

        while true {
            let messages: [Message]
            let cached = await gate.withLock { initialResponse }
            if service == 0x01, base == 0x00, suffix.isEmpty, !cached.isEmpty {
                messages = cached
            } else if let answer = try? await request([service, base].hexString + suffix) {
                messages = answer
            } else {
                break
            }

            var found: Set<UInt8> = []
            let offset = 2 + suffix.count / 2
            for message in messages {
                //            || ||
                // 7E8 06 41 00 BE 7F B8 13
                let bytes = [UInt8](message.payload)
                guard bytes.count >= offset + 4, bytes[1] == base else { continue }
                for bit in 0 ..< 32 where bytes[offset + bit / 8] & (0x80 >> UInt8(bit % 8)) != 0 {
                    found.insert(base &+ UInt8(bit + 1))
                }
            }
            supported.formUnion(found)

            guard found.contains(base &+ 0x20), base < 0xE0 else { break }
            base += 0x20
        }
        return supported
    }

    /// Kept for compatibility: converts a bitmap, as an array of bits, into the PIDs it enables.
    /// - Parameter offset: the PID of the request the bitmap answers (`0x20` for `0120`…).
    func extractSupportedPIDs(_ binaryData: [Int], offset: Int = 0) -> Set<String> {
        var supportedPIDs: Set<String> = []

        for (index, value) in binaryData.enumerated() where value == 1 {
            supportedPIDs.insert(String(format: "%02X", offset + index + 1))
        }
        return supportedPIDs
    }
}

enum ECUHeader {
    static let ENGINE = "7E0"
}

public struct OBDInfo: Codable, Hashable {
    public var vin: String?
    public var supportedPIDs: [OBDCommand]?
    public var obdProtocol: PROTOCOL?
    /// The role of each ECU that answered, indexed by the low byte of its address.
    public var ecuMap: [UInt8: ECUID]?
    /// What the adapter says about itself, e.g. `ELM327 v1.5`.
    public var adapter: String?
    /// Battery voltage measured by the adapter when the connection was established.
    public var voltage: Double?
}
