//
//  Characteristic.swift
//  factory-tourguide-iOS
//
//  Created by kazuya ito on 2020/10/29.
//

import CoreBluetooth

class Characteristic: Identifiable {
    var id: UUID
    var characteristic: CBCharacteristic
    var description: String
    var uuid: CBUUID
    var readValue: String
    var service: CBService

    init(_characteristic: CBCharacteristic,
         _description: String,
         _uuid: CBUUID,
         _readValue: String,
         _service: CBService) {
        
        id = UUID()
        characteristic = _characteristic
        description = _description == "" ? "NoName" : _description
        uuid = _uuid
        readValue = _readValue == "" ? "NoData" : _readValue
        service = _service
    }
}
