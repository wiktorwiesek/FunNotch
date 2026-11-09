//
//  WebcamManager.swift
//  FunNotch
//
//  Drives the "mirror" — a live front-camera preview inside the open notch.
//  The session only runs while the mirror is actually visible so the camera
//  light is never on for longer than it needs to be.
//

import AVFoundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class WebcamManager: NSObject, ObservableObject {
    static let shared = WebcamManager()

    @Published private(set) var isRunning = false
    @Published private(set) var authorizationStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var hasCamera = false

    let session = AVCaptureSession()
    // Touched only on `sessionQueue`, never concurrently.
    nonisolated(unsafe) private var input: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "com.funnotch.camera")

    private override init() {
        super.init()
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        hasCamera = AVCaptureDevice.default(for: .video) != nil
    }

    func requestAccessIfNeeded(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationStatus = .authorized
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.authorizationStatus = granted ? .authorized : .denied
                        completion(granted)
                    }
                }
            }
        default:
            authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
            DiagnosticLog.write("camera", "access not granted (\(authorizationStatus.rawValue))")
            completion(false)
        }
    }

    /// Denied or restricted: asking again does nothing, only System Settings can change it.
    var isAccessBlocked: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// True from `start()` until `stop()`. The camera takes a moment to come up
    /// on its own queue, and the mirror can be closed before it has: without
    /// this, that late "started" would flip `isRunning` on after `stop()` and
    /// leave the camera light burning behind a closed notch.
    private var wantsRunning = false

    func start() {
        wantsRunning = true
        requestAccessIfNeeded { [weak self] granted in
            guard granted, let self, self.wantsRunning else { return }
            self.configureAndRun()
        }
    }

    private func configureAndRun() {
        guard !isRunning else { return }
        guard let device = AVCaptureDevice.default(for: .video) else {
            hasCamera = false
            return
        }
        hasCamera = true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .medium

            if self.input == nil, let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.input = input
            }

            self.session.commitConfiguration()
            if !self.session.isRunning {
                self.session.startRunning()
            }
            let running = self.session.isRunning

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Stopped while starting: the stop block queued after this one
                    // shuts the session down, so nothing is left running.
                    self.isRunning = running && self.wantsRunning
                }
            }
        }
    }

    func stop() {
        wantsRunning = false
        isRunning = false
        // Always queued, even when `isRunning` is still false: a start may be
        // in flight, and the serial queue runs this after it.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
}

/// Hosts the AVFoundation preview layer inside SwiftUI.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.previewLayer.session = session
        nsView.applyMirroring()
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.addSublayer(previewLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not supported") }

        /// The preview layer has no connection until the session has a camera
        /// input, so this is applied on every update rather than once at init
        /// (where it silently did nothing).
        func applyMirroring() {
            guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            if !connection.isVideoMirrored { connection.isVideoMirrored = true }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
            applyMirroring()
        }
    }
}
