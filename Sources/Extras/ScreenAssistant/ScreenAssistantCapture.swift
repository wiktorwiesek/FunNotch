//
//  ScreenAssistantCapture.swift
//  FunNotch
//
//  Taking the screenshot and keeping it somewhere private. The selection is
//  made by the system's own `screencapture -i` (crosshair, Esc cancels and
//  leaves no file), so Fun Notch links no capture framework and never touches
//  pixels it was not shown. The file lives in a 0700 folder of its own that
//  the controller removes when the panel closes or the app quits.
//

import AppKit
import Foundation
import ImageIO

enum ScreenAssistantStorage {
    private static let prefix = "FunNotch-ScreenAssistant-"

    /// A new folder only the current user can enter.
    static func makePrivateDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    /// Folders a crash or force-quit left behind. Anything younger than an
    /// hour may belong to a session that is still open.
    static func removeStaleDirectories() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: manager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for url in entries where url.lastPathComponent.hasPrefix(prefix) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? manager.removeItem(at: url)
            }
        }
    }
}

enum ScreenAssistantCapture {
    /// Runs the crosshair selection and reports whether an image was written.
    static func capture(to url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", "-t", "png", url.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // Capturing `process` keeps it alive until it exits; the handler
            // is released after it has run.
            process.terminationHandler = { [process] _ in
                _ = process
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                continuation.resume(returning: size > 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    /// Decodes the capture straight to a thumbnail of at most `maxPixel`
    /// pixels, so the full bitmap (tens of megabytes on a large display) is
    /// never held in memory.
    static func thumbnail(at url: URL, maxPixel: Int = 600) async -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
