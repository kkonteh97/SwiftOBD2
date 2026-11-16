//
//  Formula.swift
//  SwiftOBD2
//
//  A small arithmetic expression evaluator for custom PIDs.
//

import Foundation

public enum FormulaError: Error, LocalizedError, Equatable {
    case syntax(String)
    case missingByte(String)
    case unknownFunction(String)
    case notANumber

    public var errorDescription: String? {
        switch self {
        case let .syntax(message): return "Invalid formula: \(message)"
        case let .missingByte(name): return "The response is too short: byte \(name) is missing."
        case let .unknownFunction(name): return "Unknown function \(name)."
        case .notANumber: return "The formula did not produce a number."
        }
    }
}

/// An expression turning the data bytes of a response into a value, using the notation that scan
/// tool PID lists share: `A` is the first data byte, `B` the second… (`AA` follows `Z`).
///
///     ((A*256)+B)/4          engine speed
///     A-40                   temperature
///     {A:3}                  bit 3 of the first byte (0 is the least significant)
///     SIGNED(A)*0.5          8 bit two's complement
///     INT16(A,B)/10          16 bit two's complement
///
/// Supported operators, from the lowest to the highest precedence: `|`, `&`, `<<` `>>`, `+` `-`,
/// `*` `/` `%`, unary `-`, `^` (power). Functions: `SIGNED`, `SIGNED16`, `SIGNED32`, `INT16`,
/// `UINT16`, `BIT`, `ABS`, `MIN`, `MAX`. Numbers may be decimal (`1.5`) or hexadecimal (`0x1F`).
public struct Formula {
    private indirect enum Node {
        case number(Double)
        case byte(index: Int, name: String)
        case bit(index: Int, name: String, bit: Int)
        case negate(Node)
        case binary(Character, Node, Node)
        case shift(left: Bool, Node, Node)
        case call(String, [Node])
    }

    private let root: Node
    public let source: String

    public init(_ source: String) throws {
        self.source = source
        var parser = Parser(tokens: try Formula.tokenize(source))
        root = try parser.parseExpression()
        guard parser.isAtEnd else {
            throw FormulaError.syntax("unexpected '\(parser.peekDescription)' in \"\(source)\"")
        }
    }

    /// Evaluates the expression against the data bytes of a response.
    public func evaluate(_ bytes: [UInt8]) throws -> Double {
        let value = try Formula.evaluate(root, bytes)
        guard value.isFinite else { throw FormulaError.notANumber }
        return value
    }

    // MARK: Cache

    private static let cacheLock = NSLock()
    private static var cache: [String: Formula] = [:]

    /// Compiles an expression once and reuses it: formulas are evaluated at every poll.
    static func cached(_ source: String) throws -> Formula {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let formula = cache[source] { return formula }
        let formula = try Formula(source)
        cache[source] = formula
        return formula
    }

    // MARK: Evaluation

    private static func evaluate(_ node: Node, _ bytes: [UInt8]) throws -> Double {
        switch node {
        case let .number(value):
            return value

        case let .byte(index, name):
            guard index < bytes.count else { throw FormulaError.missingByte(name) }
            return Double(bytes[index])

        case let .bit(index, name, bit):
            guard index < bytes.count else { throw FormulaError.missingByte(name) }
            return Double((bytes[index] >> UInt8(bit)) & 1)

        case let .negate(operand):
            return -(try evaluate(operand, bytes))

        case let .binary(op, lhs, rhs):
            let left = try evaluate(lhs, bytes), right = try evaluate(rhs, bytes)
            switch op {
            case "+": return left + right
            case "-": return left - right
            case "*": return left * right
            case "/": return left / right
            case "%": return left.truncatingRemainder(dividingBy: right)
            case "^": return pow(left, right)
            case "&": return Double(try integer(left) & integer(right))
            case "|": return Double(try integer(left) | integer(right))
            default: throw FormulaError.syntax("unknown operator \(op)")
            }

        case let .shift(isLeft, lhs, rhs):
            let value = try integer(evaluate(lhs, bytes)), amount = try integer(evaluate(rhs, bytes))
            guard (0 ..< 63).contains(amount) else { throw FormulaError.notANumber }
            return Double(isLeft ? value << amount : value >> amount)

        case let .call(name, arguments):
            let values = try arguments.map { try evaluate($0, bytes) }
            switch (name, values.count) {
            case ("SIGNED", 1): return Double(twosComp(try integer(values[0]), length: 8))
            case ("SIGNED16", 1): return Double(twosComp(try integer(values[0]), length: 16))
            case ("SIGNED32", 1): return Double(twosComp(try integer(values[0]), length: 32))
            case ("INT16", 2): return Double(twosComp(try integer(values[0]) << 8 | integer(values[1]), length: 16))
            case ("UINT16", 2): return Double(try integer(values[0]) << 8 | integer(values[1]))
            case ("BIT", 2):
                let bit = try integer(values[1])
                guard (0 ..< 63).contains(bit) else { throw FormulaError.notANumber }
                return Double((try integer(values[0]) >> bit) & 1)
            case ("ABS", 1): return abs(values[0])
            case ("MIN", 2...): return values.min() ?? 0
            case ("MAX", 2...): return values.max() ?? 0
            default: throw FormulaError.unknownFunction("\(name)/\(values.count)")
            }
        }
    }

    private static func integer(_ value: Double) throws -> Int {
        guard value.isFinite, abs(value) < 9.0e15 else { throw FormulaError.notANumber }
        return Int(value)
    }

    // MARK: Lexer

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case symbol(String)
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters = Array(source)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                index += 1
            } else if character.isNumber || character == "." {
                var end = index
                if character == "0", index + 1 < characters.count, characters[index + 1] == "x" || characters[index + 1] == "X" {
                    end = index + 2
                    while end < characters.count, characters[end].isHexDigit { end += 1 }
                    guard let value = UInt64(String(characters[index + 2 ..< end]), radix: 16) else {
                        throw FormulaError.syntax("invalid hexadecimal number in \"\(source)\"")
                    }
                    tokens.append(.number(Double(value)))
                } else {
                    while end < characters.count, characters[end].isNumber || characters[end] == "." { end += 1 }
                    guard let value = Double(String(characters[index ..< end])) else {
                        throw FormulaError.syntax("invalid number in \"\(source)\"")
                    }
                    tokens.append(.number(value))
                }
                index = end
            } else if character.isLetter {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber { end += 1 }
                tokens.append(.identifier(String(characters[index ..< end]).uppercased()))
                index = end
            } else if character == "<" || character == ">" {
                guard index + 1 < characters.count, characters[index + 1] == character else {
                    throw FormulaError.syntax("unexpected '\(character)' in \"\(source)\"")
                }
                tokens.append(.symbol(String([character, character])))
                index += 2
            } else if "+-*/%^&|(),{}:".contains(character) {
                tokens.append(.symbol(String(character)))
                index += 1
            } else {
                throw FormulaError.syntax("unexpected '\(character)' in \"\(source)\"")
            }
        }
        return tokens
    }

    // MARK: Parser

    private struct Parser {
        let tokens: [Token]
        var position = 0

        var isAtEnd: Bool { position >= tokens.count }

        var peekDescription: String {
            guard !isAtEnd else { return "end" }
            switch tokens[position] {
            case let .number(value): return "\(value)"
            case let .identifier(name): return name
            case let .symbol(symbol): return symbol
            }
        }

        private mutating func accept(_ symbols: String...) -> String? {
            guard !isAtEnd, case let .symbol(symbol) = tokens[position], symbols.contains(symbol) else { return nil }
            position += 1
            return symbol
        }

        private mutating func expect(_ symbol: String) throws {
            guard accept(symbol) != nil else {
                throw FormulaError.syntax("expected '\(symbol)' but found '\(peekDescription)'")
            }
        }

        mutating func parseExpression() throws -> Node {
            var node = try parseBitAnd()
            while accept("|") != nil {
                node = .binary("|", node, try parseBitAnd())
            }
            return node
        }

        private mutating func parseBitAnd() throws -> Node {
            var node = try parseShift()
            while accept("&") != nil {
                node = .binary("&", node, try parseShift())
            }
            return node
        }

        private mutating func parseShift() throws -> Node {
            var node = try parseAdditive()
            while let symbol = accept("<<", ">>") {
                node = .shift(left: symbol == "<<", node, try parseAdditive())
            }
            return node
        }

        private mutating func parseAdditive() throws -> Node {
            var node = try parseTerm()
            while let symbol = accept("+", "-") {
                node = .binary(Character(symbol), node, try parseTerm())
            }
            return node
        }

        private mutating func parseTerm() throws -> Node {
            var node = try parseUnary()
            while let symbol = accept("*", "/", "%") {
                node = .binary(Character(symbol), node, try parseUnary())
            }
            return node
        }

        private mutating func parseUnary() throws -> Node {
            if accept("-") != nil { return .negate(try parseUnary()) }
            if accept("+") != nil { return try parseUnary() }
            let base = try parsePrimary()
            if accept("^") != nil {
                return .binary("^", base, try parseUnary())
            }
            return base
        }

        private mutating func parsePrimary() throws -> Node {
            guard !isAtEnd else { throw FormulaError.syntax("unexpected end of formula") }
            let token = tokens[position]
            position += 1

            switch token {
            case let .number(value):
                return .number(value)

            case .symbol("("):
                let node = try parseExpression()
                try expect(")")
                return node

            case .symbol("{"):
                // {A:3} → bit 3 of byte A
                guard !isAtEnd, case let .identifier(name) = tokens[position], let index = Parser.byteIndex(name) else {
                    throw FormulaError.syntax("expected a byte name after '{'")
                }
                position += 1
                try expect(":")
                guard !isAtEnd, case let .number(bit) = tokens[position], (0 ... 7).contains(bit), bit == bit.rounded() else {
                    throw FormulaError.syntax("expected a bit number between 0 and 7")
                }
                position += 1
                try expect("}")
                return .bit(index: index, name: name, bit: Int(bit))

            case let .identifier(name):
                if accept("(") != nil {
                    var arguments: [Node] = []
                    if accept(")") == nil {
                        repeat {
                            arguments.append(try parseExpression())
                        } while accept(",") != nil
                        try expect(")")
                    }
                    return .call(name, arguments)
                }
                guard let index = Parser.byteIndex(name) else {
                    throw FormulaError.syntax("unknown variable \(name)")
                }
                return .byte(index: index, name: name)

            case let .symbol(symbol):
                throw FormulaError.syntax("unexpected '\(symbol)'")
            }
        }

        /// `A`…`Z` are bytes 0…25, `AA`…`AZ` bytes 26…51 and so on, as in a spreadsheet.
        static func byteIndex(_ name: String) -> Int? {
            let letters = name.unicodeScalars.map { Int($0.value) - 65 }
            guard (1 ... 2).contains(letters.count), letters.allSatisfy({ (0 ..< 26).contains($0) }) else { return nil }
            return letters.count == 1 ? letters[0] : (letters[0] + 1) * 26 + letters[1]
        }
    }
}
