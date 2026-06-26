import Cocoa

// Reads ~/.codex/statusbar/state.json (written by Codex hooks) and renders a
// Codex "prompt" mark + short status label in the macOS menu bar. No window, no dock icon.

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statesDir = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/statusbar/states.d")
    let legacyStatePath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/statusbar/state.json")
    let sessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/statusbar/sessions.d")
    // sessionId -> (SessionState, file mtime observed). mtime lets tick() reload only changed files.
    var sessions: [String: (state: SessionState, mtime: Date)] = [:]
    var pinnedSession: String?
    var pinnedDiedAt: Date?   // when the pinned session went stale; grey it for 5s before dropping
    var doneShownAt: [String: Date] = [:]   // per-session "Done" dismiss clocks
    var timeoutLogged: Set<String> = []    // sessionIds already logged as timed out (dedupe per stuck episode)

    var lastMTime: Date = .distantPast
    var pollTimer: Timer?
    var animTimer: Timer?
    var frameIdx = 0

    // Self-quit lifecycle: we're launched by the session-start hook; we decide when to
    // leave (see checkLifecycle). No background/login item — the check only runs while
    // we're already alive.
    let launchedAt = Date()
    var notNeededSince: Date?
    let launchGrace: TimeInterval = 5   // settle time after launch before we may quit
    let idleQuitDelay: TimeInterval = 3 // "not needed" must persist this long before quitting
    let freshWindow: TimeInterval = 20  // a session file touched this recently counts as active

    var activeBase = ""        // label without the elapsed clock
    var activeStartedAt: TimeInterval = 0
    var activePausedTotal: TimeInterval = 0
    var activePauseStart: TimeInterval = 0
    var activeColor: NSColor? = nil

    let brand = NSColor(srgbRed: 0.30, green: 0.56, blue: 1.00, alpha: 1) // #4D8FFF accent
    let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "awaiting permission" yellow dot
    let frames: [NSImage] = StatusController.loadFrames() // prompt morph masks
    let spriteFPS: Double = 9 // tune: frames per loop -> ~0.9s/cycle

    var showTimer = true
    var iconSystem = false // false = brand accent; true = adaptive black/white (template image)
    var iconColor: NSColor? { iconSystem ? nil : brand } // nil => render as an adaptive template
    var fps: Double { spriteFPS }
    var frameCount: Int { max(1, frames.count) }

    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "iconSystem") != nil { iconSystem = d.bool(forKey: "iconSystem") }
        if let p = d.string(forKey: "pinnedSession"), !p.isEmpty { pinnedSession = p }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render(label: "", color: iconColor, animate: false, startedAt: 0)
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
        ensureHooksInstalled()
    }

    // Wire up the Codex hooks ourselves by running the bundled installer, so the
    // user just drags the app in and opens it — no manual Terminal step. Runs on first
    // install AND whenever the version or bundled hook resources change, so upgrades pick
    // up new/changed hooks and retire old artifacts. install.js is idempotent.
    func ensureHooksInstalled() {
        let d = UserDefaults.standard
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        guard let installer = Bundle.main.path(forResource: "install", ofType: "js") else { return }
        let fingerprint = "\(current)|\(hookInstallFingerprint(installer: installer))"
        guard d.string(forKey: "installedHookFingerprint") != fingerprint else { return }
        DispatchQueue.global().async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // GUI apps don't inherit a terminal PATH and `zsh -lc` skips ~/.zshrc, so node
            // from nvm/fnm/asdf may be missing — prepend the common Homebrew locations as a
            // best-effort, and surface a clear alert when node still isn't found.
            task.arguments = ["-lc", "PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\" node \"\(installer)\""]
            do { try task.run() } catch { self?.showInstallerFailure(installer: installer); return }
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                UserDefaults.standard.set(fingerprint, forKey: "installedHookFingerprint")
            } else {
                self?.showInstallerFailure(installer: installer)
            }
        }
    }

    func showInstallerFailure(installer: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Codex Status Bar couldn’t set up its hooks"
            alert.informativeText = "Node.js wasn’t found on the app’s PATH, so the Codex hooks were not installed. Open Terminal and run:\n\nnode \"\(installer)\"\n\nThen start codex and approve the hooks."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func hookInstallFingerprint(installer: String) -> String {
        let resourceDir = (installer as NSString).deletingLastPathComponent
        let names = ["install.js", "update.js", "lifecycle.js", "uninstall.js"]
        return names.map { name in
            let path = (resourceDir as NSString).appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber,
                  let modified = attrs[.modificationDate] as? Date else {
                return "\(name):missing"
            }
            let modifiedAt = String(format: "%.6f", modified.timeIntervalSince1970)
            return "\(name):\(size.int64Value):\(modifiedAt)"
        }.joined(separator: "|")
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let openItem = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        appendSessionsMenu(into: menu)

        menu.addItem(.separator())

        let timerItem = NSMenuItem(title: "Show timer", action: #selector(toggleTimer), keyEquivalent: "")
        timerItem.target = self
        timerItem.state = showTimer ? .on : .off
        menu.addItem(timerItem)

        menu.addItem(.separator())
        for (sys, name) in [(false, "Accent"), (true, "System")] {
            let it = NSMenuItem(title: name, action: #selector(chooseColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = sys
            it.state = iconSystem == sys ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit Codex Status Bar", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    func appendSessionsMenu(into menu: NSMenu) {
        let now = Date().timeIntervalSince1970
        let all = sessions.map { $0.value.state }
        let live = all.filter { displayEligible($0, now: now) }
        let ordered = menuOrder(pinned: pinnedSession, sessions: live, now: now, limit: 5)

        // Track pinned death so the pinned item can be greyed for 5s before dropping.
        let pinnedAlive = pinnedSession.flatMap { id in live.first { $0.sessionId == id }?.isAlive(now: now) } ?? false
        if pinnedSession != nil, !pinnedAlive {
            if pinnedDiedAt == nil { pinnedDiedAt = Date() }
            if let died = pinnedDiedAt, Date().timeIntervalSince(died) > 5 {
                pinnedSession = nil; pinnedDiedAt = nil
                UserDefaults.standard.removeObject(forKey: "pinnedSession")
            }
        } else {
            pinnedDiedAt = nil
        }

        var endedState: SessionState?
        if let p = pinnedSession, !pinnedAlive, let died = pinnedDiedAt,
           Date().timeIntervalSince(died) <= 5 {
            endedState = all.first(where: { $0.sessionId == p })
        }

        if ordered.isEmpty {
            if let st = endedState {
                menu.addItem(.separator())
                menu.addItem(endedMenuItem(for: st))
                menu.addItem(.separator())
            }
            return
        }
        if let st = endedState {
            menu.addItem(.separator())
            menu.addItem(endedMenuItem(for: st))
        }
        menu.addItem(.separator())
        for st in ordered {
            let isPinned = st.sessionId == pinnedSession
            let title = "\(isPinned ? "● " : "")\(st.project.isEmpty ? st.sessionId : st.project) · \(st.label)"
            let item = NSMenuItem(title: title, action: #selector(pinSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = st.sessionId
            item.state = isPinned ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    func endedMenuItem(for st: SessionState) -> NSMenuItem {
        let title = "● \(st.project.isEmpty ? st.sessionId : st.project) · ended"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func pinSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        pinnedSession = (pinnedSession == id) ? nil : id
        pinnedDiedAt = nil
        UserDefaults.standard.set(pinnedSession, forKey: "pinnedSession")
        evaluate()
    }

    @objc func quit() { NSApp.terminate(nil) }

    // Prefer the Codex desktop app if it's installed; otherwise fall back to running
    // `codex` in Terminal.app. The app is looked up by bundle id via LaunchServices so
    // it's found no matter where it lives (/Applications, ~/Applications, …). Only
    // Terminal.app answers AppleScript's "do script" event (Ghostty/iTerm2 don't), so
    // the fallback stays Terminal-only.
    @objc func openCodex() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e", "tell application \"Terminal\" to do script \"codex\"",
            "-e", "tell application \"Terminal\" to activate",
        ]
        try? task.run()
    }

    @objc func toggleTimer() {
        showTimer.toggle()
        UserDefaults.standard.set(showTimer, forKey: "showTimer")
        applyTitle()
    }

    @objc func chooseColor(_ sender: NSMenuItem) {
        guard let sys = sender.representedObject as? Bool else { return }
        iconSystem = sys
        UserDefaults.standard.set(iconSystem, forKey: "iconSystem")
        evaluate() // re-render the current state in the new color
    }

    // MARK: state polling

    func tick() {
        checkLifecycle()
        loadSessions()
        evaluate()
    }

    // Reload any per-session state file whose mtime advanced. Also handles one-shot
    // backward compat: if states.d/ is empty but a legacy single state.json exists,
    // read it once under a synthetic session id so upgrades keep working until the new
    // hooks take over.
    //
    // Timeout logging lives here (not in evaluate) on purpose: selectDisplay filters
    // sessions at staleAfter=900s, so by the time evaluate sees a session its age is
    // already ≤ 900 — the age>900 safety net in evaluate would be dead code. Scanning
    // here catches sessions the moment they cross 900s while still in thinking/tool,
    // and logs each stuck episode once (deduped via timeoutLogged).
    func loadSessions() {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        var seen: Set<String> = []                          // sanitized filenames on disk
        var seenIds: Set<String> = []                       // raw sessionIds loaded this pass
        if let names = try? fm.contentsOfDirectory(atPath: statesDir) {
            for name in names {
                let p = (statesDir as NSString).appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: p),
                      let m = attrs[.modificationDate] as? Date else { continue }
                seen.insert(name)
                // Populate seenIds for EVERY file present on disk — including those we
                // short-circuit below. If we only inserted after the mtime check, a stuck
                // session (frozen mtime → `continue`) would never enter seenIds, and the
                // doneShownAt/timeoutLogged pruning loops would wipe its entry every tick
                // (re-opening the Done flicker and re-logging every 0.4s).
                if let prev = sessions[name] { seenIds.insert(prev.state.sessionId) }
                if let prev = sessions[name], prev.mtime == m { continue }
                guard let data = fm.contents(atPath: p),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let st = SessionState(json: obj) else { continue }
                sessions[name] = (st, m)
                seenIds.insert(st.sessionId)
            }
        }
        for k in sessions.keys where !seen.contains(k) { sessions.removeValue(forKey: k) }
        // Prune per-session done timers by RAW sessionId (the key space doneShownAt uses).
        for k in doneShownAt.keys where !seenIds.contains(k) { doneShownAt.removeValue(forKey: k) }
        for k in timeoutLogged where !seenIds.contains(k) { timeoutLogged.remove(k) }

        // Timeout sweep — runs EVERY tick over the in-memory cache, NOT gated by mtime.
        // A stuck session has a frozen file → frozen mtime → the loop above `continue`s
        // past it, so the age check must live here or it would never fire. Deduped via
        // timeoutLogged so each stuck episode logs once; cleared when the writer recovers
        // (new write → fresh ts → age < 900).
        for entry in sessions.values {
            let st = entry.state
            let age = now - st.ts
            if (st.state == "thinking" || st.state == "tool") && age > 900
                && !timeoutLogged.contains(st.sessionId) {
                appendTimeoutLog(chosen: st, age: age)
                timeoutLogged.insert(st.sessionId)
            }
            if age < 900 { timeoutLogged.remove(st.sessionId) }
        }

        // One-shot legacy fallback.
        if sessions.isEmpty, let attrs = try? fm.attributesOfItem(atPath: legacyStatePath),
           let m = attrs[.modificationDate] as? Date, m != lastMTime {
            lastMTime = m
            if let data = fm.contents(atPath: legacyStatePath),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let st = SessionState(json: obj) {
                sessions["__legacy__"] = (st, m)
            }
        }
    }

    func displayEligible(_ st: SessionState, now: TimeInterval) -> Bool {
        let ownerAlive = st.ownerPid > 0 && processAlive(st.ownerPid)
        return st.isDisplayEligible(now: now, ownerAlive: ownerAlive)
    }

    func processAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    func evaluate() {
        let now = Date().timeIntervalSince1970
        let all = sessions.map { $0.value.state }.filter { displayEligible($0, now: now) }
        guard let chosen = selectDisplay(pinned: pinnedSession, sessions: all, now: now) else {
            render(label: "", color: iconColor, animate: false, startedAt: 0,
                   pausedTotal: 0, pauseStart: 0)
            return
        }
        let label = chosen.label
        let state = chosen.state

        // No age>900 safety net here: selectDisplay already excludes sessions older
        // than staleAfter=900s, and stuck-turn logging fires in loadSessions. By the
        // time a session reaches evaluate, it is alive and recent.

        switch state {
        case "thinking", "tool":
            let fallback = state == "thinking" ? "Thinking…" : "Working…"
            render(label: label.isEmpty ? fallback : label, color: iconColor, animate: true,
                   startedAt: chosen.startedAt, pausedTotal: chosen.pausedTotal, pauseStart: chosen.pauseStart)
        case "permission":
            // Timer stays visible but frozen at net time (spec §6.4). The amber dot
            // signals the pause; the clock just stops advancing until post fires.
            render(label: "Awaiting permission", color: amber, animate: false,
                   startedAt: chosen.startedAt, pausedTotal: chosen.pausedTotal,
                   pauseStart: chosen.pauseStart, dot: true)
        case "done":
            renderDone(chosen: chosen, now: now)
        default:
            render(label: "", color: iconColor, animate: false, startedAt: 0,
                   pausedTotal: 0, pauseStart: 0)
        }
    }

    // Show a brief "Done" confirmation for 2s after a session's Stop event, so users
    // can distinguish "just finished" from "idle". Falls back to the resting mark after.
    // The doneShownAt entry is a permanent "already shown" sentinel (NOT cleared after
    // 2s) — clearing it would re-trigger firstShow on the next tick while the state
    // file still says "done", causing the green checkmark to flicker forever.
    // loadSessions prunes the entry when the session file disappears.
    func renderDone(chosen: SessionState, now: TimeInterval) {
        if doneShownAt[chosen.sessionId] == nil { doneShownAt[chosen.sessionId] = Date(timeIntervalSince1970: now) }
        let shownAt = doneShownAt[chosen.sessionId]?.timeIntervalSince1970 ?? now
        if now - shownAt > 2 {
            render(label: "", color: iconColor, animate: false,
                   startedAt: 0, pausedTotal: 0, pauseStart: 0)
            return
        }
        render(label: "Done", color: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.40, alpha: 1),
               animate: false, startedAt: 0, pausedTotal: 0, pauseStart: 0, done: true)
    }

    func appendTimeoutLog(chosen: SessionState, age: TimeInterval) {
        let logPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/statusbar/app.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) TIMEOUT session=\(chosen.sessionId) state=\(chosen.state) age=\(Int(age)) project=\(chosen.project)\n"
        guard let data = line.data(using: .utf8) else { return }
        // String.write(toFile:) replaces the file; use FileHandle to APPEND so each
        // stuck episode is preserved for diagnostics rather than overwriting the last.
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }

    // MARK: self-quit lifecycle

    // True while a Codex process is running. The CLI, `codex exec`, and the app-server
    // backing the desktop app and the VS Code extension all run as an executable named
    // `codex`, so an exact-name match catches every surface without the false positives a
    // broad command-line match invites (e.g. an MCP server with .codex in its argv).
    func codexRunning() -> Bool {
        pgrepMatches(["-x", "codex"])
    }

    func pgrepMatches(_ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return task.terminationStatus == 0 && !data.isEmpty
    }

    // A session is "fresh" if any file in sessions.d/ was modified within freshWindow
    // seconds — covers the gap right after launch before a process is visible.
    func freshSession() -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return false }
        let now = Date()
        for name in names {
            let path = (sessionsDir as NSString).appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let m = attrs[.modificationDate] as? Date,
               now.timeIntervalSince(m) <= freshWindow {
                return true
            }
        }
        return false
    }

    // Stay while Codex is running OR a session was just touched; otherwise quit (after a
    // short, debounced grace so warmup churn and relaunches don't kill us).
    func checkLifecycle() {
        let now = Date()
        if now.timeIntervalSince(launchedAt) < launchGrace { return }
        if codexRunning() || freshSession() {
            notNeededSince = nil
            return
        }
        if let since = notNeededSince {
            if now.timeIntervalSince(since) >= idleQuitDelay { NSApp.terminate(nil) }
        } else {
            notNeededSince = now
        }
    }

    // MARK: render

    func render(label: String, color: NSColor?, animate: Bool, startedAt: TimeInterval,
                pausedTotal: TimeInterval = 0, pauseStart: TimeInterval = 0, dot: Bool = false, done: Bool = false) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        activeBase = label
        activeColor = color
        activeStartedAt = startedAt
        activePausedTotal = pausedTotal
        activePauseStart = pauseStart

        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            if done { button.image = checkIcon(color: color) }
            else if dot { button.image = dotIcon(color: color) }
            else { button.image = restingIcon(color: color) }
        }
        applyTitle()
        if button.image == nil { button.image = done ? checkIcon(color: color) : (dot ? dotIcon(color: color) : restingIcon(color: color)) }
        button.setAccessibilityLabel(label.isEmpty ? "Codex status: idle" : "Codex status: \(label)")
    }

    // Reproduce the thinking animation: step through the frame masks.
    func animStep() {
        frameIdx = (frameIdx + 1) % frameCount
        statusItem.button?.image = iconImage(color: activeColor, frame: frameIdx)
        applyTitle() // refresh the elapsed clock
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        var text = activeBase
        if showTimer, activeStartedAt > 0 {
            let secs = elapsedSeconds(now: Date().timeIntervalSince1970,
                                      startedAt: activeStartedAt,
                                      pausedTotal: activePausedTotal,
                                      pauseStart: activePauseStart)
            let m = secs / 60, s = secs % 60
            text += "  " + (m > 0 ? "\(m)m \(s)s" : "\(s)s") // e.g. "1m 1s" / "43s"
        }
        if text.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.imagePosition = .imageLeading
        // labelColor adapts: white on a dark menu bar, black on a light one. Monospaced
        // digits keep the elapsed clock from nudging neighboring menu bar icons.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular),
        ]
        button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
    }

    // MARK: icon

    // The prompt morph frames, rasterized into alpha masks (SparkFrames.swift).
    // Decoded once at launch.
    static func loadFrames() -> [NSImage] { decodePNGs(codexSparkFramePNGs) }
    static func decodePNGs(_ list: [String]) -> [NSImage] {
        list.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) }
    }

    func iconImage(color: NSColor?, frame: Int) -> NSImage { tint(frames, color: color, frame: frame) }

    // The resting icon is the Codex prompt mark.
    let logoSet: [NSImage] = Data(base64Encoded: codexLogoPNG).flatMap(NSImage.init(data:)).map { [$0] } ?? []
    func restingIcon(color: NSColor?) -> NSImage { tint(logoSet.isEmpty ? frames : logoSet, color: color, frame: 0) }

    // A small filled dot — used for the paused "awaiting permission" state.
    func dotIcon(color: NSColor?) -> NSImage {
        let s: CGFloat = 18, d: CGFloat = 9
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (color ?? .systemYellow).setFill()
            NSBezierPath(ovalIn: NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // A small checkmark — used for the 2s "Done" confirmation.
    func checkIcon(color: NSColor?) -> NSImage {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (color ?? .systemGreen).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 4, y: 9))
            path.line(to: NSPoint(x: 7.5, y: 5))
            path.line(to: NSPoint(x: 14, y: 13))
            path.stroke()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Paint `color` through a frame mask's alpha, so the same frames recolor.
    func tint(_ set: [NSImage], color: NSColor?, frame: Int) -> NSImage {
        let s: CGFloat = 18
        guard !set.isEmpty else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = set[frame % set.count]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            if let c = color {
                c.setFill()
                rect.fill()
                mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil) // nil => adaptive black/white in the menu bar
        return img
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
