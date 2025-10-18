import Foundation
import OSLog

/// Centralized logging system for SwiftOBD2
/// Provides structured logging with consistent categories and levels
public class OBDLogger {
    
    // MARK: - Categories
    
    public enum Category: String, CaseIterable {
        case connection = "Connection"
        case communication = "Communication" 
        case parsing = "Parsing"
        case service = "Service"
        case bluetooth = "Bluetooth"
        case wifi = "WiFi"
        case `protocol` = "Protocol"
        case performance = "Performance"
        case error = "Error"
    }
    
    // MARK: - Shared Instance
    
    public static let shared = OBDLogger()
    
    // MARK: - Properties
    
    private let subsystem: String
    private var loggers: [Category: Logger] = [:]
    
    /// Controls whether logging is enabled
    public var isLoggingEnabled: Bool = true
    
    /// Controls the minimum log level to display
    public var minimumLogLevel: OSLogType = .default

    // MARK: - Initialization
    
    private init() {
        self.subsystem = Bundle.main.bundleIdentifier ?? "com.swiftobd2.library"
        setupLoggers()
    }
    
    private func setupLoggers() {
        for category in Category.allCases {
            loggers[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
    }
    
    // MARK: - Logging Methods
    
    public func debug(_ message: String, category: Category = .service, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .debug, category: category, file: file, function: function, line: line)
    }
    
    public func info(_ message: String, category: Category = .service, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .info, category: category, file: file, function: function, line: line)
    }
    
    public func warning(_ message: String, category: Category = .error, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .default, category: category, file: file, function: function, line: line)
    }
    
    public func error(_ message: String, category: Category = .error, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .error, category: category, file: file, function: function, line: line)
    }
    
    public func fault(_ message: String, category: Category = .error, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .fault, category: category, file: file, function: function, line: line)
    }
    
    private func log(_ message: String, level: OSLogType, category: Category, file: String, function: String, line: Int) {
        guard isLoggingEnabled && level.rawValue >= minimumLogLevel.rawValue else {return}

        guard let logger = loggers[category] else { return }
        
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let formattedMessage = "[\(fileName):\(line)] \(function) - \(message)"
        
        switch level {
        case .debug:
            logger.debug("\(formattedMessage)")
        case .info:
            logger.info("\(formattedMessage)")
        case .default:
            logger.notice("\(formattedMessage)")
        case .error:
            logger.error("\(formattedMessage)")
        case .fault:
            logger.fault("\(formattedMessage)")
        default:
            logger.log("\(formattedMessage)")
        }
    }
    
    // MARK: - Specialized Logging Methods
    
    /// Log connection state changes
    public func logConnectionChange(from oldState: ConnectionState, to newState: ConnectionState) {
        let oldStateString = String(describing: oldState)
        let newStateString = String(describing: newState)
        info("Connection state changed: \(oldStateString) → \(newStateString)", category: .connection)
    }

    /// Log command execution with timing
    public func logCommand(_ command: String, direction: CommandDirection, data: String? = nil, duration: TimeInterval? = nil) {
        var message = "\(direction.rawValue): \(command)"
        if let data = data {
            message += " | Data: \(data)"
        }
        if let duration = duration {
            message += " | Duration: \(String(format: "%.3f", duration))s"
        }
        info(message, category: .communication)
    }
    
    /// Log parsing errors with context
    public func logParseError(_ errorMessage: String, data: Data, expectedFormat: String? = nil) {
        let hexData = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        var message = "Parse error: \(errorMessage) | Data: \(hexData)"
        if let format = expectedFormat {
            message += " | Expected: \(format)"
        }
        error(message, category: .parsing)
    }
    
    /// Log performance metrics
    public func logPerformance(_ operation: String, duration: TimeInterval, success: Bool = true) {
        let status = success ? "✓" : "✗"
        info("\(status) \(operation): \(String(format: "%.3f", duration))s", category: .performance)
    }
    
    /// Log Bluetooth specific events (deprecated - use direct obdInfo/obdDebug instead)
    @available(*, deprecated, message: "Use obdInfo() or obdDebug() with .bluetooth category directly")
    public func logBluetoothEvent(_ event: String, peripheral: String? = nil, service: String? = nil) {
        var message = event
        if let peripheral = peripheral {
            message += " | Peripheral: \(peripheral)"
        }
        if let service = service {
            message += " | Service: \(service)"
        }
        info(message, category: .bluetooth)
    }
    
    /// Log protocol detection and negotiation
    public func logProtocolEvent(_ event: String, protocol: String? = nil, details: String? = nil) {
        var message = event
        if let `protocol` = `protocol` {
            message += " | Protocol: \(`protocol`)"
        }
        if let details = details {
            message += " | Details: \(details)"
        }
        info(message, category: .protocol)
    }
}

// MARK: - Supporting Types

public enum CommandDirection: String {
    case send = "→"
    case receive = "←"
}

// MARK: - Global Convenience Functions

/// Global convenience function for debug logging
public func obdDebug(_ message: String, category: OBDLogger.Category = .service, file: String = #file, function: String = #function, line: Int = #line) {
    OBDLogger.shared.debug(message, category: category, file: file, function: function, line: line)
}

/// Global convenience function for info logging
public func obdInfo(_ message: String, category: OBDLogger.Category = .service, file: String = #file, function: String = #function, line: Int = #line) {
    OBDLogger.shared.info(message, category: category, file: file, function: function, line: line)
}

/// Global convenience function for warning logging
public func obdWarning(_ message: String, category: OBDLogger.Category = .error, file: String = #file, function: String = #function, line: Int = #line) {
    OBDLogger.shared.warning(message, category: category, file: file, function: function, line: line)
}

/// Global convenience function for error logging
public func obdError(_ message: String, category: OBDLogger.Category = .error, file: String = #file, function: String = #function, line: Int = #line) {
    OBDLogger.shared.error(message, category: category, file: file, function: function, line: line)
}

/// Global convenience function for fault logging
public func obdFault(_ message: String, category: OBDLogger.Category = .error, file: String = #file, function: String = #function, line: Int = #line) {
    OBDLogger.shared.fault(message, category: category, file: file, function: function, line: line)
}
