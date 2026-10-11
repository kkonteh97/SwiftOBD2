//
//  protocol_can.swift
//
//
//  Created by kemo konteh on 5/15/24.
//

import Foundation

protocol CANProtocol {
    var elmID: String { get }
    var name: String { get }

    func parse(_ lines: [String]) throws -> [MessageProtocol]
}

extension CANProtocol {
    func parseDefault(_ lines: [String], idBits: Int) throws -> [MessageProtocol] {
        try CANParser(lines, idBits: idBits).messages
    }

    func parseLegacy(_ lines: [String]) throws -> [MessageProtocol] {
        let messages = try LegacyParcer(lines).messages
        return messages
    }
}

class ISO_15765_4_11bit_500k: CANProtocol {
    let elmID = "6"
    let name = "ISO 15765-4 (CAN 11/500)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: 11)
    }
}

// The 29-bit variants MUST pass idBits: 29. `Frame.init` prepends "00000" padding for
// 11-bit frames (whose printed header is only 3 hex chars); applying that to an
// already-full 29-bit line ("18DAF118...", 8 header chars) makes the hex string an odd
// length, shifts every byte boundary by half a nibble, and inflates a 12-byte frame to
// 14 garbage bytes — which the 6...12 size guard then rejects. Net effect before this
// fix: EVERY frame from a 29-bit vehicle (e.g. FCA/Jeep) was silently discarded — no
// VIN, no supported PIDs, no sensors — while protocol detection still "succeeded"
// because it greps the raw text for "41 00" without parsing.
class ISO_15765_4_29bit_500k: CANProtocol {
    let elmID = "7"
    let name = "ISO 15765-4 (CAN 29/500)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: 29)
    }
}

class ISO_15765_4_11bit_250K: CANProtocol {
    let elmID = "8"
    let name = "ISO 15765-4 (CAN 11/250)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: 11)
    }
}

class ISO_15765_4_29bit_250k: CANProtocol {
    let elmID = "9"
    let name = "ISO 15765-4 (CAN 29/250)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        try parseDefault(lines, idBits: 29)
    }
}

class SAE_J1939: CANProtocol {
    let elmID = "A"
    let name = "SAE J1939 (CAN 29/250)"
    func parse(_ lines: [String]) throws -> [MessageProtocol] {
        // J1939 IDs are 29-bit too. Note frame slicing is the only thing this fixes —
        // J1939's application layer (PGN/SPN) is a different world from J1979 PIDs and
        // is not otherwise supported by this package.
        try parseDefault(lines, idBits: 29)
    }
}
