// WA Reader for Muse — export engine.
// Ported from wa-reader v2 (~/workspace/wa-reader-build/main.swift) with:
//   - config-driven thread selection (was: two hardcoded group JIDs)
//   - all-chats master toggle (off = only individually selected threads)
//   - self-healing watermarks when WhatsApp rebuilds its database
//     (the Nov 16, 2026 failure: Z_PK numbering restarted and the saved
//     position sat above the new maximum, so nothing exported, forever)
//   - a timeout on the database copy, so a wedged copy is reported
//     instead of hanging silently (the Nov 15–16 failure)
// Output files and formats are byte-compatible with wa-reader v2.
import Foundation
import SQLite3

struct ExportResult {
    var ok: Bool
    var error: String? = nil
    var groupNew: Int = 0
    var allNew: Int = 0
    var perGroup: [String: Int] = [:]
    var allLastPK: Int64 = 0
    var healed: [String] = []
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Engine {
    var config: AppConfig

    init(config: AppConfig) { self.config = config }

    // MARK: Access check (FDA)

    /// True if this process can read WhatsApp's database file. In the app,
    /// this is the app's own Full Disk Access; from a terminal it reflects
    /// the terminal's attribution (see signing.md §6c) — indicative only.
    static func canReadDatabase() -> Bool {
        guard let db = Paths.findDB() else { return false }
        guard let handle = try? FileHandle(forReadingFrom: db) else { return false }
        let data = handle.readData(ofLength: 16)
        try? handle.close()
        return data.count == 16
    }

    static func databaseExists() -> Bool { Paths.findDB() != nil }

    // MARK: Session enumeration (thread picker)

    func listSessions() -> [ChatSessionInfo] {
        guard let db = openDatabaseCopy() else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT s.Z_PK, s.ZCONTACTJID, COALESCE(s.ZPARTNERNAME, ''),
               (SELECT COUNT(*) FROM ZWAMESSAGE m WHERE m.ZCHATSESSION = s.Z_PK AND m.ZTEXT IS NOT NULL),
               (SELECT MAX(m.ZMESSAGEDATE) FROM ZWAMESSAGE m WHERE m.ZCHATSESSION = s.Z_PK)
        FROM ZWACHATSESSION s
        WHERE s.ZCONTACTJID IS NOT NULL AND s.ZCONTACTJID != 'status@broadcast'
        """
        var stmt: OpaquePointer?
        var out: [ChatSessionInfo] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = sqlite3_column_int64(stmt, 0)
                let jid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let name = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let count = sqlite3_column_int64(stmt, 3)
                var last: Date? = nil
                if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                    last = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
                }
                out.append(ChatSessionInfo(pk: pk, jid: jid,
                                           name: name.isEmpty ? jid : name,
                                           isGroup: jid.hasSuffix("@g.us"),
                                           textCount: count, lastMessageDate: last))
            }
        }
        sqlite3_finalize(stmt)
        out = Engine.dedupeSessions(out)
        out.sort {
            ($0.lastMessageDate ?? .distantPast) > ($1.lastMessageDate ?? .distantPast)
        }
        return out
    }

    /// The rebuilt WhatsApp database can hold duplicate ZWACHATSESSION rows
    /// for one JID (seen Nov 16, 2026: a @bot JID twice). Keep the row with
    /// the most text messages per JID.
    static func dedupeSessions(_ sessions: [ChatSessionInfo]) -> [ChatSessionInfo] {
        var byJID: [String: ChatSessionInfo] = [:]
        for s in sessions {
            if let existing = byJID[s.jid], existing.textCount >= s.textCount { continue }
            byJID[s.jid] = s
        }
        return Array(byJID.values)
    }

    // MARK: Database copy (with timeout) + open

    /// Copies ChatStorage.sqlite (+ -wal/-shm) to a fresh temp dir on a
    /// background queue and waits up to `timeout` seconds. Returns the temp
    /// dir, or nil on failure/timeout. A wedged copy is abandoned (its temp
    /// dir is unique per call) and reported by the caller — never a hang.
    private func copyDatabase(timeout: TimeInterval = 90) -> URL? {
        guard let src = Paths.findDB() else { return nil }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wa-reader-app-\(UUID().uuidString)")
        let sem = DispatchSemaphore(value: 0)
        var result: URL? = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] {
                    let s = URL(fileURLWithPath: src.path + suffix)
                    if FileManager.default.fileExists(atPath: s.path) {
                        try FileManager.default.copyItem(at: s, to: tmpDir.appendingPathComponent("ChatStorage.sqlite" + suffix))
                    }
                }
                result = tmpDir
            } catch {
                appLog("copy failed: \(error.localizedDescription)")
                result = nil
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            appLog("copy TIMED OUT after \(Int(timeout))s (database copy wedged; will retry next run)")
            return nil
        }
        return result
    }

    private func openDatabaseCopy() -> OpaquePointer? {
        guard let tmp = copyDatabase() else { return nil }
        var db: OpaquePointer?
        let path = tmp.appendingPathComponent("ChatStorage.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            if let db = db { sqlite3_close(db) }
            return nil
        }
        // Temp dir cleanup happens on process exit for the CLI, and the app
        // removes old wa-reader-app-* dirs at launch; copies are small.
        return db
    }

    // MARK: SQLite helpers (from v2)

    private func columnNames(db: OpaquePointer?, table: String) -> Set<String> {
        var stmt: OpaquePointer?
        var names = Set<String>()
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) { names.insert(String(cString: c)) }
            }
        }
        sqlite3_finalize(stmt)
        return names
    }

    private func tableExists(db: OpaquePointer?, table: String) -> Bool {
        var stmt: OpaquePointer?
        var found = false
        if sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT)
            found = sqlite3_step(stmt) == SQLITE_ROW
        }
        sqlite3_finalize(stmt)
        return found
    }

    private func scalarInt64(db: OpaquePointer?, sql: String, bind: Int64? = nil) -> Int64 {
        var stmt: OpaquePointer?
        var value: Int64 = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if let b = bind { sqlite3_bind_int64(stmt, 1, b) }
            if sqlite3_step(stmt) == SQLITE_ROW { value = sqlite3_column_int64(stmt, 0) }
        }
        sqlite3_finalize(stmt)
        return value
    }

    private func jsonLine(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func appendLines(_ lines: [String], to url: URL) {
        if lines.isEmpty { return }
        let blob = lines.joined(separator: "\n") + "\n"
        guard let data = blob.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: [.atomic])
        }
    }

    // MARK: Legacy state files (formats unchanged from v2)

    struct ThreadState: Codable { var last_pk: Int64 }
    struct GroupState: Codable { var threads: [String: ThreadState] }
    struct AllState: Codable { var last_pk: Int64 }

    private func loadGroupState() -> GroupState {
        if let data = try? Data(contentsOf: Paths.stateURL),
           let s = try? JSONDecoder().decode(GroupState.self, from: data) { return s }
        return GroupState(threads: [:])
    }
    private func saveGroupState(_ s: GroupState) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: Paths.stateURL, options: [.atomic]) }
    }
    private func loadAllState() -> AllState {
        if let data = try? Data(contentsOf: Paths.allStateURL),
           let s = try? JSONDecoder().decode(AllState.self, from: data) { return s }
        return AllState(last_pk: 0)
    }
    private func saveAllState(_ s: AllState) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: Paths.allStateURL, options: [.atomic]) }
    }

    private func writeStatus(_ r: ExportResult) {
        var obj: [String: Any] = [
            "ran_at": isoString(Date()),
            "ok": r.ok,
            "new_messages": r.groupNew,
            "per_group": r.perGroup,
            "all_new_messages": r.allNew,
            "all_last_pk": r.allLastPK,
        ]
        if let e = r.error { obj["error"] = e }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? FileManager.default.createDirectory(at: Paths.shareDir, withIntermediateDirectories: true)
            try? data.write(to: Paths.statusURL, options: [.atomic])
        }
    }

    /// Single exit path for a failed export: status file, log line, and a
    /// structured entry in failures.jsonl (see FailureLog in Models.swift).
    private func failExport(_ result: ExportResult, stage: String) -> ExportResult {
        writeStatus(result)
        appLog("export failed: \(result.error ?? "unknown error")")
        FailureLog.recordExportFailure(stage: stage, error: result.error ?? "unknown error")
        return result
    }

    // MARK: - The export run

    func runExport() -> ExportResult {
        try? FileManager.default.createDirectory(at: Paths.shareDir, withIntermediateDirectories: true)
        var result = ExportResult(ok: false)

        guard Paths.findDB() != nil else {
            result.error = "ChatStorage.sqlite not found in any WhatsApp group container"
            return failExport(result, stage: "find_database")
        }
        guard let db = openDatabaseCopy() else {
            result.error = "could not copy/open database (Full Disk Access? or copy timed out)"
            return failExport(result, stage: "copy_open_database")
        }
        defer { sqlite3_close(db) }

        let msgCols = columnNames(db: db, table: "ZWAMESSAGE")
        guard msgCols.contains("ZTEXT"), msgCols.contains("ZMESSAGEDATE"), msgCols.contains("ZCHATSESSION") else {
            result.error = "ZWAMESSAGE schema not recognised (missing ZTEXT/ZMESSAGEDATE/ZCHATSESSION)"
            return failExport(result, stage: "schema_check")
        }

        // Sender expression (same best-effort logic as v2).
        var senderExpr = "''"
        if msgCols.contains("ZGROUPMEMBER"), tableExists(db: db, table: "ZWAGROUPMEMBER") {
            let gmCols = columnNames(db: db, table: "ZWAGROUPMEMBER")
            if gmCols.contains("ZMEMBERJID") {
                senderExpr = msgCols.contains("ZFROMJID")
                    ? "COALESCE(g.ZMEMBERJID, m.ZFROMJID, '')"
                    : "COALESCE(g.ZMEMBERJID, '')"
            }
        } else if msgCols.contains("ZFROMJID") {
            senderExpr = "COALESCE(m.ZFROMJID, '')"
        }
        let joinClause = senderExpr.hasPrefix("COALESCE(g.")
            ? "LEFT JOIN ZWAGROUPMEMBER g ON m.ZGROUPMEMBER = g.Z_PK" : ""
        let pushSelect = msgCols.contains("ZPUSHNAME") ? "COALESCE(m.ZPUSHNAME, '')" : "''"

        // Sessions, for names and selection.
        let sessions = listSessionsFrom(db: db)
        let sessionByJID = Dictionary(sessions.map { ($0.jid, $0) },
                                      uniquingKeysWith: { a, _ in a })

        // MARK: Fingerprint + self-heal
        var engineState = EngineState.load()
        let liveMaxPK = scalarInt64(db: db, sql: "SELECT COALESCE(MAX(Z_PK),0) FROM ZWAMESSAGE")
        let liveCount = scalarInt64(db: db, sql: "SELECT COUNT(*) FROM ZWAMESSAGE")
        var allState = loadAllState()
        if allState.last_pk > liveMaxPK {
            // Database was rebuilt; numbering restarted. Reset by DATE:
            // re-export everything after the newest date already exported.
            let floorDate = engineState.allLastDate.flatMap { isoDate($0) }
            var newWatermark: Int64 = 0
            if let floorDate = floorDate {
                newWatermark = scalarInt64(db: db,
                    sql: "SELECT COALESCE(MAX(Z_PK),0) FROM ZWAMESSAGE WHERE ZMESSAGEDATE <= ?",
                    bind: Int64(floorDate.timeIntervalSinceReferenceDate))
            }
            let msg = "WhatsApp database rebuilt — all-chats watermark reset \(allState.last_pk) → \(newWatermark) (date floor \(engineState.allLastDate ?? "none"))"
            appLog(msg)
            result.healed.append(msg)
            allState.last_pk = newWatermark
        }

        // MARK: Monitored-groups export (outbox.jsonl)
        var groupState = loadGroupState()
        var outLines: [String] = []
        var perGroup: [String: Int] = [:]
        let monitoredJIDs = config.threads.filter { $0.value.monitored }.map { $0.key }
        let firstRunFloors: [String: String] = [
            "120363411334797203@g.us": "2026-10-09T04:29:44Z",
            "120363430274602578@g.us": "2026-10-14T01:02:06Z",
        ]
        let msgSQL = """
        SELECT m.Z_PK, m.ZMESSAGEDATE, COALESCE(m.ZISFROMME, 0), m.ZTEXT, \(senderExpr), \(pushSelect)
        FROM ZWAMESSAGE m \(joinClause)
        WHERE m.ZCHATSESSION = ? AND m.Z_PK > ? AND m.ZTEXT IS NOT NULL
        ORDER BY m.Z_PK ASC LIMIT 2000
        """
        for jid in monitoredJIDs {
            guard let session = sessionByJID[jid] else { continue }
            var lastPK = groupState.threads[jid]?.last_pk ?? 0
            // Per-thread heal: stored watermark above this thread's live max.
            let threadMax = scalarInt64(db: db,
                sql: "SELECT COALESCE(MAX(Z_PK),0) FROM ZWAMESSAGE WHERE ZCHATSESSION = ?", bind: session.pk)
            if lastPK > threadMax {
                var newWatermark: Int64 = 0
                if let d = engineState.threadLastDates[jid].flatMap({ isoDate($0) }) {
                    newWatermark = scalarInt64(db: db,
                        sql: "SELECT COALESCE(MAX(Z_PK),0) FROM ZWAMESSAGE WHERE ZCHATSESSION = ? AND ZMESSAGEDATE <= \(Int64(d.timeIntervalSinceReferenceDate))",
                        bind: session.pk)
                }
                let msg = "WhatsApp database rebuilt — monitored watermark for \(jid) reset \(lastPK) → \(newWatermark)"
                appLog(msg)
                result.healed.append(msg)
                lastPK = newWatermark
            }
            var floor = -Double.greatestFiniteMagnitude
            if lastPK == 0, let f = firstRunFloors[jid], let d = isoDate(f) {
                floor = d.timeIntervalSinceReferenceDate
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, msgSQL, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_int64(stmt, 1, session.pk)
            sqlite3_bind_int64(stmt, 2, lastPK)
            var maxSeenPK = lastPK
            var emitted = 0
            var newestDate: String? = nil
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = sqlite3_column_int64(stmt, 0)
                if pk > maxSeenPK { maxSeenPK = pk }
                let rawDate = sqlite3_column_double(stmt, 1)
                if rawDate <= floor { continue }
                let isFromMe = sqlite3_column_int(stmt, 2) != 0
                let text = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let sender = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let push = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                let dateStr = isoString(Date(timeIntervalSinceReferenceDate: rawDate))
                let obj: [String: Any] = [
                    "thread_jid": jid,
                    "thread_name": config.threads[jid]?.name ?? session.name,
                    "pk": pk,
                    "date": dateStr,
                    "is_from_me": isFromMe,
                    "sender": sender,
                    "sender_name": push,
                    "text": text,
                ]
                if let line = jsonLine(obj) { outLines.append(line); emitted += 1; newestDate = dateStr }
            }
            sqlite3_finalize(stmt)
            groupState.threads[jid] = ThreadState(last_pk: maxSeenPK)
            perGroup[jid] = emitted
            if let nd = newestDate { engineState.threadLastDates[jid] = nd }
        }
        appendLines(outLines, to: Paths.outboxURL)
        saveGroupState(groupState)
        result.groupNew = outLines.count
        result.perGroup = perGroup

        // MARK: All-chats export (all-messages.jsonl)
        // Master ON: every thread. Master OFF: only exportSelected threads.
        var sessionFilter = ""
        if !config.masterAllChats {
            let selectedPKs = sessions.filter { config.threads[$0.jid]?.exportSelected == true }
                .map { String($0.pk) }
            sessionFilter = selectedPKs.isEmpty
                ? " AND 1 = 0"
                : " AND m.ZCHATSESSION IN (\(selectedPKs.joined(separator: ",")))"
        }
        var allLines: [String] = []
        var newestAllDate: String? = nil
        let allSQL = """
        SELECT m.Z_PK, m.ZMESSAGEDATE, COALESCE(m.ZISFROMME, 0), m.ZTEXT, \(senderExpr),
               s.ZCONTACTJID, COALESCE(s.ZPARTNERNAME, '')
        FROM ZWAMESSAGE m
        JOIN ZWACHATSESSION s ON m.ZCHATSESSION = s.Z_PK \(joinClause)
        WHERE m.Z_PK > ? AND m.ZTEXT IS NOT NULL AND s.ZCONTACTJID != 'status@broadcast'\(sessionFilter)
        ORDER BY m.Z_PK ASC LIMIT 5000
        """
        var caughtUp = false
        while !caughtUp && allLines.count < 100_000 {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, allSQL, -1, &stmt, nil) == SQLITE_OK else { break }
            sqlite3_bind_int64(stmt, 1, allState.last_pk)
            var chunkRows = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                chunkRows += 1
                let pk = sqlite3_column_int64(stmt, 0)
                if pk > allState.last_pk { allState.last_pk = pk }
                let rawDate = sqlite3_column_double(stmt, 1)
                let isFromMe = sqlite3_column_int(stmt, 2) != 0
                let text = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let sender = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let jid = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                let nm = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                let dateStr = isoString(Date(timeIntervalSinceReferenceDate: rawDate))
                let obj: [String: Any] = [
                    "thread_jid": jid,
                    "thread_name": nm.isEmpty ? jid : nm,
                    "is_group": jid.hasSuffix("@g.us"),
                    "pk": pk,
                    "date": dateStr,
                    "is_from_me": isFromMe,
                    "sender": sender,
                    "text": text,
                ]
                if let line = jsonLine(obj) { allLines.append(line); newestAllDate = dateStr }
            }
            sqlite3_finalize(stmt)
            if chunkRows < 5000 { caughtUp = true }
        }
        appendLines(allLines, to: Paths.allOutboxURL)
        saveAllState(allState)
        result.allNew = allLines.count
        result.allLastPK = allState.last_pk
        if let nd = newestAllDate { engineState.allLastDate = nd }

        // Fingerprint for next run's heal check.
        engineState.dbMaxPK = liveMaxPK
        engineState.dbCount = liveCount
        if let src = Paths.findDB(),
           let attrs = try? FileManager.default.attributesOfItem(atPath: src.path),
           let created = attrs[.creationDate] as? Date {
            engineState.dbBirthtime = created.timeIntervalSince1970
        }
        engineState.save()

        result.ok = true
        writeStatus(result)
        appLog("export ok — \(result.groupNew) group message(s), \(result.allNew) all-chat message(s)")
        FailureLog.recordExportSuccess()
        return result
    }

    private func listSessionsFrom(db: OpaquePointer?) -> [ChatSessionInfo] {
        let sql = """
        SELECT s.Z_PK, s.ZCONTACTJID, COALESCE(s.ZPARTNERNAME, ''),
               (SELECT COUNT(*) FROM ZWAMESSAGE m WHERE m.ZCHATSESSION = s.Z_PK AND m.ZTEXT IS NOT NULL),
               (SELECT MAX(m.ZMESSAGEDATE) FROM ZWAMESSAGE m WHERE m.ZCHATSESSION = s.Z_PK)
        FROM ZWACHATSESSION s
        WHERE s.ZCONTACTJID IS NOT NULL AND s.ZCONTACTJID != 'status@broadcast'
        """
        var stmt: OpaquePointer?
        var out: [ChatSessionInfo] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = sqlite3_column_int64(stmt, 0)
                let jid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let name = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let count = sqlite3_column_int64(stmt, 3)
                var last: Date? = nil
                if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                    last = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
                }
                out.append(ChatSessionInfo(pk: pk, jid: jid,
                                           name: name.isEmpty ? jid : name,
                                           isGroup: jid.hasSuffix("@g.us"),
                                           textCount: count, lastMessageDate: last))
            }
        }
        sqlite3_finalize(stmt)
        return Engine.dedupeSessions(out)
    }
}
