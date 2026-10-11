//
//  protocol_legacy.swift
//
//
//  Created by kemo konteh on 5/15/24.
//

import Foundation
import OSLog

struct FramesByECU {
    let txID: ECUID
    var frames: [LegacyFrame]
}

public struct LegacyParcer {
    let messages: [LegacyMessage]
    let frames: [LegacyFrame]

    public init(_ lines: [String]) throws {
        let obdLines = lines
            .compactMap { $0.replacingOccurrences(of: " ", with: "") }
            .filter(\.isHex)

        // `try?`, not `try` — matches the CAN parser's resilience (see its own comment):
        // one malformed frame from a noisy K-line must not discard every other frame in
        // the response. This previously aborted the whole parse on a single bad frame.
        frames = obdLines.compactMap {
            try? LegacyFrame(raw: $0)
        }

        // Group by the raw source-address byte, not `txID` — same reasoning as the CAN
        // parser (see `CANParser.init`): legacy (ISO 9141-2 / ISO 14230 KWP) source
        // addresses are manufacturer-assigned per SAE J2178, not constrained to a small
        // fixed range, so `txID`'s `& 0x07` mask can (in principle, same as the 29-bit CAN
        // case this session hit on real hardware) collide two distinct ECUs together.
        let framesByECU = Dictionary(grouping: frames) { $0.rawAddress }
        messages = framesByECU.values.compactMap {
            try? LegacyMessage(frames: $0)
        }
    }
}

struct LegacyMessage: MessageProtocol {
    var frames: [LegacyFrame]
    public var data: Data?

    public var ecu: ECUID
    public var sourceAddress: UInt8 { frames.first?.rawAddress ?? 0 }

    init(frames: [LegacyFrame]) throws {
//        guard !frames.isEmpty else {
//            return nil
//        }
        self.frames = frames
        ecu = frames.first?.txID ?? .unknown

        switch frames.count {
        case 1:
            data = try parseSingleFrameMessage(frames)
        case 2...:
            data = try parseMultiFrameMessage(frames)
        default:
            throw ParserError.error("Invalid frame count")
        }
    }

    private func parseSingleFrameMessage(_ frames: [LegacyFrame]) throws -> Data {
        guard let frame = frames.first else { // Pre-validate the length
            throw ParserError.error("Frame validation failed")
        }

        let mode = frame.data.first

        if mode == 0x43 {
            var data = Data([0x43, 0x00])

            for frame in frames {
                data.append(frame.data.dropFirst())
            }

            return data
        } else {
            return frame.data.dropFirst()
        }
    }

    private func parseMultiFrameMessage(_ frames: [LegacyFrame]) throws -> Data {
        let mode = frames.first?.data.first

        if mode == 0x43 {
            var data = Data([0x43, 0x00])

            for frame in frames {
                data.append(frame.data.dropFirst())
            }

            return data
        } else {
            ///  generic multiline requests carry an order byte

            ///  Ex.
            ///           [      Frame       ]
            ///  48 6B 10 49 02 01 00 00 00 31 ck
            ///  48 6B 10 49 02 02 44 34 47 50 ck
            ///  48 6B 10 49 02 03 30 30 52 35 ck
            ///  etc...         [] [  Data   ]

            ///  becomes:
            ///  49 02 [] 00 00 00 31 44 34 47 50 30 30 52 35
            ///       |  [         ] [         ] [         ]
            ///   order byte is removed

            // `LegacyFrame.init` only requires 2 bytes of payload after stripping the
            // header/checksum, but every access below assumes at least 3 (the order byte
            // at index 2) — a short/truncated frame (plausible on a noisy K-line) must
            // throw here, not crash on an out-of-bounds subscript.
            guard frames.allSatisfy({ $0.data.count >= 3 }) else {
                throw ParserError.error("Frame too short to carry an order byte")
            }

            //  sort the frames by the order byte
            let sortedFrames = frames.sorted { $0.data[2] < $1.data[2] }

            // Check the sequence is complete, not just that it starts at 1 — the same class
            // of gap the CAN parser used to miss (see parser.swift's validateSequence): a
            // dropped frame here left `sortedFrames` short but still "starting at 1", so this
            // used to accumulate a truncated response instead of failing it outright.
            for (index, frame) in sortedFrames.enumerated() {
                guard frame.data[2] == index + 1 else {
                    throw ParserError.error("Order-byte gap: expected \(index + 1), got \(frame.data[2])")
                }
            }

            // now that they're in order, accumulate the data from each frame
            var data = Data()
            for frame in sortedFrames {
                // pop off the only the order byte
                data.append(frame.data.dropFirst(3))
            }

            return data
        }
    }

//    private func assembleData(firstFrame: LegacyFrame, consecutiveFrames: [LegacyFrame]) -> Data {
//        var assembledFrame: LegacyFrame = firstFrame
//        // Extract data from consecutive frames, skipping the PCI byte
//        for frame in consecutiveFrames {
//            assembledFrame.data.append(frame.data[1...])
//        }
//        return extractDataFromFrame(assembledFrame, startIndex: 3)
//    }
//
//    private func extractDataFromFrame(_ frame: LegacyFrame, startIndex: Int) -> Data? {
//        return nil
//    }
}

struct LegacyFrame {
    var raw: String
    var data = Data()
    var priority: UInt8
    var rxID: UInt8
    /// The untouched source-address byte — see `Frame.rawAddress` (parser.swift) for why
    /// this, not `txID`, is what frame grouping actually uses.
    var rawAddress: UInt8
    var txID: ECUID

    init(raw: String) throws {
        self.raw = raw
        let rawData = raw

        let dataBytes = rawData.hexBytes

        guard dataBytes.count >= 6, dataBytes.count <= 12 else {
            throw ParserError.error("Invalid frame size")
        }
        data = Data(dataBytes.dropFirst(3).dropLast())

        priority = dataBytes[0]
        rxID = dataBytes[1]
        rawAddress = dataBytes[2]
        txID = ECUID(rawValue: dataBytes[2] & 0x07) ?? .unknown
    }
}

public protocol MessageProtocol {
    var data: Data? { get }
    var ecu: ECUID { get }
    /// The untouched source-address byte the responding ECU used. Unlike `ecu` (whose
    /// `& 0x07`-derived label is only meaningful for 11-bit SAE J1979 addressing and
    /// degenerates on 29-bit buses, where e.g. 0x10 and 0x18 both label "engine"), this
    /// stays distinct per module — and on both addressing schemes the PRIMARY engine ECM
    /// is the numerically lowest responder (0x7E8 on 11-bit, 0x10 on 29-bit per SAE
    /// J2178), which is what "which ECU's answer is authoritative" decisions key off.
    var sourceAddress: UInt8 { get }
}

/// Picks the authoritative response when several ECUs answered one request:
/// 1. Keep only messages whose first payload byte echoes the requested PID (when given) —
///    discards a stale/foreign response that happens to share the buffer.
/// 2. Of those, take the lowest source address — the primary engine ECM on both 11-bit
///    (0x7E8 < 0x7E9...) and 29-bit (0x10 < 0x18...) addressing.
/// Deterministic, unlike Dictionary-order `.first`, which on a two-ECU vehicle picked a
/// different module from one read to the next.
func preferredECUMessage(_ messages: [MessageProtocol], pidEcho: UInt8? = nil) -> MessageProtocol? {
    var candidates = messages
    if let pidEcho {
        let matching = messages.filter { $0.data?.first == pidEcho }
        if !matching.isEmpty { candidates = matching }
    }
    return candidates.min { $0.sourceAddress < $1.sourceAddress }
}

class SAE_J1850_PWM: CANProtocol {
    let elmID = "1"
    let name = "SAE J1850 PWM"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseLegacy(lines)
    }
}

class SAE_J1850_VPW: CANProtocol {
    let elmID = "2"
    let name = "SAE J1850 VPW"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseLegacy(lines)
    }
}

class ISO_9141_2: CANProtocol {
    let elmID = "3"
    let name = "ISO 9141-2"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseLegacy(lines)
    }
}

class ISO_14230_4_KWP_5Baud: CANProtocol {
    let elmID = "4"
    let name = "ISO 14230-4 KWP (5 baud init)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseLegacy(lines)
    }
}

public class ISO_14230_4_KWP_Fast: CANProtocol {
    let elmID = "5"
    let name = "ISO 14230-4 KWP (fast init)"
    public init() {}

    public func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseLegacy(lines)
    }
}
