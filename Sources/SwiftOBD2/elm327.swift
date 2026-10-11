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
            .removeDuplicates()
            .sink { [weak self] state in
                // The assignment's didSet already notifies obdDelegate — this
                // sink is the single delivery channel for transport states.
                self?.connectionState = state
                obdDebug("Connection state updated: \(state.description)", category: .connection)
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

        // The transport can drop mid-setup (the PID sweep swallows per-command
        // errors); don't overwrite that Disconnected with Connected to Vehicle.
        guard connectionState != .disconnected else {
            throw ELM327Error.connectionFailed(reason: "Connection lost during vehicle setup")
        }
        connectionState = .connectedToVehicle
        return OBDInfo(vin: vin, supportedPIDs: supportedPIDs, obdProtocol: detectedProtocol, ecuMap: ecuMap)
    }

    // MARK: - Protocol Selection

    /// Detects the appropriate OBD protocol by attempting preferred and fallback protocols.
    /// - Parameter preferredProtocol: An optional preferred protocol to attempt first.
    /// - Returns: The detected `PROTOCOL`.
    /// - Throws: `ELM327Error` if detection fails.
    private func detectProtocol(preferredProtocol: PROTOCOL? = nil) async throws -> PROTOCOL {
        obdInfo("Starting protocol detection...", category: .protocol)

        if let protocolToTest = preferredProtocol {
            let msg = "Protocol detect: testing preferred \(protocolToTest.description)…"
            obdInfo(msg, category: .protocol)
            obdDelegate?.logMessage(msg)
            // Select the preferred protocol before testing it. Adapter initialisation
            // leaves the ELM327 on ATSP0, so without this the "preferred" test was really
            // an auto-search and the manual choice was never applied.
            if (try? await okResponse(protocolToTest.cmd)) != nil, await testProtocol(protocolToTest) {
                let found = "Protocol found: \(protocolToTest.description)"
                obdInfo(found, category: .protocol)
                obdDelegate?.logMessage(found)
                return protocolToTest
            }
            let fallback = "Preferred protocol \(protocolToTest.description) failed — falling back to auto-detect"
            obdInfo(fallback, category: .protocol)
            obdDelegate?.logMessage(fallback)
        } else {
            obdDelegate?.logMessage("Protocol detect: starting auto-detect (ATSP0 + 0100)…")
        }

        do {
            return try await detectProtocolAutomatically()
        } catch {
            let msg = "Auto-detect failed (\(error.localizedDescription)) — trying manual sweep…"
            obdInfo(msg, category: .protocol)
            obdDelegate?.logMessage(msg)
            return try await detectProtocolManually()
        }
    }

    /// Attempts to detect the OBD protocol automatically.
    /// - Returns: The detected protocol, or nil if none could be found.
    /// - Throws: Various setup-related errors.
    private func detectProtocolAutomatically() async throws -> PROTOCOL {
        obdDelegate?.logMessage("Protocol detect: ATSP0 (auto-search)…")
        _ = try await okResponse("ATSP0")
        // ELM327 auto-search needs a moment to settle onto the bus before the
        // ECU reliably answers the first query — 1s was occasionally too tight
        // over serial and produced a spurious "no response" here even with the
        // vehicle live (the ATDPN/testProtocol path below still recovers via
        // its own retries, but this cuts down false-negative noise).
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        obdDelegate?.logMessage("Protocol detect: sending 0100 — waiting for vehicle…")
        let resp100 = try? await sendCommand("0100", retries: 2)
        obdInfo("0100 raw response: \(String(describing: resp100))", category: .protocol)
        obdDelegate?.logMessage("0100 → \(resp100.map { $0.joined(separator: " ") } ?? "no response")")

        obdDelegate?.logMessage("Protocol detect: querying ATDPN…")
        let obdProtocolNumber = try await sendCommand("ATDPN")
        obdInfo("ATDPN response: \(obdProtocolNumber)", category: .protocol)
        obdDelegate?.logMessage("ATDPN → \(obdProtocolNumber.joined(separator: " "))")

        guard let first = obdProtocolNumber.first, !first.isEmpty else {
            throw ELM327Error.invalidResponse(message: "Protocol detect: empty ATDPN response")
        }
        // ATDPN reports the active protocol, in auto mode prefixed with "A" (e.g. "A6").
        // Strip that marker; a bare digit ("6") is equally valid. "A0"/"0" means the
        // auto-search hasn't latched onto a live bus — not an error, just nothing to
        // return here, so let the manual sweep take over instead of surfacing a
        // misleading "invalid ATDPN" message. (PROTOCOL.NONE's raw value is "NONE",
        // not "0", so "0" correctly maps to nil.)
        //
        // Only strip the marker when something follows it: `PROTOCOL.protocolA`'s own raw
        // value is "A", so a bare "A" is protocol A (SAE J1939) reported in manual mode,
        // not an empty auto-mode token. Stripping unconditionally turned that into "" and
        // sent a correctly-detected J1939 bus down the manual sweep.
        let token = (first.hasPrefix("A") && first.count > 1) ? String(first.dropFirst()) : first
        guard let obdProtocol = PROTOCOL(rawValue: token) else {
            let msg = "Protocol detect: auto-search found no protocol (ATDPN \(obdProtocolNumber.joined(separator: " ")))"
            obdDelegate?.logMessage(msg)
            throw ELM327Error.noProtocolFound
        }

        let valid = await testProtocol(obdProtocol)
        let protocolMsg = "Detected protocol: \(obdProtocol.description) (valid=\(valid))"
        obdInfo(protocolMsg, category: .protocol)
        obdDelegate?.logMessage(protocolMsg)

        return obdProtocol
    }

    /// CAN first: the overwhelming majority of vehicles on the road (MY2008+ in the US,
    /// mid-2000s+ in the EU) use one of the four ISO 15765-4 variants, so probing legacy
    /// protocols ahead of them — the previous order, `PROTOCOL.allCases` in declaration
    /// order — spent up to 5 full round-trips (ATSPn + 0100 + timeout each) on protocols
    /// that were never going to answer before ever reaching the one that would. Legacy
    /// (pre-CAN) protocols come next. Only reached at all when the ELM327's own ATSP0
    /// auto-search (`detectProtocolAutomatically`) already failed.
    ///
    /// J1939 (A) and the two user-defined CAN protocols (B, C) are deliberately excluded.
    /// They are not OBD-II passenger-car protocols, and probing them transmits on pins 6/14
    /// at bitrates the vehicle's diagnostic bus isn't running, which puts error frames on a
    /// live bus (ISO 15765-4 warns about exactly this). A caller that really wants one of
    /// them selects it explicitly as the preferred protocol.
    static let manualSweepOrder: [PROTOCOL] = [
        .protocol6, .protocol7, .protocol8, .protocol9,
        .protocol1, .protocol2, .protocol3, .protocol4, .protocol5,
    ]

    /// Attempts to detect the OBD protocol manually.
    /// - Parameter desiredProtocol: An optional preferred protocol to attempt first.
    /// - Returns: The detected protocol, or nil if none could be found.
    /// - Throws: Various setup-related errors.
    private func detectProtocolManually() async throws -> PROTOCOL {
        // Single attempt per protocol: each miss costs a full command timeout and the
        // sweep is already the fallback path.
        for protocolOption in Self.manualSweepOrder {
            obdInfo("Testing protocol: \(protocolOption.description)", category: .protocol)
            _ = try await okResponse(protocolOption.cmd)
            if await testProtocol(protocolOption, retries: 1) {
                return protocolOption
            }
        }
        /// If we reach this point, no protocol was found
        obdError("No protocol found", category: .protocol)
        throw ELM327Error.noProtocolFound
    }

    // MARK: - Protocol Testing

    /// Tests a given protocol by sending a 0100 command and checking for a valid response.
    /// - Parameter obdProtocol: The protocol to test.
    /// - Throws: Various setup-related errors.
    private func testProtocol(_ obdProtocol: PROTOCOL, retries: Int = 3) async -> Bool {
        let response = try? await sendCommand("0100", retries: retries)
        let raw = response?.joined(separator: " ") ?? "no response"
        if let response, response.contains(where: { $0.range(of: #"41\s*00"#, options: .regularExpression) != nil }) {
            let msg = "Protocol \(obdProtocol.description) ✓  (0100 → \(raw))"
            obdInfo(msg, category: .protocol)
            obdDelegate?.logMessage(msg)
            r100 = response
            return true
        } else {
            let msg = "Protocol \(obdProtocol.description) ✗  (0100 → \(raw))"
            obdInfo(msg, category: .protocol)
            obdDelegate?.logMessage(msg)
            return false
        }
    }

    // MARK: - Adapter Initialization

    func connectToAdapter(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        try await comm.connectAsync(timeout: timeout, peripheral: peripheral)
    }

    /// Looks up a previously connected BLE peripheral by system identifier for
    /// a no-scan pending connect. Nil on non-BLE transports.
    func retrievePeripheral(withIdentifier identifier: UUID) async -> CBPeripheral? {
        await comm.retrievePeripheral(withIdentifier: identifier)
    }

    /// Initializes the adapter by sending a series of commands.
    /// - Parameter setupOrder: A list of commands to send in order.
    /// - Throws: Various setup-related errors.
    func adapterInitialization() async throws {
        obdInfo("Initializing ELM327 adapter...", category: .connection)
        obdDelegate?.logMessage("Adapter init: sending ATZ (reset)…")
        do {
            // ATZ is the first command after the port opens and the ELM327 is still
            // settling, so the very first reset is occasionally lost. Retry it rather
            // than failing the whole connection on a single dropped frame.
            let atzResp = try await sendCommand("ATZ", retries: 3)
            obdInfo("ATZ response: \(atzResp)", category: .connection)
            obdDelegate?.logMessage("ATZ → \(atzResp.joined(separator: " | "))")

            // The port can still be settling for the first few commands after ATZ
            // (same class of transient drop the ATZ retry above guards against), so
            // give the rest of the init sequence the same resilience rather than
            // failing the whole connection on one dropped frame.
            obdDelegate?.logMessage("Adapter init: ATE0 (echo off)…")
            _ = try await okResponse("ATE0", retries: 3)
            obdDelegate?.logMessage("ATE0 → OK")

            obdDelegate?.logMessage("Adapter init: ATL0 ATH1 ATS0…")
            _ = try await okResponse("ATL0", retries: 3)
            _ = try await okResponse("ATS0", retries: 3)
            _ = try await okResponse("ATH1", retries: 3)
            obdDelegate?.logMessage("ATL0 / ATS0 / ATH1 → OK")

            // Best-effort, not `okResponse`: both are v1.3+/v2.x features that a cheap or
            // older clone may not implement, and an unrecognized command ("?") must not
            // abort the whole connection over what's an optional reliability improvement.
            // ATAT1 (adaptive timing) is Elm Electronics' own recommendation for noisy
            // links — it grows the per-command timeout based on observed bus response
            // time instead of a fixed one, exactly the failure mode this session kept
            // chasing on both adapters. ATCAF1 (CAN auto-formatting) makes explicit an
            // assumption every parser in this package already makes implicitly: that the
            // adapter — not us — strips CAN padding/PCI framing before handing us lines.
            obdDelegate?.logMessage("Adapter init: ATAT1 (adaptive timing) / ATCAF1 (CAN auto-format)…")
            let atatResp = try? await sendCommand("ATAT1")
            let atcafResp = try? await sendCommand("ATCAF1")
            obdDelegate?.logMessage("ATAT1 → \(atatResp?.joined(separator: " | ") ?? "no response (unsupported?)"), ATCAF1 → \(atcafResp?.joined(separator: " | ") ?? "no response (unsupported?)")")

            obdDelegate?.logMessage("Adapter init: ATSP0 (auto protocol)…")
            _ = try await okResponse("ATSP0", retries: 3)
            obdDelegate?.logMessage("ATSP0 → OK — adapter ready")
            obdInfo("ELM327 adapter initialized successfully.", category: .connection)
        } catch {
            let msg = "Adapter init FAILED: \(error.localizedDescription)"
            obdError(msg, category: .connection)
            obdDelegate?.logMessage(msg)
            throw ELM327Error.adapterInitializationFailed
        }
    }

    private func setHeader(header: String) async throws {
        _ = try await okResponse("AT SH " + header)
    }

    /// Switches the dongle to a different CAN protocol without dropping the BT/Serial connection.
    /// Sends ATSP<n> and re-asserts ATH1. Bus-specific init commands (ATSH, ATFCSH, etc.)
    /// are the caller's responsibility — they live in the app layer, not this package.
    func switchProtocol(_ proto: PROTOCOL) async throws {
        _ = try await okResponse(proto.cmd)
        _ = try await okResponse("ATH1")
    }

    func stopConnection() {
        comm.disconnectPeripheral()
        connectionState = .disconnected
    }

    // MARK: - Message Sending

    func sendCommand(_ message: String, retries: Int = 1) async throws -> [String] {
        let result = try await comm.sendCommand(message, retries: retries)
        if ConfigurationService.shared.obdCommandLogging {
            let response = result.joined(separator: " | ")
            obdInfo("CMD \(message) → \(response)", category: .communication)
            obdDelegate?.logMessage("CMD \(message) → \(response)")
        }
        return result
    }

    func sendMonitorCommand(_ command: String, duration: TimeInterval) async throws -> [String] {
        try await comm.sendMonitorCommand(command, duration: duration)
    }

    private func okResponse(_ message: String, retries: Int = 1) async throws -> [String] {
        let response = try await sendCommand(message, retries: retries)
        if response.contains("OK") {
            return response
        } else {
            obdError("Invalid response: \(response)", category: .communication)
            throw ELM327Error.invalidResponse(message: "message: \(message), \(String(describing: response.first))")
        }
    }

    func getStatus() async throws -> Result<DecodeResult, DecodeError> {
        obdDebug("Getting status", category: .service)
        let statusCommand = OBDCommand.Mode1.status
        let statusResponse = try await sendCommand(statusCommand.properties.command)
        obdDebug("Status response: \(statusResponse)", category: .service)
        guard let messages = try canProtocol?.parse(statusResponse), !messages.isEmpty else {
            return .failure(.noData)
        }
        // MIL / DTC count / monitor readiness are a real per-ECU reading, not a bitmap to
        // union — and `.first` (Dictionary order) was non-deterministic on a two-ECU bus.
        // `preferredECUMessage` keys off the raw source address (lowest = primary ECM on
        // both addressing schemes) — the `.ecu == .engine` label used before degenerates
        // on 29-bit buses, where every module's address masks to the same "engine" label.
        guard let statusData = preferredECUMessage(messages, pidEcho: 0x01)?.data else {
            return .failure(.noData)
        }
        // message.data is [PID, A, B, C, D]; decode() no longer strips the PID
        // byte, so drop it here (as sendCommand does) before StatusDecoder reads
        // A as the MIL/DTC-count byte.
        return statusCommand.properties.decode(data: statusData.dropFirst())
    }

    func scanForTroubleCodes() async throws -> [ECUID: [TroubleCode]] {
        obdInfo("Scanning for trouble codes", category: .service)
        var dtcs: [ECUID: [TroubleCode]] = [:]

        // Mode $03 — confirmed codes. This is the primary scan; let its errors
        // propagate so a dropped connection surfaces rather than reading as clean.
        let confirmed = try await scanDTCs(command: OBDCommand.Mode3.GET_DTC.properties.command,
                                           status: .confirmed)
        merge(confirmed, into: &dtcs)

        // Mode $07 (pending) and Mode $0A (permanent) are best-effort: a vehicle
        // that doesn't support a service answers "NO DATA" or a $7F negative
        // response, which must not fail the whole scan.
        if let pending = try? await scanDTCs(command: OBDCommand.Mode7.GET_PENDING_DTC.properties.command,
                                             status: .pending) {
            merge(pending, into: &dtcs)
        }
        if let permanent = try? await scanDTCs(command: OBDCommand.Mode10.GET_PERMANENT_DTC.properties.command,
                                               status: .permanent) {
            merge(permanent, into: &dtcs)
        }

        return dtcs
    }

    /// Sends a single DTC service command ($03/$07/$0A) and decodes the per-ECU
    /// codes, tagging each with the originating `status`. The three services
    /// share the same 2-byte DTC payload, so they all decode via `.dtc`.
    private func scanDTCs(command: String, status: DTCStatus) async throws -> [ECUID: [TroubleCode]] {
        let response = try await sendCommand(command)
        guard let messages = try canProtocol?.parse(response) else { return [:] }

        var result: [ECUID: [TroubleCode]] = [:]
        for message in messages {
            guard let data = message.data else { continue }
            switch OBDCommand.Mode3.GET_DTC.properties.decode(data: data) {
            case let .success(decoded):
                let tagged = (decoded.troubleCode ?? []).map {
                    TroubleCode(code: $0.code, description: $0.description, status: status)
                }
                result[message.ecu, default: []].append(contentsOf: tagged)
            case let .failure(error):
                obdError("Failed to decode DTC: \(error)", category: .parsing)
            }
        }
        return result
    }

    /// Merges one mode's results into the running set, de-duplicating by code per
    /// ECU and keeping the highest-priority status (permanent > confirmed >
    /// pending) when the same code is reported by more than one service.
    private func merge(_ source: [ECUID: [TroubleCode]], into dest: inout [ECUID: [TroubleCode]]) {
        for (ecu, codes) in source {
            for code in codes {
                if let index = dest[ecu]?.firstIndex(where: { $0.code == code.code }) {
                    if code.status.priority > dest[ecu]![index].status.priority {
                        dest[ecu]![index] = code
                    }
                } else {
                    dest[ecu, default: []].append(code)
                }
            }
        }
    }

    func scanForUDSDTCs(header: String) async throws -> [TroubleCode] {
        _ = try? await sendCommand("ATSH\(header)", retries: 1)
        let response = try await sendCommand("19 02 FF")
        guard let messages = try canProtocol?.parse(response) else { return [] }
        return messages.compactMap(\.data).flatMap(parseUDS19Data)
    }

    private func parseUDS19Data(_ data: Data) -> [TroubleCode] {
        let bytes = Array(data)
        // UDS $19/$02 response: 59 02 [status availability mask] then 4-byte
        // records [b1 b2 b3 statusMask] — a 3-byte DTC plus its status byte.
        guard bytes.count >= 3, bytes[0] == 0x59, bytes[1] == 0x02 else { return [] }
        var result: [TroubleCode] = []
        var i = 3
        while i + 4 <= bytes.count {
            let b1 = bytes[i], b2 = bytes[i + 1], b3 = bytes[i + 2]
            // parseDTC builds the base P/C/B/U code from b1,b2 (and rejects 00 00).
            if let base = parseDTC(Data([b1, b2])) {
                // b3 is the ISO 14229 failure-type byte; append as "-XX" so distinct
                // sub-faults of the same base code stay distinct.
                let code = base.code + String(format: "-%02X", b3)
                result.append(TroubleCode(code: code, description: base.description,
                                          status: Self.udsStatus(bytes[i + 3])))
            }
            i += 4
        }
        return result
    }

    /// Maps an ISO 14229 DTC status byte to the badge status. bit0 testFailed
    /// means failing right now; bit3 confirmedDTC without it is a stored,
    /// historical fault; bit2 pendingDTC alone is a single failed cycle.
    static func udsStatus(_ mask: UInt8) -> DTCStatus {
        if mask & 0x01 != 0 { return .confirmed }
        if mask & 0x08 != 0 { return .historical }
        if mask & 0x04 != 0 { return .pending }
        return .historical
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

        // Same non-deterministic `.first` issue as `getStatus()` — prefer the primary
        // (lowest-source-address) ECM's answer; the Mode 09 PID echo for VIN is 0x02.
        guard let messages = try? canProtocol?.parse(vinResponse), !messages.isEmpty,
              let data = preferredECUMessage(messages, pidEcho: 0x02)?.data,
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
                    obdError("parse_frame failed to extract data", category: .parsing)
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
                obdDebug("Getting supported PIDs for \(pidGetter.properties.command)", category: .protocol)
                let response = try await sendCommand(pidGetter.properties.command)
                // find first instance of 41 plus command sent, from there we determine the position of everything else
                // Ex.
                //        || ||
                // 7E8 06 41 00 BE 7F B8 13
                //
                // Each getter's bitmap only covers ITS OWN 32-PID block (0100→01-20,
                // 0120→21-40, 0140→41-60, ...) — the block base must be added to the bit
                // index, or every getter after the first reports its bits as PIDs 01-20
                // again. That silently capped every vehicle's live-sensor list at the
                // first 32 standard PIDs regardless of what the ECU actually supports —
                // anything from 0x21 up (fuel level, ambient temp, control module voltage,
                // fuel type, fuel rate, ...) could never be recognized as supported.
                let baseOffset = UInt8(pidGetter.properties.command.dropFirst(2), radix: 16) ?? 0
                guard let supportedPidsByECU = parseResponse(response, baseOffset: baseOffset) else {
                    continue
                }

                // Match within the getter's own mode. `dropFirst(2)` strips the mode, so an
                // unqualified match let one mode's bitmap vouch for another's same-numbered
                // command: the sweep includes the Mode 6 MID getters (0600, 0620, … 06A0),
                // whose bitmaps enumerate Mode 6 MIDs, and MID 0x01 being supported marked
                // Mode 1 PID 01 supported (and vice versa). A bitmap only ever describes its
                // own mode, so the mode has to be part of the match.
                let mode = String(pidGetter.properties.command.prefix(2))
                let supportedCommands = OBDCommand.allCommands.filter {
                    $0.properties.command.hasPrefix(mode)
                        && supportedPidsByECU.contains(String($0.properties.command.dropFirst(2)))
                }

                supportedPIDs.append(contentsOf: supportedCommands)
            } catch {
                // A transport drop fails every remaining getter the same way
                // (each one burning its full command timeout against a dead fd)
                // — stop the sweep instead of grinding through them.
                if connectionState == .disconnected {
                    obdError("Supported-PID sweep aborted — connection lost: \(error)", category: .connection)
                    obdDelegate?.logMessage("Supported-PID sweep aborted — connection lost")
                    break
                }
                // A "no data" refusal just means the car doesn't support this PID range /
                // Mode — expected, so keep it at debug. Anything else is a real error.
                if case BLEManagerError.noData = error {
                    obdDebug("\(pidGetter.properties.command): not supported (\(error))", category: .protocol)
                } else {
                    obdError("\(pidGetter.properties.command): \(error)", category: .protocol)
                }
            }
        }
        // filter out pidGetters
        supportedPIDs = supportedPIDs.filter { !pidGetters.contains($0) }

        // remove duplicates
        return Array(Set(supportedPIDs))
    }

    /// Unions the supported-PID bitmap across every ECU that answered, instead of trusting
    /// only the first one. On a vehicle with more than one ECU on the bus (e.g. a separate
    /// module handling body/transmission PIDs), `.first` silently discarded any PID that only
    /// the *other* ECU advertised — and since `.first` here comes from a `Dictionary`'s
    /// iteration order, which ECU "won" wasn't even guaranteed to be the same one from one
    /// connection to the next, so the set of sensors that showed up could vary connect to
    /// connect on the exact same vehicle.
    private func parseResponse(_ response: [String], baseOffset: UInt8 = 0) -> Set<String>? {
        guard let messages = try? canProtocol?.parse(response), !messages.isEmpty else {
            return nil
        }
        var combined = Set<String>()
        for message in messages {
            guard let data = message.data else { continue }
            combined.formUnion(extractSupportedPIDs(BitArray(data: data.dropFirst()).binaryArray, baseOffset: baseOffset))
        }
        return combined.isEmpty ? nil : combined
    }

    /// `baseOffset` is the PID number the response's bit 0 represents (0 for 0100's
    /// PIDs 01-20, 0x20 for 0120's PIDs 21-40, etc.) — defaults to 0 so existing callers
    /// (and the `0100`-only unit test) are unaffected.
    func extractSupportedPIDs(_ binaryData: [Int], baseOffset: UInt8 = 0) -> Set<String> {
        var supportedPIDs: Set<String> = []

        for (index, value) in binaryData.enumerated() {
            if value == 1 {
                let pid = String(format: "%02X", Int(baseOffset) + index + 1)
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
            obdError("Failed to decode command \(cmd.properties.command): \(error.localizedDescription) | Data: \(valueData.map { String(format: "%02X", $0) }.joined(separator: " "))", category: .parsing)
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
