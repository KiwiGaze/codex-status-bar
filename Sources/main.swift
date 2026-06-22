import Cocoa

// Reads ~/.codex/statusbar/state.json (written by Codex hooks) and renders a
// Codex "prompt" mark + short status label in the macOS menu bar. No window, no dock icon.

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statePath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/statusbar/state.json")
    let sessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/statusbar/sessions.d")

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

    var current: [String: Any] = [:]
    var activeBase = ""        // label without the elapsed clock
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
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
    // install AND whenever the version changes, so upgrades pick up new/changed hooks and
    // retire old artifacts. install.js is idempotent.
    func ensureHooksInstalled() {
        let d = UserDefaults.standard
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        guard d.string(forKey: "installedVersion") != current,
              let installer = Bundle.main.path(forResource: "install", ofType: "js") else { return }
        DispatchQueue.global().async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh") // login shell so `node` is on PATH
            task.arguments = ["-lc", "node \"\(installer)\""]
            try? task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { UserDefaults.standard.set(current, forKey: "installedVersion") }
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let openItem = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
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
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: statePath),
              let m = attrs[.modificationDate] as? Date else {
            evaluate(); return
        }
        if m != lastMTime {
            lastMTime = m
            if let data = fm.contents(atPath: statePath),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                current = obj
            }
        }
        evaluate()
    }

    func evaluate() {
        let state = current["state"] as? String ?? "idle"
        var label = current["label"] as? String ?? ""
        let ts = (current["ts"] as? NSNumber)?.doubleValue ?? 0
        let started = (current["startedAt"] as? NSNumber)?.doubleValue ?? 0
        let age = Date().timeIntervalSince1970 - ts

        var eff = state
        // Absolute safety net: if a turn has been "running" far too long the writer
        // likely died mid-turn, so fall back to idle rather than animating forever.
        if state == "thinking" || state == "tool" {
            if age > 900 { eff = "idle"; label = "" }
        }

        switch eff {
        case "thinking":  render(label: label.isEmpty ? "Thinking…" : label, color: iconColor, animate: true,  startedAt: started)
        case "tool":      render(label: label.isEmpty ? "Working…"  : label, color: iconColor, animate: true,  startedAt: started)
        case "permission":render(label: "Awaiting permission", color: amber, animate: false, startedAt: 0, dot: true)
        default:          render(label: "", color: iconColor, animate: false, startedAt: 0) // done + idle: just the resting mark
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

    func render(label: String, color: NSColor?, animate: Bool, startedAt: Double, dot: Bool = false) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        activeBase = label
        activeColor = color
        self.startedAt = startedAt

        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            // paused dot for "awaiting permission"; otherwise the resting prompt mark.
            button.image = dot ? dotIcon(color: color) : restingIcon(color: color)
        }
        applyTitle()
        if button.image == nil { button.image = dot ? dotIcon(color: color) : restingIcon(color: color) }
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
        if showTimer, startedAt > 0 {
            let secs = max(0, Int(Date().timeIntervalSince1970 - startedAt))
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
