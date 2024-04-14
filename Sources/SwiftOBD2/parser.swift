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

public enum ECUID: UInt8, Codable {
    case engine = 0x00
    case transmission = 0x01
    case unknown = 0x02
}

enum TxId: UInt8, Codable {
    case engine = 0x00
    case transmission = 0x01
}

public struct OBDParcer {
    public let messages: [Message]
    let frames: [Frame]

    public init?(_ lines: [String], idBits: Int) {
        let obdLines = lines
            .compactMap { $0.replacingOccurrences(of: " ", with: "") }
            .filter { $0.isHex }

        frames = obdLines.compactMap {
            if let frame = Frame(raw: $0, idBits: idBits) {
                return frame
            } else {
                print("Failed to create Frame for raw data: \($0)")
                return nil
            }
        }

        let framesByECU = Dictionary(grouping: frames) { $0.txID }

        messages = framesByECU.values.compactMap {
            Message(frames: $0)
        }
    }
}

public struct Message {
    var frames: [Frame]
    public var data: Data? {
        switch frames.count {
        case 1:
            return parseSingleFrameMessage(frames)
        case 2...:
            return parseMultiFrameMessage(frames)
        default:
            return nil
        }
    }

    var ecu: ECUID? {
        return frames.first?.txID
    }

    init?(frames: [Frame]) {
        guard !frames.isEmpty else {
            return nil
        }
        self.frames = frames
    }

    private func parseSingleFrameMessage(_ frames: [Frame]) -> Data? {
        
        guard let frame = frames.first, frame.type == .singleFrame,
              let dataLen = frame.dataLen, dataLen > 0,
                frame.data.count == dataLen + 1
        else { // Pre-validate the length
            print("Failed to parse single frame message")
            print("frame: \(frames.first)")
            return nil
        }
        return frame.data.dropFirst(2)
    }

    private func parseMultiFrameMessage(_ frames: [Frame]) -> Data? {
        guard let firstFrameValid = frames.first(where: { $0.type == .firstFrame }),
              let assembledData = assembleData(firstFrame: firstFrameValid, consecutiveFrames: frames.filter { $0.type == .consecutiveFrame })
        else {
            return nil
        }
        return assembledData
    }

    private func assembleData(firstFrame: Frame, consecutiveFrames: [Frame]) -> Data? {
        var assembledFrame: Frame = firstFrame
        // Extract data from consecutive frames, skipping the PCI byte
        for frame in consecutiveFrames {
            assembledFrame.data.append(frame.data[1...])
        }
        return extractDataFromFrame(assembledFrame, startIndex: 3)
    }

    private func extractDataFromFrame(_ frame: Frame, startIndex: Int) -> Data? {
        guard let frameDataLen = frame.dataLen else {
            return nil
        }
        let endIndex = startIndex + Int(frameDataLen) - 1
        guard endIndex <= frame.data.count else {
            return frame.data[startIndex...]
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
    var txID: ECUID
    var type: FrameType
    var seqIndex: UInt8 = 0 // Only used when type = CF
    var dataLen: UInt8?

    init?(raw: String, idBits: Int) {
        self.raw = raw
        var rawData = raw
        if idBits == 11 {
            rawData = "00000" + raw
        }

        let dataBytes = rawData.hexBytes

        data = Data(dataBytes.dropFirst(4))

//
//        guard dataBytes.count % 2 == 0, dataBytes.count >= 6, dataBytes.count <= 12 else {
//                print(dataBytes.count)
//                    print("invalid frame size")
//                    print(dataBytes.compactMap { String(format: "%02X", $0) }.joined(separator: " ") )
//                    return nil
//        }

        guard let txID = ECUID(rawValue: dataBytes[3] & 0x07), 
                let dataType = data.first,
              let type = FrameType(rawValue: dataType & 0xF0)
        else {
            print(dataBytes.compactMap { String(format: "%02X", $0) }.joined(separator: " "))
            print("invalid frame type")
            return nil
        }

        priority = dataBytes[2] & 0x0F
        addrMode = dataBytes[3] & 0xF0
        rxID = dataBytes[2]
        self.txID = txID
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
