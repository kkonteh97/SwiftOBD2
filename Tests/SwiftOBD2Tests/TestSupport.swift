//
//  TestSupport.swift
//  SwiftOBD2Tests
//

import Combine
import CoreBluetooth
import Foundation
@testable import SwiftOBD2
import XCTest

/// A transport answering from a script, to reproduce exact adapter output.
final class ScriptedComm: CommProtocol {
    @Published var connectionState: ConnectionState = .connectedToAdapter
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    private let lock = NSLock()
    private var commands: [String] = []
    private let handler: (String) throws -> [String]

    /// - Parameter handler: receives the command without whitespace, in uppercase.
    init(_ handler: @escaping (String) throws -> [String]) {
        self.handler = handler
    }

    /// Every command received, in order.
    var sent: [String] {
        lock.sync { commands }
    }

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral?) async throws {
        connectionState = .connectedToAdapter
    }

    func sendCommand(_ command: String, timeout _: TimeInterval) async throws -> [String] {
        let request = command.compactUppercased
        lock.sync { commands.append(request) }
        return try handler(request)
    }

    func disconnectPeripheral() {
        connectionState = .disconnected
    }

    func scanForPeripherals() async throws {}

    /// The answers of a well behaved adapter to the usual AT commands.
    static func adapterAnswer(_ command: String, protocolNumber: String) -> [String]? {
        guard command.hasPrefix("AT") else { return nil }
        switch command {
        case "ATZ", "ATI": return ["ELM327 v2.1"]
        case "ATRV": return ["12.4V"]
        case "ATDPN": return [protocolNumber]
        default: return ["OK"]
        }
    }
}

extension XCTestCase {
    /// A service connected to the simulated vehicle, with direct access to the simulation.
    func makeConnectedService(configure: (MOCKComm) -> Void = { _ in }) async throws -> (OBDService, MOCKComm) {
        let mock = MOCKComm()
        mock.responseDelay = 0
        configure(mock)
        let service = OBDService(comm: mock)
        _ = try await service.startConnection()
        return (service, mock)
    }
}

/// A writable scratch directory (sandboxed runners only allow the one named by `TMPDIR`).
func temporaryDirectory() -> URL {
    if let path = ProcessInfo.processInfo.environment["TMPDIR"], !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.temporaryDirectory
}

extension OBDService {
    /// Sends a command and returns its decoded answer, failing the test when there is none.
    func decoded(_ command: OBDCommand) async throws -> DecodeResult {
        try await sendCommand(command).get()
    }
}

/// Asserts that an async expression throws, and hands the error to `verify`.
func assertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T,
                          file: StaticString = #filePath,
                          line: UInt = #line,
                          _ verify: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        verify(error)
    }
}
