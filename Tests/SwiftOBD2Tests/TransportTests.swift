//
//  TransportTests.swift
//  SwiftOBD2Tests
//

import Network
@testable import SwiftOBD2
import XCTest

final class TransportTests: XCTestCase {
    // MARK: - Response assembly

    func testAnswerSplitAcrossSeveralPackets() async throws {
        let reader = ELMResponseReader()
        let lines = try await reader.request(timeout: 2) {
            // what a BLE adapter typically does: 20 byte notifications cutting through the lines
            for chunk in ["7E8 10 14 49 02 01 31", " 4E 34\r7E8 21 41 4C 33 41 50 37 44\r", "7E8 22 43 31 39 39 35 38 33\r\r", ">"] {
                DispatchQueue.global().async { reader.receive(Data(chunk.utf8)) }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        XCTAssertEqual(lines, ["7E8 10 14 49 02 01 31 4E 34", "7E8 21 41 4C 33 41 50 37 44", "7E8 22 43 31 39 39 35 38 33"])
    }

    func testLineParsing() {
        XCTAssertEqual(ELMResponseReader.lines(from: Data("ATZ\r\r\rELM327 v1.5\r\r>".utf8)), ["ATZ", "ELM327 v1.5"])
        XCTAssertEqual(ELMResponseReader.lines(from: Data("41 0C 1A F8 \r\n\r\n>".utf8)), ["41 0C 1A F8"])
        // NUL bytes sent by some clones, garbage after the prompt
        XCTAssertEqual(ELMResponseReader.lines(from: Data([0x00, 0x4F, 0x4B, 0x00, 0x0D, 0x3E, 0x41])), ["OK"])
        XCTAssertEqual(ELMResponseReader.lines(from: Data(">".utf8)), [])
    }

    func testTimeout() async {
        let reader = ELMResponseReader()
        let started = Date()
        await assertThrowsAsync(try await reader.request(timeout: 0.1) {}) { error in
            guard case CommunicationError.timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        // late data from the request that timed out does not leak into the next one
        reader.receive(Data("LATE\r>".utf8))
        let lines = try? await reader.request(timeout: 1) { reader.receive(Data("OK\r>".utf8)) }
        XCTAssertEqual(lines, ["OK"])
    }

    func testSendFailureAndDisconnection() async {
        let reader = ELMResponseReader()
        await assertThrowsAsync(try await reader.request(timeout: 1) { throw CommunicationError.notConnected }) { error in
            guard case CommunicationError.notConnected = error else { return XCTFail("Unexpected error: \(error)") }
        }
        await assertThrowsAsync(try await reader.request(timeout: 1) { reader.fail(CommunicationError.disconnected) }) { error in
            guard case CommunicationError.disconnected = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testOnlyOneRequestAtATime() async throws {
        let reader = ELMResponseReader()
        async let first = reader.request(timeout: 1) {}
        try await Task.sleep(nanoseconds: 50_000_000)

        await assertThrowsAsync(try await reader.request(timeout: 1) {}) { error in
            guard case CommunicationError.busy = error else { return XCTFail("Unexpected error: \(error)") }
        }
        reader.receive(Data("OK\r>".utf8))
        let lines = try await first
        XCTAssertEqual(lines, ["OK"])
    }

    func testCancellation() async throws {
        let reader = ELMResponseReader()
        let task = Task { try await reader.request(timeout: 5) {} }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    // MARK: - Helpers

    func testWithTimeoutReleasesTheCaller() async {
        // An operation stuck on something that ignores cancellation used to hang the caller forever.
        let started = Date()
        var cleanedUp = false
        await assertThrowsAsync(try await withTimeout(seconds: 0.1, onTimeout: { cleanedUp = true }, operation: {
            try await Task.sleep(nanoseconds: 3_000_000_000)
        })) { error in
            guard case CommunicationError.timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(cleanedUp)

        let value = try? await withTimeout(seconds: 1) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testAsyncLockIsExclusive() async {
        let lock = AsyncLock()
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 50 {
                group.addTask {
                    await lock.withLock {
                        let inside = counter.enter()
                        XCTAssertEqual(inside, 1, "two tasks inside the critical section")
                        await Task.yield()
                        counter.leave()
                    }
                }
            }
        }
        XCTAssertEqual(counter.total, 50)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var inside = 0
        private(set) var total = 0

        func enter() -> Int {
            lock.sync {
                inside += 1
                total += 1
                return inside
            }
        }

        func leave() {
            lock.sync { inside -= 1 }
        }
    }

    // MARK: - Wi-Fi

    func testWifiAdapter() async throws {
        let server = try await FakeWifiAdapter.start()
        defer { server.stop() }

        let service = OBDService(wifiHost: "127.0.0.1", wifiPort: server.port)
        let info = try await service.startConnection(timeout: 3)

        XCTAssertEqual(info.obdProtocol, .protocol6)
        XCTAssertEqual(info.vin, "1N4AL3AP7DC199583")
        XCTAssertEqual(info.adapter, "ELM327 v1.5")

        let values = try await service.requestPIDs([.mode1(.rpm), .mode1(.speed), .mode1(.coolantTemp)])
        XCTAssertEqual(values.count, 3)
        let codes = try await service.scanForTroubleCodes()
        XCTAssertEqual(codes[.engine]?.map(\.code), ["P0104"])

        // The adapter is unplugged: the pending work fails and the state follows.
        server.stop()
        await assertThrowsAsync(try await service.requestPIDs([.mode1(.rpm)]))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(service.connectionState, .disconnected)
        await assertThrowsAsync(try await service.requestPIDs([.mode1(.rpm)])) { error in
            XCTAssertTrue(OBDService.isConnectionLost(error), "\(error)")
        }
    }

    func testWifiConnectionFailsWhenNothingListens() async throws {
        // Port 1 (tcpmux) is not served on any reasonable machine.
        let manager = WifiManager(host: "127.0.0.1", port: 1)
        let started = Date()
        await assertThrowsAsync(try await manager.connectAsync(timeout: 2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertEqual(manager.connectionState, .disconnected)

        await assertThrowsAsync(try await manager.sendCommand("ATZ", timeout: 1)) { error in
            guard case CommunicationError.notConnected = error else { return XCTFail("Unexpected error: \(error)") }
        }
        await assertThrowsAsync(try await WifiManager(host: "", port: 35000).connectAsync(timeout: 1))
    }
}

/// A TCP server behaving like a Wi-Fi ELM327: it feeds what it receives to the simulated adapter
/// and writes the answer back in several segments.
final class FakeWifiAdapter {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-wifi-adapter")
    private let mock = MOCKComm()
    private var connections: [NWConnection] = []
    private var pending = Data()

    private(set) var port: UInt16 = 0

    private init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        mock.responseDelay = 0
    }

    static func start() async throws -> FakeWifiAdapter {
        let server: FakeWifiAdapter
        do {
            server = try FakeWifiAdapter()
        } catch {
            throw XCTSkip("Cannot create a local TCP listener here: \(error)")
        }
        try await server.mock.connectAsync(timeout: 1)

        let ready: Bool = (try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let once = ResumeOnce(continuation)
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: true)
                case .failed, .cancelled:
                    once.resume(returning: false)
                default:
                    break
                }
            }
            server.listener.newConnectionHandler = { [weak server] connection in
                server?.accept(connection)
            }
            server.listener.start(queue: server.queue)
        }) ?? false
        guard ready, let port = server.listener.port?.rawValue else {
            throw XCTSkip("Local TCP listening is not permitted in this environment")
        }
        server.port = port
        return server
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            self.connections.forEach { $0.cancel() }
            self.connections = []
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, error == nil else { return }
            if let data = data { self.pending.append(data) }

            while let end = self.pending.firstIndex(of: 0x0D) {
                let command = String(decoding: self.pending[self.pending.startIndex ..< end], as: UTF8.self)
                self.pending = Data(self.pending[self.pending.index(after: end)...])
                self.answer(command, on: connection)
            }
            if !isComplete { self.receive(on: connection) }
        }
    }

    private func answer(_ command: String, on connection: NWConnection) {
        Task {
            let lines = (try? await mock.sendCommand(command, timeout: 1)) ?? ["?"]
            let text = Data((lines.joined(separator: "\r") + "\r\r>").utf8)
            // Split the answer to exercise the reassembly on the client side.
            let cut = text.count / 2
            connection.send(content: text.prefix(cut), completion: .contentProcessed { _ in
                self.queue.asyncAfter(deadline: .now() + 0.002) {
                    connection.send(content: text.dropFirst(cut), completion: .contentProcessed { _ in })
                }
            })
        }
    }
}
