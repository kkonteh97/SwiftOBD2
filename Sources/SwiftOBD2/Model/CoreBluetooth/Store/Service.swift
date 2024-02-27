//
//  Service.swift
//  SwiftUI-BLE-Project
//
//  Created by kazuya ito on 2021/02/03.
//

import CoreBluetooth

class Service: Identifiable {
    var id: UUID
    var uuid: CBUUID
    var service: CBService

    init(_uuid: CBUUID,
         _service: CBService) {
        
        id = UUID()
        uuid = _uuid
        service = _service
    }
}
