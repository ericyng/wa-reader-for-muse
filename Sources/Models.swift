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

    static var whatsappDB: URL {
        home.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")
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
