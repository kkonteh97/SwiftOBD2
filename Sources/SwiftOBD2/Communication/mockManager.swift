import Foundation
import CoreBluetooth

enum CommandAction {
    case setHeaderOn
    case setHeaderOff
    case echoOn
    case echoOff
}

struct MockECUSettings {
    var headerOn = true
    var echo = false
    var vinNumber = ""
}

class MOCKComm: CommProtocol {

    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    var ecuSettings: MockECUSettings = .init()
    private let responseGenerator = MockOBDDataProvider()

    func sendCommand(_ command: String, retries: Int = 3) async throws -> [String] {
        obdInfo("Sending mock command: \(command)", category: .communication)
        guard let response =  responseGenerator.generateResponse(for: command) else {
            obdWarning("\(command) not yet implemented", category: .communication)
            return ["No Data"]
        }
        return response
    }

    func disconnectPeripheral() {
        connectionState = .disconnected
        obdDelegate?.connectionStateChanged(state: .disconnected)
    }

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        connectionState = .connectedToAdapter
        obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
    }

    func scanForPeripherals() async throws {

    }
}

public class MockOBDDataProvider {
    public struct Settings {
        var headerOn = true
        var echo = false
        var vinNumber = "1N4AL3AP7DC199583"
    }

    public var settings = Settings()

    /// Generate response for a command string
    public func generateResponse(for commandString: String) -> [String]? {
        // Handle AT commands
        if commandString.hasPrefix("AT") {
            return handleATCommand(commandString)
        }

        // Handle mode-based commands
        let mode = String(commandString.prefix(2))

        switch mode {
        case "01": // Mode 1 - Current data
            return handleMode1Command(commandString)
        case "03": // Mode 3 - Get DTCs
            return handleMode3Command()
        case "04": // Mode 4 - Clear DTCs
            return ["OK"]
        case "06": // Mode 6 - Test results
            return handleMode6Command(commandString)
        case "09": // Mode 9 - Vehicle info
            return handleMode9Command(commandString)
        default:
            return ["NO DATA"]
        }
    }

    // MARK: - AT Command Handling

    private func handleATCommand(_ command: String) -> [String] {
        let action = command.dropFirst(2).trimmingCharacters(in: .whitespaces)
        var response: [String]

        switch action {
        case "Z":
            response = ["ELM327 v1.5"]
        case "H1":
            settings.headerOn = true
            response = ["OK"]
        case "H0":
            settings.headerOn = false
            response = ["OK"]
        case "E1":
            settings.echo = true
            response = ["OK"]
        case "E0":
            settings.echo = false
            response = ["OK"]
        case "D", "L0", "AT1", "SP0", "SP6", "STFF", "S0":
            response = ["OK"]
        case "DPN":
            response = ["06"]
        case "RV":
            let voltage = Double.random(in: 12.0...14.0)
            response = [String(format: "%.1f", voltage)]
        default:
            response = ["OK"]
        }

        if settings.echo {
            response.insert(command, at: 0)
        }
        return response
    }

    // MARK: - Mode 1 Command Handling

    private func handleMode1Command(_ command: String) -> [String] {
        var responses: [String] = []

        // Add echo if enabled
        if settings.echo {
            responses.append(command)
        }

        // Parse PIDs from command
        let pids = parsePIDs(from: command)

        // Single PID request
        if pids.count == 1 {
            let response = generateSinglePIDResponse(for: pids[0])
            responses.append(response)
            return responses
        }

        // Multiple PIDs - batch request
        let batchResponse = generateBatchResponse(for: pids)
        responses.append(contentsOf: batchResponse)
        return responses
    }

    private func parsePIDs(from command: String) -> [String] {
        var pids: [String] = []
        let dataSection = String(command.dropFirst(2)) // Remove mode bytes

        var index = dataSection.startIndex
        while index < dataSection.endIndex {
            let endIndex = dataSection.index(index, offsetBy: 2, limitedBy: dataSection.endIndex) ?? dataSection.endIndex
            let pid = String(dataSection[index..<endIndex])
            if !pid.isEmpty {
                pids.append(pid.uppercased())
            }
            index = endIndex
        }

        return pids
    }

    private func generateSinglePIDResponse(for pid: String) -> String {
        let header = settings.headerOn ? "7E8" : ""

        // Get mock data for this PID
        guard let data = getMockDataForPID(pid) else {
            return "NO DATA"
        }

        // Format: [header] [len] 41 [pid] [data...]
        let responseData = "41 \(pid) \(data)"
        let dataBytes = responseData.replacingOccurrences(of: " ", with: "").count / 2
        let lengthByte = String(format: "%02X", dataBytes)

        if header.isEmpty {
            return "\(lengthByte) \(responseData)"
        } else {
            return "\(header) \(lengthByte) \(responseData)"
        }
    }

    private func generateBatchResponse(for pids: [String]) -> [String] {
        var allData = "41" // Start with mode response byte

        // Collect all PID responses
        for pid in pids {
            if let data = getMockDataForPID(pid) {
                allData += " \(pid) \(data)"
            }
        }

        // Check total length
        let dataBytes = allData.replacingOccurrences(of: " ", with: "").count / 2
        let header = settings.headerOn ? "7E8" : ""

        // Single frame if 7 bytes or less
        if dataBytes <= 7 {
            let lengthByte = String(format: "%02X", dataBytes)
            if header.isEmpty {
                return ["\(lengthByte) \(allData)"]
            } else {
                return ["\(header) \(lengthByte) \(allData)"]
            }
        }

        // Multi-frame response
        return generateMultiFrameResponse(data: allData, header: header)
    }

    private func generateMultiFrameResponse(data: String, header: String) -> [String] {
        var frames: [String] = []
        let components = data.components(separatedBy: " ").filter { !$0.isEmpty }
        let totalBytes = components.count

        // First frame: 10 [length] [first 6 bytes]
        var firstFrame = "10 " + String(format: "%02X", totalBytes)
        let firstDataCount = min(6, components.count)
        for i in 0..<firstDataCount {
            firstFrame += " " + components[i]
        }

        // Pad to 8 bytes
        while firstFrame.components(separatedBy: " ").count < 8 {
            firstFrame += " 00"
        }

        frames.append(header.isEmpty ? firstFrame : "\(header) \(firstFrame)")

        // Consecutive frames
        var remaining = Array(components.dropFirst(firstDataCount))
        var seqNum: UInt8 = 0x21

        while !remaining.isEmpty {
            var frame = String(format: "%02X", seqNum)
            let count = min(7, remaining.count)

            for i in 0..<count {
                frame += " " + remaining[i]
            }
            remaining = Array(remaining.dropFirst(count))

            // Pad to 8 bytes
            while frame.components(separatedBy: " ").count < 8 {
                frame += " 00"
            }

            frames.append(header.isEmpty ? frame : "\(header) \(frame)")

            // Increment sequence (21-2F, then wrap to 20)
            seqNum = (seqNum == 0x2F) ? 0x20 : seqNum + 1
        }

        return frames
    }

    // MARK: - Mock Data Generation with Value Tracking

    private func getMockDataForPID(_ pid: String) -> String? {
        let upperPID = pid.uppercased()

        switch upperPID {
        // Supported PIDs - always static
        case "00":
            return "BE 3F A8 13"
        // Monitor status - always static
        case "01":
            return "00 07 E5 E5"
        case "02":
            return "00 07 E5 E5"
        // Fuel system status - always static
        case "03":
            return "02 00"
        case "20":
            return "90 07 E0 11"
        case "40":
            return "FA DC 80 00"
        case "60":
            return "00 00 00 00"

        case "04": // Engine load
            let load = Int.random(in: 0...100)
            return String(format: "%02X", load)
        case "05": // Coolant temp
            let celsiusValue =  UInt8.random(in: 80...95)
            let temp = celsiusValue + 40
            return String(format: "%02X", temp)

        case "0A": // Fuel pressure
            let pressure =  UInt8.random(in: 100...133)
//            let actualKPa = Int(pressure) * 3
            return String(format: "%02X", pressure)

        case "0B": // Intake manifold pressure
            let pressure =  UInt8.random(in: 20...100)
            return String(format: "%02X", pressure)

        case "0C": // RPM
            let actualRPM = UInt16.random(in: 800...2500)
            let rpm = actualRPM * 4
            return String(format: "%02X %02X", (rpm >> 8) & 0xFF, rpm & 0xFF)

        case "0D": // Speed
            let speed = UInt8.random(in: 0...80)
            return String(format: "%02X", speed)

        case "0E": // Timing advance
            let degrees = UInt8.random(in: 10...30)
            let timing = degrees * 2 + 128
//            let actualDegrees = Double(Int(timing) - 128) / 2.0
            return String(format: "%02X", timing)

        case "0F": // Intake air temp
            let celsiusValue =  UInt8.random(in:    20...40)
            let temp = celsiusValue + 40
            return String(format: "%02X", temp)

        case "10": // MAF
            let mafValue = UInt16.random(in: 500...4000)
//            let actualGPS = Double(mafValue) / 100.0
            return String(format: "%02X %02X", (mafValue >> 8) & 0xFF, mafValue & 0xFF)

        case "11": // Throttle position
            let percent =  UInt8.random(in: 10...30)
            let pos = UInt8(Double(percent) * 2.55)
            return String(format: "%02X", pos)

        case "13": // O2 sensors present
            return "03"

        case "14": // O2 sensor data
            let voltage =  UInt8.random(in: 100...190)
            return String(format: "%02X 80", voltage)

        case "1C": // OBD standards
            return "06"

        case "1F": // Run time
            let time = UInt16.random(in: 60...3600)
            return String(format: "%02X %02X", (time >> 8) & 0xFF, time & 0xFF)

        case "2F": // Fuel level
            let percent = UInt8.random(in: 30...80)
            let level = UInt8(Double(percent) * 2.55)
            return String(format: "%02X", level)

        case "31": // Distance since codes cleared
            let distance = UInt16.random(in: 100...5000)
            return String(format: "%02X %02X", (distance >> 8) & 0xFF, distance & 0xFF)

        case "33": // Barometric pressure
            let pressure =  UInt8.random(in: 95...105)
            return String(format: "%02X", pressure)

        case "46": // Ambient air temp
            let celsiusValue = UInt8.random(in: 15...30)
            let temp = celsiusValue + 40
            return String(format: "%02X", temp)
        case "5E": // Engine Fuel rate
            let rate = UInt16.random(in: 500...2000)
            return String(format: "%02X %02X", (rate >> 8) & 0xFF, rate & 0xFF)

        // Additional Mode 1 PIDs
        case "06": // Short term fuel trim Bank 1
            let trim = UInt8.random(in: 118...138) // -10% to +10%
            return String(format: "%02X", trim)
        
        case "07": // Long term fuel trim Bank 1
            let trim = UInt8.random(in: 118...138)
            return String(format: "%02X", trim)
            
        case "08": // Short term fuel trim Bank 2
            let trim = UInt8.random(in: 118...138)
            return String(format: "%02X", trim)
            
        case "09": // Long term fuel trim Bank 2
            let trim = UInt8.random(in: 118...138)
            return String(format: "%02X", trim)
            
        case "12": // Secondary air status
            return "01"
            
        case "15": // O2 Bank 1 Sensor 2
            let voltage = UInt8.random(in: 100...190)
            return String(format: "%02X 80", voltage)
            
        case "16": // O2 Bank 1 Sensor 3
            let voltage = UInt8.random(in: 100...190)
            return String(format: "%02X 80", voltage)
            
        case "17": // O2 Bank 1 Sensor 4
            let voltage = UInt8.random(in: 100...190)
            return String(format: "%02X 80", voltage)
            
        case "18": // O2 Bank 2 Sensor 1
            let voltage = UInt8.random(in: 100...190)
            return String(format: "%02X 80", voltage)
            
        case "19": // O2 Bank 2 Sensor 2
            let voltage = UInt8.random(in: 100...190)
            return String(format: "%02X 80", voltage)
            
        case "1A": // O2 Bank 2 Sensor 3
            let voltage = UInt8.random(in: 100...190)
            return String(format: "%02X 80", voltage)
            
        case "1B": // O2 Bank 2 Sensor 4
            let voltage = UInt8.random(in: 100...190)
            return String(format: "%02X 80", voltage)
            
        case "1D": // O2 sensors present (alternate)
            return "03"
            
        case "1E": // Auxiliary input status
            return "01"
            
        case "21": // Distance with MIL on
            let distance = UInt16.random(in: 0...1000)
            return String(format: "%02X %02X", (distance >> 8) & 0xFF, distance & 0xFF)
            
        case "22": // Fuel rail pressure (relative to vacuum)
            let pressure = UInt16.random(in: 0...5177)
            return String(format: "%02X %02X", (pressure >> 8) & 0xFF, pressure & 0xFF)
            
        case "23": // Fuel rail pressure (direct inject)
            let pressure = UInt16.random(in: 0...65535)
            return String(format: "%02X %02X", (pressure >> 8) & 0xFF, pressure & 0xFF)
            
        case "24", "25", "26", "27", "28", "29", "2A", "2B": // O2 Sensor WR Lambda Voltage
            let voltage = UInt16.random(in: 0...65535)
            let current = UInt16.random(in: 32768...65535)
            return String(format: "%02X %02X %02X %02X", 
                         (voltage >> 8) & 0xFF, voltage & 0xFF,
                         (current >> 8) & 0xFF, current & 0xFF)
            
        case "2C": // Commanded EGR
            let egr = UInt8.random(in: 0...100)
            return String(format: "%02X", egr)
            
        case "2D": // EGR Error
            let error = UInt8.random(in: 120...136) // -6% to +6%
            return String(format: "%02X", error)
            
        case "2E": // Commanded evaporative purge
            let purge = UInt8.random(in: 0...100)
            return String(format: "%02X", purge)
            
        case "30": // Warm-ups since codes cleared
            let warmups = UInt8.random(in: 0...255)
            return String(format: "%02X", warmups)
            
        case "32": // Evap system vapor pressure
            let pressure = UInt16.random(in: 32768...40000) // Slight vacuum
            return String(format: "%02X %02X", (pressure >> 8) & 0xFF, pressure & 0xFF)
            
        case "34", "35", "36", "37", "38", "39", "3A", "3B": // O2 Sensor WR Lambda Current
            let voltage = UInt16.random(in: 0...65535)
            let current = UInt8.random(in: 120...136) // -6mA to +6mA
            return String(format: "%02X %02X 00 %02X", 
                         (voltage >> 8) & 0xFF, voltage & 0xFF, current)
            
        case "3C", "3D", "3E", "3F": // Catalyst Temperature
            let temp = UInt16.random(in: 400...600) // 400-600°C
            let encodedTemp = temp * 10 + 40 // Convert to raw format
            return String(format: "%02X %02X", (encodedTemp >> 8) & 0xFF, encodedTemp & 0xFF)
            
        case "41": // Monitor status this drive cycle
            return "00 00 00 00"
            
        case "42": // Control module voltage
            let voltage = UInt16.random(in: 12000...14000) // 12-14V
            return String(format: "%02X %02X", (voltage >> 8) & 0xFF, voltage & 0xFF)
            
        case "43": // Absolute load value
            let load = UInt16.random(in: 0...25700)
            return String(format: "%02X %02X", (load >> 8) & 0xFF, load & 0xFF)
            
        case "44": // Commanded equivalence ratio
            let ratio = UInt16.random(in: 32768...40000) // Around 1.0
            return String(format: "%02X %02X", (ratio >> 8) & 0xFF, ratio & 0xFF)
            
        case "45": // Relative throttle position
            let position = UInt8.random(in: 10...30)
            return String(format: "%02X", position)
            
        case "47", "48", "49", "4A", "4B": // Throttle positions B-F
            let position = UInt8.random(in: 10...30)
            return String(format: "%02X", position)
            
        case "4C": // Commanded throttle actuator
            let actuator = UInt8.random(in: 10...30)
            return String(format: "%02X", actuator)
            
        case "4D": // Time run with MIL on
            let time = UInt16.random(in: 0...3600) // 0-1 hour
            return String(format: "%02X %02X", (time >> 8) & 0xFF, time & 0xFF)
            
        case "4E": // Time since DTCs cleared
            let time = UInt16.random(in: 3600...36000) // 1-10 hours
            return String(format: "%02X %02X", (time >> 8) & 0xFF, time & 0xFF)
            
        case "4F": // Maximum values
            return "FF FF FF FF"
            
        case "50": // Maximum MAF
            let maxMaf = UInt8.random(in: 180...220)
            return String(format: "%02X 00 00 00", maxMaf)
            
        case "51": // Fuel type
            return "01" // Gasoline
            
        case "52": // Ethanol fuel percentage
            let ethanol = UInt8.random(in: 0...15) // 0-15%
            return String(format: "%02X", ethanol)
            
        case "53": // Absolute evap system vapor pressure
            let pressure = UInt16.random(in: 0...327) // 0-327 kPa
            return String(format: "%02X %02X", (pressure >> 8) & 0xFF, pressure & 0xFF)
            
        case "54": // Evap system vapor pressure (alt)
            let pressure = UInt16.random(in: 32768...40000) // Slight vacuum
            return String(format: "%02X %02X", (pressure >> 8) & 0xFF, pressure & 0xFF)
            
        case "55", "56", "57", "58": // Short/Long term secondary O2 trim
            let trim = UInt8.random(in: 118...138) // -10% to +10%
            return String(format: "%02X", trim)
            
        case "59": // Fuel rail pressure (absolute)
            let pressure = UInt16.random(in: 0...65535)
            return String(format: "%02X %02X", (pressure >> 8) & 0xFF, pressure & 0xFF)
            
        case "5A": // Relative accelerator pedal position
            let position = UInt8.random(in: 10...30)
            return String(format: "%02X", position)
            
        case "5B": // Hybrid battery pack remaining life
            let life = UInt8.random(in: 70...100)
            return String(format: "%02X", life)
            
        case "5C": // Engine oil temperature
            let temp = UInt8.random(in: 90...110) + 40 // 90-110°C
            return String(format: "%02X", temp)
            
        case "5D": // Fuel injection timing
            let timing = UInt16.random(in: 26214...39322) // -10° to +10°
            return String(format: "%02X %02X", (timing >> 8) & 0xFF, timing & 0xFF)
            
        case "5F": // Emission requirements
            return "01 02"

        default:
            return nil
        }
    }

    // MARK: - Other Modes

    private func handleMode3Command() -> [String] {
        var responses: [String] = []

        if settings.echo {
            responses.append("03")
        }

        // Mock 2 DTCs: P0104, P0207
        let header = settings.headerOn ? "7E8" : ""
        let dtcData = "43 02 01 04 02 07"

        if header.isEmpty {
            responses.append("06 \(dtcData)")
        } else {
            responses.append("\(header) 06 \(dtcData)")
        }

        return responses
    }

    private func handleMode6Command(_ command: String) -> [String]? {
       let header = settings.headerOn ? "7E8" : ""

       // Parse the MID (Monitor ID) from command
       let mid = String(command.dropFirst(2).prefix(2))

       // Generate appropriate test results based on MID
       guard let testResults = generateMode6TestResults(for: mid) else {
           return ["NO DATA"]
       }

       // If we have test results, format them properly
       return formatMode6Response(testResults: testResults, mid: mid, header: header)
   }

    private func generateMode6TestResults(for mid: String) -> [Mode6TestResult]? {
           switch mid.uppercased() {
           case "00": // Request supported MIDs 01-20
               return generateSupportedMIDsResponse(range: 0x01...0x20)

           case "01": // O2 Sensor Monitor Bank 1 Sensor 1
               return [
                   // Rich to lean threshold voltage test
                   Mode6TestResult(
                       tid: 0x01, cid: 0x0B,  // 0.001V scaling
                       value: 0x01C2,  // 450mV
                       min: 0x0190,    // 400mV minimum
                       max: 0x01F4     // 500mV maximum
                   ),
                   // Lean to rich threshold voltage test
                   Mode6TestResult(
                       tid: 0x02, cid: 0x0B,
                       value: 0x0226,  // 550mV
                       min: 0x01F4,    // 500mV minimum
                       max: 0x0258     // 600mV maximum
                   )
               ]

           case "02": // O2 Sensor Monitor Bank 1 Sensor 2
               return [
                   // Low voltage switch time
                   Mode6TestResult(
                       tid: 0x03, cid: 0x10,  // 1ms scaling
                       value: 0x0032,  // 50ms
                       min: 0x0014,    // 20ms minimum
                       max: 0x0064     // 100ms maximum
                   ),
                   // High voltage switch time
                   Mode6TestResult(
                       tid: 0x04, cid: 0x10,
                       value: 0x0028,  // 40ms
                       min: 0x0014,    // 20ms minimum
                       max: 0x0064     // 100ms maximum
                   )
               ]

           case "03": // O2 Sensor Monitor Bank 2 Sensor 1
               return [
                   // Sensor period test
                   Mode6TestResult(
                       tid: 0x0A, cid: 0x10,  // 1ms scaling
                       value: 0x03E8,  // 1000ms
                       min: 0x0320,    // 800ms minimum
                       max: 0x04B0     // 1200ms maximum
                   ),
                   // Min voltage test
                   Mode6TestResult(
                       tid: 0x07, cid: 0x0B,  // 0.001V scaling
                       value: 0x0032,  // 50mV
                       min: 0x0000,    // 0mV minimum
                       max: 0x0064     // 100mV maximum
                   )
               ]

           case "05": // O2 Sensor Heater Bank 1 Sensor 1
               return [
                   // Heater resistance test (marginal - close to limit)
                   Mode6TestResult(
                       tid: 0x41, cid: 0x14,  // 1 ohm scaling
                       value: 0x000E,  // 14 ohms (marginal - close to max)
                       min: 0x0008,    // 8 ohms minimum
                       max: 0x000F     // 15 ohms maximum
                   )
               ]

           case "06": // O2 Sensor Heater Bank 1 Sensor 2
               return [
                   // Heater current test (failed - exceeds max)
                   Mode6TestResult(
                       tid: 0x42, cid: 0x8E,  // 0.001A scaling
                       value: 0x0BB8,  // 3.0A (failed - exceeds max)
                       min: 0x03E8,    // 1.0A minimum
                       max: 0x09C4     // 2.5A maximum
                   )
               ]

           case "0B": // Misfire Monitor
               return [
                   // Average misfire counts
                   Mode6TestResult(
                       tid: 0x0B, cid: 0x02,  // 0.1 count scaling
                       value: 0x0005,  // 0.5 misfires
                       min: 0x0000,    // 0 minimum
                       max: 0x0032     // 5.0 maximum
                   ),
                   // Total misfire count
                   Mode6TestResult(
                       tid: 0x0C, cid: 0x01,  // 1 count scaling
                       value: 0x0002,  // 2 misfires
                       min: 0x0000,    // 0 minimum
                       max: 0x000A     // 10 maximum
                   )
               ]

           case "21": // Catalyst Monitor Bank 1
               return [
                   // Catalyst efficiency test
                   Mode6TestResult(
                       tid: 0x21, cid: 0x1F,  // 0.05 ratio scaling
                       value: 0x0010,  // 0.80 ratio
                       min: 0x000E,    // 0.70 minimum
                       max: 0x0014     // 1.00 maximum
                   )
               ]

           case "22": // Catalyst Monitor Bank 2
               return [
                   // Catalyst efficiency test (marginal)
                   Mode6TestResult(
                       tid: 0x21, cid: 0x1F,
                       value: 0x000F,  // 0.75 ratio (marginal - close to min)
                       min: 0x000E,    // 0.70 minimum
                       max: 0x0014     // 1.00 maximum
                   )
               ]

           case "31": // EVAP System Monitor
               return [
                   // Small leak test (0.020")
                   Mode6TestResult(
                       tid: 0x31, cid: 0x99,  // 0.1 kPa scaling
                       value: 0x0032,  // 5.0 kPa
                       min: 0x0000,    // 0 kPa minimum
                       max: 0x0064     // 10.0 kPa maximum
                   ),
                   // Large leak test (0.040")
                   Mode6TestResult(
                       tid: 0x32, cid: 0x99,
                       value: 0x0014,  // 2.0 kPa
                       min: 0x0000,    // 0 kPa minimum
                       max: 0x0032     // 5.0 kPa maximum
                   )
               ]

           case "41": // EGR Monitor
               return [
                   // EGR flow test
                   Mode6TestResult(
                       tid: 0x41, cid: 0x27,  // 0.01 g/s scaling
                       value: 0x012C,  // 3.00 g/s
                       min: 0x00C8,    // 2.00 g/s minimum
                       max: 0x0190     // 4.00 g/s maximum
                   )
               ]

           case "A0": // Request supported MIDs A1-C0
               return generateSupportedMIDsResponse(range: 0xA1...0xC0)

           default:
               // For other MIDs, return a generic passing test
               if let midValue = UInt8(mid, radix: 16), midValue > 0 {
                   return [
                       Mode6TestResult(
                           tid: 0x01, cid: 0x01,  // Generic count test
                           value: 0x0005,
                           min: 0x0000,
                           max: 0x000A
                       )
                   ]
               }
               return nil
           }
       }

       private func generateSupportedMIDsResponse(range: ClosedRange<UInt8>) -> [Mode6TestResult] {
           // For supported MIDs response, we return a bit-encoded result
           // This is a special case that doesn't follow the normal test format
           // We'll return a dummy test result that the decoder should handle specially
           var supportedBits: UInt32 = 0

           // Mark some MIDs as supported based on the range
           if range.contains(0x01) {
               supportedBits |= (1 << 31) // MID 0x01 supported
               supportedBits |= (1 << 30) // MID 0x02 supported
               supportedBits |= (1 << 29) // MID 0x03 supported
               supportedBits |= (1 << 26) // MID 0x06 supported
               supportedBits |= (1 << 20) // MID 0x0B supported
           }

           if range.contains(0x21) {
               supportedBits |= (1 << 31) // MID 0x21 supported
               supportedBits |= (1 << 30) // MID 0x22 supported
           }

           // Return as special format for supported MIDs
           return [Mode6TestResult(
               tid: 0x00, cid: 0x00,
               value: UInt16((supportedBits >> 16) & 0xFFFF),
               min: UInt16(supportedBits & 0xFFFF),
               max: 0x0001  // Indicates this is a supported MIDs response
           )]
       }

    private func formatMode6Response(testResults: [Mode6TestResult], mid: String, header: String) -> [String] {
        var responses: [String] = []

        // Add echo if enabled
        if settings.echo {
            responses.append("06\(mid)")
        }

        // Build the response data - starts with PID echo, NOT mode byte
        var responseData = mid  // Echo the requested MID/PID

        // For each test result, add 8 bytes (not 9!)
        for test in testResults {
            responseData += String(format: " %02X", test.tid)
            responseData += String(format: " %02X", test.cid)
            responseData += String(format: " %02X %02X", (test.value >> 8) & 0xFF, test.value & 0xFF)
            responseData += String(format: " %02X %02X", (test.min >> 8) & 0xFF, test.min & 0xFF)
            responseData += String(format: " %02X %02X", (test.max >> 8) & 0xFF, test.max & 0xFF)
        }

        // Check if we need multi-frame response
        let dataBytes = responseData.replacingOccurrences(of: " ", with: "").count / 2

        if dataBytes <= 7 {
            // Single frame response
            let lengthByte = String(format: "%02X", dataBytes)
            let modeAndData = "46 " + responseData  // Mode byte goes here
            if header.isEmpty {
                responses.append("\(lengthByte) \(modeAndData)")
            } else {
                responses.append("\(header) \(lengthByte) \(modeAndData)")
            }
        } else {
            // Multi-frame response - need to include mode byte in the data
            let fullData = "46 " + responseData
            responses.append(contentsOf: generateMultiFrameResponse(data: fullData, header: header))
        }

        return responses
    }

       // Helper structure for Mode 6 test results
        struct Mode6TestResult {
           let tid: UInt8
           let cid: UInt8
           let value: UInt16
           let min: UInt16
           let max: UInt16
       }

    private func handleMode9Command(_ command: String) -> [String] {
        let pid = String(command.dropFirst(2))

        switch pid {
        case "00": // Supported PIDs
            let header = settings.headerOn ? "7E8" : ""
            let response = "49 00 55 40 00 00"
            if header.isEmpty {
                return ["06 \(response)"]
            } else {
                return ["\(header) 06 \(response)"]
            }

        case "02": // VIN
            return generateVINResponse()

        default:
            return ["NO DATA"]
        }
    }

    private func generateVINResponse() -> [String] {
        let vinData = settings.vinNumber.data(using: .ascii)!
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")

        let fullData = "49 02 01 \(vinData)"
        let header = settings.headerOn ? "7E8" : ""

        return generateMultiFrameResponse(data: fullData, header: header)
    }
}

extension MockOBDDataProvider {

    /// Generate a complete Mode 6 test scenario with various test outcomes
    func generateComprehensiveMode6TestScenario() -> [String: [Mode6TestResult]] {
        return [
            // All passing tests
            "01": [
                Mode6TestResult(tid: 0x01, cid: 0x0B, value: 0x01C2, min: 0x0190, max: 0x01F4),
                Mode6TestResult(tid: 0x02, cid: 0x0B, value: 0x0226, min: 0x01F4, max: 0x0258)
            ],

            // Mix of passing and marginal
            "02": [
                Mode6TestResult(tid: 0x03, cid: 0x10, value: 0x0032, min: 0x0014, max: 0x0064),
                Mode6TestResult(tid: 0x04, cid: 0x10, value: 0x0063, min: 0x0014, max: 0x0064) // Marginal - close to max
            ],

            // Contains a failed test
            "06": [
                Mode6TestResult(tid: 0x42, cid: 0x8E, value: 0x0BB8, min: 0x03E8, max: 0x09C4) // Failed - exceeds max
            ],

            // Misfire monitor - all passing
            "0B": [
                Mode6TestResult(tid: 0x0B, cid: 0x02, value: 0x0005, min: 0x0000, max: 0x0032),
                Mode6TestResult(tid: 0x0C, cid: 0x01, value: 0x0002, min: 0x0000, max: 0x000A)
            ],

            // Catalyst monitor - marginal efficiency
            "21": [
                Mode6TestResult(tid: 0x21, cid: 0x1F, value: 0x000F, min: 0x000E, max: 0x0014) // Just above minimum
            ],

            // EVAP system - all passing
            "31": [
                Mode6TestResult(tid: 0x31, cid: 0x99, value: 0x0032, min: 0x0000, max: 0x0064),
                Mode6TestResult(tid: 0x32, cid: 0x99, value: 0x0014, min: 0x0000, max: 0x0032)
            ]
        ]
    }

    /// Generate random Mode 6 test results for testing
    func generateRandomMode6Test(tid: UInt8, cid: UInt8) -> Mode6TestResult {
        let min = UInt16.random(in: 0...1000)
        let max = min + UInt16.random(in: 100...500)

        // 70% chance of passing, 20% marginal, 10% failed
        let rand = Int.random(in: 0...100)
        let value: UInt16

        if rand < 70 {
            // Passing - comfortably within range
            let range = max - min
            value = min + UInt16(Double(range) * Double.random(in: 0.3...0.7))
        } else if rand < 90 {
            // Marginal - close to limits
            if Bool.random() {
                // Close to minimum
                value = min + UInt16.random(in: 0...UInt16(Double(max - min) * 0.1))
            } else {
                // Close to maximum
                value = max - UInt16.random(in: 0...UInt16(Double(max - min) * 0.1))
            }
        } else {
            // Failed - outside range
            if Bool.random() {
                // Below minimum
                value = min - UInt16.random(in: 1...100)
            } else {
                // Above maximum
                value = max + UInt16.random(in: 1...100)
            }
        }

        return Mode6TestResult(tid: tid, cid: cid, value: value, min: min, max: max)
    }
}
