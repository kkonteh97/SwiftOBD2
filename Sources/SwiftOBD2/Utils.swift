//
//  Utils.swift
//  SmartOBD2
//
//  Created by kemo konteh on 8/31/23.
//

import Foundation

func bytesToInt(_ byteArray: Data) -> Int {
    var value = 0
    for byte in byteArray.prefix(8) {
        value = value << 8 | Int(byte)
    }
    return value
}

/// Interprets the lowest `length` bits of `value` as a two's complement signed number.
func twosComp(_ value: Int, length: Int) -> Int {
    guard length > 0, length < Int.bitWidth else { return value }
    let masked = value & ((1 << length) - 1)
    return masked & (1 << (length - 1)) != 0 ? masked - (1 << length) : masked
}

extension String {
    /// The bytes described by a string of hexadecimal digit pairs. Invalid pairs are skipped.
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

    /// The string without any whitespace, in uppercase: the canonical form of a command.
    var compactUppercased: String {
        uppercased().filter { !$0.isWhitespace }
    }
}

extension Sequence where Element == UInt8 {
    /// Uppercase hexadecimal representation without separator.
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}

extension Data {
    func bitCount() -> Int {
        reduce(0) { $0 + $1.nonzeroBitCount }
    }
}

public enum PROTOCOL: String, Codable, CaseIterable {
    case
        protocol1 = "1",
        protocol2 = "2",
        protocol3 = "3",
        protocol4 = "4",
        protocol5 = "5",
        protocol6 = "6",
        protocol7 = "7",
        protocol8 = "8",
        protocol9 = "9",
        protocolA = "A",
        protocolB = "B",
        protocolC = "C",
        NONE

    public var description: String {
        switch self {
        case .protocol1: return "1: SAE J1850 PWM (41.6 kbaud)"
        case .protocol2: return "2: SAE J1850 VPW (10.4 kbaud)"
        case .protocol3: return "3: ISO 9141-2 (5 baud init, 10.4 kbaud)"
        case .protocol4: return "4: ISO 14230-4 KWP (5 baud init, 10.4 kbaud)"
        case .protocol5: return "5: ISO 14230-4 KWP (fast init, 10.4 kbaud)"
        case .protocol6: return "6: ISO 15765-4 CAN (11 bit ID,500 Kbaud)"
        case .protocol7: return "7: ISO 15765-4 CAN (29 bit ID,500 Kbaud)"
        case .protocol8: return "8: ISO 15765-4 CAN (11 bit ID,250 Kbaud)"
        case .protocol9: return "9: ISO 15765-4 CAN (29 bit ID,250 Kbaud)"
        case .protocolA: return "A: SAE J1939 CAN (11* bit ID, 250* kbaud)"
        case .protocolB: return "B: USER1 CAN (11* bit ID, 125* kbaud)"
        case .protocolC: return "C: USER2 CAN (11* bit ID, 50* kbaud)"
        case .NONE: return "None"
        }
    }

    var idBits: Int {
        switch self {
        case .protocol6, .protocol8, .protocolB, .protocolC: return 11
        default: return 29
        }
    }

    /// `true` for the protocols carried over CAN (ISO 15765-4, SAE J1939 and the user defined ones).
    public var isCAN: Bool {
        switch self {
        case .protocol6, .protocol7, .protocol8, .protocol9, .protocolA, .protocolB, .protocolC: return true
        default: return false
        }
    }

    /// The header (`AT SH`) the ELM327 uses for standard OBD-II requests on this protocol.
    var defaultHeader: String? {
        switch self {
        case .protocol1: return "616AF1"
        case .protocol2, .protocol3: return "686AF1"
        case .protocol4, .protocol5: return "C133F1"
        case .protocol6, .protocol8: return "7DF"
        case .protocol7, .protocol9: return "18DB33F1"
        default: return nil
        }
    }

    /// Parses adapter output for this protocol.
    var parser: CANProtocol? {
        protocols[self]
    }

    func nextProtocol() -> PROTOCOL {
        let protocolMap: [PROTOCOL: PROTOCOL] = [
            .protocolC: .protocolB,
            .protocolB: .protocolA,
            .protocolA: .protocol9,
            .protocol9: .protocol8,
            .protocol8: .protocol7,
            .protocol7: .protocol6,
            .protocol6: .protocol5,
            .protocol5: .protocol4,
            .protocol4: .protocol3,
            .protocol3: .protocol2,
            .protocol2: .protocol1,
            .protocol1: .NONE,
        ]

        return protocolMap[self] ?? .NONE
    }

    var cmd: String {
        "ATSP\(rawValue)"
    }

    public static let asArray: [PROTOCOL] = [
        .protocol1, .protocol2, .protocol3, .protocol4, .protocol5,
        .protocol6, .protocol7, .protocol8, .protocol9, .protocolA,
        .protocolB, .protocolC, .NONE,
    ]
}

// dictionary of all the protocols
let protocols: [PROTOCOL: CANProtocol] = [
    .protocol1: SAE_J1850_PWM(),
    .protocol2: SAE_J1850_VPW(),
    .protocol3: ISO_9141_2(),
    .protocol4: ISO_14230_4_KWP_5Baud(),
    .protocol5: ISO_14230_4_KWP_Fast(),
    .protocol6: ISO_15765_4_11bit_500k(),
    .protocol7: ISO_15765_4_29bit_500k(),
    .protocol8: ISO_15765_4_11bit_250K(),
    .protocol9: ISO_15765_4_29bit_250k(),
    .protocolA: SAE_J1939(),
    .protocolB: UserCAN(elmID: "B", name: "USER1 CAN"),
    .protocolC: UserCAN(elmID: "C", name: "USER2 CAN"),
]
