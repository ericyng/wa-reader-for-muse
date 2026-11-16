# WA Reader — Mac app design

Status: DRAFT for Eric's review (Nov 16, 2026). Design first; no code yet.

## 1. What this replaces, and why

Today's WhatsApp feed is three moving parts on m4m, all built since October:

- **wa-reader** — a single-purpose Swift command-line binary (`~/.local/bin/wa-reader`), run every 30 min by a LaunchAgent. It holds Full Disk Access (FDA), copies WhatsApp's `ChatStorage.sqlite` (+ `-wal`/`-shm`) to a temp dir, opens only the copy, and exports text messages two ways: the two Stratford groups (hardcoded JIDs) to `outbox.jsonl`, and every chat to `all-messages.jsonl`. Watermarks are `Z_PK`-based (`state.json`, `state_all.json`). Writes `status.json` per run.
- **wa-serve** — a LaunchAgent running `python http.server` on port 8735, exposed to the tailnet via Tailscale Serve (8734). Serves the files above to M's checks.
- **wa-health** — a Python watchdog every 5 min that writes `health.json` (is the feed actually fresh?), and auto-opens WhatsApp if it finds it closed (30-min cooldown).

Failure modes actually hit in the last month — these drive the design:

1. **FDA fragility.** The grant attaches to the CLI binary's code signature. A rebuild can silently break it ("rebuilding can break the TCC grant" has been in the README since v1). The Nov 2026 macOS upgrade broke it again and Eric had to re-add the binary by hand.
2. **Wedged file access.** After the OS upgrade, every read of WhatsApp's container failed ("Interrupted system call"); the reader hung inside `clonefileat` for ~20 hours across retries until the Mac was rebooted. Nothing surfaced this except M reading logs over SSH.
3. **Stranded watermarks (Nov 16).** WhatsApp rebuilt its database during the upgrade; message numbering (`Z_PK`) restarted. The reader's saved position (17,816) sat above the new database's maximum (16,534), so a perfectly healthy reader exported nothing, forever. Fixed by hand (state reset + full re-export).
4. **Hardcoded threads.** The exported groups are compiled into the binary. Changing which threads are read means a rebuild + reinstall + FDA roulette.
5. **No visibility.** Health is a JSON file. There is no UI anywhere that says "the feed is fine" or "the feed is stuck, click here."

## 2. Goals / non-goals

Goals:

- A real, signed Mac app with a **stable identity**, so the FDA grant survives rebuilds and OS upgrades.
- A **first-run FDA onboarding flow** that detects the grant live and walks Eric through granting it. (macOS has no API to *request* FDA — see §4.)
- A **thread picker**: choose which WhatsApp groups/threads are exported, changeable any time with no rebuild.
- The **same outputs in the same place** (`~/.local/share/wa-reader/*.jsonl`, `status.json`, `health.json`), so every existing consumer — the hourly dad check, the school checks, the /dad-update skill — keeps working untouched.
- **Self-healing** for the failure modes above, and a menubar presence that makes feed health visible at a glance.

Non-goals: sending messages; reading media/attachments (text only, as today); App Store distribution; running on anyone else's Mac; changing the consumers.

## 3. Form factor

- Native **SwiftUI** app, **menubar-first** (`MenuBarExtra`): a status icon in the menubar with a dropdown panel; a separate **Settings window** for the thread picker, schedule, and log. Menubar-only by default, with a preference to also show in the Dock as a full app (decided Nov 16, §12).
- Starts at login via `SMAppService` (the modern login-item API) — replaces the wa-reader and wa-health LaunchAgents. wa-serve stays as-is in v1 (see §9).
- Swift + the system `SQLite3` C API, same as the current binary's queries. No third-party dependencies.
- Minimum macOS: the version on m4m (Tahoe-era); no legacy support burden.

Menubar dropdown contents:

- Status line in plain words: "Feed healthy — last export 9:26 AM, newest message 8:27 AM" / "Feed stale — WhatsApp isn't running" / "Needs Full Disk Access."
- Buttons: **Run export now**, **Open WhatsApp**, **Choose threads…**, **Open System Settings (Full Disk Access)** (shown when ungranted), **View log**, **Open data folder**, **Quit**.

## 4. Signing, and the FDA flow (the important part)

**Why the current grant keeps breaking:** TCC ties an FDA grant to the app's *designated requirement* — effectively bundle ID + signing certificate. A CLI tool rebuilt with a different (ad-hoc) signature is a different app to TCC.

**Design:**

- Fixed bundle ID: `com.ericng.wareaderformuse` (app name: "WA Reader for Muse," per §12).
- Signed with a **dedicated self-signed local certificate** — "WA Reader for Muse Local Signing" — following Eric's established runbook (`~/OpenCode/signing.md`, the citlla-e510 pattern): the cert lives in its own keychain (`~/Library/Keychains/wareader-signing.keychain-db`, password file in `~/Library/Application Support/WAReaderForMuse/signing/`), created once by `Scripts/create-signing-identity.sh`. Same cert + same bundle ID = the designated requirement (`identifier "com.ericng.wareaderformuse" and certificate root = H"…") never changes = **the FDA grant survives rebuilds and macOS upgrades**. No Apple ID / Developer account involved. Created Nov 16, 2026; cert SHA-1 C34F19CDE24AC9C178FFC659D7C4B496D6728BAF, 10-year validity. Never re-create it (`--force` invalidates every grant); build scripts unlock the keychain from the password file and report which signature they applied, with an explicit identifier-only ad-hoc DR as the stopgap fallback.
- **Not sandboxed** (the sandbox is incompatible with reading another app's container this way) and not notarized for distribution — it never leaves Eric's Mac. Hardened Runtime on.

**FDA onboarding (first-run window):**

macOS offers no permission prompt for FDA — an app cannot ask; the user must add it in System Settings. So the app makes that path as short as possible:

1. On launch, the app tests access by attempting to read `ChatStorage.sqlite` (the actual file it needs — the only honest test).
2. If the read fails, the onboarding window shows: a plain explanation, a screenshot-style 3-step guide, and an **"Open System Settings"** button deep-linking to Privacy & Security → Full Disk Access (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`), plus an **"Reveal app in Finder"** helper for the drag/add step.
3. The app re-tests every few seconds; the moment the read succeeds, the window flips to "Access granted" and moves on to the thread picker. No restart needed.
4. The same check runs on every launch and every export; losing FDA later shows up as a red menubar state + the same one-click path back to Settings.

## 5. Thread picker

- The app enumerates `ZWACHATSESSION` from a copied database: every group and 1:1 chat with display name, JID, last-activity time, and message count. Search box; sort by recent activity or name; groups and 1:1 in separate sections.
- Each thread has an **export toggle**. Two export feeds, preserving today's semantics:
  - **Monitored feed** (`outbox.jsonl`) — the threads the school checks watch. Today: Stratford LG Room 20 (G1) and 1st Grade Village | 26-27.
  - **All-chats feed** (`all-messages.jsonl`) — what the dad check reads (3 & Me, Hermanas, everything else). Controlled by one master toggle ("Export all chats"), default **on** to match today, with a plain-language note that it exports every thread's text. Turning it off limits exports to toggled threads only.
  - In practice a thread can be in the monitored feed, the all-chats feed (via the master toggle), or both — same as today.
- Per-thread row shows: last exported message date, watermark state, and a warning icon if the thread has vanished from WhatsApp's database (deleted/renamed chats keep their JID visible so exports don't silently stop).
- Selection persists in `config.json` in the data directory. Changes apply on the next run — no rebuild, no reinstall, no FDA impact.
- First run **imports today's selection automatically** (the two Stratford groups + all-chats on) so migration is a confirmation, not a re-setup.

## 6. Export engine

- Same approach as the current binary: copy `ChatStorage.sqlite` + `-wal`/`-shm` to a private temp dir, open the copy read-only, export text messages only, append JSON lines in today's exact formats, write `status.json`.
- Schema introspection (as in v2) so WhatsApp schema tweaks degrade loudly instead of silently.
- **Self-healing watermarks** — the Nov 16 fix, automated: before each run, fingerprint the database (file creation date + message count + `MAX(Z_PK)`). If a stored watermark exceeds the live `MAX(Z_PK)`, or the fingerprint says the database was rebuilt, the app logs "WhatsApp database rebuilt — resetting export position," falls back to a **date-based floor** (the newest date already in each output file), and re-exports from there. Consumers filter by date, so a re-export is harmless duplication, never lost messages.
- **Nothing wedges silently:** the copy step runs with a timeout on a background queue. A hung copy is abandoned, logged, and reported in `health.json` as a stale reason — the app never leaves a zombie process behind (the Nov 15–16 lesson).
- Triggers: a timer (default every 30 min, configurable 5–120), an **FSEvents watch** on WhatsApp's container directory for near-real-time exports (debounced 60 s), on launch, and on demand from the menubar.

## 7. Health & the watchdog role

- The app absorbs wa-health: it writes `health.json` in the **same schema** (ok / stale / reasons / corpus newest / reader age) so M's existing gates behave identically — a stuck feed still reads as a *missed check*, never as "no news."
- The auto-open-WhatsApp behavior carries over as a toggle (default on, 30-min cooldown) — exactly the narrow behavior approved Nov 11.
- Menubar icon reflects health: green (fresh), amber (stale but recoverable — e.g., WhatsApp closed), red (FDA missing or exports failing), grey (paused). Optional macOS notification when the feed goes stale for >1 hour (off by default; M's checks already surface outages).

## 8. Data & privacy

- Read-only, text-only, exactly as today. Nothing leaves the Mac except the files wa-serve already serves over the tailnet.
- No analytics, no network calls by the app itself.
- Config, state, and logs live in `~/.local/share/wa-reader/` alongside the outputs, so M can still inspect everything over SSH — the app is a better citizen of the same layout, not a black box.

## 9. Migration plan

1. Build and sign the app; install on m4m alongside the current setup (nothing switched yet).
2. Eric grants FDA to the app (one trip through the onboarding window).
3. App imports today's thread selection; run it in **parallel** with the CLI reader for one cycle and diff the outputs.
4. Disable the wa-reader + wa-health LaunchAgents; the app takes over exports and health. wa-serve keeps serving the same files — consumers never notice.
5. Rollback = re-enable the two LaunchAgents; the CLI binary, its state files, and its FDA grant are left untouched on disk.

## 10. Build & delivery mechanics

- Source lives in `~/workspace/wa-reader-app/`; the app must be **built on the Mac** (Xcode — presence on m4m to be confirmed in the build phase; Command Line Tools alone can assemble a SwiftUI app bundle, but Xcode is strongly preferred).
- Eric's hands-on steps are kept to: build/install (or run an installer script M prepares), the one-time FDA grant, and confirming the picker. Everything else — verification, output diffs, cutover — M does over SSH.
- Updates: rebuild + replace the app in place; the FDA grant persists per §4. The app shows its version and last-export stats in Settings → About.

## 11. v1 scope vs. later

**v1:** signed app + menubar + FDA onboarding/detection + thread picker + export engine with self-healing watermarks + health.json/status.json + auto-open toggle + login start + migration.

**Later, if wanted:** absorb wa-serve into the app (retire the Python server); per-thread schedules; an export preview ("what would be exported"); stale-feed notifications; a small "family feed" status page for the tailnet.

## 12. Decisions (Eric, Nov 16, 2026)

1. **All-chats feed: master toggle kept.** Master ON = every thread exports to the all-chats feed (today's behavior; the dad check depends on it). Master OFF = only threads with their individual toggle on are exported, so every selected thread needs its own toggle in that mode. The monitored feed (outbox.jsonl) keeps its own per-thread toggles either way.
2. **Outputs: redesign permitted, with a hard checkpoint.** The legacy files/schemas are the guaranteed baseline — existing consumers must keep working throughout. A redesign may be prototyped on top (e.g. a unified export store with legacy writers generated from it), but at the checkpoint — end of the engine prototype, before any consumer is touched — if output parity against the legacy files fails, or the redesign is growing past roughly a day of extra work, **revert and ship the original outputs**. No consumer changes without Eric's separate say-so.
3. **Name: "WA Reader for Muse."** Display name as chosen; bundle ID `com.ericng.wareaderformuse`.
4. **Dock: option to show in the Dock as a full app.** A preference toggle (default off — menubar-first). When the Dock icon is on, the app behaves as a regular app: clicking it opens the main window (picker/settings), and it stays in the Dock while running.

Build readiness (checked Nov 16, 2026): m4m has Xcode 27.1 / Swift 6.4 on macOS 27.2.1. No codesigning identity is visible over SSH — Eric likely needs to add his Apple ID in Xcode (Settings → Accounts) so an Apple Development certificate exists; that's a GUI step only he can do, needed before the first signed build.
