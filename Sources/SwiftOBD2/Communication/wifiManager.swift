//
//  wifiManager.swift
//
//
//  Created by kemo konteh on 2/26/24.
//

import CoreBluetooth
import Foundation
import Network

// CommProtocol and CommunicationError are defined in CommProtocol.swift

// NWConnection callbacks land outside Swift concurrency, so all continuation
// resumes are gated through ResumeOnce to guarantee exactly-one semantics even
// when a deadline and a receive callback race. It also owns the lock-protected
// text buffer those callbacks accumulate into.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var buffer = ""
    var continuation: CheckedContinuation<String, Error>?

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += text
    }

    var accumulated: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func finishWithAccumulated() {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation?.resume(returning: buffer)
    }

    func finish(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation?.resume(throwing: error)
    }
}

// Void variant of the exactly-once guard, used by connectAsync. The stateUpdateHandler and the
// timeout deadline resolve on different threads and race to a terminal outcome; whichever arrives
// first resumes, the loser is a no-op. `finish` returns whether it actually resumed so the timeout
// can cancel the socket only when it genuinely won the race.
private final class ConnectOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var continuation: CheckedContinuation<Void, Error>?

    @discardableResult
    func finishSuccess() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        continuation?.resume(returning: ())
        return true
    }

    @discardableResult
    func finish(throwing error: Error) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        continuation?.resume(throwing: error)
        return true
    }
}

class WifiManager: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected

    var obdDelegate: OBDServiceDelegate?

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    var tcp: NWConnection?

    private let hostString: String
    private let portString: String

    init(host: String = "192.168.0.10", port: String = "35000") {
        self.hostString = host
        self.portString = port
    }

    func connectAsync(timeout: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        let host = NWEndpoint.Host(hostString)
        guard let port = NWEndpoint.Port(portString) else {
            throw CommunicationError.invalidData
        }
        // Keepalive turns a silently dead adapter (power pulled, car off) into a
        // real .failed transition within ~8 s; without it a half-open TCP link
        // just times out command-by-command and connectionState never drops.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.keepaliveInterval = 2
        tcpOptions.keepaliveCount = 3
        tcpOptions.connectionTimeout = 10
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        #if os(iOS)
        // The adapter's AP has no internet, so iOS keeps the default route on
        // cellular/another network; pinning to the Wi-Fi interface is what makes
        // traffic flow while the status bar says "No Internet Connection".
        params.requiredInterfaceType = .wifi
        #endif
        let connection = NWConnection(host: host, port: port, using: params)
        tcp = connection

        let gate = ConnectOnce()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.continuation = continuation

            // Honor the caller's timeout. A wrong IP, or a phone that isn't on the adapter's Wi-Fi
            // network, leaves NWConnection parked in `.waiting` indefinitely — without this deadline
            // the await never returns and the command gate stays wedged. Cancelling drives the
            // handler to `.cancelled`; the gate ensures only the race winner resumes.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak connection] in
                if gate.finish(throwing: CommunicationError.timeout) {
                    connection?.cancel()
                }
            }

            connection.stateUpdateHandler = { [weak self] newState in
                guard let self = self else { return }
                switch newState {
                case .ready:
                    obdInfo("Connected to \(host.debugDescription):\(port.debugDescription)", category: .wifi)
                    self.connectionState = .connectedToAdapter
                    gate.finishSuccess()
                case let .waiting(error):
                    // The Local Network permission prompt parks the connection here until the user
                    // answers, so don't fail fast — the timeout above is the only stop condition.
                    obdInfo("Connection waiting: \(error.localizedDescription)", category: .wifi)
                case let .failed(error):
                    obdError("Connection failed: \(error.localizedDescription)", category: .connection)
                    self.connectionState = .disconnected
                    gate.finish(throwing: CommunicationError.errorOccurred(error))
                case .cancelled:
                    // Reached via disconnectPeripheral() or the app-side timeout cancelling before
                    // we ever became ready. Resume the waiter so the connect attempt unwinds.
                    self.connectionState = .disconnected
                    gate.finish(throwing: CommunicationError.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }
        obdDebug("Sending: \(command)", category: .communication)

        // ATZ resets the adapter hardware — most WiFi ELM327 adapters drop the TCP
        // connection immediately after. Fire-and-forget the command, wait for the
        // reset to complete, then re-establish the TCP connection.
        if command.uppercased() == "ATZ" {
            let old = tcp
            old?.send(content: data, completion: .contentProcessed { _ in })
            try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 s for adapter reset
            // Detach the handler first: this cancel is a planned swap, and the
            // .cancelled arm would otherwise publish a transient .disconnected
            // that the app treats as a link drop mid-handshake.
            old?.stateUpdateHandler = nil
            old?.cancel()
            try await connectAsync(timeout: 10, peripheral: nil)
            return ["ELM327 v2.1"]
        }

        return try await sendCommandInternal(data: data, retries: retries)
    }

    func sendMonitorCommand(_ command: String, duration: TimeInterval) async throws -> [String] {
        guard let tcpConnection = tcp, let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }

        let gate = ResumeOnce()
        let raw: String = try await withCheckedThrowingContinuation { continuation in
            gate.continuation = continuation

            // Monitor mode streams frames with no '>' terminator; the deadline is the
            // only stop condition. Whatever accumulated by then is the capture.
            DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
                gate.finishWithAccumulated()
            }

            tcpConnection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    gate.finishWithAccumulated()
                    return
                }
                func readNext() {
                    tcpConnection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, isComplete, error in
                        // After the deadline this pending receive doubles as the drain
                        // for the "STOPPED >" acknowledgment — consume and stop.
                        if gate.isDone { return }
                        if let chunk, let str = String(data: chunk, encoding: .utf8) {
                            gate.append(str)
                        }
                        if error != nil || isComplete {
                            gate.finishWithAccumulated()
                        } else {
                            readNext()
                        }
                    }
                }
                readNext()
            })
        }

        // A bare CR stops ELM327 monitor mode; the loop's still-pending receive
        // drains the resulting "STOPPED >" so it can't corrupt the next command.
        if let cr = "\r".data(using: .ascii) {
            tcpConnection.send(content: cr, completion: .contentProcessed { _ in })
        }

        return raw
            .replacingOccurrences(of: ">", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.uppercased() != "STOPPED" }
    }

    private func sendCommandInternal(data: Data, retries: Int) async throws -> [String] {
        // Clamp so retries <= 0 still makes one attempt — `1 ... 0` is an invalid
        // range and traps at runtime.
        let attempts = max(1, retries)
        for attempt in 1 ... attempts {
            do {
                let response = try await sendAndReceiveData(data)
                if let lines = processResponse(response) {
                    return lines
                } else if attempt < attempts {
                    obdDebug("No data received, retrying attempt \(attempt + 1) of \(attempts)...", category: .communication)
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second delay
                }
            } catch {
                if attempt == attempts {
                    throw error
                }
                // A fatal socket error cancels the connection (see sendAndReceiveData), and
                // a cancelled or failed NWConnection never recovers — every remaining
                // attempt would fail instantly against a dead socket, burning the retry
                // budget and the sleeps between them for nothing.
                if let state = tcp?.state {
                    switch state {
                    case .cancelled, .failed:
                        obdDebug("Socket is \(state) — abandoning remaining attempts", category: .communication)
                        throw error
                    default:
                        break
                    }
                }
                obdDebug("Attempt \(attempt) failed, retrying: \(error.localizedDescription)", category: .communication)
            }
        }
        throw CommunicationError.invalidData
    }

    private func sendAndReceiveData(_ data: Data) async throws -> String {
        guard let tcpConnection = tcp else {
            throw CommunicationError.invalidData
        }
        let gate = ResumeOnce()

        return try await withCheckedThrowingContinuation { continuation in
            gate.continuation = continuation

            // 15-second hard deadline — covers slow protocol auto-detection (SEARCHING...).
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                gate.finish(throwing: CommunicationError.invalidData)
            }

            tcpConnection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    obdError("Error sending data: \(error.localizedDescription)", category: .communication)
                    gate.finish(throwing: CommunicationError.errorOccurred(error))
                    // The socket is broken — cancel so the stateUpdateHandler
                    // publishes .disconnected and the app can react to the drop.
                    tcpConnection.cancel()
                    return
                }

                // Accumulate TCP chunks until the ELM327 '>' prompt is received.
                // A single receive() call may only return a partial response.
                func readNext() {
                    tcpConnection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { chunk, _, isComplete, error in
                        if gate.isDone { return }
                        if let error = error {
                            obdError("Error receiving data: \(error.localizedDescription)", category: .communication)
                            gate.finish(throwing: gate.accumulated.isEmpty
                                ? CommunicationError.errorOccurred(error)
                                : CommunicationError.invalidData)
                            tcpConnection.cancel()
                            return
                        }

                        if let chunk, let str = String(data: chunk, encoding: .utf8) {
                            gate.append(str)
                        }

                        if gate.accumulated.contains(">") {
                            gate.finishWithAccumulated()
                        } else if isComplete {
                            // `isComplete` here means the TCP stream reached EOF — the
                            // adapter (or the WiFi link) closed the connection before ever
                            // sending the closing prompt. Treating this as success used to
                            // hand whatever partial bytes arrived to the parser as if they
                            // were a complete, well-formed response.
                            gate.finish(throwing: CommunicationError.connectionClosed)
                        } else {
                            readNext()
                        }
                    }
                }

                readNext()
            })
        }
    }

    private func processResponse(_ response: String) -> [String]? {
        obdDebug("Processing response: \(response)", category: .communication)
        // Strip the '>' prompt character itself rather than dropping whichever line
        // contains it: some WiFi ELM327 clones append the prompt directly onto the
        // last data line with no preceding newline (e.g. "43 00 00 00 00 00 00>" as
        // one line). The previous `lines.last?.contains(">") → removeLast()` logic
        // discarded that entire line — including real trouble-code/measurement
        // bytes — whenever the adapter happened to frame it that way. Also trim
        // each line before the "no data" check: an untrimmed trailing \r made
        // "no data\r" fail to match "no data" and read as a real (garbage) line.
        let lines = response
            .replacingOccurrences(of: ">", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            obdDebug("Empty response lines", category: .communication)
            return nil
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

    func reset() {
        disconnectPeripheral()
    }
}
