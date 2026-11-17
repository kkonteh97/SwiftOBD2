@testable import SwiftOBD2
import XCTest

/// Regression tests for the connect path that previously hung forever when a Wi-Fi OBD adapter
/// was unreachable (wrong IP, phone not on the adapter's network, adapter asleep). `connectAsync`
/// now honors its timeout and resumes on cancellation instead of leaking the continuation.
final class WifiManagerTests: XCTestCase {
    // 192.0.2.1 is RFC 5737 TEST-NET-1 — guaranteed unroutable, so the TCP connect never
    // completes and NWConnection parks in `.waiting`/`.preparing`. Before the fix this hung
    // indefinitely; now the deadline must fail the attempt.
    private static let unreachableHost = "192.0.2.1"

    func testConnectTimesOutOnUnreachableHost() async {
        let wifi = WifiManager(host: Self.unreachableHost, port: "35000")
        let start = Date()
        do {
            try await wifi.connectAsync(timeout: 2)
            XCTFail("connectAsync should not succeed against an unreachable host")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            // Core guarantee: it unwinds instead of hanging past the timeout.
            XCTAssertLessThan(elapsed, 6, "connectAsync hung past its 2s timeout (\(elapsed)s)")
            // Expected shape: our deadline fired (.timeout), or the stack rejected the route
            // outright (.errorOccurred). Anything else is wrong.
            switch error {
            case CommunicationError.timeout, CommunicationError.errorOccurred:
                break
            default:
                XCTFail("expected .timeout or .errorOccurred, got \(error)")
            }
        }
        wifi.disconnectPeripheral()
    }

    // A user disconnect / app-side timeout cancels the socket mid-connect. The `.cancelled`
    // state must resume the waiter (previously it fell through `default:` and hung).
    func testCancelDuringConnectThrowsPromptly() async throws {
        let wifi = WifiManager(host: Self.unreachableHost, port: "35000")
        let connectTask = Task { try await wifi.connectAsync(timeout: 8) }

        // Let the connection enter its waiting state, then cancel it out from under the connect.
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelledAt = Date()
        wifi.disconnectPeripheral()

        do {
            try await connectTask.value
            XCTFail("connectAsync should throw after cancellation")
        } catch {
            let elapsed = Date().timeIntervalSince(cancelledAt)
            XCTAssertLessThan(elapsed, 4, "cancel did not unblock connectAsync promptly (\(elapsed)s)")
            guard case CommunicationError.cancelled = error else {
                return XCTFail("expected .cancelled, got \(error)")
            }
        }
    }

    // A non-numeric / out-of-range port can't build an NWEndpoint.Port and must fail fast rather
    // than opening a socket. (The app now also blocks this in the UI, but the transport stays safe.)
    func testInvalidPortThrowsInvalidData() async {
        let wifi = WifiManager(host: "192.168.0.10", port: "notaport")
        do {
            try await wifi.connectAsync(timeout: 2)
            XCTFail("connectAsync should reject an invalid port")
        } catch {
            guard case CommunicationError.invalidData = error else {
                return XCTFail("expected .invalidData, got \(error)")
            }
        }
    }
}
