//
//  Utils.swift
//  SmartOBD2
//
//  Created by kemo konteh on 8/31/23.
//

import Foundation

func bytesToInt(_ byteArray: Data) -> Int {
    var value = 0
    var power = 0

    for byte in byteArray.reversed() {
        value += Int(byte) << power
        power += 8
    }
    return value
}

// enum RESPONSE {
//
//    enum ERROR: String {
//
//        case QUESTION_MARK = "?",
//             ACT_ALERT = "ACT ALERT",
//             BUFFER_FULL = "BUFFER FULL",
//             BUS_BUSSY = "BUS BUSSY",
//             BUS_ERROR = "BUS ERROR",
//             CAN_ERROR = "CAN ERROR",
//             DATA_ERROR = "DATA ERROR",
//             ERRxx = "ERR",
//             FB_ERROR = "FB ERROR",
//             LP_ALERT = "LP ALERT",
//             LV_RESET = "LV RESET",
//             NO_DATA = "NO DATA",
//             RX_ERROR = "RX ERROR",
//             STOPPED = "STOPPED",
//             UNABLE_TO_CONNECT = "UNABLE TO CONNECT"
//
//        static let asArray: [ERROR] = [QUESTION_MARK, ACT_ALERT, BUFFER_FULL, BUS_BUSSY,
//                                       BUS_ERROR, CAN_ERROR, DATA_ERROR, ERRxx, FB_ERROR,
//                                       LP_ALERT, LV_RESET, NO_DATA, RX_ERROR,STOPPED,
//                                       UNABLE_TO_CONNECT]
//    }
// }

public enum PROTOCOL: String, Codable {
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
        case .protocolC: return "C: USER1 CAN (11* bit ID, 50* kbaud)"
        case .NONE: return "None"
        }
    }

    var idBits: Int {
        switch self {
        case .protocol6, .protocol8, .protocolB: return 11
        default: return 29
        }
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
            .protocol1: .NONE
        ]

        return protocolMap[self] ?? .NONE
    }

    var cmd: String {
        switch self {
        case .protocol1:
            return "ATSP1"

        case .protocol2:
            return "ATSP2"

        case .protocol3:
            return "ATSP3"

        case .protocol4:
            return "ATSP4"

        case .protocol5:
            return "ATSP5"

        case .protocol6:
            return "ATSP6"

        case .protocol7:
            return "ATSP7"

        case .protocol8:
            return "ATSP8"

        case .protocol9:
            return "ATSP9"

        case .protocolA:
            return "ATSPA"

        case .protocolB:
            return "ATSPB"

        case .protocolC:
            return "ATSPC"

        case .NONE:
            return ""
        }
    }

    public static let asArray: [PROTOCOL] = [
        protocol1,
        protocol2,
        protocol3,
        protocol4,
        protocol5,
        protocol6,
        protocol7,
        protocol8,
        protocol9,
        protocolA,
        protocolB,
        protocolC,
        NONE
    ]
}

// enum GET_DTCS_STEP{
//
//    //Setup goes in this order
//    case
//    send_0101,
//    send_03,
//    finished,
//    none
//
//    func next() -> GET_DTCS_STEP{
//        switch (self) {
//
//        case .send_0101: return .send_03
//        case .send_03: return .finished
//        case .finished: return .none
//        case .none: return .none
//        }
//    }
// } //END GET_DTCS_STEP
