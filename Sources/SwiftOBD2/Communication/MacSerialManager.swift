#if os(macOS)
import Foundation
import CoreBluetooth

/// macOS backend for serial OBD adapters (e.g., USB to Serial).
/// Uses POSIX file descriptors and termios for communication.
final class MacSerialManager: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    private var fileDescriptor: Int32 = -1
    private var isMonitoring = false
    private var monitorContinuation: CheckedContinuation<[String], Error>?
    private var monitorFrames: [String] = []

    private var readTask: Task<Void, Never>?
    private var responseContinuation: CheckedContinuation<String, Error>?
    private var responseToken: UUID?
    private var receiveBuffer = ""
    // Set when a command times out: the adapter may still deliver that command's
    // reply late, so the next send must drop pending input first or the stale
    // reply is read as the new command's response. Main-confined like the rest
    // of the continuation state.
    private var needsResync = false


    func scanForPeripherals() async throws {}

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?) async throws {
        let path = UserDefaults.standard.string(forKey: "serialPath") ?? ""
        guard !path.isEmpty else {
            obdError("No serial path configured", category: .connection)
            throw CommunicationError.invalidData
        }

        fileDescriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            let err = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            obdError("Failed to open \(path): \(err.localizedDescription)", category: .connection)
            throw CommunicationError.errorOccurred(err)
        }

        // Probe each baud rate: send ATI, wait 1 s, check if response is valid ASCII
        // and contains the prompt. tcsetattr always succeeds, so we must actually
        // talk to the adapter to confirm.
        let candidates: [(speed_t, Int)] = [
            (speed_t(B115200), 115200),
            (speed_t(B38400),  38400),
            (speed_t(B57600),  57600),
            (speed_t(B9600),   9600),
        ]

        for (baud, rate) in candidates {
            guard applyBaudRate(baud) else { continue }
            obdDelegate?.logMessage("Serial: probing \(path) at \(rate) baud…")
            obdInfo("Probing \(path) at \(rate) baud", category: .connection)

            if await probeRespondsValidASCII() {
                obdInfo("Baud rate confirmed: \(rate)", category: .connection)
                obdDelegate?.logMessage("Serial: \(rate) baud confirmed — adapter responding")
                // The probe reads for a fixed 1 s, but a slow adapter can still be
                // emitting its prompt afterwards. Drop any straggler bytes before
                // the read loop starts, otherwise they land in the first command's
                // receive buffer and can swallow / corrupt its response (seen as a
                // first-connect "Timeout waiting for response to: ATZ").
                tcflush(fileDescriptor, TCIOFLUSH)
                connectionState = .connectedToAdapter
                startReading()
                return
            } else {
                obdDelegate?.logMessage("Serial: no valid response at \(rate) baud")
            }
        }

        close(fileDescriptor)
        fileDescriptor = -1
        obdDelegate?.logMessage("Serial: no baud rate produced a valid response — check cable/adapter")
        throw CommunicationError.invalidData
    }

    /// Sends ATI and returns true if the reply is all printable ASCII and contains
    /// the '>' prompt. Garbage bytes (baud-rate mismatch) contain high-bit or
    /// control characters and never produce a prompt.
    ///
    /// ATI specifically, not a bare '\r': the ELM327 treats a lone CR as "repeat
    /// last command", so a CR probe re-executes whatever a previous session left
    /// in the adapter's command buffer (an ATZ re-reset, or a live 0100 query to
    /// the vehicle) and the probe then reads that command's output as its own
    /// response. ATI is side-effect-free, answers instantly with the version
    /// banner, and any received character also interrupts an in-progress
    /// protocol SEARCHING ("STOPPED") instead of replaying it.
    private func probeRespondsValidASCII() async -> Bool {
        // Flush any stale bytes before probing.
        tcflush(fileDescriptor, TCIOFLUSH)

        writeBytes("ATI\r")

        // Collect bytes for up to 1 second.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let bufSize = 64
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        let n = read(fileDescriptor, buf, bufSize)
        guard n > 0 else { return false }

        let bytes = UnsafeBufferPointer(start: buf, count: n)
        let printable = bytes.allSatisfy { b in
            (b >= 0x20 && b <= 0x7E) || b == 0x0D || b == 0x0A
        }
        let hasPrompt = bytes.contains(UInt8(ascii: ">"))
        let valid = printable && hasPrompt
        let preview = String(bytes: bytes, encoding: .ascii) ?? "<non-ASCII>"
        obdInfo("Probe at fd=\(self.fileDescriptor): \(n) bytes, valid=\(valid), preview=\(preview)", category: .connection)
        return valid
    }

    private func applyBaudRate(_ baud: speed_t) -> Bool {
        var settings = termios()
        guard tcgetattr(fileDescriptor, &settings) == 0 else { return false }
        cfmakeraw(&settings)
        cfsetspeed(&settings, baud)
        settings.c_cc.16 = 0   // VMIN  — non-blocking read
        settings.c_cc.17 = 10  // VTIME — 1 second inter-byte timeout
        return tcsetattr(fileDescriptor, TCSANOW, &settings) == 0
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
        // All monitor/continuation state is main-confined (handleReceivedData is
        // @MainActor and the deadline fires on main), so set it up there too.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CommunicationError.invalidData)
                    return
                }
                self.isMonitoring = true
                self.monitorFrames = []
                self.monitorContinuation = continuation
                self.writeBytes(command + "\r")
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    guard let self = self else { return }
                    self.isMonitoring = false
                    let frames = self.monitorFrames
                    self.monitorContinuation?.resume(returning: frames)
                    self.monitorContinuation = nil
                    self.writeBytes("\r")
                }
            }
        }
    }

    func disconnectPeripheral() {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        readTask?.cancel()
        readTask = nil
        connectionState = .disconnected
        // Continuation state is main-confined (sendRaw / timeout / read handler
        // all run on main); fail any pending waiters there.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.responseContinuation?.resume(throwing: CommunicationError.invalidData)
            self.responseContinuation = nil
            self.responseToken = nil
            self.isMonitoring = false
            self.monitorContinuation?.resume(throwing: CommunicationError.invalidData)
            self.monitorContinuation = nil
        }
    }

    func reset() {
        disconnectPeripheral()
    }

    private func sendRaw(_ command: String) async throws -> String {
        guard fileDescriptor >= 0 else {
            throw CommunicationError.invalidData
        }
        if ConfigurationService.shared.serialVerboseLogging {
            obdInfo("→ \(command)", category: .connection)
            obdDelegate?.logMessage("TX: \(command)")
        }

        let token = UUID()
        // Continuation state is main-confined: handleReceivedData is @MainActor and
        // the deadline fires on main, so registration must hop there too — otherwise
        // setup races an in-flight read of the previous command.
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            DispatchQueue.main.async {
                guard let self else {
                    continuation.resume(throwing: CommunicationError.invalidData)
                    return
                }
                self.responseContinuation?.resume(throwing: CommunicationError.invalidData)
                self.responseContinuation = continuation
                self.responseToken = token
                if self.needsResync {
                    // A previous command timed out; its late reply may be sitting in
                    // the tty input queue. Drop it right before writing so it can't
                    // be prepended to this command's response.
                    tcflush(self.fileDescriptor, TCIFLUSH)
                    self.needsResync = false
                }
                self.receiveBuffer = ""
                self.writeBytes(command + "\r")

                // 20-second per-command deadline. The token check ensures a stale timeout
                // from a previous command cannot cancel a later command's continuation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self,
                          self.responseToken == token,
                          let cont = self.responseContinuation else { return }
                    obdError("Timeout waiting for response to: \(command)", category: .connection)
                    self.obdDelegate?.logMessage("Serial: 20s timeout waiting for '\(command)' — no data received")
                    self.responseContinuation = nil
                    self.responseToken = nil
                    self.needsResync = true
                    cont.resume(throwing: CommunicationError.invalidData)
                }
            }
        }
    }

    private func writeBytes(_ string: String) {
        guard fileDescriptor >= 0 else { return }
        let bytes = Array(string.utf8)
        let written = bytes.withUnsafeBufferPointer { ptr in
            write(fileDescriptor, ptr.baseAddress, bytes.count)
        }
        if written != bytes.count {
            obdError("writeBytes: sent \(written)/\(bytes.count) bytes, errno=\(errno)", category: .connection)
            obdError("writeBytes partial: \(written)/\(bytes.count) bytes", category: .connection)
        }
    }

    private func startReading() {
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while let self = self, self.fileDescriptor >= 0, !Task.isCancelled {
                // Use select with 100 ms timeout to avoid busy-spin.
                var fds = fd_set()
                let fd = self.fileDescriptor
                // Manually set the bit for this fd in the fd_set.
                let slot = Int(fd) / 32
                let bit  = Int(fd) % 32
                withUnsafeMutableBytes(of: &fds) { ptr in
                    let words = ptr.bindMemory(to: Int32.self)
                    if slot < words.count { words[slot] |= Int32(bitPattern: 1 << bit) }
                }
                var tv = timeval(tv_sec: 0, tv_usec: 100_000)
                let ready = select(fd + 1, &fds, nil, nil, &tv)

                if ready > 0 {
                    let bytesRead = read(fd, buffer, bufferSize)
                    if bytesRead > 0 {
                        let raw = UnsafeBufferPointer(start: buffer, count: bytesRead)
                        let chunk = String(bytes: raw, encoding: .ascii)
                            ?? String(bytes: raw, encoding: .isoLatin1)
                            ?? "<\(bytesRead) non-ASCII bytes>"
                        await self.handleReceivedData(chunk)
                    } else if bytesRead < 0 && errno != EAGAIN {
                        let err = errno
                        await self.handleError(errno: err)
                        break
                    }
                }
            }
        }
    }

    @MainActor
    private func handleReceivedData(_ chunk: String) {
        let printable = chunk.replacingOccurrences(of: "\r", with: "↵").replacingOccurrences(of: "\n", with: "↵")
        if ConfigurationService.shared.serialVerboseLogging {
            obdInfo("← \(printable)", category: .connection)
            obdDelegate?.logMessage("RX: \(printable)")
        }

        if isMonitoring {
            monitorFrames.append(contentsOf: parseLines(chunk))
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

    @MainActor
    private func handleError(errno err: Int32) {
        // strerror_r, not strerror: the latter returns a pointer into a shared static
        // buffer that another thread's call can overwrite mid-read.
        var buffer = [CChar](repeating: 0, count: 256)
        let reason = strerror_r(err, &buffer, buffer.count) == 0
            ? String(cString: buffer)
            : "unknown error"
        obdError("Serial read error (errno \(err): \(reason)), disconnecting", category: .connection)
        obdDelegate?.logMessage("Serial: read error — errno \(err) (\(reason)) — disconnecting")
        disconnectPeripheral()
    }

    private func parseLines(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != ">" }
    }
}
#endif
