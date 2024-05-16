//
//  File.swift
//
//
//  Created by kemo konteh on 5/15/24.
//

import Foundation

struct FramesByECU {
  let txID: UInt8
    var frames: [LegacyFrame]
}

public struct LegacyParcer {
    public let messages: [LegacyMessage]
    let frames: [LegacyFrame]

    public init?(_ lines: [String]) {
        let obdLines = lines
            .compactMap { $0.replacingOccurrences(of: " ", with: "") }
            .filter { $0.isHex }

        frames = obdLines.compactMap {
            if let frame = LegacyFrame(raw: $0) {
                return frame
            } else {
                print("Failed to create Frame for raw data: \($0)")
                return nil
            }
        }

        let framesByECU: [FramesByECU] = frames.reduce(into: []) { result, frame in
          if let existingIndex = result.firstIndex(where: { $0.txID == frame.txID }) {
            result[existingIndex].frames.append(frame)
          } else {
            result.append(FramesByECU(txID: frame.txID, frames: [frame]))
          }
        }

//        print("framesByECU: \(framesByECU.first?.frames.first?.data.compactMap { String(format: "%02X", $0) })")

        messages = framesByECU.compactMap {
            LegacyMessage(frames: $0.frames)
        }
    }
}

struct LegacyFrame {
    var raw: String
    var data = Data()
    var priority: UInt8
//    var addrMode: UInt8
    var rxID: UInt8
    var txID: UInt8
//    var type: FrameType
//    var seqIndex: UInt8 = 0 // Only used when type = CF
//    var dataLen: UInt8?

    init?(raw: String) {
        self.raw = raw
        var rawData = raw

        let dataBytes = rawData.hexBytes

        data = Data(dataBytes.dropFirst(3))

//        print("data: \(data.compactMap { String(format: "%02X", $0) })")
//        print("dataBytes: \(dataBytes.compactMap { String(format: "%02X", $0) })")

//
//        guard dataBytes.count % 2 == 0, dataBytes.count >= 6, dataBytes.count <= 12 else {
//                print(dataBytes.count)
//                    print("invalid frame size")
//                    print(dataBytes.compactMap { String(format: "%02X", $0) }.joined(separator: " ") )
//                    return nil
//        }

//        guard let dataType = data.first,
//              let type = FrameType(rawValue: dataType & 0xF0)
//        else {
//            print(dataBytes.compactMap { String(format: "%02X", $0) })
//            print("invalid frame type")
//            return nil
//        }

        priority = dataBytes[0]
        rxID = dataBytes[1]
        self.txID = dataBytes[2]

//        switch type {
//        case .singleFrame:
//            dataLen = (data[0] & 0x0F)
//        case .firstFrame:
//            dataLen = ((UInt8(data[0] & 0x0F) << 8) + UInt8(data[1]))
//        case .consecutiveFrame:
//            seqIndex = data[0] & 0x0F
//        }
    }
}

public struct LegacyMessage {
    var frames: [LegacyFrame]
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

    var ecu: UInt8? {
        return frames.first?.txID
    }

    init?(frames: [LegacyFrame]) {
        guard !frames.isEmpty else {
            return nil
        }
        self.frames = frames
    }

    private func parseSingleFrameMessage(_ frames: [LegacyFrame]) -> Data? {

        guard let frame = frames.first else { // Pre-validate the length
            print("Failed to parse single frame message")
            print("frame: \(String(describing: frames.first))")
            return nil
        }
        return frame.data.dropFirst()
    }

    private func parseMultiFrameMessage(_ frames: [LegacyFrame]) -> Data? {
        print("Parsing multi-frame message")
        return nil
    }

    private func assembleData(firstFrame: LegacyFrame, consecutiveFrames: [LegacyFrame]) -> Data? {
        var assembledFrame: LegacyFrame = firstFrame
        // Extract data from consecutive frames, skipping the PCI byte
        for frame in consecutiveFrames {
            assembledFrame.data.append(frame.data[1...])
        }
        return extractDataFromFrame(assembledFrame, startIndex: 3)
    }

    private func extractDataFromFrame(_ frame: LegacyFrame, startIndex: Int) -> Data? {
        return nil
    }
}

class SAE_J1850_PWM: CANProtocol {
    let elmID = "1"
    let name = "SAE J1850 PWM"
    func parcer(_ lines: [String]) -> Data? {
        guard let messages = LegacyParcer(lines)?.messages else {
            return nil
        }

        return messages.first?.data
    }
}

class SAE_J1850_VPW: CANProtocol {
    let elmID = "2"
    let name = "SAE J1850 VPW"
    func parcer(_ lines: [String]) -> Data? {
        guard let messages = LegacyParcer(lines)?.messages else {
            return nil
        }

        return messages.first?.data
    }
}

class ISO_9141_2: CANProtocol {
    let elmID = "3"
    let name = "ISO 9141-2"
    func parcer(_ lines: [String]) -> Data? {
        guard let messages = LegacyParcer(lines)?.messages else {
            return nil
        }

        return messages.first?.data
    }
}

class ISO_14230_4_KWP_5Baud: CANProtocol {
    let elmID = "4"
    let name = "ISO 14230-4 KWP (5 baud init)"
    func parcer(_ lines: [String]) -> Data? {
        guard let messages = LegacyParcer(lines)?.messages else {
            return nil
        }
        return messages.first?.data
    }
}

public class ISO_14230_4_KWP_Fast: CANProtocol {
    let elmID = "5"
    let name = "ISO 14230-4 KWP (fast init)"
    public init() {}

    public func parcer(_ lines: [String]) -> Data? {
        guard let messages = LegacyParcer(lines)?.messages else {
            return nil
        }

        for message in messages {
//            print("ECU: \(String(format: "%02X", message.ecu ?? 0))")
//            print("Data: \(message.data?.compactMap { String(format: "%02X", $0) } ?? [])")
        }


        return messages.first?.data
    }
}
