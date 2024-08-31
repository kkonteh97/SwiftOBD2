//
//  wifimanager.swift
//
//
//  Created by kemo konteh on 2/26/24.
//

import Foundation
import Network
import OSLog
import CoreBluetooth

protocol CommProtocol {
    func sendCommand(_ command: String) async throws -> [String]
    func disconnectPeripheral()
    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?) async throws
    func scanForPeripherals() async throws
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
    var obdDelegate: OBDServiceDelegate? { get set }
}

enum CommunicationError: Error {
    case invalidData
    case errorOccurred(Error)
}

class WifiManager: CommProtocol {
    func scanForPeripherals() async throws {
    }
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "wifiManager")

    var obdDelegate: OBDServiceDelegate?

    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    var tcp: NWConnection?

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        let host = NWEndpoint.Host("192.168.0.10")
        guard let port = NWEndpoint.Port("35000") else {
            throw CommunicationError.invalidData
        }
        tcp = NWConnection(host: host, port: port, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tcp?.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    print("Connected")
                    self.connectionState = .connectedToAdapter
                    continuation.resume(returning: ())
                case let .waiting(error):
                    print("Waiting \(error)")
                case let .failed(error):
                    print("Failed \(error)")
                    continuation.resume(throwing: CommunicationError.errorOccurred(error))
                default:
                    break
                }
            }
            tcp?.start(queue: .main)
        }
    }

    func sendCommand(_ command: String) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }
        logger.info("Sending: \(command)")
        return try await withRetry(retries: 3, delay: 0.3) { [weak self] in
                    try await self?.sendCommandInternal(data: data) ?? []
        }
//        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
//            self.tcp?.send(content: data, completion: .contentProcessed { error in
//                if let error = error {
//                    self.logger.error("Error sending data \(error)")
//                    continuation.resume(throwing: error)
//                }
//
//                self.tcp?.receive(minimumIncompleteLength: 1, maximumLength: 500, completion: { data, _, _, _ in
//                    guard let response = data, let string = String(data: response, encoding: .utf8) else {
//                        return
//                    }
//                    if string.contains(">") {
////                        self.logger.info("Received \(string)")
//
//                        var lines = string
//                            .components(separatedBy: .newlines)
//                            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
//                        print(lines.first ?? "")
//                        if lines.first?.lowercased() == "no data" {
//                            print("ola")
//                        }
//                        lines.removeLast()
//
//                        continuation.resume(returning: lines)
//                    }
//                })
//            })
//        }
    }

    private func sendCommandInternal(data: Data, retries: Int = 3) async throws -> [String] {
        var attempt = 0

        while attempt < retries {
            attempt += 1

            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String]?, Error>) in
                self.tcp?.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        self.logger.error("Error sending data: \(error)")
                        continuation.resume(throwing: error)
                        return
                    }

                    self.tcp?.receive(minimumIncompleteLength: 1, maximumLength: 500, completion: { data, _, _, error in
                        if let error = error {
                            self.logger.error("Error receiving data: \(error)")
                            continuation.resume(throwing: error)
                            return
                        }

                        guard let response = data, let string = String(data: response, encoding: .utf8) else {
                            self.logger.warning("Received empty response")
                            continuation.resume(throwing: CommunicationError.invalidData)
                            return
                        }

                        if string.contains(">") {
                            self.logger.info("Received response: \(string)")

                            var lines = string
                                .components(separatedBy: .newlines)
                                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                            lines.removeLast()

                            if lines.first?.lowercased() == "no data" {
                                self.logger.info("No data received on attempt \(attempt)")
                                if attempt < retries {
                                    // Retry the operation
                                    self.logger.info("Retrying due to 'no data' response (Attempt \(attempt) of \(retries))")
                                    continuation.resume(returning: nil) // Indicate the need to retry
                                } else {
                                    // No more retries, return an error
                                    self.logger.warning("Max retries reached, failing with 'no data'")
                                    continuation.resume(throwing: CommunicationError.invalidData)
                                }
                                return
                            } else {
                                continuation.resume(returning: lines)
                            }
                        } else {
                            self.logger.warning("Incomplete response received")
                            continuation.resume(throwing: CommunicationError.invalidData)
                        }
                    })
                })
            }

            if let result = result {
                return result // Success, return the lines
            }

            // Delay before retrying if needed
            if attempt < retries {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds delay
            }
        }

        throw CommunicationError.invalidData
    }


    private func withRetry<T>(retries: Int, delay: TimeInterval, task: @escaping () async throws -> T) async throws -> T {
            var attempt = 0
            while true {
                do {
                    return try await task()
                } catch {
                    attempt += 1
                    if attempt >= retries {
                        throw error
                    }
                    logger.warning("Attempt \(attempt) failed, retrying in \(delay) seconds...")
                    try await Task.sleep(nanoseconds: UInt64(delay * Double(NSEC_PER_SEC)))
                }
            }
    }

    func disconnectPeripheral() {
        tcp?.cancel()
    }
}
