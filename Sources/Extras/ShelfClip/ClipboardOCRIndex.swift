//
//  ClipboardOCRIndex.swift
//  FunNotch
//
//  Reads the text out of copied images once, in the background, so the
//  clipboard search can find a screenshot by the words in it. The reading is
//  done on-device by a worker process (see TextRecognition); the recognised
//  text is kept in memory only and is dropped with its history entry.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
final class ClipboardOCRIndex: ObservableObject {
    static let shared = ClipboardOCRIndex()

    @Published private(set) var texts: [UUID: String] = [:]

    /// Entries already queued or done, so each image is read exactly once.
    private var requested: Set<UUID> = []

    /// One at a time: recognition is heavy and nothing here is urgent.
    private nonisolated static let queue = DispatchQueue(label: "com.funnotch.clipboard-ocr", qos: .utility)

    private enum Source: Sendable {
        /// The image as PNG.
        case image(Data)
        case files([URL])
    }

    private init() {}

    /// Nil while OCR search is off, so text recognised earlier stops matching too.
    func text(for id: UUID) -> String? { ShelfClipPrefs.ocr ? texts[id] : nil }

    func index(_ entry: ClipboardEntry) {
        guard ShelfClipPrefs.ocr, !requested.contains(entry.id) else { return }

        let source: Source
        switch entry.payload {
        case .text:
            return
        case let .image(image):
            source = .image(image.png)
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
        case let .image(png): return TextRecognition.text(inImageData: png)
        case let .files(urls): return TextRecognition.text(inImagesAt: urls)
        }
    }
}
