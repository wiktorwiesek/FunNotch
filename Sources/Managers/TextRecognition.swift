//
//  TextRecognition.swift
//  FunNotch
//
//  Reads the text out of an image, in a process of its own.
//
//  Vision keeps its models and caches for as long as the process that used it
//  lives, and has no call to let go of them: a process that weighed 2 MB
//  weighs 97 MB twelve seconds after one accurate reading of one screenshot
//  (measured on macOS 27.3; `malloc_zone_pressure_relief` gives nothing back).
//  Fun Notch reads every copied image, so it would carry that all day. The
//  reading is therefore done by a second copy of the app's own binary, started
//  with `--ocr`: it takes the image on its standard input, or paths as
//  arguments, prints the text and exits, and the memory goes with it.
//
//  Still entirely on-device: no network, nothing leaves the Mac, and a copied
//  image does not touch the disk on its way to the worker.
//

import Foundation
import ImageIO
import Vision

enum TextRecognition {
    private static let flag = "--ocr"

    // MARK: - The app's side

    /// The text in an encoded image (PNG, TIFF, JPEG…). Blocks until the
    /// worker is done, a second or two: call it off the main thread.
    static func text(inImageData data: Data) -> String {
        run(arguments: [], input: data)
    }

    /// The text in image files, one after another.
    static func text(inImagesAt urls: [URL]) -> String {
        urls.isEmpty ? "" : run(arguments: urls.map(\.path), input: nil)
    }

    private static func run(arguments: [String], input: Data?) -> String {
        guard let executable = Bundle.main.executableURL else { return "" }
        // A worker that dies before it has read its input must cost a failed
        // write, not the app: the default answer to SIGPIPE is to terminate.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = executable
        process.arguments = [flag] + arguments
        let output = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = output
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            DiagnosticLog.write("ocr", "worker did not start: \(error.localizedDescription)")
            return ""
        }
        // A reading that takes a minute is one that will never end.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: watchdog)

        if let input {
            // The worker reads all of it before it writes anything, so this
            // cannot deadlock against the read below.
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }
        let data = try? output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else {
            DiagnosticLog.write("ocr", "worker failed (\(process.terminationStatus))")
            return ""
        }
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    // MARK: - The worker's side

    static var isWorker: Bool { CommandLine.arguments.contains(flag) }

    /// Reads what it was given, prints the text, and exits. Called before
    /// anything of the app is set up.
    static func runWorker() -> Never {
        let paths = CommandLine.arguments.drop { $0 != flag }.dropFirst()
        var sources: [CGImageSource] = []
        if paths.isEmpty {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if let source = CGImageSourceCreateWithData(data as CFData, nil) { sources.append(source) }
        } else {
            sources = paths.compactMap { CGImageSourceCreateWithURL(URL(fileURLWithPath: $0) as CFURL, nil) }
        }
        let texts = sources.compactMap { source -> String? in
            guard let image = load(source) else { return nil }
            let text = recognise(image)
            return text.isEmpty ? nil : text
        }
        FileHandle.standardOutput.write(Data(texts.joined(separator: "\n").utf8))
        exit(0)
    }

    /// Orientation applied and capped at 4096 px: more than enough for text,
    /// and it keeps a 50-megapixel photo from taking half a minute.
    private static func load(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func recognise(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Vision reads English only unless told otherwise, so Polish
        // diacritics came out as plain letters. Ask only for languages this
        // Vision revision knows; an unknown one makes the request throw.
        if let supported = try? request.supportedRecognitionLanguages() {
            let wanted = ["pl-PL", "en-US"].filter(supported.contains)
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
        }
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
