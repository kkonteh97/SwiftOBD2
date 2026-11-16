//
//  CommProtocol.swift
//  SwiftOBD2
//
//  Transport abstraction shared by every way of reaching an ELM327 adapter
//  (Bluetooth LE, Wi-Fi, mock…) plus the small concurrency helpers they rely on.
//

import Combine
import CoreBluetooth
import Foundation

/// A byte pipe to an ELM327 compatible adapter.
///
/// A transport only moves text: it writes one command line and returns the raw lines the adapter
/// printed before its `>` prompt. Interpreting those lines (errors, retries, OBD parsing) is the
/// job of ``ELM327``.
protocol CommProtocol: AnyObject {
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?) async throws
    /// Sends `command` (without the trailing carriage return) and waits for the adapter prompt.
    func sendCommand(_ command: String, timeout: TimeInterval) async throws -> [String]
    func disconnectPeripheral()
    func scanForPeripherals() async throws
}

/// Errors raised by the transport layer, whatever the medium.
public enum CommunicationError: Error, LocalizedError {
    /// The command could not be encoded, or the endpoint description is invalid.
    case invalidData
    /// No adapter is connected.
    case notConnected
    /// The adapter did not answer in time.
    case timeout
    /// A command is already waiting for its answer.
    case busy
    /// The link dropped while a command was in flight.
    case disconnected
    /// The underlying system framework reported an error.
    case errorOccurred(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidData: return "Invalid data or endpoint."
        case .notConnected: return "The adapter is not connected."
        case .timeout: return "The adapter did not answer in time."
        case .busy: return "Another command is already in progress."
        case .disconnected: return "The connection to the adapter was lost."
        case let .errorOccurred(error): return "Communication error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Response assembly

/// Accumulates the bytes coming back from an ELM327 until its `>` prompt, then hands the response
/// lines to the single request waiting for them.
///
/// Every transport feeds the bytes it receives into ``receive(_:)`` and sends through
/// ``request(timeout:send:)``, so buffering, time-outs and cancellation behave identically over
/// Bluetooth and Wi-Fi.
final class ELMResponseReader: @unchecked Sendable {
    private static let prompt = UInt8(ascii: ">")
    private static let maxBufferSize = 64 * 1024

    private let lock = NSLock()
    private var buffer = Data()
    private var pending: CheckedContinuation<[String], Error>?
    private var generation = 0

    /// Feeds bytes received from the adapter. Bytes arriving while no request is pending are dropped.
    func receive(_ data: Data) {
        lock.lock()
        guard pending != nil else {
            lock.unlock()
            return
        }
        buffer.append(data)

        if buffer.contains(Self.prompt) {
            let lines = Self.lines(from: buffer)
            let continuation = takePending()
            lock.unlock()
            continuation?.resume(returning: lines)
        } else if buffer.count > Self.maxBufferSize {
            let continuation = takePending()
            lock.unlock()
            continuation?.resume(throwing: CommunicationError.invalidData)
        } else {
            lock.unlock()
        }
    }

    /// Fails the pending request, if any (link lost, write error…).
    func fail(_ error: Error) {
        lock.lock()
        let continuation = takePending()
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    /// Registers the request, runs `send`, and suspends until the prompt, the time-out or a failure.
    func request(timeout: TimeInterval, send: @escaping () throws -> Void) async throws -> [String] {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                lock.lock()
                guard pending == nil else {
                    lock.unlock()
                    continuation.resume(throwing: CommunicationError.busy)
                    return
                }
                generation += 1
                let requestGeneration = generation
                buffer.removeAll(keepingCapacity: true)
                // The continuation is registered *before* writing so a fast answer cannot be missed.
                pending = continuation
                lock.unlock()

                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.expire(generation: requestGeneration)
                }

                do {
                    try send()
                } catch {
                    self.fail(error)
                }
            }
        } onCancel: {
            self.fail(CancellationError())
        }
    }

    private func expire(generation expired: Int) {
        lock.lock()
        guard generation == expired, pending != nil else {
            lock.unlock()
            return
        }
        let continuation = takePending()
        lock.unlock()
        continuation?.resume(throwing: CommunicationError.timeout)
    }

    /// Must be called with the lock held.
    private func takePending() -> CheckedContinuation<[String], Error>? {
        let continuation = pending
        pending = nil
        buffer.removeAll(keepingCapacity: true)
        return continuation
    }

    /// Splits a raw adapter answer into trimmed, non empty lines (prompt removed).
    static func lines(from data: Data) -> [String] {
        // ELM327 output is plain ASCII; some clones sprinkle NUL bytes in it.
        let ascii = data.prefix { $0 != prompt }.filter { $0 != 0x00 && $0 < 0x80 }
        return String(decoding: ascii, as: UTF8.self)
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Concurrency helpers

/// A minimal asynchronous mutex: commands sent to the adapter must never interleave, and a
/// multi-step exchange (set header, request, restore header) has to stay atomic.
final class AsyncLock: @unchecked Sendable {
    private let lock = NSLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isLocked {
                waiters.append(continuation)
                lock.unlock()
            } else {
                isLocked = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func release() {
        lock.lock()
        if waiters.isEmpty {
            isLocked = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// Wraps a continuation so that competing callbacks (success, failure, time-out) resume it only once.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// - Parameter beforeResuming: runs only if this call wins, before the waiter is released.
    /// - Returns: `true` if this call resumed the continuation.
    @discardableResult
    func resume(with result: Result<T, Error>, beforeResuming: (() -> Void)? = nil) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending = pending else { return false }
        beforeResuming?()
        pending.resume(with: result)
        return true
    }

    @discardableResult
    func resume(returning value: T) -> Bool {
        resume(with: .success(value))
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        resume(with: .failure(error))
    }
}

/// Runs `operation` and throws `timeoutError` if it has not finished after `seconds`.
///
/// The caller is released as soon as the time-out fires, even when `operation` is suspended on
/// something that does not react to cancellation. `onTimeout` is the place to unblock it.
func withTimeout<R>(
    seconds: TimeInterval,
    timeoutError: Error = CommunicationError.timeout,
    onTimeout: (() -> Void)? = nil,
    operation: @escaping () async throws -> R
) async throws -> R {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<R, Error>) in
        let once = ResumeOnce(continuation)

        let work = Task {
            do {
                once.resume(returning: try await operation())
            } catch {
                once.resume(throwing: error)
            }
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, seconds)) {
            // Clean up first: the caller must find a consistent state when it resumes.
            if once.resume(with: .failure(timeoutError), beforeResuming: onTimeout) {
                work.cancel()
            }
        }
    }
}
