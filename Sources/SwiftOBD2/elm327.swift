import Foundation
import CoreBluetooth
import Combine
import OSLog

// MARK: - ELM327 Class Documentation
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


struct ECUHeader {
    static let ENGINE = "7E0"
}

// Possible setup errors
enum SetupError: Error {
    case noECUCharacteristic
    case invalidResponse(message: String)
    case noProtocolFound
    case adapterInitFailed
    case timeout
    case peripheralNotFound
    case ignitionOff
    case invalidProtocol
}

// MARK: - ELM327 Class
final class ELM327 {
    // MARK: - Properties
    let logger = Logger(subsystem: "com.kemo.SmartOBD2", category: "ELM327")

    /// The Bluetooth manager responsible for handling communication with the adapter.
    private let bleManager: BLEManager

    var obdProtocol: PROTOCOL = .NONE

    init(bleManager: BLEManager) {
        self.bleManager = bleManager
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
    func setupVehicle(preferedProtocol: PROTOCOL?) async throws -> (OBDProtocol: PROTOCOL, VIN: String?) {
        var obdProtocol: PROTOCOL?

        if let desiredProtocol = preferedProtocol {
            do {
                obdProtocol = try await manualProtocolDetection(desiredProtocol: desiredProtocol)
            } catch {
                obdProtocol = nil // Fallback to autoProtocol
            }
        }

        if obdProtocol == nil {
            obdProtocol = try await connectToVehicle(autoProtocol: true)
        }

        guard let obdProtocol = obdProtocol else {
            throw SetupError.noProtocolFound
        }

        self.obdProtocol = obdProtocol
        //        if obdInfo.vin == nil {
        let vin = await requestVin()
        //        }
        try await setHeader(header: ECUHeader.ENGINE)
        //        obdInfo.supportedPIDs = await getSupportedPIDs()

        return (obdProtocol, vin)
    }


    func connectToVehicle(autoProtocol: Bool) async throws -> PROTOCOL? {
        if autoProtocol {
            guard let obdProtocol = try await autoProtocolDetection() else {
                logger.error("No protocol found")
                throw SetupError.noProtocolFound
            }
            return obdProtocol
        } else {
            guard let obdProtocol = try await manualProtocolDetection(desiredProtocol: nil) else {
                logger.error("No protocol found")
                throw SetupError.noProtocolFound
            }
            return obdProtocol
        }
    }

    // MARK: - Protocol Selection

     /// Attempts to detect the OBD protocol automatically.
     /// - Returns: The detected protocol, or nil if none could be found.
     /// - Throws: Various setup-related errors.
    private func autoProtocolDetection() async throws -> PROTOCOL? {
        _ = try await okResponse(message: "ATSP0")
        Thread.sleep(forTimeInterval: 0.2)
        _ = try await sendMessageAsync("0100", withTimeoutSecs: 20)

        let obdProtocolNumber = try await sendMessageAsync("ATDPN")
        print(obdProtocolNumber)
        guard let obdProtocol = PROTOCOL(rawValue: String(obdProtocolNumber[0].dropFirst())) else {
            throw SetupError.invalidResponse(message: "Invalid protocol number: \(obdProtocolNumber)")
        }

        try await testProtocol(obdProtocol: obdProtocol)

        return obdProtocol
    }

    /// Attempts to detect the OBD protocol manually.
    /// - Parameter desiredProtocol: An optional preferred protocol to attempt first.
    /// - Returns: The detected protocol, or nil if none could be found.
    /// - Throws: Various setup-related errors.
    private func manualProtocolDetection(desiredProtocol: PROTOCOL?) async throws -> PROTOCOL? {
        if let desiredProtocol = desiredProtocol {
            try? await testProtocol(obdProtocol: desiredProtocol)
            return desiredProtocol
        }
        while obdProtocol != .NONE {
            do {
                try await testProtocol(obdProtocol: obdProtocol)
                return obdProtocol // Exit the loop if the protocol is found successfully
            } catch {
                // Other errors are propagated
                obdProtocol = obdProtocol.nextProtocol()
            }
        }
        // If we reach this point, no protocol was found
        logger.error("No protocol found")
        throw SetupError.noProtocolFound
    }

    // MARK: - Protocol Testing

    private func testProtocol(obdProtocol: PROTOCOL) async throws {
        // test protocol by sending 0100 and checking for 41 00 response
        _ = try await okResponse(message: obdProtocol.cmd)

        let r100 = try await sendMessageAsync("0100", withTimeoutSecs: 10)

        if r100.joined().contains("NO DATA") {
            throw SetupError.ignitionOff
        }

        guard r100.joined().contains("41 00") else {
            logger.error("Invalid response to 0100")
            throw SetupError.invalidProtocol
        }

        logger.info("Protocol \(obdProtocol.rawValue) found")

        let response = try await sendMessageAsync("0100", withTimeoutSecs: 10)
        let messages = try OBDParcer(response, idBits: obdProtocol.idBits).messages

        _ = populateECUMap(messages)
    }

    func adapterInitialization(setupOrder: [OBDCommand.General] = [.ATD, .ATZ, .ATL0, .ATE0, .ATH1, .ATAT1, .ATRV, .ATDPN]) async throws {
        for step in setupOrder {
            switch step {
            case .ATD, .ATL0, .ATE0, .ATH1, .ATAT1, .ATSTFF, .ATH0:
                _ = try await okResponse(message: step.properties.command)
            case .ATZ:
                _ = try await sendMessageAsync(step.properties.command)
            case .ATRV:
                // get the voltage
                _ = try await sendMessageAsync(step.properties.command)
            case .ATDPN:
                // Describe current protocol number
                let protocolNumber = try await sendMessageAsync(step.properties.command)
                self.obdProtocol = PROTOCOL(rawValue: protocolNumber[0]) ?? .protocol9
            }
        }
    }

    private func setHeader(header: String) async throws {
        _ = try await okResponse(message: "AT SH " + header)
    }

    func stopConnection() {
        bleManager.disconnectPeripheral()
    }

    // MARK: - Message Sending

    func sendMessageAsync(_ message: String, withTimeoutSecs: TimeInterval = 5) async throws -> [String] {
        return try await self.bleManager.sendMessageAsync(message)
    }

    private func okResponse(message: String) async throws -> [String] {
        let response = try await self.sendMessageAsync(message)
        if response.contains("OK") {
            return response
        } else {
            logger.error("Invalid response: \(response)")
            throw SetupError.invalidResponse(message: response[0])
        }
    }

    func getStatus() async throws -> Status? {
        let statusCommand = OBDCommand.Mode1.status
        let statusResponse = try await sendMessageAsync(statusCommand.properties.command)
        let statueMessages = try OBDParcer(statusResponse, idBits: obdProtocol.idBits).messages

        guard let statusData = statueMessages[0].data else {
            return nil
        }
        guard let decodedStatus = statusCommand.properties.decoder.decode(data: statusData) else {
            return nil
        }
        switch decodedStatus {
        case .statusResult(let value):
            return value
        default:
            return nil
        }
    }

    func scanForTroubleCodes() async throws -> [String: String]? {
        let dtcCommand = OBDCommand.Mode3.GET_DTC
        let dtcResponse = try await sendMessageAsync(dtcCommand.properties.command)

        let dtcMessages = try OBDParcer(dtcResponse, idBits: obdProtocol.idBits).messages

        guard let dtcData = dtcMessages[0].data else {
            return nil
        }
        guard let decodedDtc = dtcCommand.properties.decoder.decode(data: dtcData) else {
            return nil
        }

        switch decodedDtc {
        case .troubleCode(let value):
            return value
        default:
            return nil
        }
    }

    func clearTroubleCodes() async throws {
        let command = OBDCommand.Mode4.CLEAR_DTC

        let response = try await sendMessageAsync(command.properties.command)
        print("Response: \(response)")
    }

    private func requestVin() async -> String? {
        let command = OBDCommand.Mode9.VIN
        guard let vinResponse = try? await sendMessageAsync(command.properties.command) else {
            return nil
        }

        let messages = try? OBDParcer(vinResponse, idBits: obdProtocol.idBits).messages
        guard let data = messages?[0].data,
              var vinString = String(bytes: data, encoding: .utf8) else {
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
    func requestPIDs(_ pids: [OBDCommand]) async throws -> [Message] {
        let response = try await sendMessageAsync("01" + pids.compactMap { $0.properties.command.dropFirst(2) }.joined())
        return try OBDParcer(response, idBits: obdProtocol.idBits).messages
    }

    private func populateECUMap(_ messages: [Message]) -> [UInt8: ECUID]? {
        let engineTXID = 0
        let transmissionTXID = 1
        var ecuMap: [UInt8: ECUID] = [:]

        // If there are no messages, return an empty map
        guard !messages.isEmpty else {
            return nil
        }

        // If there is only one message, assume it's from the engine
        if messages.count == 1 {
            ecuMap[messages[0].ecu?.rawValue ?? 0] = .engine
            return ecuMap
        }

        // Find the engine and transmission ECU based on TXID
        var foundEngine = false

        for message in messages {
            guard let txID = message.ecu?.rawValue else {
                logger.error("parse_frame failed to extract TX_ID")
                continue
            }

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
                    bestTXID = message.ecu?.rawValue
                }
            }

            if let bestTXID = bestTXID {
                ecuMap[bestTXID] = .engine
            }
        }

        // Assign transmission ECU to messages without an ECU assignment
        for message in messages where ecuMap[message.ecu?.rawValue ?? 0] == nil {
            ecuMap[message.ecu?.rawValue ?? 0] = .transmission
        }

        return ecuMap
    }
}

extension ELM327 {
    func getSupportedPIDs() async -> [OBDCommand] {
        let pidGetters = OBDCommand.pidGetters
        var supportedPIDs: [OBDCommand] = []

        for pidGetter in pidGetters {
            do {
                let response = try await sendMessageAsync(pidGetter.properties.command)
                // find first instance of 41 plus command sent, from there we determine the position of everything else
                // Ex.
                //        || ||
                // 7E8 06 41 00 BE 7F B8 13
                guard let supportedPidsByECU = try? parseResponse(response) else {
                    continue
                }

                let supportedCommands = OBDCommand.allCommands
                    .filter { supportedPidsByECU.contains(String($0.properties.command.dropFirst(2))) }
                    .map { $0 }

                supportedPIDs.append(contentsOf: supportedCommands)
            } catch {
                logger.error("\(error.localizedDescription)")
                print(error.localizedDescription)
            }
        }
        // filter out pidGetters
        supportedPIDs = supportedPIDs.filter { !pidGetters.contains($0) }

        // remove duplicates
        return Array(Set(supportedPIDs))
    }

    private func parseResponse(_ response: [String]) throws -> Set<String> {
        let messages = try OBDParcer(response, idBits: obdProtocol.idBits).messages

        guard !messages.isEmpty,
              let ecuData = messages[0].data else {
            throw NSError(domain: "Invalid data format", code: 0, userInfo: nil)
        }
        let binaryData = BitArray(data: ecuData[1...]).binaryArray
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

    func extractDataLength(_ startIndex: Int, _ response: [String]) throws -> Int? {
        guard let lengthHex = UInt8(response[startIndex - 1], radix: 16) else {
            return nil
        }
        // Extract frame data, type, and dataLen
        // Ex.
        //     ||
        // 7E8 06 41 00 BE 7F B8 13

        let frameType = FrameType(rawValue: lengthHex & 0xF0)

        switch frameType {
        case .singleFrame:
            return Int(lengthHex) & 0x0F
        case .firstFrame:
            guard let secondLengthHex = UInt8(response[startIndex - 2], radix: 16) else {
                throw NSError(domain: "Invalid data format", code: 0, userInfo: nil)
            }
            return Int(lengthHex) + Int(secondLengthHex)
        case .consecutiveFrame:
            return Int(lengthHex)
        default:
            return nil
        }
    }

    func hexToBinary(_ hexString: String) -> String? {
        // Create a scanner to parse the hex string
        let scanner = Scanner(string: hexString)

        // Check if the string starts with "0x" or "0X" and skip it if present
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: "0x")
        var intValue: UInt64 = 0

        // Use the scanner to convert the hex string to an integer
        if scanner.scanHexInt64(&intValue) {
            // Convert the integer to a binary string with leading zeros
            let binaryString = String(intValue, radix: 2)
            let leadingZerosCount = hexString.count * 4 - binaryString.count
            let leadingZeros = String(repeating: "0", count: leadingZerosCount)
            return leadingZeros + binaryString
        }
        // Return nil if the conversion fails
        return nil
    }
}

public struct BatchedResponse {
    private var buffer: Data

    public init(response: Data) {
        self.buffer = response
    }

    public mutating func getValueForCommand(_ cmd: OBDCommand) -> OBDDecodeResult? {
        guard buffer.count >= cmd.properties.bytes else {
            return nil
        }
        let value = buffer.prefix(cmd.properties.bytes)
        //        print("value ",value.compactMap { String(format: "%02X ", $0) }.joined())

        buffer.removeFirst(cmd.properties.bytes)
        //        print("Buffer: \(buffer.compactMap { String(format: "%02X ", $0) }.joined())")

        return cmd.properties.decoder.decode(data: value.dropFirst())
    }
}

extension String {
    var hexBytes: [UInt8] {
        var position = startIndex
        return (0..<count/2).compactMap { _ in
            defer { position = index(position, offsetBy: 2) }
            return UInt8(self[position...index(after: position)], radix: 16)
        }
    }
}

public enum ECUID: UInt8, Codable {
    case engine = 0x00
    case transmission = 0x01
    case unknown = 0x02
}

enum TxId: UInt8, Codable {
    case engine = 0x00
    case transmission = 0x01
}

extension Data {
    func bitCount() -> Int {
        return self.count * 8
    }

    func hexString() -> String {
        return map { String(format: "%02hhx", $0) }.joined(separator: " ")
    }
}
