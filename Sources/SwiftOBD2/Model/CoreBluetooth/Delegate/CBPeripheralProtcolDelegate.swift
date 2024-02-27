//
//  CBPeripheralProtcolDelegate.swift
//  factory-tourguide-iOS
//
//  Created by kazuya ito on 2020/10/28.
//

import Foundation
import CoreBluetooth

// MARK: - CBPeripheral
protocol CBPeripheralProtocolDelegate {
    func didDiscoverServices(_ peripheral: CBPeripheralProtocol, error: Error?)
    func didDiscoverCharacteristics(_ peripheral: CBPeripheralProtocol, service: CBService, error: Error?)
    func didUpdateValue(_ peripheral: CBPeripheralProtocol, characteristic: CBCharacteristic, error: Error?)
}

public protocol CBPeripheralProtocol {
    var delegate: CBPeripheralDelegate? { get set }

    var name: String? { get }
    var identifier: UUID { get }
    var state: CBPeripheralState { get }
    var services: [CBService]? { get }
    var debugDescription: String { get }

    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService)
    func discoverDescriptors(for characteristic: CBCharacteristic)
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType)
    func readValue(for characteristic: CBCharacteristic)
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic)
}

extension CBPeripheral : CBPeripheralProtocol {}

// MARK: - CBCentralManager
public protocol CBCentralManagerProtocolDelegate {
    func didUpdateState(_ central: CBCentralManagerProtocol)
    
//    func willRestoreState(_ central: CBCentralManagerProtocol, dict: [String : Any])
    
    func didDiscover(_ central: CBCentralManagerProtocol,
                     peripheral: CBPeripheralProtocol,
                     advertisementData: [String : Any],
                     rssi: NSNumber)
    
    func didConnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol)
 
    func didFailToConnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol, error: Error?)

    func didDisconnect(_ central: CBCentralManagerProtocol, peripheral: CBPeripheralProtocol, error: Error?)

    func connectionEventDidOccur(_ central: CBCentralManagerProtocol,
                                 event: CBConnectionEvent,
                                 peripheral: CBPeripheralProtocol)

}

public protocol CBCentralManagerProtocol {
    var delegate: CBCentralManagerDelegate? { get set }
    var state: CBManagerState { get }
    var isScanning: Bool { get }
    
    init(delegate: CBCentralManagerDelegate?, queue: DispatchQueue?, options: [String : Any]?)

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String : Any]?)
    func stopScan()

    func connect(_ peripheral: CBPeripheralProtocol, options: [String : Any]?)
    func cancelPeripheralConnection(_ peripheral: CBPeripheralProtocol)
    func retrievePeripherals(_ identifiers: [UUID]) -> [CBPeripheralProtocol]
}

//func connectAsync(peripheral: CBPeripheralProtocol) async throws -> CBPeripheralProtocol

extension CBCentralManager : CBCentralManagerProtocol {
    public func connect(_ peripheral: CBPeripheralProtocol, options: [String: Any]?) {
        guard let peripheral = peripheral as? CBPeripheral else { return }
        connect(peripheral, options: options)
    }

    public func cancelPeripheralConnection(_ peripheral: CBPeripheralProtocol) {
        guard let peripheral = peripheral as? CBPeripheral else { return }
        cancelPeripheralConnection(peripheral)
    }
    
    public func retrievePeripherals(_ identifiers: [UUID]) -> [CBPeripheralProtocol] {
        return retrievePeripherals(withIdentifiers: identifiers)
    }
}
