//
//  SettingsScreenViewModel.swift
//  SmartOBD2
//
//  Created by kemo konteh on 8/31/23.
//

import Foundation
import CoreBluetooth
import Combine

struct VINResults: Codable {
    let Results: [VINInfo]
}

struct VINInfo: Codable, Hashable {
    let Make: String
    let Model: String
    let ModelYear: String
    let EngineCylinders: String
}

public class OBDService: ObservableObject {
    @Published var connectedPeripheral: CBPeripheralProtocol? = nil
    @Published public var connectionState: ConnectionState = .disconnected
    @Published var foundPeripherals: [Peripheral]?

    let setupOrder: [OBDCommand.General] = [.ATD, .ATZ, .ATL0, .ATE0, .ATH1, .ATAT1, .ATRV, .ATDPN]
    var elm327: ELM327
    let bleManager: BLEManager

    var cancellables = Set<AnyCancellable>()

    public init() {
        self.bleManager = BLEManager()
        self.elm327 = ELM327(bleManager: bleManager)

        bleManager.$connectionState
            .sink { [weak self] state in
                self?.connectionState = state
            }
            .store(in: &cancellables)

        bleManager.$foundPeripherals
            .sink { [weak self] peripherals in
                self?.foundPeripherals = peripherals
            }
            .store(in: &cancellables)
    }

     public func startConnection(_ preferedProtocol: PROTOCOL?) async throws -> (OBDProtocol: PROTOCOL, VIN: String?) {
        try await initAdapter()
        return try await initVehicle(preferedProtocol)
    }

    func stopConnection() {
        self.connectionState = .disconnected
        self.elm327.stopConnection()
    }

    public func initAdapter(timeout: TimeInterval = 7) async throws {
        if connectionState != .connectedToAdapter {
            let foundPeripheral = try await scanForPeripheral(timeout: timeout)
            _ = try await connect(to: foundPeripheral)
        }
        if bleManager.ecuWriteCharacteristic == nil || bleManager.ecuReadCharacteristic == nil {
            await bleManager.processCharacteristics()
        }
        try await elm327.adapterInitialization(setupOrder: setupOrder)
    }

    func scanForPeripheral(timeout: TimeInterval) async throws -> CBPeripheralProtocol {
        guard let peripheral = try await self.bleManager.scanForPeripheralAsync(timeout: timeout) else { throw OBDServiceError.noAdapterFound }
        return peripheral
    }

    func connect(to peripheral: CBPeripheralProtocol) async throws  -> CBPeripheralProtocol {
        let connectedPeripheral = try await self.bleManager.connectAsync(peripheral: peripheral)
        return connectedPeripheral
    }

    public func initVehicle(_ preferedProtocol: PROTOCOL?) async throws -> (OBDProtocol: PROTOCOL, VIN: String?) {
        let obd2info = try await elm327.setupVehicle(preferedProtocol: preferedProtocol)
        DispatchQueue.main.async {
            self.connectionState = .connectedToVehicle
        }
        return obd2info
    }

    public func getSupportedPIDs() async -> [OBDCommand] {
        return await elm327.getSupportedPIDs()
    }

    func scanForTroubleCodes() async throws -> [String: String]? {
        guard self.connectionState == .connectedToVehicle else {
            throw OBDServiceError.notConnectedToVehicle
        }
        return try await elm327.scanForTroubleCodes()
    }

    public func requestPIDs(_ commands: [OBDCommand]) async throws -> [Message] {
        return try await elm327.requestPIDs(commands)
    }

    public func clearTroubleCodes() async throws {
        guard self.connectionState == .connectedToVehicle else {
            throw OBDServiceError.notConnectedToVehicle
        }
        try await elm327.clearTroubleCodes()
    }

    public func getStatus() async throws -> Status? {
        return try await elm327.getStatus()
    }

//    func scanForPeripherals() {
//        bleManager.scanForPeripherals()
//    }

    func disconnectPeripheral(peripheral: Peripheral) {
        bleManager.disconnectPeripheral()
    }

    func switchToDemoMode(_ isDemoMode: Bool) {
        stopConnection()
        bleManager.demoModeSwitch(isDemoMode)
    }
}

enum OBDServiceError: Error, CustomStringConvertible {
    case noAdapterFound
    case notConnectedToVehicle
    var description: String {
        switch self {
        case .noAdapterFound: return "No adapter found"
        case .notConnectedToVehicle: return "Not connected to vehicle"
        }
    }
}


//enum OBDDevices: CaseIterable {
//    case carlyOBD
//    case mockOBD
//    case blueDriver
//
//    var properties: DeviceInfo {
//        switch self {
//        case .carlyOBD:
//            return DeviceInfo(id: UUID(uuidString: "5B6EE3F4-2FCA-CE45-6AE7-8D7390E64D6D") ?? UUID(), deviceName: "Carly", serviceUUID: "FFE0")
//
//        case .blueDriver:
//            return DeviceInfo(id: UUID(uuidString: "5B6EE3F4-2FCA-CE45-6AE7-8D7390E64D61") ?? UUID(), deviceName: "BlueDriver")
//        case .mockOBD:
//            return DeviceInfo(id: UUID(uuidString: "5B6EE3F4-2FCA-CE45-6AE7-8D7390E64A34") ?? UUID(), deviceName: "MockOBD")
//        }
//    }
//}

