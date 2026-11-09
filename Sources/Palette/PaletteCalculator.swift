//
//  PaletteCalculator.swift
//  FunNotch
//
//  The palette's inline calculator. It has its own small parser instead of
//  NSExpression: NSExpression raises an Objective-C exception on malformed
//  input, which Swift cannot catch and which would take the whole app down
//  while someone is merely typing "2+". It also does integer division
//  ("5/2" → 2), which is the wrong answer in a calculator.
//
//  Accepts a decimal comma or point, + - * / × ÷ ^, parentheses, a trailing %
//  ("200 + 10%" is 220, "50%" is 0.5) and a few functions.
//

import Foundation

enum PaletteCalculator {
    /// The formatted result for `input`, or nil when it is not a calculation.
    /// Plain numbers are not calculations unless `force` is set.
    static func evaluate(_ input: String, force: Bool = false) -> String? {
        guard let value = value(of: input, force: force), value.isFinite else { return nil }
        return format(value)
    }

    static func value(of input: String, force: Bool = false) -> Double? {
        var parser = Parser(input)
        guard let result = parser.parse() else { return nil }
        guard force || parser.sawOperation else { return nil }
        return result
    }

    /// Up to 10 decimals, a decimal comma, no thousands separators, so the
    /// copied text pastes cleanly into a spreadsheet.
    static func format(_ value: Double) -> String {
        // Past 15 digits a double no longer holds the digits it would print, so
        // 2^1000 would come out as 300 digits of fiction.
        if abs(value) >= 1e15 {
            let parts = String(format: "%.10e", value).split(separator: "e")
            var mantissa = String(parts[0])
            while mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
            let exponent = Int(parts[1]) ?? 0
            return mantissa.replacingOccurrences(of: ".", with: ",") + "e\(exponent)"
        }
        let formatter = NumberFormatter()
        formatter.locale = Polish.locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: Parser

    private struct Parser {
        private let chars: [Character]
        private var index = 0
        /// Whether the input held an operator, function or percent; a bare
        /// "42" is just a number being typed.
        private(set) var sawOperation = false

        /// Recursion depth of nested parentheses, signs and powers. A pasted
        /// wall of "((((" would otherwise overflow the stack and take the app down.
        private var depth = 0
        private static let maxDepth = 64

        init(_ text: String) {
            chars = Array(text.lowercased())
        }

        mutating func parse() -> Double? {
            guard let result = expression()?.value else { return nil }
            skipSpaces()
            return index == chars.count ? result : nil
        }

        /// A value, and whether it was written as a percentage ("10%").
        private typealias Operand = (value: Double, isPercent: Bool)

        private mutating func skipSpaces() {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
        }

        private mutating func peek() -> Character? {
            skipSpaces()
            return index < chars.count ? chars[index] : nil
        }

        private mutating func expression() -> Operand? {
            guard var left = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                sawOperation = true
                guard let right = term() else { return nil }
                // "200 + 10%" means ten percent of the 200.
                let amount = right.isPercent ? left.value * right.value : right.value
                left = (op == "+" ? left.value + amount : left.value - amount, false)
            }
            return left
        }

        private mutating func term() -> Operand? {
            guard var left = unary() else { return nil }
            while let op = peek(), "*/×÷x".contains(op) {
                // A lone "x" is only a multiplication sign between two operands.
                index += 1
                sawOperation = true
                guard let right = unary() else { return nil }
                switch op {
                case "*", "×", "x":
                    left = (left.value * right.value, false)
                default:
                    guard right.value != 0 else { return nil }
                    left = (left.value / right.value, false)
                }
            }
            return left
        }

        /// A sign binds looser than a power, as on paper and in Google: -2^2 is -4.
        private mutating func unary() -> Operand? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maxDepth else { return nil }
            if let sign = peek(), sign == "-" || sign == "+" {
                index += 1
                guard let operand = unary() else { return nil }
                return sign == "-" ? (-operand.value, operand.isPercent) : operand
            }
            return power()
        }

        private mutating func power() -> Operand? {
            guard let base = postfix() else { return nil }
            if peek() == "^" {
                index += 1
                sawOperation = true
                // Right-associative, and the exponent may carry a sign: 2^-2.
                guard let exponent = unary() else { return nil }
                return (pow(base.value, exponent.value), false)
            }
            return base
        }

        private mutating func postfix() -> Operand? {
            guard let operand = primary() else { return nil }
            var result = operand
            while peek() == "%" {
                index += 1
                sawOperation = true
                result = (result.value / 100, true)
            }
            return result
        }

        private mutating func primary() -> Operand? {
            guard let c = peek() else { return nil }
            if c == "(" {
                index += 1
                guard let inner = expression() else { return nil }
                guard peek() == ")" else { return nil }
                index += 1
                return inner
            }
            if c.isLetter { return namedValue() }
            return number()
        }

        private mutating func number() -> Operand? {
            var text = ""
            var seenSeparator = false
            var integerDigits = 0
            var grouped = false
            while index < chars.count {
                let c = chars[index]
                if c.isASCII, c.isNumber {
                    text.append(c)
                    if !seenSeparator { integerDigits += 1 }
                } else if c == "," || c == ".", !seenSeparator {
                    seenSeparator = true
                    text.append(".")
                } else if !seenSeparator, Self.isGroupSpace(c), startsThousandsGroup(at: index, integerDigits: integerDigits, grouped: grouped) {
                    // Polish thousands grouping: "1 000", "12 345 678".
                    grouped = true
                    integerDigits = 0
                } else {
                    break
                }
                index += 1
            }
            guard !text.isEmpty, text != ".", let value = Double(text) else { return nil }
            return (value, false)
        }

        private static func isGroupSpace(_ c: Character) -> Bool {
            c == " " || c == "\u{00A0}" || c == "\u{202F}"
        }

        /// A space between digit groups counts as a thousands separator only when
        /// exactly three digits follow it (and the first group has at most three),
        /// so "2 3" and "100 5" are still errors rather than 23 and 1005.
        private func startsThousandsGroup(at spaceIndex: Int, integerDigits: Int, grouped: Bool) -> Bool {
            guard integerDigits > 0, grouped || integerDigits <= 3 else { return false }
            guard !grouped || integerDigits == 3 else { return false }
            let start = spaceIndex + 1
            guard start + 3 <= chars.count else { return false }
            for i in start ..< start + 3 where !(chars[i].isASCII && chars[i].isNumber) { return false }
            return start + 3 == chars.count || !(chars[start + 3].isASCII && chars[start + 3].isNumber)
        }

        private mutating func namedValue() -> Operand? {
            var name = ""
            while index < chars.count, chars[index].isLetter {
                name.append(chars[index])
                index += 1
            }
            if name == "pi" || name == "π" {
                // A bare constant is a value, not a calculation: typing "pi" in
                // the palette must still find the app called Pi-something.
                return (Double.pi, false)
            }
            guard peek() == "(" else { return nil }
            index += 1
            guard let argument = expression(), peek() == ")" else { return nil }
            index += 1
            let x = argument.value
            let result: Double
            switch name {
            case "sqrt", "pierwiastek": guard x >= 0 else { return nil }; result = x.squareRoot()
            case "abs": result = abs(x)
            case "round": result = x.rounded()
            case "floor": result = x.rounded(.down)
            case "ceil": result = x.rounded(.up)
            case "ln": guard x > 0 else { return nil }; result = log(x)
            case "log": guard x > 0 else { return nil }; result = log10(x)
            case "sin": result = sin(x)
            case "cos": result = cos(x)
            case "tan": result = tan(x)
            default: return nil
            }
            sawOperation = true
            return (result, false)
        }
    }
}
