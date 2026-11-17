//
//  OBDDataLogger.swift
//  SwiftOBD2
//
//  Records live data over time, in memory and optionally straight to a CSV file.
//

import Combine
import Foundation

/// Records the values of a set of commands at a regular pace.
///
///     let logger = OBDDataLogger(service: obdService)
///     try logger.start([.mode1(.rpm), .mode1(.speed), .custom(boost)], interval: 0.2, fileURL: csvURL)
///     …
///     logger.stop()
///     let csv = logger.csv()
///
/// When a file is given every sample is appended to it as it arrives, so nothing is lost if the
/// app is terminated during a drive.
public final class OBDDataLogger: ObservableObject {
    /// The values read during one polling round.
    public struct Sample {
        /// When the sample was taken.
        public let date: Date
        /// Seconds since the recording started.
        public let elapsed: TimeInterval
        /// The values read, by command; failed reads are missing.
        public let values: [OBDCommand: MeasurementResult]
    }

    /// `true` while recording.
    @Published public private(set) var isRecording = false
    /// The number of samples taken by the current recording.
    @Published public private(set) var sampleCount = 0

    /// Called for each sample, on an arbitrary queue.
    public var onSample: ((Sample) -> Void)?
    /// Called when the recording ends, with the error that interrupted it if any (connection lost…).
    public var onFinish: ((Error?) -> Void)?
    /// Upper bound of the samples kept in memory, oldest dropped first. `nil` keeps everything;
    /// set a limit for long recordings that go to a file anyway.
    public var memoryLimit: Int?

    private weak var service: OBDService?
    private let lock = NSLock()
    private var storedSamples: [Sample] = []
    private var storedCommands: [OBDCommand] = []
    private var units: [OBDCommand: String] = [:]
    private var task: Task<Void, Never>?
    private var fileHandle: FileHandle?
    private var fileHasHeader = false
    private var total = 0
    /// Identifies the current recording, so that the tail of a previous one cannot disturb it.
    private var generation = 0
    private var isActive = false

    /// Creates a logger reading its values through `service`.
    public init(service: OBDService) {
        self.service = service
    }

    deinit {
        task?.cancel()
        try? fileHandle?.close()
    }

    /// The samples recorded so far.
    public var samples: [Sample] {
        lock.sync { storedSamples }
    }

    /// The commands being recorded, in column order.
    public var commands: [OBDCommand] {
        lock.sync { storedCommands }
    }

    // MARK: - Recording

    /// Starts a new recording, discarding the previous one.
    /// - Parameters:
    ///   - commands: The commands to record. Only the ones producing a number are kept.
    ///   - interval: Minimum time between two samples, `0` to go as fast as the vehicle allows.
    ///   - fileURL: An optional CSV file to append the samples to as they arrive. It is overwritten.
    /// - Throws: `OBDServiceError.notConnectedToVehicle`, or the file system error when the file
    ///   cannot be created.
    public func start(_ commands: [OBDCommand],
                      interval: TimeInterval = 0.5,
                      unit: MeasurementUnit = .metric,
                      fileURL: URL? = nil) throws {
        stop()
        guard let service = service, service.elm327.obdProtocol != nil else {
            throw OBDServiceError.notConnectedToVehicle
        }

        var handle: FileHandle?
        if let fileURL = fileURL {
            try Data().write(to: fileURL)
            handle = try FileHandle(forWritingTo: fileURL)
        }

        let recording: Int = lock.sync {
            generation += 1
            isActive = true
            storedSamples = []
            storedCommands = commands
            units = [:]
            fileHandle = handle
            fileHasHeader = false
            total = 0
            return generation
        }
        publish(isRecording: true, count: 0)

        let started = Date()
        let stream = service.liveData(commands, unit: unit, interval: interval)
        let worker = Task { [weak self] in
            var failure: Error?
            do {
                for try await values in stream {
                    guard let self = self else { return }
                    let now = Date()
                    self.record(Sample(date: now, elapsed: now.timeIntervalSince(started), values: values), recording: recording)
                }
            } catch {
                failure = error
            }
            self?.finish(recording, with: failure)
        }
        lock.sync {
            if isActive, generation == recording { task = worker }
        }
    }

    /// Stops the recording. The samples stay available until the next ``start(_:interval:unit:fileURL:)``.
    public func stop() {
        let (running, recording): (Task<Void, Never>?, Int) = lock.sync { (task, generation) }
        running?.cancel()
        finish(recording, with: nil)
    }

    private func record(_ sample: Sample, recording: Int) {
        let count: Int? = lock.sync {
            guard recording == generation, isActive else { return nil }
            for (command, measurement) in sample.values where units[command] == nil {
                units[command] = measurement.unit.symbol
            }
            storedSamples.append(sample)
            if let limit = memoryLimit, storedSamples.count > limit {
                storedSamples.removeFirst(storedSamples.count - limit)
            }
            total += 1

            if let handle = fileHandle {
                var text = ""
                if !fileHasHeader {
                    text += headerRow() + "\n"
                    fileHasHeader = true
                }
                text += row(for: sample) + "\n"
                handle.write(Data(text.utf8))
            }
            return total
        }
        guard let count = count else { return }
        onSample?(sample)
        publish(isRecording: true, count: count)
    }

    private func finish(_ recording: Int, with error: Error?) {
        let wasRunning: Bool = lock.sync {
            guard recording == generation, isActive else { return false }
            isActive = false
            try? fileHandle?.close()
            fileHandle = nil
            task = nil
            return true
        }
        guard wasRunning else { return }
        publish(isRecording: false, count: nil)
        onFinish?(error)
    }

    private func publish(isRecording: Bool, count: Int?) {
        DispatchQueue.main.async {
            if self.isRecording != isRecording { self.isRecording = isRecording }
            if let count = count { self.sampleCount = count }
        }
    }

    // MARK: - Export

    /// The recording as CSV: one row per sample, one column per command.
    public func csv() -> String {
        lock.sync {
            ([headerRow()] + storedSamples.map(row(for:))).joined(separator: "\n") + "\n"
        }
    }

    /// Writes the recording to a CSV file.
    public func writeCSV(to url: URL) throws {
        try csv().write(to: url, atomically: true, encoding: .utf8)
    }

    /// The recording as JSON: the columns, then one object per sample.
    public func json() throws -> Data {
        struct Column: Encodable {
            let command: String
            let name: String
            let unit: String
        }
        struct Row: Encodable {
            let timestamp: Date
            let elapsed: TimeInterval
            let values: [String: Double]
        }
        struct Recording: Encodable {
            let columns: [Column]
            let samples: [Row]
        }

        let recording: Recording = lock.sync {
            Recording(
                columns: storedCommands.map {
                    Column(command: $0.properties.command, name: $0.properties.description, unit: units[$0] ?? "")
                },
                samples: storedSamples.map { sample in
                    Row(timestamp: sample.date,
                        elapsed: sample.elapsed,
                        values: Dictionary(sample.values.map { ($0.key.properties.description, $0.value.value) },
                                           uniquingKeysWith: { first, _ in first }))
                }
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(recording)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Must be called with the lock held.
    private func headerRow() -> String {
        let columns = storedCommands.map { command -> String in
            let name = command.properties.description
            guard let unit = units[command], !unit.isEmpty else { return name }
            return "\(name) (\(unit))"
        }
        return (["timestamp", "elapsed_s"] + columns).map(OBDDataLogger.escape).joined(separator: ",")
    }

    /// Must be called with the lock held.
    private func row(for sample: Sample) -> String {
        let values = storedCommands.map { sample.values[$0].map { OBDDataLogger.format($0.value) } ?? "" }
        return ([OBDDataLogger.timestampFormatter.string(from: sample.date), String(format: "%.3f", sample.elapsed)] + values)
            .joined(separator: ",")
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { ",\"\n\r".contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Up to four decimals, without trailing zeroes and always with a dot as separator.
    private static func format(_ value: Double) -> String {
        var text = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
