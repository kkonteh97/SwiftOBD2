//
//  File.swift
//
//
//  Created by kemo konteh on 5/15/24.
//

import Foundation
import OSLog

let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "parcer")

struct FramesByECU {
  let txID: ECUID
    var frames: [LegacyFrame]
}

public struct LegacyParcer {
    let messages: [LegacyMessage]
    let frames: [LegacyFrame]

    public init?(_ lines: [String]) {
        let obdLines = lines
            .compactMap { $0.replacingOccurrences(of: " ", with: "") }
            .filter { $0.isHex }

        frames = obdLines.compactMap {
            if let frame = LegacyFrame(raw: $0) {
                return frame
            } else {
                logger.error("Failed to create Frame for raw data: \($0)")
                return nil
            }
        }

        let framesByECU = Dictionary(grouping: frames) { $0.txID }
        messages = framesByECU.values.compactMap {
            LegacyMessage(frames: $0)
        }
    }
}

struct LegacyMessage: MessageProtocol {
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

    public var ecu: ECUID {
        return frames.first?.txID ?? .unknown
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
            return nil
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

    private func parseMultiFrameMessage(_ frames: [LegacyFrame]) -> Data? {
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

            //  sort the frames by the order byte
            let sortedFrames = frames.sorted { $0.data[2] < $1.data[2] }

            // check contiguity
            guard sortedFrames.first?.data[2] == 1 else {
                print("Invalid order byte")
                return nil
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


struct LegacyFrame {
    var raw: String
    var data = Data()
    var priority: UInt8
    var rxID: UInt8
    var txID: ECUID

    init?(raw: String) {
        self.raw = raw
        var rawData = raw

        let dataBytes = rawData.hexBytes

        data = Data(dataBytes.dropFirst(3).dropLast())
        guard dataBytes.count >= 6, dataBytes.count <= 12 else {
            print("invalid frame size", dataBytes.count, dataBytes.compactMap { String(format: "%02X", $0) }.joined(separator: " "))
            return nil
        }

        priority = dataBytes[0]
        rxID = dataBytes[1]
        self.txID = ECUID(rawValue: dataBytes[2] & 0x07) ?? .unknown
    }
}

public protocol MessageProtocol {
    var data: Data? { get }
    var ecu: ECUID { get }
}

class SAE_J1850_PWM: CANProtocol {
    let elmID = "1"
    let name = "SAE J1850 PWM"
    func parce(_ lines: [String]) -> [MessageProtocol] {
        guard let messages = LegacyParcer(lines)?.messages else {
            return []
        }

        return messages
    }
}

class SAE_J1850_VPW: CANProtocol {
    let elmID = "2"
    let name = "SAE J1850 VPW"
    func parce(_ lines: [String]) -> [MessageProtocol] {
        guard let messages = LegacyParcer(lines)?.messages else {
            return []
        }

        return messages
    }
}

class ISO_9141_2: CANProtocol {
    let elmID = "3"
    let name = "ISO 9141-2"
    func parce(_ lines: [String]) -> [MessageProtocol] {
        guard let messages = LegacyParcer(lines)?.messages else {
            return []
        }

        return messages
    }
}

class ISO_14230_4_KWP_5Baud: CANProtocol {
    let elmID = "4"
    let name = "ISO 14230-4 KWP (5 baud init)"
    func parce(_ lines: [String]) -> [MessageProtocol] {
        guard let messages = LegacyParcer(lines)?.messages else {
            return []
        }
        return messages
    }
}

public class ISO_14230_4_KWP_Fast: CANProtocol {
    let elmID = "5"
    let name = "ISO 14230-4 KWP (fast init)"
    public init() {}

    public func parce(_ lines: [String]) -> [MessageProtocol] {
        guard let messages = LegacyParcer(lines)?.messages else {
            return []
        }

        for message in messages {
//            print("ECU: \(String(format: "%02X", message.ecu ?? 0))")
//            print("Data: \(message.data?.compactMap { String(format: "%02X", $0) } ?? [])")
        }


        return messages
    }
}
