//
//  NowPlayingController.swift
//  FunNotch
//
//  System-wide now playing: the one backend that sees browsers, YouTube,
//  podcasts apps and whatever else publishes to the Now Playing widget.
//
//  MediaRemote is a private framework, and since macOS 15.4 it answers only
//  processes holding a private entitlement. Apple's own /usr/bin/perl holds it,
//  so the app runs perl, which loads `mrbridge.dylib` (built from
//  Tools/mrbridge.m by build.sh) and streams what MediaRemote says as one JSON
//  object per line. Without the dylib the controller falls back to calling
//  MediaRemote in-process, which works only before 15.4.
//

import AppKit
import Foundation

private typealias MRGetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
private typealias MRGetIsPlaying = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
private typealias MRRegisterForNotifications = @convention(c) (DispatchQueue) -> Void
private typealias MRSendCommand = @convention(c) (Int, [String: Any]?) -> Bool
private typealias MRSetElapsedTime = @convention(c) (Double) -> Void

private enum MRCommand: Int {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
}

final class NowPlayingController: MediaController {
    let type: MediaControllerType = .nowPlaying
    var onUpdate: ((TrackInfo) -> Void)?

    // MARK: Availability

    private static let perlPath = "/usr/bin/perl"

    /// The helper library shipped inside the app, if this build has one.
    static var bridgeURL: URL? {
        Bundle.main.url(forResource: "mrbridge", withExtension: "dylib")
    }

    /// True when MediaRemote can be read through perl.
    static var usesBridge: Bool {
        bridgeURL != nil && FileManager.default.isExecutableFile(atPath: perlPath)
    }

    /// MediaRemote stopped answering unentitled callers in macOS 15.4, and
    /// without the bridge there is no way round that.
    static var isDeprecated: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let locked = version.majorVersion > 15 || (version.majorVersion == 15 && version.minorVersion >= 4)
        return locked && !usesBridge
    }

    var isAvailable: Bool {
        if Self.usesBridge { return bridgeFailed == false }
        return getNowPlayingInfo != nil && (everAnswered || !Self.isDeprecated)
    }

    // MARK: State

    private var current = TrackInfo()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    // Bridge
    private var process: Process?
    private var lineBuffer = Data()
    private var stopping = false
    /// The helper is not delivering: either paused after dying repeatedly
    /// (it is tried again) or unusable.
    private var bridgeFailed = false
    /// MediaRemote is missing or the helper cannot be run at all, which no
    /// retry mends.
    private var bridgeUnusable = false
    private var quickExits = 0
    private var retryDelay = NowPlayingController.firstRetryDelay
    private var retryWork: DispatchWorkItem?
    private var artworkID = ""
    private var artworkImage: NSImage?

    // In-process fallback
    private var handle: UnsafeMutableRawPointer?
    private var getNowPlayingInfo: MRGetNowPlayingInfo?
    private var getIsPlaying: MRGetIsPlaying?
    private var registerForNotifications: MRRegisterForNotifications?
    private var sendCommand: MRSendCommand?
    private var setElapsedTime: MRSetElapsedTime?
    /// Set once MediaRemote has actually answered with something.
    private var everAnswered = false

    init() {
        if !Self.usesBridge { loadFramework() }
    }

    private func loadFramework() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY) else { return }
        self.handle = handle

        func symbol<T>(_ name: String, as: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        getNowPlayingInfo = symbol("MRMediaRemoteGetNowPlayingInfo", as: MRGetNowPlayingInfo.self)
        getIsPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: MRGetIsPlaying.self)
        registerForNotifications = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: MRRegisterForNotifications.self)
        sendCommand = symbol("MRMediaRemoteSendCommand", as: MRSendCommand.self)
        setElapsedTime = symbol("MRMediaRemoteSetElapsedTime", as: MRSetElapsedTime.self)
    }

    // MARK: Lifecycle

    func start() {
        stop()
        if Self.usesBridge {
            stopping = false
            launchBridge()
            return
        }

        registerForNotifications?(.main)

        for name in [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
            observers.append(observer)
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        stopping = true
        retryWork?.cancel()
        retryWork = nil
        if let process {
            process.terminationHandler = nil
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        process = nil
        lineBuffer.removeAll()
    }

    func refresh() {
        // The bridge streams on its own; nothing to ask for.
        guard !Self.usesBridge, let getNowPlayingInfo else { return }

        getNowPlayingInfo(.main) { [weak self] information in
            guard let self else { return }
            self.everAnswered = self.everAnswered || !information.isEmpty

            var info = TrackInfo()
            if !information.isEmpty {
                info.title = information["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
                info.artist = TrackInfo.tidyArtist(information["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "")
                info.album = information["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
                info.duration = information["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval ?? 0
                info.elapsed = information["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval ?? 0
                let rate = information["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
                info.isPlaying = rate > 0
                info.timestamp = Date()

                if let data = information["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                    info.artwork = NSImage(data: data)
                } else {
                    info.artwork = self.current.artwork
                }
            }

            self.current = info
            self.onUpdate?(info)
        }
    }

    // MARK: Bridge

    /// The perl program that loads the helper and calls one exported function.
    private static let loader =
        "use DynaLoader;my $l=DynaLoader::dl_load_file($ARGV[0],0) or die 'load';"
            + "my $s=DynaLoader::dl_find_symbol($l,$ARGV[1]) or die 'symbol';"
            + "&{DynaLoader::dl_install_xsub('main::f',$s)}();"

    private func makeProcess(function: String, environment: [String: String] = [:]) -> Process? {
        guard let library = Self.bridgeURL else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.perlPath)
        process.arguments = ["-e", Self.loader, library.path, function]
        // A clean environment, not the app's: perl is not hardened-runtime, so
        // variables such as PERLLIB (not just PERL5LIB/PERL5OPT) would make it
        // load someone else's code with this app's privacy permissions.
        var env = ["PATH": "/usr/bin:/bin"]
        for key in ["HOME", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        for (key, value) in environment { env[key] = value }
        process.environment = env
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private func launchBridge() {
        guard let process = makeProcess(function: "fn_stream") else {
            bridgeFailed = true
            bridgeUnusable = true
            return
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        let started = Date()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.consume(data) }
        }

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, !self.stopping, self.process === finished else { return }
                self.process = nil
                self.publishEmpty()
                guard !self.bridgeUnusable else { return }
                // A helper that dies at once every time is broken for now, not
                // unlucky: let another source take over, and try again later.
                self.quickExits = Date().timeIntervalSince(started) < Self.settleTime ? self.quickExits + 1 : 0
                if self.quickExits >= 3 {
                    self.pauseBridge(status: finished.terminationStatus)
                    return
                }
                self.relaunchBridge(after: 2)
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            bridgeFailed = true
            bridgeUnusable = true
            DiagnosticLog.write("media", "now playing bridge failed to start: \(error.localizedDescription)")
            return
        }

        // Still running after a moment: whatever was killing it has passed.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTime) { [weak self] in
            guard let self, self.process === process, process.isRunning else { return }
            self.retryDelay = Self.firstRetryDelay
            if self.bridgeFailed {
                self.bridgeFailed = false
                DiagnosticLog.write("media", "now playing bridge is back")
            }
        }
    }

    /// A run shorter than this is the helper dying at once.
    private static let settleTime: TimeInterval = 3
    private static let firstRetryDelay: TimeInterval = 30
    private static let maxRetryDelay: TimeInterval = 600

    /// Stops respawning for a while. It used to stop for good, and what kills
    /// the helper at start is whatever the Mac is playing at that moment (an
    /// item it cannot describe): the next item is fine, but system-wide Now
    /// Playing stayed off until the app was restarted.
    private func pauseBridge(status: Int32) {
        if !bridgeFailed {
            DiagnosticLog.write(
                "media", "now playing bridge keeps exiting (status \(status)), trying again in \(Int(retryDelay)) s"
            )
        }
        bridgeFailed = true
        quickExits = 0
        relaunchBridge(after: retryDelay)
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
    }

    private func relaunchBridge(after delay: TimeInterval) {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopping, self.process == nil, !self.bridgeUnusable else { return }
            self.launchBridge()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func publishEmpty() {
        guard !current.isEmpty || current.isPlaying else { return }
        current = TrackInfo()
        onUpdate?(current)
    }

    /// Splits the pipe's bytes into lines and reads each as one snapshot.
    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer.subdata(in: lineBuffer.startIndex ..< newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex ... newline)
            if !line.isEmpty { apply(line: line) }
        }
        // A runaway line would only be garbage; do not let it grow forever.
        if lineBuffer.count > 8 << 20 { lineBuffer.removeAll() }
    }

    private func apply(line: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let error = root["error"] as? String {
            bridgeFailed = true
            bridgeUnusable = true
            DiagnosticLog.write("media", "now playing bridge: \(error)")
            return
        }
        // quickExits is reset by the termination handler (a run of 3 s or more),
        // not here: a bridge that prints one line and crashes must still count.

        var info = TrackInfo()
        let title = root["title"] as? String ?? ""
        if !title.isEmpty || !(root["artist"] as? String ?? "").isEmpty {
            info.title = title
            info.artist = TrackInfo.tidyArtist(root["artist"] as? String ?? "")
            info.album = root["album"] as? String ?? ""
            info.duration = max((root["duration"] as? NSNumber)?.doubleValue ?? 0, 0)
            info.elapsed = max((root["elapsed"] as? NSNumber)?.doubleValue ?? 0, 0)
            info.isPlaying = (root["playing"] as? NSNumber)?.boolValue ?? false
            // `elapsed` was true at `timestamp`, which can be well in the past:
            // the player only reports on a state change. The model projects
            // forward from that moment.
            if let stamp = (root["timestamp"] as? NSNumber)?.doubleValue, stamp > 0 {
                info.timestamp = Date(timeIntervalSince1970: stamp)
            } else {
                info.timestamp = Date()
            }
            let bundle = root["bundle"] as? String ?? ""
            info.bundleIdentifier = bundle.isEmpty ? nil : bundle

            let id = root["artworkID"] as? String ?? ""
            if let encoded = root["artwork"] as? String,
               let data = Data(base64Encoded: encoded),
               let image = NSImage(data: data)
            {
                artworkID = id
                artworkImage = image
            } else if id != artworkID {
                artworkID = id
                artworkImage = nil
            }
            info.artwork = artworkImage
        } else {
            artworkID = ""
            artworkImage = nil
        }

        current = info
        onUpdate?(info)
    }

    // MARK: Transport

    private func send(_ command: MRCommand) {
        if Self.usesBridge {
            runOneShot(environment: ["FN_MR_COMMAND": String(command.rawValue)])
        } else {
            _ = sendCommand?(command.rawValue, nil)
        }
    }

    private func runOneShot(environment: [String: String]) {
        guard let process = makeProcess(function: "fn_send", environment: environment) else { return }
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
    }

    func togglePlayPause() { send(.togglePlayPause) }
    func play() { send(.play) }
    func pause() { send(.pause) }
    func nextTrack() { send(.nextTrack) }
    func previousTrack() { send(.previousTrack) }

    func seek(to time: TimeInterval) {
        if Self.usesBridge {
            runOneShot(environment: ["FN_MR_POSITION": String(time)])
        } else {
            setElapsedTime?(time)
        }
        current.elapsed = time
        current.timestamp = Date()
        onUpdate?(current)
    }
}
