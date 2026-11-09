//
//  ClipboardOCRIndex.swift
//  FunNotch
//
//  Reads the text out of copied images once, in the background, so the
//  clipboard search can find a screenshot by the words in it. Vision runs
//  on-device; the recognised text is kept in memory only and is dropped with
//  its history entry.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

@MainActor
final class ClipboardOCRIndex: ObservableObject {
    static let shared = ClipboardOCRIndex()

    @Published private(set) var texts: [UUID: String] = [:]

    /// Entries already queued or done, so each image is read exactly once.
    private var requested: Set<UUID> = []

    /// One at a time: recognition is heavy and nothing here is urgent.
    private nonisolated static let queue = DispatchQueue(label: "com.funnotch.clipboard-ocr", qos: .utility)

    private enum Source {
        case image(CGImage)
        case files([URL])
    }

    private init() {}

    func text(for id: UUID) -> String? { texts[id] }

    func index(_ entry: ClipboardEntry) {
        guard ShelfClipPrefs.ocr, !requested.contains(entry.id) else { return }

        let source: Source
        switch entry.payload {
        case .text:
            return
        case let .image(image):
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            source = .image(cgImage)
        case let .files(urls):
            let images = urls.filter(Self.isReadableImage).prefix(3)
            guard !images.isEmpty else { return }
            source = .files(Array(images))
        }

        requested.insert(entry.id)
        let id = entry.id
        Self.queue.async {
            let text = Self.recognise(source)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ClipboardOCRIndex.shared.finish(id, text: text) }
            }
        }
    }

    /// Forgets text for entries that left the history.
    func prune(keeping ids: Set<UUID>) {
        requested.formIntersection(ids)
        if texts.keys.contains(where: { !ids.contains($0) }) {
            texts = texts.filter { ids.contains($0.key) }
        }
    }

    private func finish(_ id: UUID, text: String) {
        // The entry may have been deleted while Vision was working.
        guard requested.contains(id), !text.isEmpty else { return }
        texts[id] = text
    }

    private nonisolated static func isReadableImage(_ url: URL) -> Bool {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              type.conforms(to: .image), !type.conforms(to: .svg)
        else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0 && size < 40_000_000
    }

    private nonisolated static func recognise(_ source: Source) -> String {
        switch source {
        case let .image(image):
            return recognise(image)
        case let .files(urls):
            return urls.compactMap { url -> String? in
                guard let image = loadImage(url) else { return nil }
                let text = recognise(image)
                return text.isEmpty ? nil : text
            }.joined(separator: "\n")
        }
    }

    /// Orientation applied and capped at 4096 px: more than enough for text,
    /// and it keeps a 50-megapixel photo from taking half a minute.
    private nonisolated static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func recognise(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Only ask for languages this Vision revision knows; an unknown one
        // makes the whole request throw.
        if let supported = try? request.supportedRecognitionLanguages() {
            let wanted = ["pl-PL", "en-US"].filter(supported.contains)
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            DiagnosticLog.write("clipboard", "OCR failed: \(error.localizedDescription)")
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
