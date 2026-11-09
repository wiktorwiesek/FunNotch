//
//  WiFiMonitor.swift
//  FunNotch
//
//  The Wi-Fi widgets' own state, kept apart from `WeatherManager`: reading it
//  needs no forecast, no location request and no timers. CoreWLAN announces
//  link, power and network changes, so nothing polls.
//
//  macOS hands out the network *name* only to apps with location access. This
//  monitor never asks for it (that is `WeatherManager.requestAccess`, behind an
//  explicit click); it only notices when the answer changes. Without access the
//  widgets can say connected or not, which needs no permission.
//

import Combine
import CoreLocation
import CoreWLAN
import Foundation

@MainActor
final class WiFiMonitor: NSObject, ObservableObject {
    static let shared = WiFiMonitor()

    /// Current network name; nil when not connected or when macOS withholds it.
    @Published private(set) var network: String?
    /// Whether the Wi-Fi interface is on and associated, knowable without the name.
    @Published private(set) var isConnected = false
    @Published private(set) var isLocationAuthorized = false

    /// Only reads the authorisation and hears about changes; it never requests
    /// a location or the permission, so creating it cannot raise a prompt.
    private let locationStatus = CLLocationManager()
    private var subscribers = 0

    private override init() {
        super.init()
        locationStatus.delegate = self
        isLocationAuthorized = Self.authorized(locationStatus.authorizationStatus)
    }

    private static func authorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorized || status == .authorizedAlways
    }

    func addSubscriber() {
        subscribers += 1
        if subscribers == 1 { start() }
        read()
    }

    func removeSubscriber() {
        subscribers = max(subscribers - 1, 0)
        if subscribers == 0 { stop() }
    }

    private func start() {
        let client = CWWiFiClient.shared()
        client.delegate = self
        for event in [CWEventType.linkDidChange, .ssidDidChange, .powerDidChange] {
            do {
                try client.startMonitoringEvent(with: event)
            } catch {
                DiagnosticLog.write("wifi", "cannot watch \(event.rawValue): \(error.localizedDescription)")
            }
        }
    }

    private func stop() {
        let client = CWWiFiClient.shared()
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
    }

    private func read() {
        let interface = CWWiFiClient.shared().interface()
        // Assigned only on change: every assignment to a published property
        // redraws whatever observes it.
        let connected = interface?.powerOn() == true && interface?.serviceActive() == true
        if connected != isConnected { isConnected = connected }
        let name = connected ? interface?.ssid() : nil
        if name != network { network = name }
    }
}

extension WiFiMonitor: CWEventDelegate {
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) { reread() }
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) { reread() }
    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { reread() }

    /// Events arrive on a CoreWLAN queue.
    private nonisolated func reread() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { WiFiMonitor.shared.read() }
        }
    }
}

extension WiFiMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let monitor = WiFiMonitor.shared
                let allowed = Self.authorized(status)
                if allowed != monitor.isLocationAuthorized { monitor.isLocationAuthorized = allowed }
                // The name becomes readable the moment access is granted.
                monitor.read()
            }
        }
    }
}
