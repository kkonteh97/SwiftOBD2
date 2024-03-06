//
//  ELM327Parser.swift
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

enum FrameError: Error {
    case oddFrame
    case invalidFrameSize
    case invalidSingleFrame
    case noDataInSingleFrame
    case missingDataLength
    case invalidDataLength
    case nonContiguousFrame
    case missingDataInFrame
    case missingFirstFrame
    case missingAssembledData
    case missingDataLengthInFrame
}

extension String {
    var isHex: Bool {
        return !isEmpty && allSatisfy { $0.isHexDigit }
    }
}

public struct OBDParcer {
    let idBits: Int
    public let messages: [Message]
    let frames: [Frame]

    public init(_ lines: [String], idBits: Int) throws {
        self.idBits = idBits
        let obdLines = lines
            .compactMap { $0.replacingOccurrences(of: " ", with: "") }
            .filter { $0.isHex }

        self.frames = obdLines.compactMap {
            if let frame = Frame(raw: $0, idBits: idBits) {
                return frame
            } else {
                print("Failed to create Frame for raw data: \($0)")
                return nil
            }
        }

        let framesByECU = Dictionary(grouping: frames) { $0.txID }

        self.messages = try framesByECU.values.compactMap {
            try Message(frames: $0)
        }

        guard !messages.isEmpty else {
            throw OBDParcerError.noMessages
        }
    }
}

public struct Message {
    var frames: [Frame]
    public var data: Data? {
          do {
              switch frames.count {
              case 1:
                  return try parseSingleFrameMessage(frames)
              case 2...:
                  return try parseMultiFrameMessage(frames)
              default:
                  print(FrameError.invalidFrameSize)
                  return nil
              }
          } catch {
              print(error)
              return nil
          }
      }

    var ecu: ECUID? {
        return frames.first?.txID
    }

    init(frames: [Frame], data: Data = Data()) throws {
        guard !frames.isEmpty else {
            throw FrameError.invalidFrameSize
        }
        self.frames = frames
    }

    private func parseSingleFrameMessage(_ frames: [Frame]) throws -> Data {
        guard let frame = frames.first, frame.type == .singleFrame, let dataLen = frame.dataLen, dataLen > 0 else {
            throw FrameError.invalidSingleFrame
        }
        return Data(frame.data[2..<(1 + Int(dataLen))])
    }

    private func parseMultiFrameMessage(_ frames: [Frame]) throws -> Data {
        guard let firstFrameValid = frames.first(where: { $0.type == .firstFrame }),
              let assembledData = try? assembleData(firstFrame: firstFrameValid, consecutiveFrames: frames.filter { $0.type == .consecutiveFrame }) else {
            throw FrameError.missingFirstFrame
        }
        return assembledData
    }

    private func assembleData(firstFrame: Frame, consecutiveFrames: [Frame]) throws -> Data? {
        var assembledFrame: Frame = firstFrame
        // Extract data from consecutive frames, skipping the PCI byte
        for frame in consecutiveFrames {
            assembledFrame.data.append(frame.data[1...])
        }
        guard let extractedData = try extractDataFromFrame(assembledFrame, startIndex: 3) else {
            throw FrameError.missingDataInFrame
        }
        return extractedData
    }

    private func extractDataFromFrame(_ frame: Frame, startIndex: Int) throws -> Data? {
        guard let frameDataLen = frame.dataLen else {
            throw FrameError.missingDataLengthInFrame
        }
        let endIndex = startIndex + Int(frameDataLen) - 1
        guard endIndex <= frame.data.count else {
            return frame.data[startIndex...]
        }
        return frame.data[startIndex..<endIndex]
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

        let dataBytes = Data(rawData.hexBytes)

        self.data = Data(dataBytes.dropFirst(4))

//
//        guard dataBytes.count % 2 == 0, dataBytes.count >= 6, dataBytes.count <= 12 else {
//                print(dataBytes.count)
//                    print("invalid frame size")
//                    print(dataBytes.compactMap { String(format: "%02X", $0) }.joined(separator: " ") )
//                    return nil
//        }

        guard let txID = ECUID(rawValue: dataBytes[3] & 0x07),
              let type = FrameType(rawValue: data[0] & 0xF0) else {
                    return nil
        }

        self.priority = dataBytes[2] & 0x0F
        self.addrMode = dataBytes[3] & 0xF0
        self.rxID = dataBytes[2]
        self.txID = txID
        self.type = type

        switch type {
            case .singleFrame:
                self.dataLen = (data[0] & 0x0F)
            case .firstFrame:
                self.dataLen = ((UInt8(data[0] & 0x0F) << 8) + UInt8(data[1]))
            case .consecutiveFrame:
                self.seqIndex = data[0] & 0x0F
        }
    }
}

enum OBDParcerError: Error {
    case noMessages
}
