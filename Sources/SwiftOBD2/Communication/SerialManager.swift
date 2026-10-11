#if os(iOS)
import Foundation
import ExternalAccessory
import CoreBluetooth
import Combine

/// USB serial backend for MFi OBD adapters (e.g. OBDLink EX).
/// Connects via the ExternalAccessory framework using the OBDLink protocol string.
/// The adapter must be physically connected via USB-C/Lightning before calling connectAsync.
final class SerialManager: NSObject, CommProtocol, StreamDelegate {

    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    private static let obdProtocol = "com.scantool.stnobd"

    private var session: EASession?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    // Single-response path: accumulates bytes until ELM327 ">" prompt
    private var receiveBuffer = ""
    private var responseContinuation: CheckedContinuation<String, Error>?
    private var responseToken: UUID?

    // Monitor-mode path: collects lines for a fixed duration
    private var monitorFrames: [String] = []
    private var monitorContinuation: CheckedContinuation<[String], Error>?
    private var monitorEndDate: Date?

    // MARK: - CommProtocol

    func scanForPeripherals() async throws {
        // USB accessories are already connected — nothing to scan for
    }

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        guard let accessory = accessories.first(where: {
            $0.protocolStrings.contains(Self.obdProtocol)
        }) else {
            throw CommunicationError.invalidData
        }

        guard let s = EASession(accessory: accessory, forProtocol: Self.obdProtocol) else {
            throw CommunicationError.invalidData
        }
        session = s

        let input  = s.inputStream
        let output = s.outputStream
        inputStream  = input
        outputStream = output

        input?.delegate  = self
        output?.delegate = self
        input?.schedule(in: .main, forMode: .common)
        output?.schedule(in: .main, forMode: .common)
        input?.open()
        output?.open()

        connectionState = .connectedToAdapter
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        var lastError: Error = CommunicationError.invalidData
        for attempt in 0 ..< max(1, retries) {
            do {
                let raw = try await sendRaw(command)
                return parseLines(raw)
            } catch {
                lastError = error
                if attempt < max(1, retries) - 1 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        throw lastError
    }

    func sendMonitorCommand(_ command: String, duration: TimeInterval) async throws -> [String] {
        // Continuation state is main-confined: the stream delegate runs on the main
        // RunLoop and the deadline fires on main, so set up there too.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CommunicationError.invalidData)
                    return
                }
                self.monitorFrames  = []
                self.monitorEndDate = Date().addingTimeInterval(duration)
                self.monitorContinuation = continuation
                self.writeBytes(command + "\r")
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    guard let self else { return }
                    let frames = self.monitorFrames
                    self.monitorContinuation?.resume(returning: frames)
                    self.monitorContinuation = nil
                    self.monitorEndDate      = nil
                    self.writeBytes("\r")  // interrupt ELM327 monitor mode
                }
            }
        }
    }

    func disconnectPeripheral() {
        inputStream?.remove(from: .main, forMode: .common)
        outputStream?.remove(from: .main, forMode: .common)
        inputStream?.close()
        outputStream?.close()
        inputStream  = nil
        outputStream = nil
        session      = nil
        connectionState = .disconnected
        // Continuation state is main-confined; fail any pending waiters there.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.responseContinuation?.resume(throwing: CommunicationError.invalidData)
            self.responseContinuation = nil
            self.responseToken = nil
            self.monitorContinuation?.resume(returning: self.monitorFrames)
            self.monitorContinuation = nil
            self.monitorEndDate = nil
        }
    }

    func reset() { disconnectPeripheral() }

    // MARK: - Private

    private func sendRaw(_ command: String) async throws -> String {
        guard let output = outputStream, output.streamStatus == .open else {
            throw CommunicationError.invalidData
        }
        let token = UUID()
        // Main-confined setup, matching the stream delegate and the deadline. Any
        // pending continuation from an overlapped call is failed, not silently
        // dropped — overwriting it would leave that caller suspended forever.
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            DispatchQueue.main.async {
                guard let self else {
                    continuation.resume(throwing: CommunicationError.invalidData)
                    return
                }
                self.responseContinuation?.resume(throwing: CommunicationError.invalidData)
                self.responseContinuation = continuation
                self.responseToken = token
                self.receiveBuffer = ""
                self.writeBytes(command + "\r")

                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self,
                          self.responseToken == token,
                          let cont = self.responseContinuation else { return }
                    self.responseContinuation = nil
                    self.responseToken = nil
                    cont.resume(throwing: CommunicationError.invalidData)
                }
            }
        }
    }

    private func writeBytes(_ string: String) {
        guard let output = outputStream, output.streamStatus == .open else { return }
        let bytes = Array(string.utf8)
        output.write(bytes, maxLength: bytes.count)
    }

    private func parseLines(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
           .map    { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
           .filter { !$0.isEmpty && $0 != ">" }
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard aStream === inputStream else { return }
        switch eventCode {
        case .hasBytesAvailable:
            drainInputStream()
        case .errorOccurred:
            let err = aStream.streamError ?? CommunicationError.invalidData
            responseContinuation?.resume(throwing: CommunicationError.errorOccurred(err))
            responseContinuation = nil
            responseToken = nil
            monitorContinuation?.resume(returning: monitorFrames)
            monitorContinuation = nil
            monitorEndDate = nil
            connectionState = .disconnected
        default:
            break
        }
    }

    private func drainInputStream() {
        var temp = [UInt8](repeating: 0, count: 512)
        guard let stream = inputStream else { return }
        let count = stream.read(&temp, maxLength: temp.count)
        guard count > 0 else { return }
        let chunk = String(bytes: temp.prefix(count), encoding: .ascii) ?? ""

        if monitorEndDate != nil {
            let lines = parseLines(chunk)
            monitorFrames.append(contentsOf: lines)
        } else {
            receiveBuffer += chunk
            if receiveBuffer.contains(">") {
                let raw = receiveBuffer
                receiveBuffer = ""
                responseContinuation?.resume(returning: raw)
                responseContinuation = nil
                responseToken = nil
            }
        }
    }
}
#endif
