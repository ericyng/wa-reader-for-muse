// WA Reader for Muse — health watchdog, ported from wa-health.py.
// Writes health.json in the exact schema existing consumers gate on:
// a stale feed must read as a MISSED check, never as "no news."
// Auto-open of WhatsApp (approved by Eric 2026-11-11) carries over,
// including the shared wa-health-state.json cooldown file, so behavior
// is identical whether the Python watchdog or this app ran last.
import Foundation

struct HealthReport {
    var ok: Bool
    var stale: Bool
    var reasons: [String]
    var whatsappRunning: Bool
    var dbLastWrite: Date?
    var readerRanAt: String?
    var readerOk: Bool?
    var corpusNewestAt: String?
    var autoOpenAttempted: Bool
    var lastAutoOpenAt: String?
}

enum Health {
    static let dbStaleSeconds: TimeInterval = 2 * 3600
    static let readerStaleSeconds: TimeInterval = 45 * 60
    static let relaunchCooldown: TimeInterval = 30 * 60

    static func whatsappRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "WhatsApp"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private struct HealthState: Codable { var last_relaunch_ts: Double? }

    private static func loadHealthState() -> HealthState {
        if let data = try? Data(contentsOf: Paths.healthStateURL),
           let s = try? JSONDecoder().decode(HealthState.self, from: data) { return s }
        return HealthState()
    }

    private static func saveHealthState(_ s: HealthState) {
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: Paths.healthStateURL, options: [.atomic])
        }
    }

    /// Open WhatsApp if it is not running (30-min cooldown). Returns
    /// (attemptedThisRun, lastAttemptISO). The relaunching check still
    /// reports stale — recovery shows in the next check's verdict.
    private static func maybeRelaunch(now: Date, running: Bool, enabled: Bool) -> (Bool, String?) {
        var state = loadHealthState()
        var attempted = false
        if enabled && !running {
            let last = state.last_relaunch_ts
            if last == nil || now.timeIntervalSince1970 - last! >= relaunchCooldown {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", "WhatsApp"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil {
                    p.waitUntilExit()
                    attempted = true
                    state.last_relaunch_ts = now.timeIntervalSince1970
                    saveHealthState(state)
                }
            }
        }
        let lastISO = state.last_relaunch_ts.map { isoString(Date(timeIntervalSince1970: $0)) }
        return (attempted, lastISO)
    }

    private static func newestCorpusDate() -> String? {
        let url = Paths.allOutboxURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let start = max(0, size - 262144)
        handle.seek(toFileOffset: UInt64(start))
        let data = handle.readDataToEndOfFile()
        try? handle.close()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var best: String? = nil
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"), let d = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let date = obj["date"] as? String else { continue }
            if best == nil || date > best! { best = date }
        }
        return best
    }

    static func check(autoOpenEnabled: Bool) -> HealthReport {
        let now = Date()
        var reasons: [String] = []

        let running = whatsappRunning()
        if !running { reasons.append("whatsapp_not_running") }
        let (attempted, lastAuto) = maybeRelaunch(now: now, running: running, enabled: autoOpenEnabled)

        var dbTS: Date? = nil
        for suffix in ["", "-wal"] {
            let p = Paths.whatsappDB.path + suffix
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
               let m = attrs[.modificationDate] as? Date {
                dbTS = max(dbTS ?? .distantPast, m)
            }
        }
        let dbAge = dbTS.map { now.timeIntervalSince($0) }
        if running && (dbAge == nil || dbAge! > dbStaleSeconds) {
            reasons.append("db_not_written_recently")
        }

        var readerRanAt: String? = nil
        var readerAge: TimeInterval? = nil
        var readerOk: Bool? = nil
        if let data = try? Data(contentsOf: Paths.statusURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            readerOk = obj["ok"] as? Bool
            readerRanAt = obj["ran_at"] as? String
            if let r = readerRanAt, let d = isoDate(r) { readerAge = now.timeIntervalSince(d) }
        } else {
            reasons.append("reader_status_unreadable")
        }
        if readerAge == nil || readerAge! > readerStaleSeconds { reasons.append("reader_stale") }
        if readerOk == false { reasons.append("reader_reported_not_ok") }

        let newest = newestCorpusDate()
        let corpusAge = newest.flatMap { isoDate($0) }.map { now.timeIntervalSince($0) }

        let report = HealthReport(
            ok: reasons.isEmpty,
            stale: !reasons.isEmpty,
            reasons: reasons,
            whatsappRunning: running,
            dbLastWrite: dbTS,
            readerRanAt: readerRanAt,
            readerOk: readerOk,
            corpusNewestAt: newest,
            autoOpenAttempted: attempted,
            lastAutoOpenAt: lastAuto
        )

        var obj: [String: Any] = [
            "checked_at": isoString(now),
            "ok": report.ok,
            "stale": report.stale,
            "reasons": reasons,
            "whatsapp_running": running,
            "auto_open_attempted": attempted,
        ]
        obj["db_last_write"] = dbTS.map { isoString($0) } ?? NSNull()
        obj["db_age_s"] = dbAge.map { Int($0) } ?? NSNull()
        obj["reader_ran_at"] = readerRanAt ?? NSNull()
        obj["reader_age_s"] = readerAge.map { Int($0) } ?? NSNull()
        obj["reader_ok"] = readerOk ?? NSNull()
        obj["corpus_newest_at"] = newest ?? NSNull()
        obj["corpus_age_s"] = corpusAge.map { Int($0) } ?? NSNull()
        obj["last_auto_open_at"] = lastAuto ?? NSNull()

        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? data.write(to: Paths.healthURL, options: [.atomic])
        }
        appLog("health: \(report.ok ? "ok" : "STALE " + reasons.joined(separator: ","))\(attempted ? " (auto-open attempted)" : "")")
        return report
    }
}
