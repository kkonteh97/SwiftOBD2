@testable import SwiftOBD2
import XCTest

class FullPipelineTests: XCTestCase {
    var elm327: ELM327!
    var mockComm: MOCKComm!
    var pipelineCoverageAnalyzer: PipelineCoverageAnalyzer!
    
    override func setUpWithError() throws {
        mockComm = MOCKComm()
        elm327 = ELM327(comm: mockComm)
        pipelineCoverageAnalyzer = PipelineCoverageAnalyzer()
    }
    
    override func tearDownWithError() throws {
        elm327 = nil
        mockComm = nil
        pipelineCoverageAnalyzer = nil
    }
    
    func testFullPipelineAllCommands() async throws {
        // Setup ELM327 with mock settings
        try await setupELM327()
        
        let allCommands = OBDCommand.allCommands
        print("Testing \(allCommands.count) commands through full pipeline...")
        
        var successfulCommands = 0
        var failedCommands = 0
        
        for (index, command) in allCommands.enumerated() {
            print("Testing command \(index + 1)/\(allCommands.count): \(command.properties.description)")
            
            let result = await testCommandThroughPipeline(command)
            pipelineCoverageAnalyzer.recordTest(result)
            
            if result.success {
                successfulCommands += 1
            } else {
                failedCommands += 1
                print("❌ Failed: \(command.properties.description) - \(result.error ?? "Unknown error")")
            }
        }
        
        // Print comprehensive report
        let report = pipelineCoverageAnalyzer.generateReport()
//        print("\n" + "="*60)
        print("FULL PIPELINE TEST RESULTS")
//        print("="*60)
        print("Total commands tested: \(allCommands.count)")
        print("Successful: \(successfulCommands)")
        print("Failed: \(failedCommands)")
        print("Success rate: \(String(format: "%.1f", Double(successfulCommands) / Double(allCommands.count) * 100))%")
        print("\n" + report)
        
        // Ensure at least 90% success rate
        let successRate = Double(successfulCommands) / Double(allCommands.count)
        XCTAssertGreaterThan(successRate, 0.90, "Pipeline success rate should be > 90%")
    }
    
    private func setupELM327() async throws {
        // Simulate ELM327 initialization as in production
        let setupResult = try await elm327.setupVehicle(preferredProtocol: nil)
        
        // Verify we have a working protocol
        XCTAssertNotNil(elm327.canProtocol, "CAN protocol should be set after setup")
        XCTAssertEqual(setupResult.obdProtocol, .protocol6, "Should detect ISO 15765-4 protocol")
        
        print("✅ ELM327 setup complete with protocol: \(String(describing: setupResult.obdProtocol))")
    }
    
    private func testCommandThroughPipeline(_ command: OBDCommand) async -> PipelineTestResult {
        let commandString = command.properties.command
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            // Step 1: Send command through ELM327 (MockComm)
            let rawResponse = try await elm327.sendCommand(commandString)
            
            // Step 2: Parse response through CAN protocol
            guard let canProtocol = elm327.canProtocol else {
                return PipelineTestResult(
                    command: command,
                    success: false,
                    stage: .setup,
                    error: "No CAN protocol available",
                    executionTime: CFAbsoluteTimeGetCurrent() - startTime
                )
            }
            
            let parsedMessages = try canProtocol.parse(rawResponse)
            
            guard let firstMessage = parsedMessages.first else {
                return PipelineTestResult(
                    command: command,
                    success: false,
                    stage: .parsing,
                    error: "No messages parsed from response",
                    rawResponse: rawResponse,
                    executionTime: CFAbsoluteTimeGetCurrent() - startTime
                )
            }
            
            guard let messageData = firstMessage.data else {
                return PipelineTestResult(
                    command: command,
                    success: false,
                    stage: .parsing,
                    error: "Parsed message contains no data",
                    rawResponse: rawResponse,
                    executionTime: CFAbsoluteTimeGetCurrent() - startTime
                )
            }
            
            // Step 3: Decode through command decoder
            let decodedResult = try command.properties.decode(data: messageData, unit: .imperial)
            
            let executionTime = CFAbsoluteTimeGetCurrent() - startTime
            
            return PipelineTestResult(
                command: command,
                success: true,
                stage: .complete,
                rawResponse: rawResponse,
                parsedData: messageData,
                decodedResult: decodedResult,
                executionTime: executionTime
            )
            
        } catch {
            let executionTime = CFAbsoluteTimeGetCurrent() - startTime
            let stage = determineFailureStage(error: error)
            
            return PipelineTestResult(
                command: command,
                success: false,
                stage: stage,
                error: error.localizedDescription,
                executionTime: executionTime
            )
        }
    }
    
    private func determineFailureStage(error: Error) -> PipelineStage {
        let errorString = error.localizedDescription.lowercased()
        
        if errorString.contains("parse") || errorString.contains("frame") {
            return .parsing
        } else if errorString.contains("decode") || errorString.contains("unsupported") {
            return .decoding
        } else {
            return .communication
        }
    }
    
    func testSpecificCommandsPipeline() async throws {
        try await setupELM327()
        
        let testCommands: [OBDCommand] = [
            .mode1(.rpm),
            .mode1(.speed),
            .mode1(.coolantTemp),
            .mode1(.engineLoad),
            .mode3(.GET_DTC),
            .mode9(.VIN)
        ]
        
        for command in testCommands {
            let result = await testCommandThroughPipeline(command)
            
            XCTAssertTrue(result.success, 
                         "Command \(command.properties.description) should succeed. Error: \(result.error ?? "nil")")
            
            if result.success {
                XCTAssertNotNil(result.decodedResult, "Should have decoded result")
                print("✅ \(command.properties.description): \(result.decodedResult?.measurementMonitor.debugDescription ?? result.decodedResult?.troubleCode.debugDescription ?? result.decodedResult?.statusResult.debugDescription ?? "")")
            }
        }
    }
    
    func testPipelinePerformance() async throws {
        try await setupELM327()
        
        let testCommands: [OBDCommand] = [
            .mode1(.rpm),
            .mode1(.speed),
            .mode1(.coolantTemp)
        ]
        
        // Measure time for full pipeline vs direct decoding
        let iterations = 100
        var totalPipelineTime: Double = 0
        
        for _ in 0..<iterations {
            for command in testCommands {
                let startTime = CFAbsoluteTimeGetCurrent()
                let _ = await testCommandThroughPipeline(command)
                totalPipelineTime += CFAbsoluteTimeGetCurrent() - startTime
            }
        }
        
        let avgTimePerCommand = totalPipelineTime / Double(iterations * testCommands.count) * 1000
        print("Average pipeline time per command: \(String(format: "%.2f", avgTimePerCommand)) ms")
        
        // Pipeline should complete reasonably quickly
        XCTAssertLessThan(avgTimePerCommand, 50.0, "Pipeline should complete within 50ms per command")
    }
    
    func testErrorHandling() async throws {
        try await setupELM327()
        
        // Test command that should fail gracefully
        let invalidCommand = OBDCommand.mode1(.pidsA) // This might not have a response
        let result = await testCommandThroughPipeline(invalidCommand)
        
        // Should either succeed or fail gracefully with informative error
        if !result.success {
            XCTAssertNotNil(result.error, "Failed commands should have error descriptions")
            XCTAssertNotEqual(result.stage, .unknown, "Should identify the failure stage")
        }
    }
}

// MARK: - Supporting Types

enum PipelineStage {
    case setup
    case communication
    case parsing
    case decoding
    case complete
    case unknown
}

struct PipelineTestResult {
    let command: OBDCommand
    let success: Bool
    let stage: PipelineStage
    let error: String?
    let rawResponse: [String]?
    let parsedData: Data?
    let decodedResult: DecodeResult?
    let executionTime: Double
    
    init(command: OBDCommand,
         success: Bool,
         stage: PipelineStage,
         error: String? = nil,
         rawResponse: [String]? = nil,
         parsedData: Data? = nil,
         decodedResult: DecodeResult? = nil,
         executionTime: Double = 0) {
        self.command = command
        self.success = success
        self.stage = stage
        self.error = error
        self.rawResponse = rawResponse
        self.parsedData = parsedData
        self.decodedResult = decodedResult
        self.executionTime = executionTime
    }
}

class PipelineCoverageAnalyzer {
    private var testResults: [PipelineTestResult] = []
    
    func recordTest(_ result: PipelineTestResult) {
        testResults.append(result)
    }
    
    func generateReport() -> String {
        var report = ""
        
        let total = testResults.count
        let successful = testResults.filter { $0.success }.count
        let failed = testResults.filter { !$0.success }.count
        
        report += "PIPELINE COVERAGE ANALYSIS\n"
//        report += "-" * 40 + "\n"
        report += "Total tests: \(total)\n"
        report += "Successful: \(successful)\n"
        report += "Failed: \(failed)\n"
        report += "Success rate: \(String(format: "%.1f", Double(successful) / Double(total) * 100))%\n\n"
        
        // Failure analysis by stage
        let failures = testResults.filter { !$0.success }
        let failuresByStage = Dictionary(grouping: failures) { $0.stage }
        
        if !failures.isEmpty {
            report += "FAILURE ANALYSIS BY STAGE\n"
//            report += "-" * 40 + "\n"
            for (stage, stageFailures) in failuresByStage {
                report += "\(stage): \(stageFailures.count) failures\n"
                for failure in stageFailures.prefix(3) { // Show first 3 examples
                    report += "  - \(failure.command.properties.description): \(failure.error ?? "Unknown")\n"
                }
                if stageFailures.count > 3 {
                    report += "  ... and \(stageFailures.count - 3) more\n"
                }
            }
            report += "\n"
        }
        
        // Performance analysis
        let executionTimes = testResults.compactMap { $0.executionTime > 0 ? $0.executionTime : nil }
        if !executionTimes.isEmpty {
            let avgTime = executionTimes.reduce(0, +) / Double(executionTimes.count) * 1000
            let maxTime = executionTimes.max()! * 1000
            report += "PERFORMANCE ANALYSIS\n"
//            report += "-" * 40 + "\n"
            report += "Average execution time: \(String(format: "%.2f", avgTime)) ms\n"
            report += "Maximum execution time: \(String(format: "%.2f", maxTime)) ms\n\n"
        }
        
        // Mode coverage
        let modeResults = Dictionary(grouping: testResults) { result in
            switch result.command {
            case .mode1: return "Mode 1"
            case .mode3: return "Mode 3"
            case .mode6: return "Mode 6"
            case .mode9: return "Mode 9"
            }
        }
        
        report += "COVERAGE BY MODE\n"
//        report += "-" * 40 + "\n"
        for (mode, results) in modeResults.sorted(by: { $0.key < $1.key }) {
            let modeSuccess = results.filter { $0.success }.count
            let modeTotal = results.count
            let modeRate = Double(modeSuccess) / Double(modeTotal) * 100
            report += "\(mode): \(modeSuccess)/\(modeTotal) (\(String(format: "%.1f", modeRate))%)\n"
        }
        
        return report
    }
}

//extension String {
//    static func * (string: String, count: Int) -> String {
//        return String(repeating: string, count: count)
//    }
//}
