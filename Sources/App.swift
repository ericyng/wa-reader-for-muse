// WA Reader for Muse — entry point, CLI modes, app state.
import SwiftUI
import AppKit
import ServiceManagement

@main
struct MainEntry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--export-once") || args.contains("--list-threads")
            || args.contains("--check-access") || args.contains("--health-once")
            || args.contains("--seed-config") {
            CLI.run(args)
            return
        }
        WAReaderApp.main()
    }
}

// MARK: - Headless CLI modes (used for install-time verification over SSH;
// note signing.md §6c: a terminal-launched process borrows the terminal's
// TCC attribution, so --check-access from a shell is indicative only —
// the app's own launch state is the truth.)

enum CLI {
    static func run(_ args: [String]) {
        var config = AppConfig.load()
        let engine = Engine(config: config)

        if args.contains("--check-access") {
            print("database_exists=\(Engine.databaseExists())")
            print("can_read=\(Engine.canReadDatabase())")
            exit(0)
        }
        if args.contains("--seed-config") {
            let sessions = engine.listSessions()
            config.seedDefaults(from: sessions)
            config.save()
            print("seeded config with \(sessions.count) sessions at \(Paths.configURL.path)")
            exit(0)
        }
        if args.contains("--list-threads") {
            for s in engine.listSessions() {
                let obj: [String: Any] = [
                    "jid": s.jid, "name": s.name, "is_group": s.isGroup,
                    "text_count": s.textCount,
                    "last_message": s.lastMessageDate.map { isoString($0) } ?? NSNull(),
                ]
                if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                   let line = String(data: d, encoding: .utf8) { print(line) }
            }
            exit(0)
        }
        if args.contains("--health-once") {
            let h = Health.check(autoOpenEnabled: config.autoOpenWhatsApp)
            print("wa-health: \(h.ok ? "ok" : "STALE " + h.reasons.joined(separator: ","))")
            exit(0)
        }
        if args.contains("--export-once") {
            // Seed defaults on first ever run so the app imports today's setup.
            if !FileManager.default.fileExists(atPath: Paths.configURL.path) {
                let sessions = engine.listSessions()
                config.seedDefaults(from: sessions)
                config.save()
                engine.config = config
            }
            let r = engine.runExport()
            _ = Health.check(autoOpenEnabled: config.autoOpenWhatsApp)
            if r.ok {
                print("wa-reader: ok, \(r.groupNew) group message(s), \(r.allNew) all-chat message(s)")
                exit(0)
            } else {
                print("wa-reader: FAILED — \(r.error ?? "unknown error")")
                exit(1)
            }
        }
    }
}

// MARK: - App state

@MainActor
final class AppState: ObservableObject {
    /// Lets the app delegate kick off the engine at launch (see below).
    static weak var shared: AppState?

    init() { AppState.shared = self }

    @Published var config: AppConfig = AppConfig.load() {
        didSet {
            config.save()
            applyActivationPolicy()
            restartExportTimer()
        }
    }
    @Published var selectedTab: Int = 0
    @Published var health: HealthReport? = nil
    @Published var lastResult: ExportResult? = nil
    @Published var sessions: [ChatSessionInfo] = []
    @Published var accessGranted: Bool = Engine.canReadDatabase()
    @Published var exporting: Bool = false

    private var exportTimer: Timer? = nil
    private var healthTimer: Timer? = nil
    private var lastDBMtime: Date? = nil
    private var lastExportAt: Date = .distantPast

    var statusDot: String {
        guard let h = health else { return "⚪️" }
        if !accessGranted { return "🔴" }
        if h.ok { return "🟢" }
        if h.reasons.contains("whatsapp_not_running") { return "🟡" }
        return "🔴"
    }

    var statusHeadline: String {
        if !accessGranted { return "Needs Full Disk Access" }
        guard let h = health else { return "Checking…" }
        if h.ok { return "Feed healthy" }
        if h.reasons.contains("whatsapp_not_running") { return "WhatsApp isn't running" }
        return "Feed stale"
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        applyActivationPolicy()
        cleanupTempCopies()
        refreshAccess()
        refreshSessions()
        runHealth()
        // First export shortly after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.runExport()
        }
        restartExportTimer()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccess()
                self?.runHealth()
                self?.pollDBChange()
            }
        }
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(config.showInDock ? .regular : .accessory)
    }

    private func restartExportTimer() {
        exportTimer?.invalidate()
        let interval = TimeInterval(max(1, config.intervalMinutes) * 60)
        exportTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runExport() }
        }
    }

    private func cleanupTempCopies() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        if let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent.hasPrefix("wa-reader-app-") {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    func refreshAccess() {
        accessGranted = Engine.canReadDatabase()
    }

    func refreshSessions() {
        let cfg = config
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = Engine(config: cfg)
            let found = engine.listSessions()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.sessions = found
                var c = self.config
                let before = c.threads.count
                c.seedDefaults(from: found)
                if c.threads.count != before { self.config = c }
            }
        }
    }

    func runExport() {
        guard !exporting else { return }
        exporting = true
        let cfg = config
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = Engine(config: cfg)
            let r = engine.runExport()
            let h = Health.check(autoOpenEnabled: cfg.autoOpenWhatsApp)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lastResult = r
                self.health = h
                self.exporting = false
                self.lastExportAt = Date()
                self.refreshAccess()
            }
        }
    }

    func runHealth() {
        let auto = config.autoOpenWhatsApp
        DispatchQueue.global(qos: .utility).async {
            let h = Health.check(autoOpenEnabled: auto)
            DispatchQueue.main.async { [weak self] in self?.health = h }
        }
    }

    private func pollDBChange() {
        guard let db = Paths.findDB(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: db.path),
              let mtime = attrs[.modificationDate] as? Date else { return }
        defer { lastDBMtime = mtime }
        if let last = lastDBMtime, mtime > last,
           Date().timeIntervalSince(lastExportAt) > 60 {
            runExport()
        }
    }

    func openWhatsApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "WhatsApp"]
        try? p.run()
    }

    func openSystemSettingsFDA() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealAppInFinder() {
        NSWorkspace.shared.selectFile(Bundle.main.bundlePath,
                                      inFileViewerRootedAtPath: "")
    }

    func openDataFolder() {
        NSWorkspace.shared.open(Paths.shareDir)
    }

    func openLogFile() {
        NSWorkspace.shared.open(Paths.logURL)
    }

    // Login item (SMAppService). Failures are surfaced to the UI, not fatal.
    func setLoginItem(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}

// MARK: - App

/// Reopen handling for full-app (Dock) mode: clicking the Dock icon with no
/// visible window brings the main window back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Start the engine at launch, not only when a view first appears.
    /// A login-item or state-restored launch may never show a window, and
    /// without this the reader would sit in the menubar doing nothing —
    /// a silent dead feed, the exact failure this app exists to prevent.
    /// start() is idempotent; the views' onAppear calls stay as backstops.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task { @MainActor in AppState.shared?.start() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first { $0.title == "WA Reader for Muse" }?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

struct WAReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    /// The app icon, pre-sized for the menubar. Setting NSImage.size is what
    /// actually constrains it — a SwiftUI frame alone lets the multi-rep app
    /// icon render at its natural (huge) size in a MenuBarExtra label.
    static var menuBarIcon: NSImage {
        let img = NSApplication.shared.applicationIconImage.copy() as! NSImage
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(state)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: Self.menuBarIcon)
                Text(state.statusDot)
            }
        }
        .menuBarExtraStyle(.window)

        Window("WA Reader for Muse", id: "main") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 560, minHeight: 440)
        }
        .defaultSize(width: 680, height: 520)
    }
}
