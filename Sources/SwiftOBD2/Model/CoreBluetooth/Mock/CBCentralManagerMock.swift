//
//  CBCentralManagerMock.swift
//  factory-tourguide-iOS
//
//  Created by kazuya ito on 2020/10/28.
//

import Foundation
import CoreBluetooth

public class CBCentralManagerMock : Mock, CBCentralManagerProtocol {
    public var delegate: CBCentralManagerDelegate?
    public var state: CBManagerState = .poweredOff
    public var isScanning: Bool = false
    public var deviceLocalName: String = "MockOBD"


    required public init(delegate: CBCentralManagerDelegate?, queue: DispatchQueue?, options: [String : Any]? = nil) {
        log(#function)
        
        self.delegate = delegate

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.state = .poweredOn
            
            if let delegate = self.delegate as? CBCentralManagerProtocolDelegate {
                delegate.didUpdateState(self)
            }
        }
        
    }
    
    public func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String : Any]? = nil) {
        log(#function)
        isScanning = true
    
        guard let delegate = delegate as? BLEManager else {
            return
        }
        DispatchQueue.main.async {
            let discoveredPeripheral = CBPeripheralMock(identifier: UUID(),
                                                        name: self.deviceLocalName,
                                                        manager: self)
            delegate.didDiscover(self,
                                 peripheral: discoveredPeripheral,
                                 advertisementData: [:],
                                 rssi: -30)
        }
    }
    
    public func stopScan() {
        log(#function)
        isScanning = false
    }
    
    public func connect(_ peripheral: CBPeripheralProtocol, options: [String : Any]? = nil) {
        log(#function)
        
        guard  let delegate = delegate as? CBCentralManagerProtocolDelegate else {
            return
        }
        DispatchQueue.main.async {
            delegate.didConnect(self,
                                peripheral: peripheral)
        }
    }

    public func cancelPeripheralConnection(_ peripheral: CBPeripheralProtocol) {
        log(#function)

        if let delegate = delegate as? CBCentralManagerProtocolDelegate {
            
            delegate.didDisconnect(self,
                                   peripheral: peripheral,
                                   error: nil)
            
        }
    }
    
    public func retrievePeripherals(_ identifiers: [UUID]) -> [CBPeripheralProtocol] {
        log(#function)

        return identifiers.map { CBPeripheralMock(identifier: $0,
                                                  name: deviceLocalName,
                                                  manager: self) }
    }
    
}
