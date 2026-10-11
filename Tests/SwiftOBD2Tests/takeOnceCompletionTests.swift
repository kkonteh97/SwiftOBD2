@testable import SwiftOBD2
import XCTest

/// Regression tests for the take-once completion hand-off used by the BLE
/// connect path. Before this primitive, `waitForCharacteristicsSetup` and
/// `waitForFirstPeripheral` stored bare closures that a `reset()` racing a
/// CoreBluetooth callback could invoke twice — double-resuming (trapping) the
/// waiting continuation — or, on the characteristics error path, never nil out.
final class TakeOnceCompletionTests: XCTestCase {
    func testSetThenTakeReturnsCompletionOnce() {
        let slot = TakeOnceCompletion<Int>()
        XCTAssertTrue(slot.set { _, _ in })
        XCTAssertNotNil(slot.take())
        XCTAssertNil(slot.take(), "second take must find the slot empty")
    }

    func testSetWhilePendingIsRejected() {
        let slot = TakeOnceCompletion<Int>()
        XCTAssertTrue(slot.set { _, _ in })
        XCTAssertFalse(slot.set { _, _ in }, "a live waiter must not be clobbered")
        // The original waiter is still claimable.
        XCTAssertNotNil(slot.take())
    }

    func testConcurrentTakesClaimExactlyOnce() {
        // The real-world race: a delegate callback on the CB queue and a
        // reset()/cancellation on another thread both try to fire the waiter.
        for _ in 0..<500 {
            let slot = TakeOnceCompletion<Int>()
            let fired = ManagedAtomicCounter()
            XCTAssertTrue(slot.set { _, _ in fired.increment() })

            let group = DispatchGroup()
            for _ in 0..<4 {
                group.enter()
                DispatchQueue.global().async {
                    slot.take()?(nil, nil)
                    group.leave()
                }
            }
            group.wait()
            XCTAssertEqual(fired.value, 1, "completion must fire exactly once under contention")
        }
    }

    func testScannerTimeoutThenResetDoesNotDoubleResume() async {
        // Scan times out (nothing discovered), then a disconnect calls reset().
        // Previously reset() would re-fire the stale closure into an already
        // resumed continuation; now the cancellation handler drained the slot.
        let scanner = BLEPeripheralScanner()
        do {
            _ = try await scanner.waitForFirstPeripheral(timeout: 0.1)
            XCTFail("expected scanTimeout with no peripherals")
        } catch {
            guard case BLEScannerError.scanTimeout = error else {
                return XCTFail("expected scanTimeout, got \(error)")
            }
        }
        scanner.reset() // must be a safe no-op, not a second resume
    }

    func testScannerWaitCancellationResumesPromptly() async {
        let scanner = BLEPeripheralScanner()
        let task = Task {
            try await scanner.waitForFirstPeripheral(timeout: 30)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let start = Date()
        do {
            _ = try await task.value
            XCTFail("cancelled wait should throw")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                              "cancellation must resume the waiter, not run out the 30s timeout")
        }
    }

    func testWithTimeoutInfinityRunsOperationBare() async throws {
        // .infinity must skip the timeout child entirely — the nanosecond
        // conversion would trap on a non-finite value.
        let value = try await withTimeout(seconds: .infinity) { 42 }
        XCTAssertEqual(value, 42)
    }
}

/// Minimal lock-guarded counter for asserting exactly-once semantics.
private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}
