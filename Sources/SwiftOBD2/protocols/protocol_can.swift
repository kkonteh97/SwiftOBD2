//
//  protocol_can.swift
//
//
//  Created by kemo konteh on 5/15/24.
//

import Foundation

/// Turns the lines printed by the adapter into ECU messages for one OBD protocol.
///
/// The name is historical: the legacy (non CAN) protocols conform to it as well.
protocol CANProtocol {
    var elmID: String { get }
    var name: String { get }

    func parse(_ lines: [String]) throws -> [Message]
}

class ISO_15765_4_11bit_500k: CANProtocol {
    let elmID = "6"
    let name = "ISO 15765-4 (CAN 11/500)"
    func parse(_ lines: [String]) throws -> [Message] {
        try CANParser(lines, idBits: 11).messages
    }
}

class ISO_15765_4_29bit_500k: CANProtocol {
    let elmID = "7"
    let name = "ISO 15765-4 (CAN 29/500)"
    func parse(_ lines: [String]) throws -> [Message] {
        try CANParser(lines, idBits: 29).messages
    }
}

class ISO_15765_4_11bit_250K: CANProtocol {
    let elmID = "8"
    let name = "ISO 15765-4 (CAN 11/250)"
    func parse(_ lines: [String]) throws -> [Message] {
        try CANParser(lines, idBits: 11).messages
    }
}

class ISO_15765_4_29bit_250k: CANProtocol {
    let elmID = "9"
    let name = "ISO 15765-4 (CAN 29/250)"
    func parse(_ lines: [String]) throws -> [Message] {
        try CANParser(lines, idBits: 29).messages
    }
}

/// SAE J1939 does not use the OBD-II services: only raw requests make sense on it.
class SAE_J1939: CANProtocol {
    let elmID = "A"
    let name = "SAE J1939 (CAN 29/250)"
    func parse(_ lines: [String]) throws -> [Message] {
        try CANParser(lines, idBits: 29).messages
    }
}

/// The two user defined CAN protocols of the ELM327 (`AT PB` / `AT PP 2C…2F`).
class UserCAN: CANProtocol {
    let elmID: String
    let name: String

    init(elmID: String, name: String) {
        self.elmID = elmID
        self.name = name
    }

    func parse(_ lines: [String]) throws -> [Message] {
        try CANParser(lines).messages
    }
}
