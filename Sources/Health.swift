// WA Reader for Muse — health watchdog, ported from wa-health.py.
// Writes health.json in the exact schema existing consumers gate on:
// a stale feed must read as a MISSED check, never as "no news."
// Auto-open of WhatsApp (approved by Eric 2026-11-11) carries over,
// including the shared wa-health-state.json cooldown file, so behavior
// is identical whether the Python watchdog or this app ran last.
//
// Probing (added 2026-11-18): a stale ChatStorage alone used to be
// indistinguishable from a quiet night — on 2026-11-18 the 2:41 AM check
// flagged db_not_written_recently after ~2.5 h of ChatStorage silence,
// and the feed "recovered" minutes later when the WAL next wrote, with
// no evidence either way. Health.check now also collects a Probe: the
// other stores' WAL activity in the same group container, WhatsApp's
// own log freshness, the last server ping ack in that log's tail, and
// the WhatsApp process itself. See the classification rule in check().
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
    var probe: ProbeData? = nil
}

enum Health {
    static let dbStaleSeconds: TimeInterval = 2 * 3600
    static let readerStaleSeconds: TimeInterval = 45 * 60
    static let relaunchCooldown: TimeInterval = 30 * 60

    static func whatsappRunning() -> Bool {
        whatsappPID() != nil
    }

    static func whatsappPID() -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "WhatsApp"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let first = text.split(separator: "\n").first,
              let pid = Int(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        return pid
    }

    /// Age of a process in seconds, from `ps -o etime=` ([[dd-]hh:]mm:ss).
    private static func processAge(pid: Int) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", "\(pid)", "-o", "etime="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8) else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var days = 0
        if let dash = text.firstIndex(of: "-") {
            days = Int(text[..<dash]) ?? 0
            text = String(text[text.index(after: dash)...])
        }
        let parts = text.split(separator: ":").map { Int($0) ?? 0 }
        switch parts.count {
        case 3: return days * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return days * 86400 + parts[0] * 60 + parts[1]
        case 1: return days * 86400 + parts[0]
        default: return nil
        }
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

    // MARK: - Probe

    private static func fileStat(_ url: URL) -> (mtime: Date, size: Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = attrs[.modificationDate] as? Date else { return nil }
        return (m, (attrs[.size] as? NSNumber)?.intValue ?? 0)
    }

    private static func fill(_ probe: inout ProbeData, _ stat: (mtime: Date, size: Int)?,
                             now: Date,
                             at: WritableKeyPath<ProbeData, String?>,
                             age: WritableKeyPath<ProbeData, Int?>,
                             size: WritableKeyPath<ProbeData, Int?>) {
        guard let stat = stat else { return }
        probe[keyPath: at] = isoString(stat.mtime)
        probe[keyPath: age] = Int(now.timeIntervalSince(stat.mtime))
        probe[keyPath: size] = stat.size
    }

    /// Last server ping ack in the tail (~256 KB) of WhatsApp's log.
    /// Log lines carry only a time of day ("04:21:53.415 … server_ping/ack"),
    /// so the date is reconstructed from `now`: that time today, or
    /// yesterday if it would land in the future. PRIVACY: only the
    /// timestamp is extracted — never the log line's content.
    private static func lastPingAck(logURL: URL, now: Date) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int, size > 0,
              let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        handle.seek(toFileOffset: UInt64(max(0, size - 262144)))
        let data = handle.readDataToEndOfFile()
        try? handle.close()
        let text = String(decoding: data, as: UTF8.self)
        let range = text.range(of: "server_ping/ack", options: .backwards)
            ?? text.range(of: "server_ping", options: .backwards)
        guard let r = range else { return nil }
        let before = text[..<r.lowerBound]
        let lineStart = before.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let stamp = text[lineStart...].prefix(8)  // "HH:mm:ss"
        let parts = stamp.split(separator: ":").map { Int($0) }
        guard parts.count == 3, let h = parts[0], let m = parts[1], let s = parts[2],
              (0...23).contains(h), (0...59).contains(m), (0...60).contains(s) else { return nil }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = h; comps.minute = m; comps.second = s
        guard var d = cal.date(from: comps) else { return nil }
        if d.timeIntervalSince(now) > 120 { d = d.addingTimeInterval(-86400) }
        if now.timeIntervalSince(d) > 2 * 86400 { return nil }
        return d
    }

    /// Collect the probe: per-store WAL activity in WhatsApp's group
    /// container, WhatsApp's own log freshness + last server ping ack,
    /// and the WhatsApp process. Metadata and timestamps only — no file
    /// content beyond the log-tail timestamp extraction above.
    static func collectProbe(now: Date, pid: Int?) -> ProbeData {
        var probe = ProbeData()
        let container = Paths.whatsappContainer

        fill(&probe, fileStat(Paths.whatsappDB), now: now,
             at: \.chatstorage_at, age: \.chatstorage_age_s, size: \.chatstorage_size)
        fill(&probe, fileStat(URL(fileURLWithPath: Paths.whatsappDB.path + "-wal")), now: now,
             at: \.chatstorage_wal_at, age: \.chatstorage_wal_age_s, size: \.chatstorage_wal_size)
        fill(&probe, fileStat(container.appendingPathComponent("Axolotl.sqlite-wal")), now: now,
             at: \.axolotl_wal_at, age: \.axolotl_wal_age_s, size: \.axolotl_wal_size)
        fill(&probe, fileStat(container.appendingPathComponent("LocalKeyValue.sqlite-wal")), now: now,
             at: \.localkeyvalue_wal_at, age: \.localkeyvalue_wal_age_s, size: \.localkeyvalue_wal_size)

        // Newest WAL write anywhere in the container: WhatsApp touches
        // many stores; any recent one means the app is alive and writing.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: container.path) {
            var best: (mtime: Date, name: String)? = nil
            for name in names where name.hasSuffix(".sqlite-wal") {
                if let st = fileStat(container.appendingPathComponent(name)),
                   best == nil || st.mtime > best!.mtime {
                    best = (st.mtime, name)
                }
            }
            if let best = best {
                probe.container_newest_wal_at = isoString(best.mtime)
                probe.container_newest_wal_age_s = Int(now.timeIntervalSince(best.mtime))
                probe.container_newest_wal_name = best.name
            }
        }

        // Newest WhatsApp log file by mtime (files rotate at ~1 MB).
        if let names = try? FileManager.default.contentsOfDirectory(atPath: Paths.whatsappLogsDir.path) {
            var best: (mtime: Date, url: URL)? = nil
            for name in names where name.hasSuffix(".log") {
                let url = Paths.whatsappLogsDir.appendingPathComponent(name)
                if let st = fileStat(url), best == nil || st.mtime > best!.mtime {
                    best = (st.mtime, url)
                }
            }
            if let best = best {
                probe.whatsapp_log_at = isoString(best.mtime)
                probe.whatsapp_log_age_s = Int(now.timeIntervalSince(best.mtime))
                probe.whatsapp_log_name = best.url.lastPathComponent
                if let ping = lastPingAck(logURL: best.url, now: now) {
                    probe.server_ping_ack_found = true
                    probe.server_ping_ack_at = isoString(ping)
                    probe.server_ping_ack_age_s = Int(now.timeIntervalSince(ping))
                }
            }
        }

        if let pid = pid {
            probe.whatsapp_pid = pid
            probe.whatsapp_age_s = processAge(pid: pid)
        }
        return probe
    }

    static func check(autoOpenEnabled: Bool) -> HealthReport {
        let now = Date()
        var reasons: [String] = []

        let pid = whatsappPID()
        let running = pid != nil
        if !running { reasons.append("whatsapp_not_running") }
        let (attempted, lastAuto) = maybeRelaunch(now: now, running: running, enabled: autoOpenEnabled)

        var probe = collectProbe(now: now, pid: pid)

        var dbTS: Date? = nil
        for suffix in ["", "-wal"] {
            let p = Paths.whatsappDB.path + suffix
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
               let m = attrs[.modificationDate] as? Date {
                dbTS = max(dbTS ?? .distantPast, m)
            }
        }
        let dbAge = dbTS.map { now.timeIntervalSince($0) }

        // Refined stale classification (2026-11-18): ChatStorage silence
        // alone is NOT a stale feed when the probe shows WhatsApp alive
        // and connected — i.e. the newest container WAL was written
        // within 30 min, OR WhatsApp's log was written within 15 min,
        // OR a server ping ack appears within the last 15 min. That is
        // a quiet period, not a wedge: no db_not_written_recently
        // reason is recorded, and probe.db_quiet_s carries the
        // ChatStorage idle time so the quiet stays visible. Only when
        // ChatStorage is stale AND the container, log, and ping are
        // all stale too is db_not_written_recently kept — that is a
        // real wedge or a genuinely silent app.
        let dbStale = running && (dbAge == nil || dbAge! > dbStaleSeconds)
        if dbStale {
            let containerAlive = probe.container_newest_wal_age_s.map { $0 <= 30 * 60 } ?? false
            let logAlive = probe.whatsapp_log_age_s.map { $0 <= 15 * 60 } ?? false
            let pingAlive = probe.server_ping_ack_age_s.map { $0 <= 15 * 60 } ?? false
            if containerAlive || logAlive || pingAlive {
                probe.db_quiet_s = dbAge.map { Int($0) } ?? Int(dbStaleSeconds)
            } else {
                reasons.append("db_not_written_recently")
            }
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

        probe.classification = !reasons.isEmpty ? "stale" : (probe.db_quiet_s != nil ? "quiet" : "healthy")

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
            lastAutoOpenAt: lastAuto,
            probe: probe
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
        if let pdata = try? JSONEncoder().encode(probe),
           let pdict = try? JSONSerialization.jsonObject(with: pdata) {
            obj["probe"] = pdict
        }

        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? data.write(to: Paths.healthURL, options: [.atomic])
        }
        appLog("health: \(report.ok ? "ok" : "STALE " + reasons.joined(separator: ","))\(attempted ? " (auto-open attempted)" : "") (probe: \(probe.classification))")
        FailureLog.noteHealth(ok: report.ok, reasons: reasons)
        ProbeLog.noteTransition(ok: report.ok, reasons: reasons, probe: probe)
        return report
    }
}
