import Foundation

/// Collects the notifications of the adapter's read characteristic into complete answers.
///
/// A BLE notification carries at most one MTU of data: an answer usually spans several of them
/// and is only complete once the `>` prompt has been received.
class BLEMessageProcessor {
    private let reader = ELMResponseReader()

    func processReceivedData(_ data: Data) {
        reader.receive(data)
    }

    /// Runs `write`, then waits for the complete answer.
    /// - Throws: `CommunicationError.timeout` when the prompt does not arrive in time,
    ///   `CommunicationError.busy` when another command is still waiting for its answer.
    func request(timeout: TimeInterval, write: @escaping () throws -> Void) async throws -> [String] {
        try await reader.request(timeout: timeout, send: write)
    }

    /// Fails the command in flight: the peripheral is gone.
    func reset() {
        reader.fail(CommunicationError.disconnected)
    }
}

// MARK: - Error Types

enum BLEMessageProcessorError: Error, LocalizedError {
    case characteristicNotWritable
    case writeOperationFailed
    case responseTimeout
    case invalidResponseData

    var errorDescription: String? {
        switch self {
        case .characteristicNotWritable:
            return "BLE characteristic does not support write operations"
        case .writeOperationFailed:
            return "Failed to write data to BLE characteristic"
        case .responseTimeout:
            return "Timeout waiting for BLE response"
        case .invalidResponseData:
            return "Received invalid response data from BLE device"
        }
    }
}
