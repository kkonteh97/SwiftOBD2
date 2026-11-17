//
//  CustomCommand.swift
//  SwiftOBD2
//
//  User defined commands: manufacturer specific PIDs, UDS data identifiers, KWP local identifiers…
//

import Foundation

/// Addresses one specific ECU instead of broadcasting to every emission related one.
///
/// Manufacturer specific data usually lives outside of the standard OBD-II services and has to be
/// requested from the module that owns it (engine, gearbox, ABS, body computer…).
public struct ECUTarget: Codable, Hashable {
    /// The request header, as given to `AT SH`:
    /// - CAN 11 bit: the identifier of the ECU, e.g. `7E0`
    /// - CAN 29 bit: the full identifier, e.g. `18DA10F1`
    /// - J1850 / ISO 9141 / KWP2000: the three header bytes, e.g. `8110F1`
    public var header: String
    /// The address answers are expected from (`AT CRA` on CAN, `AT SR` otherwise). When `nil` on
    /// CAN it is derived from the header with the usual convention (`7E0` → `7E8`,
    /// `18DA10F1` → `18DAF110`).
    public var receiveAddress: String?
    /// Additional AT commands to run when switching to this ECU (extended addressing, custom
    /// flow control, wake-up messages…).
    public var setupCommands: [String]
    /// AT commands undoing ``setupCommands``, run before the adapter addresses something else.
    public var teardownCommands: [String]

    /// Creates a target from a request header and, optionally, the address of the answers.
    public init(header: String, receiveAddress: String? = nil, setupCommands: [String] = [], teardownCommands: [String] = []) {
        self.header = header.compactUppercased
        self.receiveAddress = receiveAddress?.compactUppercased
        self.setupCommands = setupCommands
        self.teardownCommands = teardownCommands
    }

    /// The engine control module on an 11 bit CAN bus.
    public static let engine = ECUTarget(header: "7E0", receiveAddress: "7E8")
    /// The transmission control module on an 11 bit CAN bus.
    public static let transmission = ECUTarget(header: "7E1", receiveAddress: "7E9")

    /// The receive address to program on a CAN bus.
    var canReceiveAddress: String? {
        if let receiveAddress = receiveAddress, !receiveAddress.isEmpty { return receiveAddress }
        switch header.count {
        case 3:
            guard let id = UInt32(header, radix: 16) else { return nil }
            return String(format: "%03X", (id + 8) & 0x7FF)
        case 8 where header.hasPrefix("18DA"):
            // physical addressing: swap target and source
            let bytes = header.hexBytes
            guard bytes.count == 4 else { return nil }
            return [bytes[0], bytes[1], bytes[3], bytes[2]].hexString
        default:
            return nil
        }
    }
}

/// A command that is not part of the built-in catalog.
///
///     let oilTemperature = CustomCommand(
///         name: "Oil temperature",
///         request: "221154",          // UDS ReadDataByIdentifier 0x1154
///         formula: "A-40",
///         unit: "°C",
///         header: "7E0"
///     )
///     let values = try await obdService.requestPIDs([.custom(oilTemperature)])
///
/// The `formula` is evaluated on the bytes that follow the echoed request in the answer (see
/// ``Formula``), which is the convention of the PID lists shared between scan tools.
public struct CustomCommand: Codable, Hashable, Comparable, Identifiable {
    /// A unique name, used as identifier and as column title in logs.
    public var name: String
    /// The request bytes in hexadecimal: service, then identifier (`0142`, `221154`, `2101`…).
    public var request: String
    /// The formula turning the data bytes into a value (`(A*256+B)/4`). See ``Formula``.
    public var formula: String
    /// The unit symbol of the result, purely informative.
    public var unit: String
    /// The ECU to query, or `nil` to broadcast with the standard OBD-II header.
    public var target: ECUTarget?
    /// The lowest expected value, for gauges.
    public var minValue: Double
    /// The highest expected value, for gauges.
    public var maxValue: Double

    /// The name of the command.
    public var id: String {
        "\(target?.header ?? "")/\(target?.receiveAddress ?? "")/\(request)"
    }

    public init(name: String,
                request: String,
                formula: String = "A",
                unit: String = "",
                header: String? = nil,
                receiveAddress: String? = nil,
                minValue: Double = 0,
                maxValue: Double = 100) {
        self.init(name: name,
                  request: request,
                  formula: formula,
                  unit: unit,
                  target: header.flatMap { $0.isEmpty ? nil : ECUTarget(header: $0, receiveAddress: receiveAddress) },
                  minValue: minValue,
                  maxValue: maxValue)
    }

    public init(name: String,
                request: String,
                formula: String = "A",
                unit: String = "",
                target: ECUTarget?,
                minValue: Double = 0,
                maxValue: Double = 100) {
        self.name = name
        var request = request.compactUppercased
        if request.hasPrefix("0X") { request.removeFirst(2) }
        self.request = request
        self.formula = formula
        self.unit = unit
        self.target = target
        self.minValue = minValue
        self.maxValue = maxValue
    }

    public static func < (lhs: CustomCommand, rhs: CustomCommand) -> Bool {
        (lhs.name, lhs.id) < (rhs.name, rhs.id)
    }

    /// Checks that the request is well formed and that the formula compiles.
    public func validate() throws {
        guard request.isHex, request.count % 2 == 0, request.count >= 2 else {
            throw FormulaError.syntax("\"\(request)\" is not a valid request: expected hexadecimal bytes")
        }
        _ = try Formula(formula)
    }

    var properties: CommandProperties {
        CommandProperties(request, name, 0, .formula(expression: formula, unit: unit), true, maxValue: maxValue, minValue: minValue)
    }

    /// The data bytes of an answer: what follows the response service identifier and the echo of
    /// the request parameters.
    func dataBytes(in payload: Data) -> Data? {
        let requestBytes = request.hexBytes
        guard let service = requestBytes.first, payload.first == service &+ 0x40 else { return nil }
        var bytes = [UInt8](payload.dropFirst())
        for echoed in requestBytes.dropFirst() {
            guard bytes.first == echoed else { break }
            bytes.removeFirst()
        }
        return Data(bytes)
    }
}

// MARK: - Importing PID lists

public extension CustomCommand {
    /// Reads the "extended PID" CSV format popularised by Torque, which most community maintained
    /// manufacturer PID lists use:
    ///
    ///     Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,Units,Header
    ///     Transmission temperature,Trans temp,221E1C,(A*256+B)/16,-40,215,°C,7E1
    ///
    /// Rows that cannot be understood (unsupported functions, references to other PIDs…) are skipped.
    static func parseCSV(_ text: String) -> [CustomCommand] {
        let rows = parseCSVRows(text)
        guard let header = rows.first else { return [] }

        // Locate the columns by name, falling back on the usual order.
        let names = header.map { $0.lowercased().filter { $0.isLetter } }
        func column(_ candidates: [String], default fallback: Int) -> Int {
            names.firstIndex { candidates.contains($0) } ?? fallback
        }
        let hasHeaderRow = names.contains("modeandpid") || names.contains("equation") || names.contains("name")
        let nameColumn = column(["name"], default: 0)
        let requestColumn = column(["modeandpid", "pid"], default: 2)
        let formulaColumn = column(["equation", "formula"], default: 3)
        let minColumn = column(["minvalue", "min"], default: 4)
        let maxColumn = column(["maxvalue", "max"], default: 5)
        let unitColumn = column(["units", "unit"], default: 6)
        let headerColumn = column(["header"], default: 7)

        return rows.dropFirst(hasHeaderRow ? 1 : 0).compactMap { row in
            func field(_ index: Int) -> String {
                index < row.count ? row[index].trimmingCharacters(in: .whitespaces) : ""
            }
            let header = field(headerColumn)
            let command = CustomCommand(
                name: field(nameColumn),
                request: field(requestColumn),
                formula: field(formulaColumn),
                unit: field(unitColumn),
                header: header.lowercased() == "auto" ? nil : header,
                minValue: Double(field(minColumn)) ?? 0,
                maxValue: Double(field(maxColumn)) ?? 100
            )
            guard !command.name.isEmpty, (try? command.validate()) != nil else { return nil }
            return command
        }
    }

    private static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var characters = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()

        func endRow() {
            row.append(field)
            field = ""
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []
        }

        while let character = characters.next() {
            if inQuotes {
                if character == "\"" {
                    inQuotes = false
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    // A doubled quote inside a quoted field is a literal quote.
                    if !field.isEmpty { field.append(character) }
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n", "\r":
                    endRow()
                default:
                    field.append(character)
                }
            }
        }
        endRow()
        return rows
    }
}
