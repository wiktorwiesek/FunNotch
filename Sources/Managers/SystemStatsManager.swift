//
//  SystemStatsManager.swift
//  FunNotch
//
//  CPU, memory, disk, network, GPU and CPU temperature readings for the notch
//  widgets. CPU, memory, disk and network come from Mach, BSD and the file
//  system; GPU load comes from the IOKit registry and the temperature from the
//  IOHID sensors (`CPUTemperatureSensor`). None of it needs a permission.
//
//  Every metric is sampled only while something that shows it is on screen:
//  subscribers say which metrics they need, and the single timer reads just
//  those.
//

import Combine
import Darwin
import Foundation

@MainActor
final class SystemStatsManager: ObservableObject {
    static let shared = SystemStatsManager()

    /// 0...1 across all cores.
    @Published private(set) var cpuUsage: Double = 0
    /// 0...1 of physical memory in use.
    @Published private(set) var memoryUsage: Double = 0
    @Published private(set) var memoryUsedBytes: UInt64 = 0
    /// 0...1 of the boot volume used.
    @Published private(set) var diskUsage: Double = 0
    @Published private(set) var diskFreeBytes: Int64 = 0

    /// Bytes per second over the real network interfaces. Nil until two
    /// samples exist, or when the interface list cannot be read.
    @Published private(set) var downloadBytesPerSecond: Double?
    @Published private(set) var uploadBytesPerSecond: Double?
    /// 0...1 busiest GPU, nil when the registry does not report one.
    @Published private(set) var gpuUsage: Double?
    /// Degrees Celsius, nil when no sensor answers (Intel Macs, sandboxes).
    @Published private(set) var cpuTemperature: Double?

    /// Recent CPU and memory samples, oldest first, for the sparklines on the
    /// home strip. Capped rather than unbounded: at one sample every three
    /// seconds this is about two minutes of history, which is all a graph this
    /// small can show anyway.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    private let historyLimit = 48

    private var timer: Timer?
    private var previousTicks: (used: UInt64, total: UInt64)?
    /// Widgets are the only consumer, so polling stops when none are shown.
    private var subscribers = 0

    /// What a subscriber wants read.
    struct Metrics: OptionSet {
        let rawValue: Int
        static let cpu = Metrics(rawValue: 1 << 0)
        static let memory = Metrics(rawValue: 1 << 1)
        static let disk = Metrics(rawValue: 1 << 2)
        static let network = Metrics(rawValue: 1 << 3)
        static let gpu = Metrics(rawValue: 1 << 4)
        static let temperature = Metrics(rawValue: 1 << 5)

        /// What the subscribers that predate the per-metric API always got.
        static let classic: Metrics = [.cpu, .memory, .disk]
    }

    private static let orderedMetrics: [Metrics] = [.cpu, .memory, .disk, .network, .gpu, .temperature]
    /// Subscriber count per metric, indexed like `orderedMetrics`.
    private var metricCounts = [Int](repeating: 0, count: 6)

    private var activeMetrics: Metrics {
        var active: Metrics = []
        for (index, metric) in Self.orderedMetrics.enumerated() where metricCounts[index] > 0 {
            active.insert(metric)
        }
        return active
    }

    /// Network state: the previous per-interface counters and when they were read.
    private struct InterfaceCounters {
        var received: UInt32
        var sent: UInt32
    }
    private var previousNetwork: (time: Double, counters: [String: InterfaceCounters])?
    private var temperatureSensor: CPUTemperatureSensor?
    /// Set once the IOHID symbols turn out to be missing, so it is not retried.
    private var temperatureUnavailable = false

    private init() {}

    /// Reference-counted so the timer only runs while something is watching.
    /// Without arguments it asks for CPU, memory and disk, as it always did.
    func addSubscriber(_ metrics: Metrics = .classic) {
        let before = activeMetrics
        for (index, metric) in Self.orderedMetrics.enumerated() where metrics.contains(metric) {
            metricCounts[index] += 1
        }
        subscribers += 1
        if subscribers == 1 {
            start()
        } else {
            // A reading straight away for what was not being watched yet, so
            // opening the notch shows a value rather than an empty box until
            // the three-second timer first fires.
            let fresh = activeMetrics.subtracting(before)
            if !fresh.isEmpty { read(fresh) }
        }
    }

    func removeSubscriber(_ metrics: Metrics = .classic) {
        let before = activeMetrics
        for (index, metric) in Self.orderedMetrics.enumerated() where metrics.contains(metric) {
            metricCounts[index] = max(metricCounts[index] - 1, 0)
        }
        subscribers = max(subscribers - 1, 0)
        if subscribers == 0 {
            stop()
        } else {
            tearDown(before.subtracting(activeMetrics))
        }
    }

    private func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            // Nobody is looking behind a lock screen or a sleeping display.
            guard !SystemActivityMonitor.isScreenIdle else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        tearDown([.cpu, .network, .temperature])
    }

    /// Drops the state of metrics nobody shows any more, so nothing stale or
    /// retained outlives its widget.
    private func tearDown(_ gone: Metrics) {
        if gone.contains(.cpu) { previousTicks = nil }
        if gone.contains(.network) { previousNetwork = nil }
        if gone.contains(.temperature) {
            temperatureSensor?.close()
            temperatureSensor = nil
        }
    }

    /// Reads whatever has a subscriber. With none (the self-test calls this
    /// directly) it reads what the original three-metric version did.
    func refresh() {
        let wanted = activeMetrics
        read(wanted.isEmpty ? .classic : wanted)
    }

    private func read(_ wanted: Metrics) {
        if wanted.contains(.cpu) { readCPU() }
        if wanted.contains(.memory) { readMemory() }
        // Free space is an XPC round trip to the cache-delete daemon (it
        // counts purgeable space) and barely moves; a minute is plenty.
        if wanted.contains(.disk), Date().timeIntervalSince(lastDiskRead) >= 60 {
            lastDiskRead = Date()
            readDisk()
        }
        if wanted.contains(.network) { readNetwork() }
        if wanted.contains(.gpu) { readGPU() }
        if wanted.contains(.temperature) { readTemperature() }
        recordHistory(wanted)
    }

    private var lastDiskRead = Date.distantPast

    private func recordHistory(_ wanted: Metrics) {
        if wanted.contains(.cpu) {
            cpuHistory.append(cpuUsage)
            if cpuHistory.count > historyLimit { cpuHistory.removeFirst(cpuHistory.count - historyLimit) }
        }
        if wanted.contains(.memory) {
            memoryHistory.append(memoryUsage)
            if memoryHistory.count > historyLimit { memoryHistory.removeFirst(memoryHistory.count - historyLimit) }
        }
    }

    // MARK: - CPU

    private func readCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)

        let used = user + system + nice
        let total = used + idle

        // The counters are cumulative since boot, so usage is the delta.
        defer { previousTicks = (used, total) }
        guard let previous = previousTicks else { return }

        let usedDelta = Double(used &- previous.used)
        let totalDelta = Double(total &- previous.total)
        guard totalDelta > 0 else { return }

        cpuUsage = min(max(usedDelta / totalDelta, 0), 1)
    }

    // MARK: - Memory

    private func readMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)
        // "Used" the way Activity Monitor counts it: everything but free and
        // speculative, with purgeable pages given back.
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        let used = active + wired + compressed
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return }

        // Unchanged values are not assigned: each assignment invalidates
        // every view observing this manager.
        if memoryUsedBytes != used { memoryUsedBytes = used }
        let usage = min(max(Double(used) / Double(total), 0), 1)
        if memoryUsage != usage { memoryUsage = usage }
    }

    // MARK: - Disk

    private func readDisk() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]) else { return }

        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values.volumeTotalCapacity ?? 0)
        guard total > 0 else { return }

        diskFreeBytes = free
        diskUsage = min(max(Double(total - free) / Double(total), 0), 1)
    }

    // MARK: - Network

    private func readNetwork() {
        guard let counters = Self.interfaceCounters() else { return }
        let now = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        guard let previous = previousNetwork else {
            previousNetwork = (now, counters)
            return
        }

        // The clock keeps running through sleep, so a long gap means the
        // machine slept and the average would be meaningless; a very short one
        // (a widget re-appearing) would only amplify the rounding of the counters.
        let elapsed = now - previous.time
        guard elapsed >= 0.5 else {
            // Keep the older baseline so the next full interval measures properly.
            return
        }
        previousNetwork = (now, counters)
        guard elapsed <= 30 else { return }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, current) in counters {
            // An interface that just appeared has no baseline yet.
            guard let before = previous.counters[name] else { continue }
            received += Self.counterDelta(from: before.received, to: current.received)
            sent += Self.counterDelta(from: before.sent, to: current.sent)
        }

        let down = Double(received) / elapsed
        let up = Double(sent) / elapsed
        if downloadBytesPerSecond != down { downloadBytesPerSecond = down }
        if uploadBytesPerSecond != up { uploadBytesPerSecond = up }
    }

    /// The interface counters are 32-bit and wrap after 4 GB. A smaller value
    /// than before is a wrap only when the old one was high enough to plausibly
    /// wrap within one interval; otherwise the interface was reset.
    private static func counterDelta(from old: UInt32, to new: UInt32) -> UInt64 {
        if new >= old { return UInt64(new - old) }
        if old >= 0x8000_0000 { return UInt64(UInt32.max - old) + UInt64(new) + 1 }
        return 0
    }

    /// Byte counters of the interfaces that carry real traffic: up, running,
    /// not loopback, and Ethernet/Wi-Fi/cellular. Tunnels (`utun`), AirDrop
    /// (`awdl`) and bridges are left out because their bytes are already
    /// counted on the interface underneath them.
    private static func interfaceCounters() -> [String: InterfaceCounters]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var result: [String: InterfaceCounters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let interface = entry.pointee

            guard let address = interface.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK,
                  let data = interface.ifa_data
            else { continue }

            let flags = Int32(bitPattern: interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }

            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = InterfaceCounters(received: stats.ifi_ibytes, sent: stats.ifi_obytes)
        }
        return result
    }

    // MARK: - GPU

    private func readGPU() {
        let usage = Self.gpuUtilisation()
        if gpuUsage != usage { gpuUsage = usage }
    }

    /// The busiest accelerator's load, 0...1. Apple Silicon reports
    /// `Device Utilization %`; some drivers only have `GPU Activity(%)`.
    private static func gpuUtilisation() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var busiest: Double?
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let statistics = IORegistryEntryCreateCFProperty(
                entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            let value = (statistics["Device Utilization %"] as? NSNumber)
                ?? (statistics["GPU Activity(%)"] as? NSNumber)
            guard let percent = value?.doubleValue else { continue }
            busiest = max(busiest ?? 0, percent)
        }
        guard let busiest else { return nil }
        return min(max(busiest / 100, 0), 1)
    }

    // MARK: - Temperature

    private func readTemperature() {
        if temperatureSensor == nil, !temperatureUnavailable {
            temperatureSensor = CPUTemperatureSensor()
            if temperatureSensor == nil { temperatureUnavailable = true }
        }
        let value = temperatureSensor?.read()
        if cpuTemperature != value { cpuTemperature = value }
    }

    // MARK: - Formatting

    var cpuText: String { "\(Int(round(cpuUsage * 100)))%" }
    var memoryText: String { "\(Int(round(memoryUsage * 100)))%" }
    var diskFreeText: String { formattedFileSize(diskFreeBytes) }

    /// "37%", or a dash when the GPU does not report a load.
    var gpuText: String {
        guard let gpuUsage else { return "—" }
        return "\(Int(round(gpuUsage * 100)))%"
    }

    /// "54°", or a dash when there is no sensor.
    var temperatureText: String {
        guard let cpuTemperature else { return "—" }
        return "\(Int(round(cpuTemperature)))°"
    }

    var downloadText: String { Self.rateText(downloadBytesPerSecond) }
    var uploadText: String { Self.rateText(uploadBytesPerSecond) }

    /// A speed in at most eight characters ("1,2 MB/s", "980 KB/s", "12 MB/s"):
    /// decimal units like the network pane, one decimal only below ten.
    static func rateText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        let kilobytes = bytesPerSecond / 1_000
        if kilobytes < 999.5 { return "\(Int(kilobytes.rounded())) KB/s" }
        let megabytes = bytesPerSecond / 1_000_000
        if megabytes < 999.5 { return "\(rateAmount(megabytes)) MB/s" }
        return "\(rateAmount(bytesPerSecond / 1_000_000_000)) GB/s"
    }

    private static func rateAmount(_ value: Double) -> String {
        guard value < 9.95 else { return "\(Int(value.rounded()))" }
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10),\(tenths % 10)"
    }
}
