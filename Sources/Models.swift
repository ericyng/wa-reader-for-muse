// WA Reader for Muse — shared models, paths, config, logging.
import Foundation

enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Output/data directory. WA_READER_DIR overrides it for headless tests so
    /// a smoke test never touches the live feed state.
    static var shareDir: URL {
        if let override = ProcessInfo.processInfo.environment["WA_READER_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return home.appendingPathComponent(".local/share/wa-reader")
    }

    static var stateURL: URL { shareDir.appendingPathComponent("state.json") }
    static var outboxURL: URL { shareDir.appendingPathComponent("outbox.jsonl") }
    static var allStateURL: URL { shareDir.appendingPathComponent("state_all.json") }
    static var allOutboxURL: URL { shareDir.appendingPathComponent("all-messages.jsonl") }
    static var statusURL: URL { shareDir.appendingPathComponent("status.json") }
    static var healthURL: URL { shareDir.appendingPathComponent("health.json") }
    static var configURL: URL { shareDir.appendingPathComponent("config.json") }
    static var engineStateURL: URL { shareDir.appendingPathComponent("engine-state.json") }
    static var healthStateURL: URL { shareDir.appendingPathComponent("wa-health-state.json") }
    static var logURL: URL { shareDir.appendingPathComponent("app.log") }
    static var failuresURL: URL { shareDir.appendingPathComponent("failures.jsonl") }
    static var failureStateURL: URL { shareDir.appendingPathComponent("failure-state.json") }
    static var probesURL: URL { shareDir.appendingPathComponent("probes.jsonl") }
    static var probeStateURL: URL { shareDir.appendingPathComponent("probe-state.json") }

    static var whatsappDB: URL {
        home.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")
    }

    static var whatsappContainer: URL {
        home.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
    }

    static var whatsappLogsDir: URL {
        whatsappContainer.appendingPathComponent("Logs/WhatsApp_2")
    }

    static let dbCandidates = [
        "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite",
        "Library/Group Containers/group.net.whatsapp.WhatsApp.private/ChatStorage.sqlite",
        "Library/Group Containers/group.net.whatsapp.WhatsApp.family/ChatStorage.sqlite",
    ]

    static func findDB() -> URL? {
        for rel in dbCandidates {
            let u = home.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}

// MARK: - ISO8601 helpers

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func isoString(_ date: Date) -> String { isoFormatter.string(from: date) }
func isoDate(_ s: String) -> Date? { isoFormatter.date(from: s) }

// MARK: - Logging (app.log beside the feed files + stderr)

func appLog(_ message: String) {
    let line = "\(isoString(Date())) \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    let url = Paths.logURL
    try? FileManager.default.createDirectory(at: Paths.shareDir, withIntermediateDirectories: true)
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

func recentLogLines(_ count: Int) -> [String] {
    guard let text = try? String(contentsOf: Paths.logURL, encoding: .utf8) else { return [] }
    return Array(text.split(separator: "\n").suffix(count)).map(String.init)
}

// MARK: - Failure tracking (failures.jsonl beside the feed files)
//
// app.log is a running narrative; this is the structured counterpart for
// troubleshooting: every failed export attempt is recorded with its stage
// and error, health checks are recorded on TRANSITION only (ok→stale and
// stale→ok, so a long stale stretch is two entries, not hundreds), and a
// recovery entry closes the arc when exports succeed again. The file is
// trimmed to the most recent ~1000 events so it stays small forever.

struct FailureEvent: Codable {
    var at: String              // ISO timestamp
    var kind: String            // "export" | "health"
    var event: String           // "failure" | "recovered"
    var stage: String? = nil    // export stage, or "health_check"
    var error: String? = nil    // error text, or comma-joined stale reasons
    var consecutive: Int? = nil // failure events: run length including this one
    var afterFailures: Int? = nil // recovered events: failures it took to get here
}

enum FailureLog {
    private struct State: Codable {
        var consecutiveExport: Int = 0
        var healthWasOK: Bool? = nil
    }

    private static let lock = NSLock()

    private static func loadState() -> State {
        if let data = try? Data(contentsOf: Paths.failureStateURL),
           let s = try? JSONDecoder().decode(State.self, from: data) { return s }
        return State()
    }

    private static func saveState(_ s: State) {
        // The data dir may not exist yet on the very first failure of a
        // fresh install — create it, or the counter silently never persists.
        try? FileManager.default.createDirectory(at: Paths.shareDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: Paths.failureStateURL, options: [.atomic])
        }
    }

    private static func append(_ e: FailureEvent) {
        guard let data = try? JSONEncoder().encode(e),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = Paths.failuresURL
        try? FileManager.default.createDirectory(at: Paths.shareDir, withIntermediateDirectories: true)
        guard let blob = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(blob)
            try? handle.close()
        } else {
            try? blob.write(to: url, options: [.atomic])
        }
        trimIfNeeded()
    }

    private static func trimIfNeeded() {
        let url = Paths.failuresURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 256 * 1024,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").suffix(1000)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Record one failed export attempt. Bumps the consecutive counter that
    /// the eventual recovery entry reports against.
    static func recordExportFailure(stage: String, error: String) {
        lock.lock(); defer { lock.unlock() }
        var st = loadState()
        st.consecutiveExport += 1
        saveState(st)
        append(FailureEvent(at: isoString(Date()), kind: "export", event: "failure",
                            stage: stage, error: error, consecutive: st.consecutiveExport))
    }

    /// On a successful export, close out any open failure run with a
    /// recovery entry. Silent when there was nothing to recover from.
    static func recordExportSuccess() {
        lock.lock(); defer { lock.unlock() }
        var st = loadState()
        guard st.consecutiveExport > 0 else { return }
        let n = st.consecutiveExport
        st.consecutiveExport = 0
        saveState(st)
        append(FailureEvent(at: isoString(Date()), kind: "export", event: "recovered",
                            afterFailures: n))
        appLog("export recovered after \(n) failed attempt(s)")
    }

    /// Record health transitions only: the first stale check of a stretch
    /// and the first healthy check after it. Called on every check; the
    /// persisted previous verdict decides whether anything is written.
    static func noteHealth(ok: Bool, reasons: [String]) {
        lock.lock(); defer { lock.unlock() }
        var st = loadState()
        let was = st.healthWasOK
        st.healthWasOK = ok
        saveState(st)
        guard let was = was, was != ok else { return }
        if ok {
            append(FailureEvent(at: isoString(Date()), kind: "health", event: "recovered",
                                stage: "health_check"))
            appLog("health recovered (was stale)")
        } else {
            append(FailureEvent(at: isoString(Date()), kind: "health", event: "failure",
                                stage: "health_check", error: reasons.joined(separator: ",")))
        }
    }

    static func consecutiveExportFailures() -> Int {
        lock.lock(); defer { lock.unlock() }
        return loadState().consecutiveExport
    }

    static func recentEvents(_ count: Int) -> [FailureEvent] {
        guard let text = try? String(contentsOf: Paths.failuresURL, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").suffix(count).compactMap { line in
            line.data(using: .utf8).flatMap { try? dec.decode(FailureEvent.self, from: $0) }
        }
    }

    /// (failures in last 24h, failures in last 7d, last failure event)
    static func summary() -> (day: Int, week: Int, last: FailureEvent?) {
        guard let text = try? String(contentsOf: Paths.failuresURL, encoding: .utf8) else { return (0, 0, nil) }
        let dec = JSONDecoder()
        let events = text.split(separator: "\n").compactMap { line in
            line.data(using: .utf8).flatMap { try? dec.decode(FailureEvent.self, from: $0) }
        }
        let now = Date()
        var day = 0, week = 0
        var last: FailureEvent? = nil
        for e in events where e.event == "failure" {
            last = e
            if let d = isoDate(e.at) {
                let age = now.timeIntervalSince(d)
                if age < 24 * 3600 { day += 1 }
                if age < 7 * 24 * 3600 { week += 1 }
            }
        }
        return (day, week, last)
    }
}

// MARK: - Probe (probes.jsonl beside the feed files)
//
// A probe is the forensic snapshot Health.check collects on every run:
// file metadata for WhatsApp's stores, its own log, its last server
// ping ack, and its process. health.json embeds the latest probe;
// probes.jsonl keeps one line per health TRANSITION (ok→stale and
// stale→ok) so a stale stretch can be diagnosed after the fact —
// "wedged vs quiet night" was indistinguishable before this existed
// (2026-11-18). Timestamps and pattern names only: no log content, no
// message content, no names are ever recorded here.

struct ProbeData: Codable {
    var chatstorage_at: String? = nil
    var chatstorage_age_s: Int? = nil
    var chatstorage_size: Int? = nil
    var chatstorage_wal_at: String? = nil
    var chatstorage_wal_age_s: Int? = nil
    var chatstorage_wal_size: Int? = nil
    var axolotl_wal_at: String? = nil
    var axolotl_wal_age_s: Int? = nil
    var axolotl_wal_size: Int? = nil
    var localkeyvalue_wal_at: String? = nil
    var localkeyvalue_wal_age_s: Int? = nil
    var localkeyvalue_wal_size: Int? = nil
    var container_newest_wal_at: String? = nil
    var container_newest_wal_age_s: Int? = nil
    var container_newest_wal_name: String? = nil
    var whatsapp_log_at: String? = nil
    var whatsapp_log_age_s: Int? = nil
    var whatsapp_log_name: String? = nil
    var server_ping_ack_found: Bool = false
    var server_ping_ack_at: String? = nil
    var server_ping_ack_age_s: Int? = nil
    var whatsapp_pid: Int? = nil
    var whatsapp_age_s: Int? = nil
    /// Set only when ChatStorage passed the stale threshold but the
    /// probe showed WhatsApp alive-and-connected (quiet, not wedged).
    var db_quiet_s: Int? = nil
    /// "healthy" | "quiet" | "stale" — mirrors the health verdict.
    var classification: String = "healthy"
}

struct ProbeSnapshot: Codable {
    var at: String
    var ok: Bool
    var stale: Bool
    var reasons: [String]
    var probe: ProbeData
}

enum ProbeLog {
    private struct State: Codable {
        var healthWasOK: Bool? = nil
    }

    private static let lock = NSLock()

    private static func loadState() -> State {
        if let data = try? Data(contentsOf: Paths.probeStateURL),
           let s = try? JSONDecoder().decode(State.self, from: data) { return s }
        return State()
    }

    private static func saveState(_ s: State) {
        try? FileManager.default.createDirectory(at: Paths.shareDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: Paths.probeStateURL, options: [.atomic])
        }
    }

    private static func append(_ snap: ProbeSnapshot) {
        guard let data = try? JSONEncoder().encode(snap),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = Paths.probesURL
        try? FileManager.default.createDirectory(at: Paths.shareDir, withIntermediateDirectories: true)
        guard let blob = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(blob)
            try? handle.close()
        } else {
            try? blob.write(to: url, options: [.atomic])
        }
        trimIfNeeded()
    }

    private static func trimIfNeeded() {
        let url = Paths.probesURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 256 * 1024,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").suffix(1000)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Snapshot on health transitions only: the first stale check of a
    /// stretch and the first healthy check after it. Called on every
    /// check; the persisted previous verdict decides whether anything
    /// is written, so a clean run writes no probe spam.
    static func noteTransition(ok: Bool, reasons: [String], probe: ProbeData) {
        lock.lock(); defer { lock.unlock() }
        var st = loadState()
        let was = st.healthWasOK
        st.healthWasOK = ok
        saveState(st)
        guard let was = was, was != ok else { return }
        append(ProbeSnapshot(at: isoString(Date()), ok: ok, stale: !ok,
                             reasons: reasons, probe: probe))
        appLog("probe snapshot: health \(ok ? "recovered" : "went stale") (\(reasons.joined(separator: ",")))")
    }

    static func recentSnapshots(_ count: Int) -> [ProbeSnapshot] {
        guard let text = try? String(contentsOf: Paths.probesURL, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").suffix(count).compactMap { line in
            line.data(using: .utf8).flatMap { try? dec.decode(ProbeSnapshot.self, from: $0) }
        }
    }
}

// MARK: - Config (config.json in the data dir)

struct ThreadConfig: Codable {
    var name: String = ""
    /// Individual export toggle — governs the all-chats feed when the master
    /// toggle is off, and is the per-thread opt-in generally.
    var exportSelected: Bool = false
    /// Monitored feed (outbox.jsonl) membership — the school checks read this.
    var monitored: Bool = false
}

struct AppConfig: Codable {
    var version: Int = 1
    var masterAllChats: Bool = true
    var intervalMinutes: Int = 30
    var autoOpenWhatsApp: Bool = true
    var showInDock: Bool = false
    var onboarded: Bool = false
    var threads: [String: ThreadConfig] = [:]

    /// JIDs monitored by default (the two Stratford groups, as in wa-reader v1/v2).
    static let defaultMonitoredJIDs: Set<String> = [
        "120363411334797203@g.us",
        "120363430274602578@g.us",
    ]
    /// Thread names selected by default for the all-chats feed when the master
    /// toggle is off (the threads M actually reads for Eric).
    static let defaultSelectedNames: Set<String> = [
        "3 & Me",
        "Hermanas 😬",
        "Stratford LG Room 20 (G1)",
        "1st Grade Village | 26-27",
    ]

    static func load() -> AppConfig {
        if let data = try? Data(contentsOf: Paths.configURL),
           let c = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return c
        }
        return AppConfig()
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.shareDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Paths.configURL, options: [.atomic])
        }
    }

    /// Apply first-run defaults to a session list: monitored flags for the
    /// Stratford groups, exportSelected for the threads M reads. Existing
    /// user choices are never overwritten.
    mutating func seedDefaults(from sessions: [ChatSessionInfo]) {
        for s in sessions {
            var tc = threads[s.jid] ?? ThreadConfig()
            if tc.name.isEmpty { tc.name = s.name }
            if AppConfig.defaultMonitoredJIDs.contains(s.jid) { tc.monitored = true }
            if AppConfig.defaultSelectedNames.contains(s.name) { tc.exportSelected = true }
            threads[s.jid] = tc
        }
    }
}

// MARK: - Engine-internal state (engine-state.json; legacy state files stay untouched in shape)

struct EngineState: Codable {
    var dbBirthtime: Double? = nil       // filesystem creation time of ChatStorage.sqlite
    var dbMaxPK: Int64 = 0
    var dbCount: Int64 = 0
    var allLastDate: String? = nil       // newest date written to all-messages.jsonl
    var threadLastDates: [String: String] = [:]  // per monitored thread, newest date in outbox.jsonl

    static func load() -> EngineState {
        if let data = try? Data(contentsOf: Paths.engineStateURL),
           let s = try? JSONDecoder().decode(EngineState.self, from: data) {
            return s
        }
        return EngineState()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Paths.engineStateURL, options: [.atomic])
        }
    }
}

// MARK: - Chat session info (thread picker)

struct ChatSessionInfo: Identifiable {
    var id: String { jid }
    var pk: Int64
    var jid: String
    var name: String
    var isGroup: Bool
    var textCount: Int64
    var lastMessageDate: Date?
}
