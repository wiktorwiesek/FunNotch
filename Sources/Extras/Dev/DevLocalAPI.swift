//
//  DevLocalAPI.swift
//  FunNotch
//
//  A tiny HTTP server on 127.0.0.1:9999 so scripts, CI hooks and the shell can
//  put something in the notch: `POST /island`, `POST /activity/start`,
//  `POST /activity/end`.
//
//  It is off by default and guarded twice. It only ever binds the loopback
//  address, and every request needs `Authorization: Bearer <token>` with a
//  random per-install token that lives in the Keychain. The token is checked
//  before the route is, so an unauthenticated caller cannot even learn which
//  paths exist. A web page cannot get at it either: a browser would have to
//  send the Authorization header, which makes it ask first (a preflight with
//  no header, answered 401 with no CORS headers).
//

import AppKit
import Foundation
import Network
import Security
import SwiftUI

// MARK: - Token

/// The shared secret. Stored as a generic password so the shell hook can read
/// it at run time with `security find-generic-password` instead of anything
/// being written into a dotfile.
enum LocalAPIToken {
    static let service = "pl.funnotch.local-api"
    static let account = "token"

    private static var baseQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    static func current() -> String? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func ensure() -> String? {
        current() ?? regenerate()
    }

    /// Replaces the token. Anything still holding the old one stops working,
    /// which is the point of the button in Settings.
    @discardableResult
    static func regenerate() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData] = Data(token.utf8)
        attributes[kSecAttrLabel] = "Fun Notch — lokalne API"
        // Trust this app and /usr/bin/security up front. Without it the shell
        // hook's `security` call would raise a Keychain password prompt in
        // the background of every terminal.
        if let access = makeAccess() { attributes[kSecAttrAccess] = access }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            DiagnosticLog.write("api", "Keychain: could not store the token (\(status))")
            return nil
        }
        return token
    }

    private static func makeAccess() -> SecAccess? {
        var own: SecTrustedApplication?
        var tool: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &own) == errSecSuccess,
              SecTrustedApplicationCreateFromPath("/usr/bin/security", &tool) == errSecSuccess,
              let own, let tool
        else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Fun Notch — lokalne API" as CFString, [own, tool] as CFArray, &access) == errSecSuccess
        else { return nil }
        return access
    }
}

// MARK: - HTTP plumbing

struct DevHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct DevHTTPResponse {
    let status: Int
    let body: Data

    init(_ status: Int, _ object: [String: Any]) {
        self.status = status
        body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    var reason: String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }

    var wire: Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if status == 401 { head += "WWW-Authenticate: Bearer\r\n" }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

private enum DevHTTPParse {
    case incomplete(sendContinue: Bool)
    case invalid(DevHTTPResponse)
    case complete(DevHTTPRequest)

    static let maxBody = 64 * 1024

    static func parse(_ data: Data) -> DevHTTPParse {
        guard let terminator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16 * 1024
                ? .invalid(DevHTTPResponse(413, ["error": "headers too large"]))
                : .incomplete(sendContinue: false)
        }
        guard let head = String(data: data[..<terminator.lowerBound], encoding: .utf8) else {
            return .invalid(DevHTTPResponse(400, ["error": "bad request"]))
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            return .invalid(DevHTTPResponse(400, ["error": "bad request"]))
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else {
            return .invalid(DevHTTPResponse(400, ["error": "bad content-length"]))
        }
        guard length <= maxBody else {
            return .invalid(DevHTTPResponse(413, ["error": "body too large"]))
        }
        let body = data[terminator.upperBound...]
        guard body.count >= length else {
            // curl sends "Expect: 100-continue" for bodies over 1 KB and waits
            // a second for an answer before sending them.
            return .incomplete(sendContinue: headers["expect"]?.lowercased() == "100-continue")
        }
        // Query strings carry nothing here.
        let path = String(requestLine[1]).components(separatedBy: "?")[0]
        return .complete(DevHTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: path,
            headers: headers,
            body: Data(body.prefix(length))
        ))
    }
}

/// One accepted socket: read a request, hand it to the manager, write the
/// answer, close. Everything here runs on the server's queue; only routing
/// hops to the main actor.
private final class DevHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var sentContinue = false
    private var finished = false

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        // Belt and braces: the listener is bound to loopback already.
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
        }
        connection.start(queue: queue)
        // A client that connects and goes quiet must not hold the socket.
        queue.asyncAfter(deadline: .now() + 5) { [self] in finish() }
        receive()
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        default: return false
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            switch DevHTTPParse.parse(buffer) {
            case .invalid(let response):
                send(response)
            case .complete(let request):
                Task { @MainActor in
                    let response = LocalAPIManager.shared.route(request)
                    self.queue.async { self.send(response) }
                }
            case .incomplete(let sendContinue):
                if error != nil || isComplete || buffer.count > DevHTTPParse.maxBody + 32 * 1024 {
                    finish()
                    return
                }
                if sendContinue, !sentContinue {
                    sentContinue = true
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                }
                receive()
            }
        }
    }

    private func send(_ response: DevHTTPResponse) {
        guard !finished else { return }
        connection.send(content: response.wire, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [self] _ in finish() })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        connection.cancel()
    }
}

// MARK: - Manager

@MainActor
final class LocalAPIManager: ObservableObject {
    static let shared = LocalAPIManager()
    nonisolated static let port: UInt16 = 9999
    static let enabledKey = "extras.dev.api.enabled"

    private struct Activity {
        let title: String
        let symbol: String
        let started: Date
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?
    @Published private(set) var runningActivities = 0

    private var listener: NWListener?
    private var token: String?
    private var activities: [String: Activity] = [:]
    private let queue = DispatchQueue(label: "pl.funnotch.local-api")

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Safe to call repeatedly: only one listener ever exists.
    func start() {
        guard isEnabled, listener == nil else { return }
        guard let token = LocalAPIToken.ensure() else {
            lastError = "Nie udało się zapisać tokenu w Pęku kluczy."
            return
        }
        self.token = token

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only: nothing on the network can reach this.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            lastError = "Nie udało się uruchomić serwera: \(error.localizedDescription)"
            DiagnosticLog.write("api", "listener failed: \(error)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.listenerStateChanged(state) }
        }
        listener.newConnectionHandler = { [queue] connection in
            DevHTTPConnection(connection, queue: queue).start()
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
        activities.removeAll()
        runningActivities = 0
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        lastError = nil
        if enabled { start() } else { stop() }
    }

    /// The current token, created on first ask.
    func revealToken() -> String? {
        if token == nil { token = LocalAPIToken.ensure() }
        return token
    }

    func regenerateToken() {
        token = LocalAPIToken.regenerate()
        objectWillChange.send()
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            lastError = nil
            DiagnosticLog.write("api", "listening on 127.0.0.1:\(Self.port)")
        case .failed(let error):
            isListening = false
            listener?.cancel()
            listener = nil
            // Almost always "address already in use": another copy, or
            // something else, owns the port.
            lastError = "Port \(Self.port) jest zajęty lub niedostępny (\(error.localizedDescription))."
            DiagnosticLog.write("api", "listener failed: \(error)")
        default:
            break
        }
    }

    // MARK: Routing

    func route(_ request: DevHTTPRequest) -> DevHTTPResponse {
        guard isAuthorized(request) else {
            return DevHTTPResponse(401, ["error": "missing or invalid bearer token"])
        }
        let allowed: [String: String] = [
            "/status": "GET", "/island": "POST", "/activity/start": "POST", "/activity/end": "POST",
        ]
        guard let method = allowed[request.path] else {
            return DevHTTPResponse(404, ["error": "not found"])
        }
        guard request.method == method else {
            return DevHTTPResponse(405, ["error": "use \(method)"])
        }
        switch request.path {
        case "/status": return DevHTTPResponse(200, ["ok": true, "app": "FunNotch", "activities": runningActivities])
        case "/island": return postIsland(request.body)
        case "/activity/start": return startActivity(request.body)
        default: return endActivity(request.body)
        }
    }

    private func isAuthorized(_ request: DevHTTPRequest) -> Bool {
        guard let token = revealToken(),
              let header = request.headers["authorization"],
              header.lowercased().hasPrefix("bearer ")
        else { return false }
        let supplied = Array(header.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8)
        let expected = Array(token.utf8)
        // Compared without an early exit so the time taken says nothing about
        // how much of a guess was right.
        var difference = supplied.count ^ expected.count
        for index in 0 ..< expected.count {
            difference |= Int(expected[index] ^ (index < supplied.count ? supplied[index] : 0))
        }
        return difference == 0
    }

    private struct IslandBody: Decodable {
        var title: String
        var detail: String?
        var symbol: String?
        var tint: String?
        var trailing: String?
        var duration: Double?
    }

    private struct StartBody: Decodable {
        var id: String
        var title: String
        var symbol: String?
    }

    private struct EndBody: Decodable {
        var id: String
        var ok: Bool?
    }

    private func postIsland(_ body: Data) -> DevHTTPResponse {
        guard let payload = try? JSONDecoder().decode(IslandBody.self, from: body) else {
            return DevHTTPResponse(400, ["error": "expected JSON with a title"])
        }
        let title = Self.clean(payload.title, limit: 120)
        guard !title.isEmpty else { return DevHTTPResponse(400, ["error": "title is empty"]) }
        let tint = payload.tint.flatMap(Self.color(fromHex:))
        if payload.tint != nil, tint == nil {
            return DevHTTPResponse(400, ["error": "tint must be a hex colour like #34C759"])
        }
        let trailing = payload.trailing.map { Self.clean($0, limit: 16) }.flatMap { $0.isEmpty ? nil : $0 }
        IslandCenter.shared.post(Island(
            symbol: Self.symbol(payload.symbol, fallback: "bell.fill"),
            tint: tint ?? .white,
            title: title,
            detail: Self.detail(payload.detail),
            trailing: trailing,
            duration: min(max(payload.duration ?? 3, 1), 30)
        ))
        return DevHTTPResponse(200, ["ok": true])
    }

    private func startActivity(_ body: Data) -> DevHTTPResponse {
        guard let payload = try? JSONDecoder().decode(StartBody.self, from: body) else {
            return DevHTTPResponse(400, ["error": "expected JSON with id and title"])
        }
        let id = Self.clean(payload.id, limit: 80)
        let title = Self.clean(payload.title, limit: 120)
        guard !id.isEmpty, !title.isEmpty else {
            return DevHTTPResponse(400, ["error": "id and title are required"])
        }
        pruneActivities()
        // A forgotten `end` must not grow this forever.
        if activities.count >= 64, activities[id] == nil,
           let oldest = activities.min(by: { $0.value.started < $1.value.started })?.key {
            activities.removeValue(forKey: oldest)
        }
        let symbol = Self.symbol(payload.symbol, fallback: "hourglass")
        activities[id] = Activity(title: title, symbol: symbol, started: Date())
        runningActivities = activities.count
        IslandCenter.shared.post(Island(
            symbol: symbol, tint: SettingsStyle.blue, title: title, detail: " · w toku", duration: 2.5
        ))
        return DevHTTPResponse(200, ["ok": true])
    }

    private func endActivity(_ body: Data) -> DevHTTPResponse {
        guard let payload = try? JSONDecoder().decode(EndBody.self, from: body) else {
            return DevHTTPResponse(400, ["error": "expected JSON with id"])
        }
        let id = Self.clean(payload.id, limit: 80)
        guard let activity = activities.removeValue(forKey: id) else {
            return DevHTTPResponse(404, ["error": "no running activity with this id"])
        }
        runningActivities = activities.count
        let succeeded = payload.ok ?? true
        let elapsed = DevFormat.duration(Date().timeIntervalSince(activity.started))
        IslandCenter.shared.post(Island(
            symbol: succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill",
            tint: succeeded ? SettingsStyle.green : SettingsStyle.red,
            title: activity.title,
            detail: succeeded ? " · gotowe po \(elapsed)" : " · niepowodzenie po \(elapsed)",
            duration: succeeded ? 4 : 6
        ))
        return DevHTTPResponse(200, ["ok": true])
    }

    private func pruneActivities() {
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        activities = activities.filter { $0.value.started > cutoff }
    }

    // MARK: Input hygiene

    private static func clean(_ text: String, limit: Int) -> String {
        let flat = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(flat.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    /// The chin line is "bold title" + softer detail, which by convention
    /// starts with a separator; callers should not have to know that.
    private static func detail(_ text: String?) -> String {
        guard let text else { return "" }
        let cleaned = clean(text, limit: 160)
        guard !cleaned.isEmpty else { return "" }
        return cleaned.hasPrefix("·") ? " " + cleaned : " · " + cleaned
    }

    private static func symbol(_ name: String?, fallback: String) -> String {
        guard let name, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return fallback }
        return name
    }

    static func color(fromHex text: String) -> Color? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// A command you can paste straight into a terminal.
    func curlExample() -> String {
        let token = revealToken() ?? "<token>"
        return """
        curl -s -X POST http://127.0.0.1:\(Self.port)/island \\
          -H "Authorization: Bearer \(token)" \\
          -H "Content-Type: application/json" \\
          -d '{"title":"Gotowe","detail":"build zakończony","symbol":"checkmark.circle.fill","tint":"#34C759"}'
        """
    }
}

// MARK: - Shared formatting

enum DevFormat {
    /// "8 s", "1 min 20 s", "2 godz. 5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        if total >= 3600 { return "\(total / 3600) godz. \((total % 3600) / 60) min" }
        if total >= 60 { return "\(total / 60) min \(total % 60) s" }
        return "\(total) s"
    }
}
