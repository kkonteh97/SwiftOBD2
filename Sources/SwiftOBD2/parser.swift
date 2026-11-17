//
//  parser.swift
//  SmartOBD2
//
//  Created by kemo konteh on 9/19/23.
//

import Foundation

enum FrameType: UInt8, Codable {
    case singleFrame = 0x00
    case firstFrame = 0x10
    case consecutiveFrame = 0x20
}

/// `Sendable`: a `UInt8` raw enum with no associated values, so it is inherently
/// safe to pass across isolation domains. Declared explicitly because consumers
/// build with strict concurrency and default main-actor isolation, where a
/// `[ECUID: …]` dictionary otherwise cannot cross off the main actor.
public enum ECUID: UInt8, Codable, Sendable {
    case engine = 0x00
    case transmission = 0x01
    case unknown = 0x02
    case becm = 0x04

    public var description: String {
        switch self {
        case .engine:
            return "Engine"
        case .transmission:
            return "Transmission"
        case .unknown:
            return "Unknown"
        case .becm:
            return "BECM"
        }
    }
}

enum TxId: UInt8, Codable {
    case engine = 0x00
    case transmission = 0x01
}

public struct CANParser {
    public let messages: [Message]
    let frames: [Frame]

    public init(_ lines: [String], idBits: Int) throws {
        let obdLines = lines
            .map { $0.replacingOccurrences(of: " ", with: "") }
            .filter(\.isHex)

        // Skip individually-malformed frames rather than aborting the whole
        // response: real adapter output interleaves padding, negative-response
        // ($7F) and the occasional truncated line, and one bad frame must not
        // discard every valid ECU reply (which previously surfaced as an empty
        // "no trouble codes" result). Frame.init still logs each rejection.
        frames = obdLines.compactMap { try? Frame(raw: $0, idBits: idBits) }

        // Group by the raw address byte, not `txID` — `txID`'s `& 0x07` mask only means
        // anything for the 11-bit SAE J1979 functional range (0x7E8-0x7EF, where the low
        // nibble directly IS the 0-7 ECU index). On a 29-bit bus (ISO 15765-4 29-bit,
        // protocol 7/9 — common on Chrysler/Jeep/FCA and others), source addresses like
        // 0x10 and 0x18 both mask to 0 and collapse onto the same `ECUID.engine` bucket:
        // two physically distinct ECUs' single-frame replies to the same request got
        // merged into one 2-frame group, which `Message.init` then tried to decode as a
        // multi-frame ISO-TP sequence instead of two separate single-frame messages —
        // failing outright (no `.firstFrame` to anchor on) and silently discarding both
        // ECUs' data. Grouping by the untouched byte keeps distinct addresses distinct
        // regardless of ID width; `txID` is still computed below for display purposes.
        let framesByECU = Dictionary(grouping: frames) { $0.rawAddress }

        // Likewise tolerate one ECU's frames failing to assemble without losing
        // the others.
        messages = framesByECU.values.compactMap { try? Message(frames: $0) }
    }
}

public struct Message: MessageProtocol {
    var frames: [Frame]
    public var data: Data?

    public var ecu: ECUID {
        frames.first?.txID ?? .unknown
    }

    public var sourceAddress: UInt8 {
        frames.first?.rawAddress ?? 0
    }

    init(frames: [Frame]) throws {
        self.frames = frames
        switch frames.count {
        case 1:
            data = try parseSingleFrameMessage(frames)
        case 2...:
            data = try parseMultiFrameMessage(frames)
        default:
            throw ParserError.error("Invalid frame count")
        }
    }

    private func parseSingleFrameMessage(_ frames: [Frame]) throws -> Data {
        guard let frame = frames.first, frame.type == .singleFrame,
              let dataLen = frame.dataLen, dataLen > 0,
              frame.data.count >= dataLen + 1
        else { // Pre-validate the length
            throw ParserError.error("Frame validation failed")
        }
        // The PCI length nibble counts [mode-echo byte + real payload] and says nothing
        // about what follows — a CAN frame shorter than 8 bytes gets padded (ISO 15765-2
        // specifies 0xCC, though 0xAA/0x55 are common in practice), and this used to
        // return everything after the mode echo, padding included. Harmless for
        // fixed-offset PID decoders (they only ever read the bytes they need), but
        // DTCDecoder walks the ENTIRE length in 2-byte strides — non-zero padding bytes
        // there decode as a phantom trouble code that has nothing to do with the vehicle.
        let payloadLength = Int(dataLen) - 1
        return frame.data.dropFirst(2).prefix(payloadLength)
    }

    private func parseMultiFrameMessage(_ frames: [Frame]) throws -> Data {
        guard let firstFrame = frames.first(where: { $0.type == .firstFrame }) else {
            throw ParserError.error("Failed to parse multi frame message")
        }
        let consecutiveFrames = frames.filter { $0.type == .consecutiveFrame }
        try validateSequence(consecutiveFrames)
        return try assembleData(firstFrame: firstFrame, consecutiveFrames: consecutiveFrames)
    }

    /// ISO-TP consecutive frames are numbered 1, 2, 3, … (wrapping 15→0) with no
    /// gaps. A BLE notification dropped mid-transfer used to go unnoticed here —
    /// `assembleData` just concatenated whatever frames DID arrive, in receive
    /// order, silently shifting every byte after the gap. That produces a
    /// plausible-looking but wrong result (e.g. a bogus trouble code) instead of
    /// a clean failure. Reject anything but a complete, in-order run.
    private func validateSequence(_ consecutiveFrames: [Frame]) throws {
        guard !consecutiveFrames.isEmpty else { return }
        var expected: UInt8 = 1
        for frame in consecutiveFrames {
            guard frame.seqIndex == expected else {
                throw ParserError.error("Consecutive-frame gap: expected sequence \(expected), got \(frame.seqIndex)")
            }
            expected = expected == 15 ? 0 : expected + 1
        }
    }

    private func assembleData(firstFrame: Frame, consecutiveFrames: [Frame]) throws -> Data {
        var assembledFrame: Frame = firstFrame
        // Extract data from consecutive frames, skipping the PCI byte
        for frame in consecutiveFrames {
            assembledFrame.data.append(frame.data[1...])
        }
        return try extractDataFromFrame(assembledFrame, startIndex: 3)
    }

    private func extractDataFromFrame(_ frame: Frame, startIndex: Int) throws -> Data {
        guard let frameDataLen = frame.dataLen else {
            throw ParserError.error("Failed to extract data from frame")
        }
        let endIndex = startIndex + Int(frameDataLen) - 1
        // A short assembly (a trailing consecutive frame never arrived) used to
        // fall through and return whatever partial bytes were on hand — a
        // truncated-but-plausible byte string that decoders would happily
        // misinterpret. Incomplete data must fail, not degrade silently.
        guard endIndex <= frame.data.count else {
            throw ParserError.error("Incomplete frame: expected \(endIndex) bytes, got \(frame.data.count)")
        }
        return frame.data[startIndex ..< endIndex]
    }
}

struct Frame {
    var raw: String
    var data = Data()
    var priority: UInt8
    var addrMode: UInt8
    var rxID: UInt8
    /// The untouched source-address byte (`dataBytes[3]`) — used to group frames by ECU.
    /// Unlike `txID`, this stays distinct across every possible address regardless of
    /// ID width, which is what frame reassembly actually depends on being correct.
    var rawAddress: UInt8
    var txID: ECUID
    var type: FrameType
    var seqIndex: UInt8 = 0 // Only used when type = CF
    var dataLen: UInt8?

    init(raw: String, idBits: Int) throws {
        self.raw = raw

        let paddedRawData = idBits == 11 ? "00000" + raw : raw

        let dataBytes = paddedRawData.hexBytes

        data = Data(dataBytes.dropFirst(4))

        guard dataBytes.count >= 6, dataBytes.count <= 12 else {
            obdError("Invalid frame size: \(dataBytes.count) bytes", category: .parsing)
            OBDLogger.shared.logParseError("Frame size out of range (6-12 bytes)", data: Data(dataBytes), expectedFormat: "6-12 bytes")
            throw ParserError.error("Invalid frame size")
        }

        guard let dataType = data.first,
              let type = FrameType(rawValue: dataType & 0xF0)
        else {
            obdError("Invalid frame type detected", category: .parsing)
            OBDLogger.shared.logParseError("Unknown frame type", data: Data(dataBytes), expectedFormat: "Valid FrameType enum value")
            throw ParserError.error("Invalid frame type")
        }

        priority = dataBytes[2] & 0x0F
        addrMode = dataBytes[3] & 0xF0
        rxID = dataBytes[2]
        rawAddress = dataBytes[3]
        txID = ECUID(rawValue: dataBytes[3] & 0x07) ?? .unknown
        self.type = type

        switch type {
        case .singleFrame:
            dataLen = (data[0] & 0x0F)
        case .firstFrame:
            dataLen = ((UInt8(data[0] & 0x0F) << 8) + UInt8(data[1]))
        case .consecutiveFrame:
            seqIndex = data[0] & 0x0F
        }
    }
}

enum ParserError: Error, LocalizedError {
    case error(String)

    var errorDescription: String? {
        switch self {
        case .error(let message): return message
        }
    }
}
