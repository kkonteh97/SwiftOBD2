//
//  protocol_legacy.swift
//
//
//  Created by kemo konteh on 5/15/24.
//
//  SAE J1850 (PWM / VPW), ISO 9141-2 and ISO 14230-4 (KWP2000): every frame carries a three byte
//  header and a trailing checksum.
//

import Foundation

/// A single frame of one of the pre-CAN protocols, as printed by the ELM327 with headers enabled.
struct LegacyFrame {
    /// Address of the ECU that sent the frame (third header byte).
    let source: UInt8
    /// Service bytes, without header nor checksum.
    let data: [UInt8]

    /// - Parameters:
    ///   - hex: one response line without spaces, e.g. `486B104100BE3FB813FF`.
    ///   - isKWP: ISO 14230 encodes the payload length in its first header byte.
    init?(hex: String, isKWP: Bool = false) {
        let bytes = hex.hexBytes
        // 3 header bytes + at least one data byte + checksum
        guard hex.count % 2 == 0, bytes.count >= 5 else { return nil }

        source = bytes[2]

        if isKWP, bytes[0] & 0x80 != 0 {
            var length = Int(bytes[0] & 0x3F)
            var start = 3
            if length == 0 {
                // Long frames carry the length in an extra header byte.
                length = Int(bytes[3])
                start = 4
            }
            let end = min(start + length, bytes.count - 1)
            guard end > start else { return nil }
            data = Array(bytes[start ..< end])
        } else {
            data = Array(bytes[3 ..< bytes.count - 1])
        }
    }

    /// The conventional role of the ECU owning this address (SAE J2178).
    var defaultECU: ECUID {
        switch source {
        case 0x10 ... 0x17: return .engine
        case 0x18 ... 0x1F: return .transmission
        default: return .unknown
        }
    }
}

public struct LegacyParcer {
    public let messages: [Message]

    public init(_ lines: [String], isKWP: Bool = false) throws {
        let hexLines = lines
            .map { $0.replacingOccurrences(of: " ", with: "") }
            .filter(\.isHex)
        let frames = hexLines.compactMap { LegacyFrame(hex: $0, isKWP: isKWP) }

        var order: [UInt8] = []
        var framesBySource: [UInt8: [LegacyFrame]] = [:]
        for frame in frames {
            if framesBySource[frame.source] == nil { order.append(frame.source) }
            framesBySource[frame.source, default: []].append(frame)
        }

        let assembled = order.flatMap { LegacyParcer.assemble(framesBySource[$0] ?? []) }
        if assembled.isEmpty, !hexLines.isEmpty {
            throw ParserError.error("No valid frame in \(hexLines)")
        }
        messages = assembled
    }

    /// Merges the frames one ECU sent in answer to a single request.
    private static func assemble(_ frames: [LegacyFrame]) -> [Message] {
        guard let first = frames.first, let service = first.data.first else { return [] }

        func message(_ payload: [UInt8]) -> Message {
            Message(address: UInt32(first.source), ecu: first.defaultECU, payload: payload, isCAN: false)
        }

        if frames.allSatisfy({ $0.data.first == service }) {
            switch service {
            case 0x43, 0x47, 0x4A:
                // Trouble codes: every frame repeats the service byte followed by up to three codes.
                return [message([service] + frames.flatMap { $0.data.dropFirst() })]

            case 0x49 where frames.allSatisfy({ $0.data.count > 3 && $0.data[1] == first.data[1] }):
                // Vehicle information: each frame carries a sequence number after the info type.
                //
                //           [      Frame       ]
                //  48 6B 10 49 02 01 00 00 00 31 ck
                //  48 6B 10 49 02 02 44 34 47 50 ck
                //  48 6B 10 49 02 03 30 30 52 35 ck
                //                 [] [  Data   ]
                let ordered = frames.sorted { $0.data[2] < $1.data[2] }
                return [message([service, first.data[1]] + ordered.flatMap { $0.data.dropFirst(3) })]

            default:
                break
            }
        }

        return frames.map { message($0.data) }
    }
}

class SAE_J1850_PWM: CANProtocol {
    let elmID = "1"
    let name = "SAE J1850 PWM"
    func parse(_ lines: [String]) throws -> [Message] {
        try LegacyParcer(lines).messages
    }
}

class SAE_J1850_VPW: CANProtocol {
    let elmID = "2"
    let name = "SAE J1850 VPW"
    func parse(_ lines: [String]) throws -> [Message] {
        try LegacyParcer(lines).messages
    }
}

class ISO_9141_2: CANProtocol {
    let elmID = "3"
    let name = "ISO 9141-2"
    func parse(_ lines: [String]) throws -> [Message] {
        try LegacyParcer(lines).messages
    }
}

class ISO_14230_4_KWP_5Baud: CANProtocol {
    let elmID = "4"
    let name = "ISO 14230-4 KWP (5 baud init)"
    func parse(_ lines: [String]) throws -> [Message] {
        try LegacyParcer(lines, isKWP: true).messages
    }
}

public class ISO_14230_4_KWP_Fast: CANProtocol {
    let elmID = "5"
    let name = "ISO 14230-4 KWP (fast init)"
    public init() {}

    public func parse(_ lines: [String]) throws -> [Message] {
        try LegacyParcer(lines, isKWP: true).messages
    }
}
