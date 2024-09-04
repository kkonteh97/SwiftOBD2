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
    func sendCommand(_ command: String, retries: Int) async throws -> [String]
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
    @Published var connectionState: ConnectionState = .disconnected

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.app", category: "wifiManager")

    var obdDelegate: OBDServiceDelegate?

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    var tcp: NWConnection?

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
            let host = NWEndpoint.Host("192.168.0.10")
            guard let port = NWEndpoint.Port("35000") else {
                throw CommunicationError.invalidData
            }
            tcp = NWConnection(host: host, port: port, using: .tcp)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                tcp?.stateUpdateHandler = { [weak self] newState in
                    guard let self = self else { return }
                    switch newState {
                    case .ready:
                        self.logger.info("Connected to \(host.debugDescription):\(port.debugDescription)")
                        self.connectionState = .connectedToAdapter
                        continuation.resume(returning: ())
                    case let .waiting(error):
                        self.logger.warning("Connection waiting: \(error.localizedDescription)")
                    case let .failed(error):
                        self.logger.error("Connection failed: \(error.localizedDescription)")
                        self.connectionState = .disconnected
                        continuation.resume(throwing: CommunicationError.errorOccurred(error))
                    default:
                        break
                    }
                }
                tcp?.start(queue: .main)
            }
        }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }
        logger.info("Sending: \(command)")
        return try await self.sendCommandInternal(data: data, retries: retries)
    }

    private func sendCommandInternal(data: Data, retries: Int) async throws -> [String] {
        for attempt in 1...retries {
            do {
                let response = try await sendAndReceiveData(data)
                if let lines = processResponse(response) {
                    return lines
                } else if attempt < retries {
                    logger.info("No data received, retrying attempt \(attempt + 1) of \(retries)...")
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.5 seconds delay
                }
            } catch {
                if attempt == retries {
                    throw error
                }
                logger.warning("Attempt \(attempt) failed, retrying: \(error.localizedDescription)")
            }
        }
        throw CommunicationError.invalidData
    }

    private func sendAndReceiveData(_ data: Data) async throws -> String {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                tcp?.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        self.logger.error("Error sending data: \(error.localizedDescription)")
                        continuation.resume(throwing: CommunicationError.errorOccurred(error))
                        return
                    }

                    self.tcp?.receive(minimumIncompleteLength: 1, maximumLength: 500) { data, _, _, error in
                        if let error = error {
                            self.logger.error("Error receiving data: \(error.localizedDescription)")
                            continuation.resume(throwing: CommunicationError.errorOccurred(error))
                            return
                        }

                        guard let response = data, let responseString = String(data: response, encoding: .utf8) else {
                            self.logger.warning("Received invalid or empty data")
                            continuation.resume(throwing: CommunicationError.invalidData)
                            return
                        }

                        continuation.resume(returning: responseString)
                    }
                })
            }
    }

    private func processResponse(_ response: String) -> [String]? {
            logger.info("Processing response: \(response)")
            var lines = response.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            guard !lines.isEmpty else {
                logger.warning("Empty response lines")
                return nil
            }

            if lines.last?.contains(">") == true {
                lines.removeLast()
            }

            if lines.first?.lowercased() == "no data" {
                return nil
            }

            return lines
        }

    func disconnectPeripheral() {
        tcp?.cancel()
    }

    func scanForPeripherals() async throws {}
}
