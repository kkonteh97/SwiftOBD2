//
//  Peripheral.swift
//  SwiftUI-BLE-Project
//
//  Created by kazuya ito on 2021/02/02.
//

import CoreBluetooth

class Peripheral: Identifiable {
    var id: UUID
    var peripheral: CBPeripheralProtocol
    var name: String
    var advertisementData: [String : Any]
    var rssi: Int
    var discoverCount: Int
    
    init(_peripheral: CBPeripheralProtocol,
         _name: String,
         _advData: [String : Any]?,
         _rssi: NSNumber?,
         _discoverCount: Int) {
        id = UUID()
        peripheral = _peripheral
        name = _name
        advertisementData = _advData ?? [:]
        rssi = _rssi?.intValue ?? 0
        discoverCount = _discoverCount + 1
    }
}
