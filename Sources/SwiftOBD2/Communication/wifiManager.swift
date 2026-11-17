//
//  wifiManager.swift
//
//
//  Created by kemo konteh on 2/26/24.
//

import Combine
import CoreBluetooth
import Foundation
import Network

/// Talks to a Wi-Fi ELM327 adapter over a plain TCP socket.
///
/// These adapters create their own access point and listen on a fixed address, `192.168.0.10:35000`
/// for most of them. The phone has to be joined to that network before connecting, and on iOS the
/// app needs the `NSLocalNetworkUsageDescription` key in its Info.plist.
class WifiManager: CommProtocol {
    @Published private(set) var connectionState: ConnectionState = .disconnected

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    let host: String
    let port: UInt16

    private let queue = DispatchQueue(label: "com.swiftobd2.wifi", qos: .userInitiated)
    private let reader = ELMResponseReader()
    private let lock = NSLock()
    private var connection: NWConnection?

    init(host: String = "192.168.0.10", port: UInt16 = 35000) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
    }

    deinit {
        connection?.cancel()
    }

    private var currentConnection: NWConnection? {
        get { lock.sync { connection } }
        set { lock.sync { connection = newValue } }
    }

    // MARK: - Connection

    func connectAsync(timeout: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        if let existing = currentConnection, existing.state == .ready {
            obdInfo("Already connected to \(host):\(port)", category: .wifi)
            return
        }
        disconnectPeripheral()

        guard !host.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw CommunicationError.invalidData
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // commands are a handful of bytes: do not wait to coalesce them
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))

        let parameters = NWParameters(tls: nil, tcp: tcp)
        // The adapter's network has no internet access: never let the system route to cellular.
        parameters.prohibitedInterfaceTypes = [.cellular]

        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        currentConnection = connection
        connectionState = .connecting
        obdInfo("Connecting to \(host):\(port)", category: .wifi)

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce(continuation)

                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        obdInfo("Connected to Wi-Fi adapter", category: .wifi)
                        self?.connectionState = .connectedToAdapter
                        self?.receive(on: connection)
                        once.resume(returning: ())

                    case let .waiting(error):
                        // The system keeps retrying until the network path changes. A refused
                        // connection will not fix itself: report it right away.
                        obdWarning("Wi-Fi connection waiting: \(error.localizedDescription)", category: .wifi)
                        if case .posix(.ECONNREFUSED) = error {
                            once.resume(throwing: CommunicationError.errorOccurred(error))
                        }

                    case let .failed(error):
                        obdError("Wi-Fi connection failed: \(error.localizedDescription)", category: .wifi)
                        connection.cancel()
                        self?.connectionClosed(connection)
                        once.resume(throwing: CommunicationError.errorOccurred(error))

                    case .cancelled:
                        // Final state: drop the handler, it keeps the connection alive.
                        connection.stateUpdateHandler = nil
                        self?.connectionClosed(connection)
                        once.resume(throwing: CommunicationError.disconnected)

                    default:
                        break
                    }
                }
                connection.start(queue: queue)

                queue.asyncAfter(deadline: .now() + timeout) {
                    if once.resume(throwing: CommunicationError.timeout) {
                        obdError("Wi-Fi connection timed out", category: .wifi)
                    }
                }
            }
        } catch {
            connection.cancel()
            connectionClosed(connection)
            throw error
        }
    }

    func disconnectPeripheral() {
        guard let connection = currentConnection else { return }
        connection.cancel()
        connectionClosed(connection)
    }

    private func connectionClosed(_ connection: NWConnection) {
        let wasCurrent: Bool = lock.sync {
            guard self.connection === connection else { return false }
            self.connection = nil
            return true
        }
        guard wasCurrent else { return }
        if connectionState != .disconnected {
            connectionState = .disconnected
        }
        reader.fail(CommunicationError.disconnected)
    }

    // MARK: - Data

    /// Keeps reading: an answer may arrive in several segments, and the socket closing has to be noticed.
    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                self.reader.receive(data)
            }

            if let error = error {
                obdError("Wi-Fi receive error: \(error.localizedDescription)", category: .wifi)
                connection.cancel()
                self.connectionClosed(connection)
            } else if isComplete {
                obdInfo("Wi-Fi adapter closed the connection", category: .wifi)
                connection.cancel()
                self.connectionClosed(connection)
            } else {
                self.receive(on: connection)
            }
        }
    }

    func sendCommand(_ command: String, timeout: TimeInterval) async throws -> [String] {
        guard let connection = currentConnection, connection.state == .ready else {
            throw CommunicationError.notConnected
        }
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }

        let reader = self.reader
        return try await reader.request(timeout: timeout) {
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    reader.fail(CommunicationError.errorOccurred(error))
                }
            })
        }
    }

    func scanForPeripherals() async throws {}
}

extension NSLock {
    /// Runs `body` with the lock held. (Named `sync` because `withLock` requires recent systems.)
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
