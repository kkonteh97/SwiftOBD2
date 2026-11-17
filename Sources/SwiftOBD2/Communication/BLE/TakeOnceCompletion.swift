import Foundation

/// NSLock-guarded single-consumer completion slot for bridging delegate
/// callbacks to a waiting CheckedContinuation.
///
/// The registered completion can be fired from the CoreBluetooth queue
/// (callback arrived), a reset() on an arbitrary thread (disconnect), or a
/// task-cancellation handler — any two of which can race. take() makes the
/// hand-off atomic so the continuation can never be resumed twice, and set()
/// refuses to clobber a live waiter. Same semantics as BLEMessageProcessor's
/// completionLock and WifiManager's ResumeOnce.
final class TakeOnceCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Value?, Error?) -> Void)?

    /// Registers a completion. Returns false — leaving the pending waiter
    /// untouched — when one is already registered.
    func set(_ newCompletion: @escaping (Value?, Error?) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard completion == nil else { return false }
        completion = newCompletion
        return true
    }

    /// Atomically claims the pending completion; nil if none is registered
    /// or another caller already took it.
    func take() -> ((Value?, Error?) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let claimed = completion
        completion = nil
        return claimed
    }
}
