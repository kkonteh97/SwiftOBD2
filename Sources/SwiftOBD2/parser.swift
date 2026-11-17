//
//  parser.swift
//  SmartOBD2
//
//  Created by kemo konteh on 9/19/23.
//

import Foundation

/// The role of an ECU answering on the diagnostic bus.
public enum ECUID: UInt8, Codable {
    /// The engine control module.
    case engine = 0x00
    /// The transmission control module.
    case transmission = 0x01
    /// Any other ECU.
    case unknown = 0x02

    /// A description of the ECU.
    public var description: String {
        switch self {
        case .engine:
            return "Engine"
        case .transmission:
            return "Transmission"
        case .unknown:
            return "Unknown"
        }
    }
}

/// A message received from an ECU.
public protocol MessageProtocol {
    var data: Data? { get }
    var ecu: ECUID { get }
}

/// One complete diagnostic answer from one ECU, with transport framing (CAN ISO-TP segmentation,
/// legacy headers and checksums) already removed.
public struct Message: MessageProtocol {
    /// The address the ECU answered from: the CAN identifier (`0x7E8`, `0x18DAF110`…) or, for the
    /// legacy protocols, the source byte of the header (`0x10`…).
    public let address: UInt32
    /// The role of the ECU. Refined by the adapter driver once the vehicle has been probed.
    public internal(set) var ecu: ECUID
    /// The service bytes, starting with the response service identifier (`41 0C 1A F8`…).
    public let payload: Data

    /// `true` when the message travelled over CAN (ISO 15765-4).
    let isCAN: Bool

    init(address: UInt32, ecu: ECUID, payload: [UInt8], isCAN: Bool) {
        self.address = address
        self.ecu = ecu
        self.payload = Data(payload)
        self.isCAN = isCAN
    }

    /// The payload without its service identifier byte (kept for source compatibility).
    public var data: Data? {
        payload.isEmpty ? nil : Data(payload.dropFirst())
    }

    /// The response service identifier (request service + `0x40`), or `0x7F` for a negative response.
    public var serviceID: UInt8? {
        payload.first
    }

    /// `7F <service> <code>`: the ECU refused the request.
    public var isNegativeResponse: Bool {
        payload.count >= 3 && payload[0] == 0x7F
    }

    /// `7F <service> 78`: the ECU asks for more time and will answer again.
    var isResponsePending: Bool {
        isNegativeResponse && payload[2] == 0x78
    }

    /// The payload as an uppercase hexadecimal string, handy for logs.
    public var hexString: String {
        payload.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// The bytes holding trouble codes in an answer to service 03, 07 or 0A.
    var troubleCodeBytes: Data {
        guard payload.count > 1 else { return Data() }
        guard isCAN else { return Data(payload.dropFirst()) }
        // On CAN the service byte is followed by the number of codes.
        let available = Data(payload.dropFirst(2))
        let announced = Int(payload[1]) * 2
        return announced > 0 && announced <= available.count ? Data(available.prefix(announced)) : available
    }
}

// MARK: - CAN (ISO 15765-4)

/// A single CAN frame as printed by the ELM327 with headers enabled.
struct CANFrame {
    enum Kind {
        case single
        case first
        case consecutive
        case flowControl
    }

    let id: UInt32
    /// `true` for 29 bit identifiers.
    let isExtended: Bool
    /// Protocol control byte followed by the data bytes.
    let bytes: [UInt8]
    let kind: Kind

    /// - Parameter hex: one response line without spaces, e.g. `7E8064100BE3FA813` (11 bit) or
    ///   `18DAF110064100BE3FA813` (29 bit).
    init?(hex: String) {
        // 11 bit identifiers are printed on 3 hex digits, 29 bit ones on 8: the parity of the line
        // length tells them apart since the data that follows is made of whole bytes.
        let idLength = hex.count % 2 == 1 ? 3 : 8
        guard hex.count >= idLength + 2,
              let id = UInt32(hex.prefix(idLength), radix: 16)
        else { return nil }

        let bytes = String(hex.dropFirst(idLength)).hexBytes
        guard (1 ... 8).contains(bytes.count), bytes.count * 2 == hex.count - idLength else { return nil }

        switch bytes[0] >> 4 {
        case 0: kind = .single
        case 1: kind = .first
        case 2: kind = .consecutive
        case 3: kind = .flowControl
        default: return nil
        }

        self.id = id
        isExtended = idLength == 8
        self.bytes = bytes
    }

    /// The conventional role of the ECU owning this identifier (ISO 15765-4 / SAE J2178).
    var defaultECU: ECUID {
        if isExtended {
            switch UInt8(id & 0xFF) {
            case 0x10 ... 0x17: return .engine
            case 0x18 ... 0x1F: return .transmission
            default: return .unknown
            }
        }
        switch id {
        case 0x7E8: return .engine
        case 0x7E9: return .transmission
        default: return .unknown
        }
    }
}

/// Reassembles the lines returned by the adapter on CAN protocols into messages (ISO 15765-2).
public struct CANParser {
    /// The messages, one per answering ECU and request.
    public let messages: [Message]

    /// - Parameters:
    ///   - lines: the lines answered by the adapter (headers on).
    ///   - idBits: unused, the identifier length is detected on each line. Kept for compatibility.
    public init(_ lines: [String], idBits _: Int = 11) throws {
        let hexLines = lines
            .map { $0.replacingOccurrences(of: " ", with: "") }
            .filter(\.isHex)
        let frames = hexLines.compactMap(CANFrame.init(hex:))

        // Several ECUs may answer the same request with interleaved frames.
        var order: [UInt32] = []
        var framesByID: [UInt32: [CANFrame]] = [:]
        for frame in frames {
            if framesByID[frame.id] == nil { order.append(frame.id) }
            framesByID[frame.id, default: []].append(frame)
        }

        let assembled = order.flatMap { CANParser.assemble(framesByID[$0] ?? []) }
        if assembled.isEmpty, !hexLines.isEmpty {
            throw ParserError.error("No valid CAN message in \(hexLines)")
        }
        messages = assembled
    }

    /// Rebuilds the ISO-TP messages sent by one ECU.
    private static func assemble(_ frames: [CANFrame]) -> [Message] {
        var messages: [Message] = []
        var partial: (total: Int, data: [UInt8], nextSequence: UInt8)?

        func emit(_ payload: [UInt8], from frame: CANFrame) {
            messages.append(Message(address: frame.id, ecu: frame.defaultECU, payload: payload, isCAN: true))
        }

        for frame in frames {
            switch frame.kind {
            case .single:
                let length = Int(frame.bytes[0] & 0x0F)
                guard length > 0, frame.bytes.count > length else {
                    obdWarning("Ignoring malformed single frame from \(String(frame.id, radix: 16))", category: .parsing)
                    continue
                }
                // Anything past the announced length is padding.
                emit(Array(frame.bytes[1 ... length]), from: frame)

            case .first:
                guard frame.bytes.count >= 2 else { continue }
                let total = Int(frame.bytes[0] & 0x0F) << 8 | Int(frame.bytes[1])
                partial = (total, Array(frame.bytes.dropFirst(2)), 1)

            case .consecutive:
                guard var current = partial else { continue }
                let sequence = frame.bytes[0] & 0x0F
                guard sequence == current.nextSequence else {
                    obdWarning("Out of sequence frame from \(String(frame.id, radix: 16)), dropping message", category: .parsing)
                    partial = nil
                    continue
                }
                current.data.append(contentsOf: frame.bytes.dropFirst())
                current.nextSequence = (sequence + 1) & 0x0F
                if current.data.count >= current.total {
                    emit(Array(current.data.prefix(current.total)), from: frame)
                    partial = nil
                } else {
                    partial = current
                }

            case .flowControl:
                continue
            }
        }

        if partial != nil, let id = frames.first?.id {
            obdWarning("Incomplete multi-frame message from \(String(id, radix: 16))", category: .parsing)
        }
        return messages
    }
}

enum ParserError: Error, LocalizedError {
    case error(String)

    var errorDescription: String? {
        switch self {
        case let .error(message): return message
        }
    }
}
