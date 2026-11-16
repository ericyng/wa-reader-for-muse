// WA Reader for Muse — SwiftUI views: menubar panel, onboarding, settings.
import SwiftUI
import AppKit

// MARK: - Root (onboarding until access granted + setup confirmed)

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.accessGranted && state.config.onboarded {
                SettingsView()
            } else {
                OnboardingView()
            }
        }
        .onAppear { state.start() }
    }
}

// MARK: - Menubar panel

struct MenuPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(state.statusDot)
                    Text(state.statusHeadline).font(.headline)
                }
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            Group {
                Button {
                    state.runExport()
                } label: {
                    HStack {
                        Text(state.exporting ? "Exporting…" : "Run export now")
                        Spacer()
                        Text("⌘R").foregroundStyle(.secondary)
                    }
                }
                .disabled(state.exporting || !state.accessGranted)

                Button("Open WhatsApp") { state.openWhatsApp() }

                if !state.accessGranted {
                    Button("Open System Settings…") { state.openSystemSettingsFDA() }
                        .fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 6)

            Divider().padding(.vertical, 4)

            Group {
                Button {
                    state.selectedTab = 0
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack {
                        Text("Choose threads…")
                        Spacer()
                        Text("\(enabledThreadCount) on").foregroundStyle(.secondary)
                    }
                }
                Button {
                    state.selectedTab = 1
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack {
                        Text("App settings…")
                        Spacer()
                        Text("Dock, schedule").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Auto-open WhatsApp if closed")
                    Spacer()
                    Toggle("", isOn: $state.config.autoOpenWhatsApp)
                        .labelsHidden()
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            }
            .padding(.horizontal, 6)

            Divider().padding(.vertical, 4)

            Group {
                Button("View log") { state.openLogFile() }
                Button("Open data folder") { state.openDataFolder() }
            }
            .padding(.horizontal, 6)

            Divider().padding(.vertical, 4)

            Button("Quit WA Reader for Muse") { NSApp.terminate(nil) }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .buttonStyle(.plain)
        .frame(width: 340)
        .onAppear { state.start() }
    }

    private var enabledThreadCount: Int {
        if state.config.masterAllChats { return state.sessions.count }
        return state.config.threads.values.filter { $0.exportSelected }.count
    }

    private var statusDetail: String {
        if !state.accessGranted {
            return "Exports are paused. The feed may be stale — that is not the same as no news."
        }
        guard let h = state.health else { return "Checking feed health…" }
        var parts: [String] = []
        if let r = h.readerRanAt, let d = isoDate(r) {
            parts.append("Last export \(timeString(d))")
        }
        if let n = h.corpusNewestAt, let d = isoDate(n) {
            parts.append("newest message \(timeString(d))")
        }
        if !h.ok { parts.append("Stale: \(h.reasons.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - Onboarding (Full Disk Access)

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var recheckTimer: Timer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if state.accessGranted {
                grantedCard
                Text("Next: pick which threads to export. Your current setup is imported automatically — the two Stratford groups in the monitored feed, and the all-chats feed on — so you can just confirm it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Use current setup") {
                        state.config.onboarded = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Review threads…") {
                        state.config.onboarded = true
                    }
                }
            } else {
                lockedCard
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Click **Open System Settings** — it takes you to Privacy & Security → Full Disk Access.")
                    step(2, "Find **WA Reader for Muse** in the list and switch it on. (If it's not listed, click **+** and pick it from Applications.)")
                    step(3, "Come back here — this window notices on its own, usually within a few seconds.")
                }
                HStack(spacing: 10) {
                    Button("Open System Settings") { state.openSystemSettingsFDA() }
                        .buttonStyle(.borderedProminent)
                    Button("Reveal app in Finder") { state.revealAppInFinder() }
                    Label("Checking access…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Why a settings trip? Apple doesn't let apps ask for Full Disk Access with a pop-up — any app that needs it has to send you to Settings. This app only ever reads WhatsApp's database, and only the threads you choose. Because it is signed with a stable local certificate, this grant survives rebuilds and macOS upgrades.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: 560)
        .onAppear {
            state.start()
            recheckTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
                Task { @MainActor in state.refreshAccess() }
            }
        }
        .onDisappear { recheckTimer?.invalidate() }
    }

    private var lockedCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("🔒").font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Full Disk Access needed").font(.headline)
                Text("WA Reader for Muse reads WhatsApp's message database on this Mac. macOS protects that file, so the app needs Full Disk Access. Nothing is exported until you grant it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.red.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.25)))
        .cornerRadius(10)
    }

    private var grantedCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("✅").font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Access granted").font(.headline)
                Text("The app can read WhatsApp's database. Because it is properly signed, this grant survives updates and macOS upgrades — you shouldn't have to do this again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.green.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.3)))
        .cornerRadius(10)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption).fontWeight(.bold).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.blue))
            Text(text).font(.callout)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView(selection: $state.selectedTab) {
            ThreadsPane()
                .tabItem { Label("Threads", systemImage: "message") }
                .tag(0)
            SchedulePane()
                .tabItem { Label("Schedule", systemImage: "clock") }
                .tag(1)
            HealthPane()
                .tabItem { Label("Health & log", systemImage: "heart.text.square") }
                .tag(2)
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(3)
        }
        .onAppear {
            state.start()
            state.refreshSessions()
        }
    }
}

struct ThreadsPane: View {
    @EnvironmentObject var state: AppState
    @State private var search: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Master toggle card
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Export all chats").font(.headline)
                    Text("Every thread's text goes to the all-chats feed — this is what the family updates (3 & Me, Hermanas) are read from. Turn off to export only the threads switched on below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $state.config.masterAllChats).labelsHidden()
            }
            .padding(12)
            .background(Color.green.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.25)))
            .cornerRadius(10)
            .padding(14)

            HStack {
                TextField("Search threads", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button("Refresh") { state.refreshSessions() }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            List {
                Section {
                    ForEach(filteredSessions.filter { $0.isGroup }) { s in threadRow(s) }
                } header: {
                    HStack(spacing: 6) {
                        Text("Groups")
                        if state.config.masterAllChats {
                            Text("(all chats are exported, see above)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(filteredSessions.filter { !$0.isGroup }) { s in threadRow(s) }
                } header: {
                    HStack(spacing: 6) {
                        Text("People")
                        if state.config.masterAllChats {
                            Text("(all chats are exported, see above)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                let gone = state.config.threads.keys.filter { jid in
                    !state.sessions.contains { $0.jid == jid }
                }
                if !gone.isEmpty {
                    Section("No longer in WhatsApp") {
                        ForEach(Array(gone).sorted(), id: \.self) { jid in
                            HStack {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                VStack(alignment: .leading) {
                                    Text(state.config.threads[jid]?.name ?? jid)
                                    Text("Not in WhatsApp's database anymore — exports for it have stopped.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var filteredSessions: [ChatSessionInfo] {
        if search.isEmpty { return state.sessions }
        return state.sessions.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func threadRow(_ s: ChatSessionInfo) -> some View {
        let tc = state.config.threads[s.jid] ?? ThreadConfig()
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(s.isGroup ? Color.green.opacity(0.18) : Color.indigo.opacity(0.15))
                Text(String((s.name.first ?? "?"))).font(.caption).fontWeight(.bold)
            }
            .frame(width: 30, height: 30)
            .opacity(state.config.masterAllChats ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).fontWeight(.medium)
                Text(metaLine(s, tc))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .opacity(state.config.masterAllChats ? 0.45 : 1)
            Spacer()
            // Monitored-feed membership: tap the badge to toggle.
            Button {
                var c = state.config
                var t = c.threads[s.jid] ?? ThreadConfig()
                t.name = s.name
                t.monitored.toggle()
                c.threads[s.jid] = t
                state.config = c
            } label: {
                Text("MONITORED")
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(tc.monitored ? Color.green.opacity(0.2) : Color.gray.opacity(0.12)))
                    .foregroundStyle(tc.monitored ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle monitored feed (outbox.jsonl) membership")
            Toggle("", isOn: Binding(
                get: { state.config.threads[s.jid]?.exportSelected ?? false },
                set: { newValue in
                    var c = state.config
                    var t = c.threads[s.jid] ?? ThreadConfig()
                    t.name = s.name
                    t.exportSelected = newValue
                    c.threads[s.jid] = t
                    state.config = c
                }
            ))
            .labelsHidden()
            .disabled(state.config.masterAllChats)
            .opacity(state.config.masterAllChats ? 0.4 : 1)
            .help(state.config.masterAllChats
                  ? "Individual selection — used when 'Export all chats' is off"
                  : "Export this thread")
        }
        .padding(.vertical, 2)
    }

    private func metaLine(_ s: ChatSessionInfo, _ tc: ThreadConfig) -> String {
        var bits: [String] = []
        if let d = s.lastMessageDate {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            bits.append("last message \(f.string(from: d))")
        }
        bits.append("\(s.textCount) messages")
        if state.config.masterAllChats {
            bits.append("in all-chats feed")
        } else if tc.exportSelected {
            bits.append("selected")
        }
        return bits.joined(separator: " · ")
    }
}

struct SchedulePane: View {
    @EnvironmentObject var state: AppState
    @State private var loginItemOn: Bool = false
    @State private var loginError: String? = nil

    var body: some View {
        Form {
            Section("App") {
                Toggle("Open as a full app (Dock icon)", isOn: Binding(
                    get: { state.config.showInDock },
                    set: { newValue in
                        state.config.showInDock = newValue
                        if newValue { NSApp.activate(ignoringOtherApps: true) }
                    }
                ))
                Text("On: WA Reader appears in the Dock like a regular app — click its icon to open the window. Off: it lives only in the menubar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Exports") {
                Picker("Export every", selection: $state.config.intervalMinutes) {
                    Text("5 minutes").tag(5)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
                Text("Also runs on launch, on demand, and shortly after WhatsApp's database changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("Start at login", isOn: Binding(
                    get: { loginItemOn },
                    set: { newValue in
                        loginError = state.setLoginItem(newValue)
                        loginItemOn = state.loginItemEnabled
                    }
                ))
                if let e = loginError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
                Toggle("Auto-open WhatsApp if closed", isOn: $state.config.autoOpenWhatsApp)
                Text("At most once per 30 minutes. WhatsApp must be running for the feed to stay fresh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Data folder") {
                    Text(Paths.shareDir.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Button("Open data folder") { state.openDataFolder() }
                Text("Same files, same place as the old wa-reader — existing checks keep working.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItemOn = state.loginItemEnabled }
    }
}

struct HealthPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(state.statusDot)
                Text(state.statusHeadline).font(.headline)
                Spacer()
                Button("Refresh") {
                    state.runHealth()
                    state.refreshAccess()
                }
                Button("Run export now") { state.runExport() }
                    .disabled(state.exporting)
            }
            if let h = state.health {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("WhatsApp running").foregroundStyle(.secondary)
                        Text(h.whatsappRunning ? "Yes" : "No")
                    }
                    GridRow {
                        Text("Full Disk Access").foregroundStyle(.secondary)
                        Text(state.accessGranted ? "Granted" : "Missing")
                    }
                    GridRow {
                        Text("Last export").foregroundStyle(.secondary)
                        Text(h.readerRanAt ?? "—")
                    }
                    GridRow {
                        Text("Newest exported message").foregroundStyle(.secondary)
                        Text(h.corpusNewestAt ?? "—")
                    }
                    GridRow {
                        Text("Stale reasons").foregroundStyle(.secondary)
                        Text(h.reasons.isEmpty ? "none" : h.reasons.joined(separator: ", "))
                    }
                }
                .font(.callout)
            }
            Text("Recent log").font(.subheadline).fontWeight(.semibold)
            ScrollView {
                Text(recentLogLines(14).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color.black.opacity(0.85))
            .foregroundStyle(Color.green.opacity(0.9))
            .cornerRadius(8)
        }
        .padding(16)
    }
}

struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WA Reader for Muse").font(.title3).fontWeight(.bold)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · \(Bundle.main.bundleIdentifier ?? "")")
                .foregroundStyle(.secondary)
            Text("Read-only exporter for WhatsApp Desktop on this Mac. Replaces the wa-reader command-line tool and the wa-health watchdog. Signed with a stable local certificate so its Full Disk Access grant survives rebuilds and macOS upgrades.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
