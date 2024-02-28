//
//  File.swift
//
//
//  Created by kemo konteh on 2/26/24.
//

import Foundation
import Network

protocol CommProtocol {
    func sendCommand(_ command: String) async throws -> [String]
    func demoModeSwitch(_ isDemoMode: Bool)
    func disconnectPeripheral()
    func connectAsync() async throws
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
}

enum CommunicationError : Error {
    case invalidData
    case errorOccurred(Error)
}

class WifiManager: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    var tcp: NWConnection?

    func connectAsync() async throws {
        let host =  NWEndpoint.Host("192.168.0.10")
        guard let port = NWEndpoint.Port("35000") else {
            throw CommunicationError.invalidData
        }
        self.tcp = NWConnection(host: host, port: port, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tcp?.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    print("Connected")
                    self.connectionState = .connectedToAdapter
                    continuation.resume(returning: ())
                case .waiting(let error):
                    print("Waiting \(error)")
                case .failed(let error):
                    print("Failed \(error)")
                    continuation.resume(throwing: CommunicationError.errorOccurred(error))
                default:
                    break
                }
            }
            tcp?.start(queue: .main)
        }
    }

    func sendCommand(_ command: String) async throws -> [String]  {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }
        print("Sending: \(command)")

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            self.tcp?.send(content: data, completion: .contentProcessed({ error in
                if let error = error {
                    print("Error sending data \(error)")
                    continuation.resume(throwing: error)
                }


                self.tcp?.receive(minimumIncompleteLength: 1, maximumLength: 500, completion: { data, _, isComplete, error in
                    guard let response = data, let string = String(data: response, encoding: .utf8) else {
                        return
                    }
                    if string.contains(">") {
                        print("Received \(string)")

                        var lines = string
                            .components(separatedBy: .newlines)
                            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        lines.removeLast()

                        continuation.resume(returning: lines)
                    }
                })
            }))
        }
    }

    func disconnectPeripheral() {
        tcp?.cancel()
    }

    func demoModeSwitch(_ isDemoMode: Bool) {

    }
}

