import Foundation
import MetricKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import os

/// Field diagnostics the person can send us (Ajustes › Diagnóstico): the reports the system hands the app through
/// MetricKit (hangs, CPU exceptions, crashes, disk writes) and the stalls `MainThreadWatch` notes itself, all in a
/// `diagnostics` folder of the app's Application Support folder. Nothing leaves the device unless the person shares it.
enum Diagnostics {
    /// `Application Support/Pier/diagnostics` (the Mac's folder is named after the bundle id: `Shared.supportDirectory`).
    static let folder = Shared.supportDirectory.appendingPathComponent("diagnostics", isDirectory: true)
    /// Every file write and removal of the folder, one at a time and off the main thread.
    static let io = DispatchQueue(label: "pier.diagnostics", qos: .utility)
    static let log = Logger(subsystem: Shared.appBundleID, category: "diagnostics")
    /// The app's build (CFBundleVersion), noted with every stall: the file outlives updates.
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    /// MetricKit's reports kept, the newest by the date the system gave them.
    static let keptReports = 20

    /// Bumped whenever a stall or a report is written or everything is deleted: the screen reads again when it moves.
    private static let changes = OSAllocatedUnfairLock(initialState: 0)
    static var revision: Int { changes.withLock { $0 } }
    static func changed() { changes.withLock { $0 += 1 } }

    /// At launch, before anything else can hold the main thread. The watchdog stays off under the UI tests' mock (a
    /// ping four times a second is activity XCUITest may wait on) unless `-diagnosticsSelfTest` asks for it; MetricKit
    /// is always on.
    @MainActor static func start() {
        MXMetricManager.shared.add(MetricReports.shared)
        #if DEBUG
        let selfTest = UserDefaults.standard.bool(forKey: "diagnosticsSelfTest")
        #else
        let selfTest = false
        #endif
        MainThreadWatch.shared.start(watching: !UITestMock.enabled || selfTest)
        #if DEBUG
        if selfTest { runSelfTest() }
        #endif
    }

    // MARK: what is kept

    /// The main thread not answering for more than half a second.
    struct Stall: Codable, Sendable, Equatable {
        enum AppState: String, Codable, Sendable { case active, inactive, background }
        /// When the watchdog's ping went out (the main thread stopped answering at most 250 ms before).
        var start: Date
        /// How long the main thread took to answer, in seconds.
        var duration: Double
        /// The `Perf` region the main thread was in while it was stuck: what held it, when it is marked.
        var region: String?
        var state: AppState
        var build: String?
        /// Still stuck when the file was written: true while it lasts, and left true by a run that ended inside it (a
        /// force quit, the system killing the app), whose duration is then "at least".
        var unfinished: Bool?
    }

    /// One of MetricKit's payloads on disk: `metrickit-<UTC date>-<kinds>[-<n>].json`.
    struct Report: Sendable, Equatable {
        enum Kind: String, Sendable { case hang, cpu, crash, disk, launch, other }
        let url: URL
        let date: Date
        let kinds: [Kind]
        /// Written by `-diagnosticsSelfTest`, not by the system.
        let test: Bool

        init?(name: String, in folder: URL, parser: DateFormatter) {
            guard name.hasPrefix("metrickit-"), name.hasSuffix(".json") else { return nil }
            let parts = name.dropFirst("metrickit-".count).dropLast(".json".count).split(separator: "-")
            guard parts.count >= 2, let date = parser.date(from: String(parts[0])) else { return nil }
            let tokens = parts[1].split(separator: "+").map(String.init)
            url = folder.appendingPathComponent(name)
            self.date = date
            kinds = tokens.compactMap(Kind.init(rawValue:))
            test = tokens.contains("test")
        }
    }

    struct Snapshot: Sendable, Equatable {
        /// Newest first.
        var stalls: [Stall] = []
        /// Newest first.
        var reports: [Report] = []
        var isEmpty: Bool { stalls.isEmpty && reports.isEmpty }
    }

    /// What the screen lists (a directory listing: call it off the main thread).
    static func snapshot() -> Snapshot {
        Snapshot(stalls: Array(MainThreadWatch.shared.stalls.reversed()), reports: reports())
    }

    static func reports() -> [Report] {
        let parser = stampFormatter()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { Report(name: $0, in: folder, parser: parser) }
            .sorted { ($0.date, $0.url.lastPathComponent) > ($1.date, $1.url.lastPathComponent) }
    }

    /// Writes one MetricKit payload (on `io`) and keeps the newest `keptReports`.
    static func saveReport(_ json: Data, date: Date, kinds: [String]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = "metrickit-\(stampFormatter().string(from: date))-\(kinds.isEmpty ? "other" : kinds.joined(separator: "+"))"
        var url = folder.appendingPathComponent(base + ".json")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(n).json")
            n += 1
        }
        do {
            try json.write(to: url, options: .atomic)
        } catch {
            log.error("report not written: \(error.localizedDescription, privacy: .public)")
        }
        // The names start with the date, so the oldest sort first.
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("metrickit-") }.sorted()
        for old in names.dropLast(keptReports) { try? fm.removeItem(at: folder.appendingPathComponent(old)) }
        changed()
    }

    /// "Apagar": the stalls (in memory and on disk) and the reports.
    static func clear() {
        MainThreadWatch.shared.clear()
        io.async {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
            removeArchives()
            changed()
        }
    }

    // MARK: sharing

    /// A .zip of the reports, the stalls as the watchdog holds them now and a note on the app and the device, in the
    /// temporary folder, for the share sheet (call it off the main thread). NSFileCoordinator zips a folder for upload
    /// by itself: no library needed, on the Mac too.
    static func archive() throws -> URL {
        let fm = FileManager.default
        let name = "Pier-diagnostics-\(stampFormatter().string(from: Date()))"
        let staging = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for report in reports() {
            try? fm.copyItem(at: report.url, to: staging.appendingPathComponent(report.url.lastPathComponent))
        }
        let stalls = MainThreadWatch.shared.stalls
        if !stalls.isEmpty { try encoder().encode(stalls).write(to: staging.appendingPathComponent("stalls.json")) }
        try JSONSerialization.data(withJSONObject: about(), options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("about.json"))

        let out = fm.temporaryDirectory.appendingPathComponent(name + ".zip")
        try? fm.removeItem(at: out)
        var coordination: NSError?
        var copy: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordination) { zip in
            // The zip only lives inside this block.
            do { try fm.copyItem(at: zip, to: out) } catch { copy = error }
        }
        if let coordination { throw coordination }
        if let copy { throw copy }
        // The one made before stays too: a share sheet opened on it may still be sending it.
        removeArchives(keeping: 2)
        return out
    }

    /// Leaves the newest `keeping` archives (their names start with the date, so they sort by it).
    private static func removeArchives(keeping: Int = 0) {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Pier-diagnostics-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in urls.dropFirst(keeping) {
            try? fm.removeItem(at: url)
        }
    }

    /// The app's version, the system and the model, which the stalls do not say on their own. Nothing about the person.
    private static func about() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        #if targetEnvironment(macCatalyst)
        let platform = "Mac Catalyst"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        return [
            "app": "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(build ?? "?"))",
            "platform": platform,
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": hardwareModel(),
            "exported": ISO8601DateFormatter().string(from: Date()),
            "watchdog": MainThreadWatch.shared.isWatching,
        ]
    }

    /// "Mac16,10", "iPhone17,1"; the simulated device on a simulator.
    private static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        if let id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return "\(id) (simulator)" }
        #endif
        #if targetEnvironment(macCatalyst) || os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: files

    /// `20261016T143205Z`: sorts by date as text, and is a file name everywhere.
    static func stampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }

    /// Readable by us as it is: ISO dates, one key per line.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: self-test

    #if DEBUG
    /// `-diagnosticsSelfTest 1`: one fake MetricKit report at once, and the main thread held for 800 ms inside a `Perf`
    /// region a few seconds after launch, so the watchdog notes a stall and Ajustes › Diagnóstico can be checked on a
    /// simulator (with `-uiTestMock 1` too: the self-test turns the watchdog on there).
    @MainActor private static func runSelfTest() {
        io.async {
            let now = Date()
            let stamp = ISO8601DateFormatter().string(from: now)
            // Shaped like MXDiagnosticPayload's jsonRepresentation(), with one hang.
            let fake: [String: Any] = [
                "timeStampBegin": stamp,
                "timeStampEnd": stamp,
                "hangDiagnostics": [[
                    "version": "1.0.0",
                    "diagnosticMetaData": [
                        "hangDuration": "0.8 sec",
                        "appBuildVersion": build ?? "?",
                        "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                        "pierSelfTest": true,
                    ] as [String: Any],
                    "callStackTree": [
                        "callStackPerThread": true,
                        "callStacks": [["threadAttributed": true, "callStackRootFrames": [[
                            "binaryName": "Pier", "binaryUUID": "00000000-0000-0000-0000-000000000000",
                            "offsetIntoBinaryTextSegment": 0, "address": 0, "sampleCount": 1,
                        ] as [String: Any]]] as [String: Any]],
                    ] as [String: Any],
                ] as [String: Any]],
            ]
            if let json = try? JSONSerialization.data(withJSONObject: fake, options: [.prettyPrinted, .sortedKeys]) {
                saveReport(json, date: now, kinds: ["hang", "test"])
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            Perf.interval("diagnostics.selfTest") { Thread.sleep(forTimeInterval: 0.8) }
            log.notice("self-test: held the main thread 800 ms")
        }
    }
    #endif
}

/// MetricKit's subscriber: each diagnostic payload (a day of hangs, CPU exceptions, crashes and disk-write exceptions,
/// or the previous run's, delivered on the next launch) goes to the folder as the system wrote it.
final class MetricReports: NSObject, MXMetricManagerSubscriber, Sendable {
    /// MetricKit keeps its subscribers weakly in some versions: this one lives for the app's run.
    static let shared = MetricReports()

    /// Called on a background queue of MetricKit's.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let kinds = Self.kinds(of: payload)
            let json = payload.jsonRepresentation()
            let date = payload.timeStampEnd
            Diagnostics.log.notice("MetricKit report: \(kinds.joined(separator: "+"), privacy: .public)")
            Diagnostics.io.async { Diagnostics.saveReport(json, date: date, kinds: kinds) }
        }
    }

    /// What the payload holds, as `Diagnostics.Report.Kind` names (the file's name says it, so the list reads no JSON).
    private static func kinds(of payload: MXDiagnosticPayload) -> [String] {
        var kinds: [String] = []
        if payload.hangDiagnostics?.isEmpty == false { kinds.append("hang") }
        if payload.cpuExceptionDiagnostics?.isEmpty == false { kinds.append("cpu") }
        if payload.crashDiagnostics?.isEmpty == false { kinds.append("crash") }
        if payload.diskWriteExceptionDiagnostics?.isEmpty == false { kinds.append("disk") }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if payload.appLaunchDiagnostics?.isEmpty == false { kinds.append("launch") }
        #endif
        return kinds
    }
}

/// Watches the main thread from a thread of its own (not a task, which a busy pool could starve): every 250 ms it
/// schedules a ping on the main queue and waits for it. An answer later than 500 ms is a stall, noted with when it
/// started, how long it lasted, the `Perf` region the main thread was in and whether the app was in front, in the last
/// 100 kept in `diagnostics/stalls.json`. While the main thread is still stuck the stall is written as it grows, so one
/// the person ends with a force quit is still there at the next launch. It sleeps between pings and allocates one small
/// block per ping. On the iPhone and the iPad it pauses in the background (a suspended app is not a stuck one); the Mac
/// keeps watching, since it keeps working with its window closed.
final class MainThreadWatch: Sendable {
    static let shared = MainThreadWatch()

    private static let period: TimeInterval = 0.25
    private static let threshold: TimeInterval = 0.5
    private static let kept = 100
    #if targetEnvironment(macCatalyst) || os(macOS)
    private static let pausesInBackground = false
    #else
    private static let pausesInBackground = true
    #endif

    private struct State: Sendable {
        /// Oldest first, at most `kept`.
        var stalls: [Diagnostics.Stall] = []
        /// The stall going on right now, written with the others while it lasts.
        var ongoing: Diagnostics.Stall?
        var appState: Diagnostics.Stall.AppState = .active
        var paused = false
        /// Trips to and from the background: a ping that crossed one measured a suspension, not a stall.
        var lifecycle = 0
        var saveDue = false
        var watching = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// When the main thread ran the last ping (uptime, ns), set before `pong` is signalled.
    private let answeredAt = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let pong = DispatchSemaphore(value: 0)
    private var file: URL { Diagnostics.folder.appendingPathComponent("stalls.json") }

    var stalls: [Diagnostics.Stall] { state.withLock { $0.stalls } }
    var isWatching: Bool { state.withLock { $0.watching } }

    @MainActor func start(watching: Bool) {
        let now = UIApplication.shared.applicationState
        moved(to: now == .active ? .active : now == .inactive ? .inactive : .background)
        observeLifecycle()
        Diagnostics.io.async { [self] in
            load()
            guard watching else { return }
            state.withLock { $0.watching = true }
            let thread = Thread { [self] in run() }
            thread.name = "pier.main-thread-watch"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    func clear() {
        state.withLock { $0.stalls.removeAll() }
    }

    // MARK: the watch

    private func run() {
        while true {
            Thread.sleep(forTimeInterval: Self.period)
            let (paused, lifecycle) = state.withLock { ($0.paused, $0.lifecycle) }
            if paused {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            ping(lifecycle: lifecycle)
        }
    }

    private func ping(lifecycle: Int) {
        let sent = DispatchTime.now()
        let start = Date()
        DispatchQueue.main.async { MainThreadWatch.shared.answer() }
        var stuck: Diagnostics.Stall?
        if pong.wait(timeout: sent + .milliseconds(Int(Self.threshold * 1000))) == .timedOut {
            // No answer yet: the main thread is stuck right now, so the region it is in is the one holding it.
            Perf.signposter.emitEvent("stall")
            let region = Perf.mainRegion
            stuck = state.withLock { s in
                let stall = Diagnostics.Stall(start: start, duration: Self.threshold, region: region, state: s.appState,
                                              build: Diagnostics.build, unfinished: true)
                s.ongoing = stall
                return stall
            }
            scheduleSave()
            while pong.wait(timeout: .now() + 1) == .timedOut {
                let soFar = Self.seconds(from: sent.uptimeNanoseconds, to: DispatchTime.now().uptimeNanoseconds)
                state.withLock { $0.ongoing?.duration = soFar }
                scheduleSave()
            }
        }
        // The time the main thread wrote, not when this thread woke up to read it.
        let latency = Self.seconds(from: sent.uptimeNanoseconds, to: answeredAt.withLock { $0 })
        record(stuck, start: start, latency: latency, lifecycle: lifecycle)
    }

    /// On the main thread: the ping's answer.
    private func answer() {
        answeredAt.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        pong.signal()
    }

    private func record(_ stuck: Diagnostics.Stall?, start: Date, latency: TimeInterval, lifecycle: Int) {
        let noted: Diagnostics.Stall? = state.withLock { s in
            s.ongoing = nil
            guard latency >= Self.threshold, !(Self.pausesInBackground && s.lifecycle != lifecycle) else { return nil }
            // A late answer this thread did not see coming (it was itself held up) has no region: what runs now is
            // not what ran then.
            var stall = stuck ?? Diagnostics.Stall(start: start, duration: latency, region: nil, state: s.appState, build: Diagnostics.build)
            stall.duration = (latency * 1000).rounded() / 1000
            stall.unfinished = nil
            s.stalls.append(stall)
            if s.stalls.count > Self.kept { s.stalls.removeFirst(s.stalls.count - Self.kept) }
            return stall
        }
        guard stuck != nil || noted != nil else { return }
        scheduleSave()
        guard let noted else { return }
        Diagnostics.changed()
        Diagnostics.log.notice("main thread stalled \(Int(noted.duration * 1000)) ms in \(noted.region ?? "-", privacy: .public) (\(noted.state.rawValue, privacy: .public))")
    }

    // MARK: the app's state

    @MainActor private func observeLifecycle() {
        let center = NotificationCenter.default
        let moves: [(Notification.Name, Diagnostics.Stall.AppState)] = [
            (UIApplication.didBecomeActiveNotification, .active),
            (UIApplication.willResignActiveNotification, .inactive),
            (UIApplication.didEnterBackgroundNotification, .background),
            (UIApplication.willEnterForegroundNotification, .inactive),
        ]
        for (name, app) in moves {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [self] _ in moved(to: app) }
        }
        // Quitting: what is pending goes to disk before the process ends.
        _ = center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [self] _ in
            Diagnostics.io.sync { save() }
        }
    }

    private func moved(to app: Diagnostics.Stall.AppState) {
        state.withLock { s in
            if (s.appState == .background) != (app == .background) { s.lifecycle += 1 }
            s.appState = app
            s.paused = Self.pausesInBackground && app == .background
        }
        // The app may not come back (iOS ends background apps without a word): what is pending goes now.
        if app == .background { Diagnostics.io.async { [self] in save() } }
    }

    // MARK: the file

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let saved = try? Diagnostics.decoder().decode([Diagnostics.Stall].self, from: data) else { return }
        state.withLock { s in s.stalls = Array((saved + s.stalls).suffix(Self.kept)) }
        Diagnostics.changed()
    }

    /// At most one write every 2 s, on `Diagnostics.io`.
    private func scheduleSave() {
        let first = state.withLock { s in
            defer { s.saveDue = true }
            return !s.saveDue
        }
        guard first else { return }
        Diagnostics.io.asyncAfter(deadline: .now() + 2) { [self] in save() }
    }

    /// On `Diagnostics.io`: writes the stalls when a write is due (its turn came, or the app is leaving).
    private func save() {
        let due: [Diagnostics.Stall]? = state.withLock { s in
            guard s.saveDue else { return nil }
            s.saveDue = false
            return s.stalls + (s.ongoing.map { [$0] } ?? [])
        }
        guard let due else { return }
        let fm = FileManager.default
        guard !due.isEmpty else { try? fm.removeItem(at: file); return }
        do {
            try fm.createDirectory(at: Diagnostics.folder, withIntermediateDirectories: true)
            try Diagnostics.encoder().encode(due).write(to: file, options: .atomic)
        } catch {
            Diagnostics.log.error("stalls not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        end > start ? Double(end - start) / 1_000_000_000 : 0
    }
}

/// Signposts for Instruments around the app's hot paths (the app's subsystem, category "perf"), and the region the main
/// thread is in, which `MainThreadWatch` names when it stops answering. Cheap when nothing records: a begin and its end
/// take about half a microsecond (os_signpost writes to memory; skipped altogether when the category is turned off), and
/// a region is a short lock and an append on a list that keeps its capacity.
///
///     Perf.interval("session.fold") { rows = fold(items) }
///     let s = Perf.begin("push"); defer { Perf.end(s) }
///
/// Only intervals begun on the main thread are regions. One that spans an `await` stays the main thread's region while
/// it is suspended, so a stall meanwhile is put on it: wrap synchronous work with `interval` when that matters.
enum Perf {
    static let signposter = OSSignposter(subsystem: Shared.appBundleID, category: "perf")

    /// An interval begun by `begin`, to hand to `end`.
    struct Interval: Sendable {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState?
        /// Its place in the main thread's regions; 0 when begun on another thread.
        fileprivate let region: UInt64
    }

    static func begin(_ name: StaticString) -> Interval {
        let state = signposter.isEnabled ? signposter.beginInterval(name, id: signposter.makeSignpostID()) : nil
        let region = Thread.isMainThread ? regions.withLock { $0.open(name) } : 0
        return Interval(name: name, state: state, region: region)
    }

    static func end(_ interval: Interval) {
        if let state = interval.state { signposter.endInterval(interval.name, state) }
        if interval.region != 0 { regions.withLock { $0.close(interval.region) } }
    }

    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let s = begin(name)
        defer { end(s) }
        return try body()
    }

    /// The innermost region open on the main thread (any thread may ask), nil outside of any.
    static var mainRegion: String? {
        regions.withLock { $0.innermost }.map { "\($0)" }
    }

    /// The main thread's open regions, in the order they began; closing one takes it out wherever it is, so intervals
    /// that end out of order (across awaits) leave the right one innermost.
    private struct Regions: Sendable {
        struct Entry: Sendable { let id: UInt64; let name: StaticString }
        var entries: [Entry] = []
        var last: UInt64 = 0

        init() { entries.reserveCapacity(16) }

        mutating func open(_ name: StaticString) -> UInt64 {
            last += 1
            entries.append(Entry(id: last, name: name))
            return last
        }
        mutating func close(_ id: UInt64) {
            if let i = entries.lastIndex(where: { $0.id == id }) { entries.remove(at: i) }
        }
        var innermost: StaticString? { entries.last?.name }
    }

    private static let regions = OSAllocatedUnfairLock(initialState: Regions())
}
