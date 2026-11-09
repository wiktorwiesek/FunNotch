//
//  Polish.swift
//  FunNotch
//
//  Polish nouns take one of three forms after a number: 1 plik, 2 pliki,
//  5 plików — and 12–14 take the third form even though they end in 2–4.
//

import Foundation

enum Polish {
    /// The form of a noun that goes after `count`: `plural(3, "plik", "pliki", "plików")` → "pliki".
    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let value = abs(count)
        if value == 1 { return one }
        let lastTwo = value % 100
        let last = value % 10
        if (2 ... 4).contains(last) && !(12 ... 14).contains(lastTwo) { return few }
        return many
    }

    /// "3 pliki", "1 plik", "12 plików".
    static func count(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(count) \(plural(count, one, few, many))"
    }

    /// Polish dates and times for anything shown on screen. Formatters that
    /// parse fixed-format text keep `en_US_POSIX`.
    static let locale = Locale(identifier: "pl_PL")
}
