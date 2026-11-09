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
            guard var left = power() else { return nil }
            while let op = peek(), "*/×÷x".contains(op) {
                // A lone "x" is only a multiplication sign between two operands.
                index += 1
                sawOperation = true
                guard let right = power() else { return nil }
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

        private mutating func power() -> Operand? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                index += 1
                sawOperation = true
                guard let exponent = power() else { return nil }
                return (pow(base.value, exponent.value), false)
            }
            return base
        }

        private mutating func unary() -> Operand? {
            if let sign = peek(), sign == "-" || sign == "+" {
                index += 1
                guard let operand = unary() else { return nil }
                return sign == "-" ? (-operand.value, operand.isPercent) : operand
            }
            return postfix()
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
            while index < chars.count {
                let c = chars[index]
                if c.isASCII, c.isNumber {
                    text.append(c)
                } else if c == "," || c == ".", !seenSeparator {
                    seenSeparator = true
                    text.append(".")
                } else {
                    break
                }
                index += 1
            }
            guard !text.isEmpty, text != ".", let value = Double(text) else { return nil }
            return (value, false)
        }

        private mutating func namedValue() -> Operand? {
            var name = ""
            while index < chars.count, chars[index].isLetter {
                name.append(chars[index])
                index += 1
            }
            if name == "pi" || name == "π" {
                sawOperation = true
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
