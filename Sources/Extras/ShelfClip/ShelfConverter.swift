//
//  ShelfConverter.swift
//  FunNotch
//
//  Converts and archives files on the shelf, entirely offline: images through
//  ImageIO, PDF pages through CoreGraphics, background removal through Vision,
//  video and audio through AVFoundation, ZIP through /usr/bin/ditto. Every
//  result is added back to the shelf as a new item.
//

import AppKit
import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

enum ShelfConversion: Hashable {
    enum ImageFormat: CaseIterable {
        case png, jpeg, heic, tiff

        var type: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .tiff: return .tiff
            }
        }

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .tiff: return "tiff"
            }
        }

        /// Every extension that already is this format, so it is not offered
        /// as a conversion of itself.
        var extensions: Set<String> {
            switch self {
            case .png: return ["png"]
            case .jpeg: return ["jpg", "jpeg"]
            case .heic: return ["heic", "heif"]
            case .tiff: return ["tif", "tiff"]
            }
        }

        var title: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            case .tiff: return "TIFF"
            }
        }

        /// HEIC in particular is not writable on every Mac.
        var isEncodable: Bool {
            let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            return identifiers.contains(type.identifier)
        }
    }

    enum VideoPreset {
        case h264, hevc, audioOnly
    }

    enum AudioFormat {
        case aac, wav, aiff

        var extensions: Set<String> {
            switch self {
            case .aac: return ["m4a"]
            case .wav: return ["wav"]
            case .aiff: return ["aif", "aiff"]
            }
        }
    }

    case image(ImageFormat)
    case pdfFirstPage
    case pdfAllPages
    case removeBackground
    case video(VideoPreset)
    case audio(AudioFormat)
    case zip
    case unzip

    var menuTitle: String {
        switch self {
        case let .image(format): return format.title
        case .pdfFirstPage: return "Pierwsza strona → PNG"
        case .pdfAllPages: return "Wszystkie strony → PNG"
        case .removeBackground: return "Usuń tło → PNG"
        case .video(.h264): return "MP4 (H.264)"
        case .video(.hevc): return "HEVC (H.265)"
        case .video(.audioOnly): return "Tylko dźwięk (M4A)"
        case .audio(.aac): return "AAC (M4A)"
        case .audio(.wav): return "WAV"
        case .audio(.aiff): return "AIFF"
        case .zip: return "Spakuj do ZIP"
        case .unzip: return "Rozpakuj"
        }
    }

    /// Short target label for the progress line: "foto.heic → PNG".
    fileprivate var targetLabel: String {
        switch self {
        case let .image(format): return format.title
        case .pdfFirstPage, .pdfAllPages, .removeBackground: return "PNG"
        case .video(.h264): return "MP4"
        case .video(.hevc): return "HEVC"
        case .video(.audioOnly), .audio(.aac): return "M4A"
        case .audio(.wav): return "WAV"
        case .audio(.aiff): return "AIFF"
        case .zip: return "ZIP"
        case .unzip: return "rozpakowanie"
        }
    }

    fileprivate var doneWord: String {
        switch self {
        case .zip: return "spakowano"
        case .unzip: return "rozpakowano"
        case .removeBackground: return "tło usunięte"
        default: return "przekonwertowano"
        }
    }
}

enum ShelfConversionError: LocalizedError {
    case unreadable
    case encoderMissing(String)
    case noForeground
    case noAudioTrack
    case lockedPDF
    case presetUnavailable
    case emptyArchive
    case tool(String)
    case tooManyPages(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Nie można odczytać pliku"
        case let .encoderMissing(name): return "Ten Mac nie potrafi zapisać formatu \(name)"
        case .noForeground: return "Nie znaleziono wyraźnego obiektu na obrazie"
        case .noAudioTrack: return "Plik nie ma ścieżki dźwiękowej"
        case .lockedPDF: return "PDF jest zablokowany hasłem"
        case .presetUnavailable: return "Ten plik nie da się wyeksportować w tym formacie"
        case .emptyArchive: return "Archiwum jest puste"
        case let .tool(message): return message.isEmpty ? "Operacja się nie powiodła" : message
        case let .tooManyPages(count): return "PDF ma \(count) stron; zamiana wszystkich naraz działa do 50"
        }
    }
}

struct ShelfConversionJob: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case done(String)
        case failed(String)
    }

    let id = UUID()
    var title: String
    /// nil while the length of the work is unknown.
    var progress: Double?
    var state: State = .running
}

@MainActor
final class ShelfConverter: ObservableObject {
    static let shared = ShelfConverter()

    @Published private(set) var jobs: [ShelfConversionJob] = []

    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Opening a PDF just to count pages is too slow to repeat on every
    /// context-menu build, and the menu is built on main.
    private var pdfPageCounts: [URL: Int] = [:]

    private func pdfPageCount(of url: URL) -> Int {
        if let cached = pdfPageCounts[url] { return cached }
        let count = CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
        if pdfPageCounts.count > 200 { pdfPageCounts.removeAll() }
        pdfPageCounts[url] = count
        return count
    }

    private init() {}

    // MARK: - What can be done to an item

    /// Conversions offered for one file (not ZIP or unzip; see `canUnzip`).
    func options(for item: ShelfItem) -> [ShelfConversion] {
        let ext = item.url.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext) else { return [] }

        var result: [ShelfConversion] = []
        if type.conforms(to: .pdf) {
            result.append(.pdfFirstPage)
            if pdfPageCount(of: item.url) > 1 { result.append(.pdfAllPages) }
        } else if type.conforms(to: .image), !type.conforms(to: .svg) {
            for format in ShelfConversion.ImageFormat.allCases
            where !format.extensions.contains(ext) && format.isEncodable {
                result.append(.image(format))
            }
            result.append(.removeBackground)
        } else if type.conforms(to: .movie) {
            result += [.video(.h264), .video(.hevc), .video(.audioOnly)]
        } else if type.conforms(to: .audio) {
            for format in [ShelfConversion.AudioFormat.aac, .wav, .aiff] where !format.extensions.contains(ext) {
                result.append(.audio(format))
            }
        }
        return result
    }

    func canUnzip(_ item: ShelfItem) -> Bool {
        item.url.pathExtension.lowercased() == "zip"
    }

    /// What a menu action applies to: the whole selection when the item is part
    /// of a multi-selection, otherwise just the item.
    func targets(for item: ShelfItem) -> [ShelfItem] {
        let shelf = ShelfManager.shared
        guard shelf.selection.contains(item.id), shelf.selection.count > 1 else { return [item] }
        return shelf.items.filter { shelf.selection.contains($0.id) }
    }

    // MARK: - Running

    func run(_ conversion: ShelfConversion, on items: [ShelfItem]) {
        guard !items.isEmpty else { return }

        switch conversion {
        case .zip:
            let urls = items.map(\.url)
            let title = urls.count == 1
                ? "\(urls[0].lastPathComponent) → ZIP"
                : "\(Polish.count(urls.count, "element", "elementy", "elementów")) → ZIP"
            let archiveName = urls.count == 1
                ? Self.archiveBaseName(for: urls[0])
                : "Archiwum \(ShelfManager.timestampSuffix())"
            launch(conversion, title: title) { staging, _ in
                [try await ShelfConversionWork.zip(urls, name: archiveName, staging: staging)]
            }

        case .unzip:
            for item in items where canUnzip(item) {
                let url = item.url
                launch(conversion, title: "\(url.lastPathComponent) → rozpakowanie") { staging, _ in
                    try await ShelfConversionWork.unzip(url, staging: staging)
                }
            }

        default:
            for item in items where options(for: item).contains(conversion) {
                let url = item.url
                launch(conversion, title: "\(item.name) → \(conversion.targetLabel)") { staging, report in
                    try await ShelfConversionWork.convert(url, conversion: conversion, staging: staging, report: report)
                }
            }
        }
    }

    private static func archiveBaseName(for url: URL) -> String {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    private func launch(
        _ conversion: ShelfConversion,
        title: String,
        work: @escaping @Sendable (URL, @escaping @Sendable (Double?) -> Void) async throws -> [URL]
    ) {
        let staging = ShelfManager.shared.makeStagingDirectory()
        let job = ShelfConversionJob(title: title)
        jobs.append(job)
        let id = job.id
        DiagnosticLog.write("shelf", "conversion started: \(title)")

        tasks[id] = Task { [weak self] in
            do {
                let outputs = try await work(staging) { value in
                    Task { @MainActor in self?.setProgress(id, value) }
                }
                try Task.checkCancellation()
                self?.finish(id, conversion: conversion, staging: staging, outputs: outputs)
            } catch is CancellationError {
                self?.cancelled(id, staging: staging)
            } catch {
                self?.fail(id, staging: staging, error: error)
            }
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func dismiss(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    private func setProgress(_ id: UUID, _ value: Double?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        jobs[index].progress = value.map { min(max($0, 0), 1) }
    }

    private func finish(_ id: UUID, conversion: ShelfConversion, staging: URL, outputs: [URL]) {
        defer {
            try? FileManager.default.removeItem(at: staging)
            tasks[id] = nil
        }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }

        let added = ShelfManager.shared.addConverted(outputs)
        guard !added.isEmpty else {
            failJob(index, message: "Nie udało się dodać wyniku na Półkę")
            return
        }

        let title = added.count == 1
            ? added[0].name
            : Polish.count(added.count, "plik", "pliki", "plików")
        jobs[index].state = .done(title)
        jobs[index].progress = 1
        DiagnosticLog.write("shelf", "conversion finished: \(title)")

        IslandCenter.shared.post(Island(
            symbol: "checkmark.circle.fill",
            tint: SettingsStyle.green,
            title: title,
            detail: "\(conversion.doneWord)",
            trailing: added.count == 1 ? formattedFileSize(added[0].size) : nil,
            duration: 3.5
        ))
        scheduleRemoval(of: id, after: 6)
    }

    private func fail(_ id: UUID, staging: URL, error: Error) {
        try? FileManager.default.removeItem(at: staging)
        tasks[id] = nil
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        failJob(index, message: error.localizedDescription)
    }

    private func failJob(_ index: Int, message: String) {
        let title = jobs[index].title
        let id = jobs[index].id
        jobs[index].state = .failed(message)
        DiagnosticLog.write("shelf", "conversion failed: \(title): \(message)")

        IslandCenter.shared.post(Island(
            symbol: "exclamationmark.triangle.fill",
            tint: SettingsStyle.orange,
            title: "Nie udało się",
            detail: "\(message)",
            duration: 5
        ))
        scheduleRemoval(of: id, after: 12)
    }

    private func cancelled(_ id: UUID, staging: URL) {
        try? FileManager.default.removeItem(at: staging)
        tasks[id] = nil
        jobs.removeAll { $0.id == id }
    }

    private func scheduleRemoval(of id: UUID, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(id) }
        }
    }
}

// MARK: - The work itself

/// Heavy lifting, kept free of the main actor so the notch stays responsive.
enum ShelfConversionWork {
    typealias Report = @Sendable (Double?) -> Void

    static func convert(
        _ source: URL,
        conversion: ShelfConversion,
        staging: URL,
        report: @escaping Report
    ) async throws -> [URL] {
        let base = source.deletingPathExtension().lastPathComponent

        switch conversion {
        case let .image(format):
            return [try convertImage(source, to: format, base: base, staging: staging)]
        case .pdfFirstPage:
            return try renderPDF(source, allPages: false, base: base, staging: staging, report: report)
        case .pdfAllPages:
            return try renderPDF(source, allPages: true, base: base, staging: staging, report: report)
        case .removeBackground:
            return [try removeBackground(source, base: base, staging: staging)]
        case .video(.h264):
            return [try await export(
                source, preset: AVAssetExportPresetHighestQuality, fileTypes: [.mp4, .mov],
                name: "\(base) (H.264)", needsAudio: false, staging: staging, report: report
            )]
        case .video(.hevc):
            return [try await export(
                source, preset: AVAssetExportPresetHEVCHighestQuality, fileTypes: [.mp4, .mov],
                name: "\(base) (HEVC)", needsAudio: false, staging: staging, report: report
            )]
        case .video(.audioOnly), .audio(.aac):
            return [try await export(
                source, preset: AVAssetExportPresetAppleM4A, fileTypes: [.m4a],
                name: base, needsAudio: true, staging: staging, report: report
            )]
        case .audio(.wav):
            return [try convertPCM(source, bigEndian: false, ext: "wav", base: base, staging: staging, report: report)]
        case .audio(.aiff):
            return [try convertPCM(source, bigEndian: true, ext: "aiff", base: base, staging: staging, report: report)]
        case .zip, .unzip:
            return []
        }
    }

    // MARK: Images

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func convertImage(_ source: URL, to format: ShelfConversion.ImageFormat, base: String, staging: URL) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0
        else { throw ShelfConversionError.unreadable }

        let output = staging.appendingPathComponent("\(base).\(format.fileExtension)")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ShelfConversionError.encoderMissing(format.title)
        }

        var options: [CFString: Any] = [:]
        if format == .jpeg || format == .heic { options[kCGImageDestinationLossyCompressionQuality] = 0.92 }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let hasAlpha = (properties?[kCGImagePropertyHasAlpha] as? Bool) ?? false

        if format == .jpeg, hasAlpha {
            // JPEG has no transparency; left alone ImageIO turns it black.
            guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  let flat = flatten(image)
            else { throw ShelfConversionError.unreadable }
            if let orientation = properties?[kCGImagePropertyOrientation] {
                options[kCGImagePropertyOrientation] = orientation
            }
            CGImageDestinationAddImage(destination, flat, options as CFDictionary)
        } else {
            // Passing the source through keeps orientation and metadata.
            CGImageDestinationAddImageFromSource(destination, imageSource, 0, options as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { throw ShelfConversionError.encoderMissing(format.title) }
        return output
    }

    private static func flatten(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ShelfConversionError.encoderMissing("PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShelfConversionError.encoderMissing("PNG") }
    }

    /// Orientation applied, longest side capped.
    private static func loadOriented(_ url: URL, maxPixel: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ShelfConversionError.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? maxPixel
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? maxPixel
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixel),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ShelfConversionError.unreadable
        }
        return image
    }

    // MARK: Background removal

    private static func removeBackground(_ source: URL, base: String, staging: URL) throws -> URL {
        let image = try loadOriented(source, maxPixel: 4096)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ShelfConversionError.noForeground
        }
        let buffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances,
            from: handler,
            croppedToInstancesExtent: false
        )
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let result = CIContext().createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: sRGB) else {
            throw ShelfConversionError.unreadable
        }

        let output = staging.appendingPathComponent("\(base) – bez tła.png")
        try writePNG(result, to: output)
        return output
    }

    // MARK: PDF

    private static let maxPDFPages = 50

    private static func renderPDF(
        _ source: URL, allPages: Bool, base: String, staging: URL, report: Report
    ) throws -> [URL] {
        guard let document = CGPDFDocument(source as CFURL) else { throw ShelfConversionError.unreadable }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
            throw ShelfConversionError.lockedPDF
        }

        // Each page is a PNG that lands on the shelf as its own item; a very
        // long PDF would flood the shelf and keep the converter busy for minutes.
        if allPages, document.numberOfPages > maxPDFPages {
            throw ShelfConversionError.tooManyPages(document.numberOfPages)
        }
        let last = allPages ? document.numberOfPages : min(1, document.numberOfPages)
        guard last > 0 else { throw ShelfConversionError.unreadable }

        var outputs: [URL] = []
        for number in 1 ... last {
            try Task.checkCancellation()
            guard let page = document.page(at: number) else { continue }

            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let pageWidth = rotated ? box.height : box.width
            let pageHeight = rotated ? box.width : box.height
            // About 2000 px on the long side (A4 at roughly 170 dpi).
            let scale = min(max(2000 / max(pageWidth, pageHeight, 1), 1.5), 4)
            let width = max(Int((pageWidth * scale).rounded()), 1)
            let height = max(Int((pageHeight * scale).rounded()), 1)

            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw ShelfConversionError.unreadable }

            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(rect)
            // getDrawingTransform never scales a page up: handed the big canvas
            // it drew the page at 1:1 in the middle of it. So it maps the crop
            // box (rotation included) onto a rect of the page's own size, and
            // the context is scaled up to the canvas separately.
            context.scaleBy(x: scale, y: scale)
            let natural = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: natural, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)

            guard let image = context.makeImage() else { throw ShelfConversionError.unreadable }
            let output = staging.appendingPathComponent("\(base) – strona \(number).png")
            try writePNG(image, to: output)
            outputs.append(output)
            report(Double(number) / Double(last))
        }
        return outputs
    }

    // MARK: Video and audio through AVAssetExportSession

    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    private static func export(
        _ source: URL,
        preset: String,
        fileTypes: [AVFileType],
        name: String,
        needsAudio: Bool,
        staging: URL,
        report: @escaping Report
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isExportable) else { throw ShelfConversionError.presetUnavailable }
        if needsAudio, try await asset.loadTracks(withMediaType: .audio).isEmpty {
            throw ShelfConversionError.noAudioTrack
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ShelfConversionError.presetUnavailable
        }
        guard let fileType = fileTypes.first(where: { session.supportedFileTypes.contains($0) }) else {
            throw ShelfConversionError.presetUnavailable
        }
        let ext = fileType == .mp4 ? "mp4" : (fileType == .mov ? "mov" : "m4a")
        let output = staging.appendingPathComponent("\(name).\(ext)")
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = fileType == .mp4

        let box = ExportBox(session)
        try Task.checkCancellation()

        let poller = Task {
            while !Task.isCancelled {
                report(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        poller.cancel()

        switch session.status {
        case .completed:
            return output
        case .cancelled:
            throw CancellationError()
        default:
            throw session.error ?? ShelfConversionError.presetUnavailable
        }
    }

    // MARK: WAV and AIFF

    private static func convertPCM(
        _ source: URL, bigEndian: Bool, ext: String, base: String, staging: URL, report: Report
    ) throws -> URL {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch { throw ShelfConversionError.unreadable }

        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = staging.appendingPathComponent("\(base).\(ext)")
        let file = try AVAudioFile(forWriting: output, settings: settings)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else {
            throw ShelfConversionError.unreadable
        }
        let total = max(input.length, 1)
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try file.write(from: buffer)
            report(Double(input.framePosition) / Double(total))
        }
        return output
    }

    // MARK: ZIP

    /// One run of /usr/bin/ditto that can be cancelled from outside.
    private final class DittoRun: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var isCancelled = false
        private var errorOutput = Data()

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            isCancelled = true
            if let process, process.isRunning { process.terminate() }
        }

        private func collect(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            // Only the start matters for the message; the rest just has to be drained.
            if errorOutput.count < 8192 { errorOutput.append(data.prefix(8192 - errorOutput.count)) }
        }

        func run(_ arguments: [String]) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = arguments
                let errors = Pipe()
                process.standardError = errors
                process.standardOutput = FileHandle.nullDevice
                // Drained while ditto runs: a pipe holds about 64 KB, and a ditto
                // that warns past that would block on write and never exit.
                errors.fileHandleForReading.readabilityHandler = { [self] handle in
                    let data = handle.availableData
                    // Empty data is EOF; without clearing the handler it would spin.
                    if data.isEmpty { handle.readabilityHandler = nil } else { collect(data) }
                }
                process.terminationHandler = { [self] finished in
                    errors.fileHandleForReading.readabilityHandler = nil
                    collect(errors.fileHandleForReading.readDataToEndOfFile())
                    lock.lock()
                    let text = String(decoding: errorOutput, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    lock.unlock()
                    if finished.terminationStatus == 0 {
                        continuation.resume()
                    } else if finished.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: ShelfConversionError.tool(text))
                    }
                }

                lock.lock()
                defer { lock.unlock() }
                if isCancelled {
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try process.run()
                    self.process = process
                } catch {
                    errors.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func ditto(_ arguments: [String]) async throws {
        let run = DittoRun()
        try await withTaskCancellationHandler {
            try await run.run(arguments)
        } onCancel: {
            run.cancel()
        }
    }

    static func zip(_ sources: [URL], name: String, staging: URL) async throws -> URL {
        let output = staging.appendingPathComponent("\(name).zip")
        // --sequesterRsrc keeps resource forks in __MACOSX.
        var flags = ["-c", "-k", "--sequesterRsrc"]

        if sources.count == 1 {
            // --keepParent puts a *folder* at the archive's root, as Finder
            // does. For a plain file ditto would embed the file's containing
            // folder instead ("Desktop/Screenshot.png"), so it is left off.
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: sources[0].path, isDirectory: &isDirectory)
            if isDirectory.boolValue { flags.append("--keepParent") }
            try await ditto(flags + [sources[0].path, output.path])
            return output
        }
        flags.append("--keepParent")

        // ditto archives exactly one source, so several items are gathered in
        // a folder named like the archive first (copies are clones on APFS).
        let payload = staging.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        for source in sources {
            try Task.checkCancellation()
            var destination = payload.appendingPathComponent(source.lastPathComponent)
            var counter = 1
            while FileManager.default.fileExists(atPath: destination.path) {
                let base = source.deletingPathExtension().lastPathComponent
                let file = source.pathExtension.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(source.pathExtension)"
                destination = payload.appendingPathComponent(file)
                counter += 1
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        try await ditto(flags + [payload.path, output.path])
        return output
    }

    static func unzip(_ archive: URL, staging: URL) async throws -> [URL] {
        let folder = staging.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await ditto(["-x", "-k", archive.path, folder.path])

        let ignored: Set<String> = ["__MACOSX", ".DS_Store"]
        let top = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !ignored.contains($0.lastPathComponent) }
        guard !top.isEmpty else { throw ShelfConversionError.emptyArchive }

        // A dozen loose files would flood the shelf; keep them in one folder.
        guard top.count > 12 else { return top }
        let wrapper = staging.appendingPathComponent(archive.deletingPathExtension().lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        for url in top {
            try FileManager.default.moveItem(at: url, to: wrapper.appendingPathComponent(url.lastPathComponent))
        }
        return [wrapper]
    }
}
