//
//  PaletteTranslation.swift
//  FunNotch
//
//  `t <text>` in the palette. On macOS 15+ it translates on the device with
//  Apple's Translation framework: Polish goes to English, every other language
//  to Polish. TranslationSession can only be obtained through SwiftUI's
//  `translationTask`, so the palette view hosts it (`paletteTranslation`) and
//  this file plans the request and renders the outcome. Where on-device
//  translation is not possible the Google Translate page is offered instead.
//

import AppKit
import NaturalLanguage
import SwiftUI
import Translation

struct PaletteTranslationRequest: Equatable {
    let id = UUID()
    let text: String
    let target: Locale.Language
    let directionLabel: String
}

enum PaletteTranslationState: Equatable {
    case idle
    case working
    /// Translated text and a label such as "polski → angielski".
    case done(String, String)
    /// Why on-device translation is not possible right now.
    case unavailable(String)
}

enum PaletteTranslation {
    enum Plan {
        case request(PaletteTranslationRequest)
        case unavailable(String)
    }

    /// Picks the direction and checks that the language pair is supported.
    @available(macOS 15.0, *)
    static func plan(for text: String) async -> Plan {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage
        let targetCode = detected == .polish ? "en" : "pl"

        let availability = LanguageAvailability()
        let supported = await availability.supportedLanguages
        let candidates = supported.filter { $0.languageCode?.identifier == targetCode }
        // English comes in regional variants; American is the common default.
        guard let target = candidates.first(where: { $0.region?.identifier == "US" }) ?? candidates.first else {
            return .unavailable("System nie obsługuje tego języka docelowego")
        }

        do {
            let status: LanguageAvailability.Status
            if let detected, detected != .undetermined {
                status = await availability.status(from: Locale.Language(identifier: detected.rawValue), to: target)
            } else {
                status = try await availability.status(for: text, to: target)
            }
            if status == .unsupported {
                return .unavailable("Ta para języków nie jest obsługiwana")
            }
        } catch {
            return .unavailable("Nie rozpoznano języka tekstu")
        }

        let sourceName = detected.flatMap { name(of: $0.rawValue) } ?? "wykryty język"
        let targetName = name(of: targetCode) ?? targetCode
        return .request(PaletteTranslationRequest(
            text: text, target: target, directionLabel: "\(sourceName) → \(targetName)"
        ))
    }

    private static func name(of code: String) -> String? {
        Polish.locale.localizedString(forLanguageCode: code)
    }

    /// The fallback: the same text, translated by the web page.
    static func openInGoogle(_ text: String) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let target = recognizer.dominantLanguage == .polish ? "en" : "pl"
        var components = URLComponents(string: "https://translate.google.com/")
        components?.queryItems = [
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "op", value: "translate"),
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    /// Whether this Mac can translate on the device at all.
    static var isOnDeviceSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }
}

// MARK: - Hosting the session

extension View {
    /// Attaches the Translation session the palette's `t ` command runs in.
    /// Language downloads, when needed, ask for confirmation in a sheet on the
    /// palette's own window.
    @ViewBuilder
    func paletteTranslation(_ model: PaletteModel) -> some View {
        if #available(macOS 15.0, *) {
            modifier(PaletteTranslationHost(model: model))
        } else {
            self
        }
    }
}

@available(macOS 15.0, *)
private struct PaletteTranslationHost: ViewModifier {
    @ObservedObject var model: PaletteModel
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                guard let request = await model.translationRequest else { return }
                do {
                    let response = try await session.translate(request.text)
                    await model.finishTranslation(request, result: .success(response.targetText))
                } catch {
                    await model.finishTranslation(request, result: .failure(error))
                }
            }
            .onChange(of: model.translationRequest?.id) {
                guard let request = model.translationRequest else { return }
                if configuration?.target == request.target {
                    // Same languages as last time: the configuration is equal, so
                    // SwiftUI would not rerun the task unless it is invalidated.
                    configuration?.invalidate()
                } else {
                    configuration = TranslationSession.Configuration(source: nil, target: request.target)
                }
            }
    }
}
