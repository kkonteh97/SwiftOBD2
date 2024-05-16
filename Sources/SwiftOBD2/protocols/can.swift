//
//  File.swift
//
//
//  Created by kemo konteh on 5/15/24.
//

import Foundation

class ISO_15765_4_11bit_500k: CANProtocol {
    let elmID = "6"
    let name = "ISO 15765-4 (CAN 11/500)"
    func parcer(_ lines: [String])  -> Data? {
        guard let messages = CANParcer(lines, idBits: 11)?.messages else {
            return nil
        }

        return messages.first?.data
    }
}

class ISO_15765_4_29bit_500k: CANProtocol {
    let elmID = "7"
    let name = "ISO 15765-4 (CAN 29/500)"
    func parcer(_ lines: [String])  -> Data? {
        guard let messages = CANParcer(lines, idBits: 29)?.messages else {
            return nil
        }

        return messages.first?.data
    }
}

class ISO_15765_4_11bit_250K: CANProtocol {
    let elmID = "8"
    let name = "ISO 15765-4 (CAN 11/250)"
    func parcer(_ lines: [String])  -> Data? {
        guard let messages = CANParcer(lines, idBits: 11)?.messages else {
            return nil
        }

        return messages.first?.data
    }
}

class ISO_15765_4_29bit_250k: CANProtocol {
    let elmID = "9"
    let name = "ISO 15765-4 (CAN 29/250)"
    func parcer(_ lines: [String])  -> Data? {
        guard let messages = CANParcer(lines, idBits: 29)?.messages else {
            return nil
        }

        return messages.first?.data
    }

}

class SAE_J1939: CANProtocol {
    let elmID = "A"
    let name = "SAE J1939 (CAN 29/250)"
    func parcer(_ lines: [String])  -> Data? {
        guard let messages = CANParcer(lines, idBits: 29)?.messages else {
            return nil
        }

        return messages.first?.data
    }
}
