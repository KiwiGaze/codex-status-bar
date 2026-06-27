import Foundation

// Standalone assertion harness. Compiled WITHOUT main.swift so it does not launch the GUI.
// Build: swiftc Tests/logic_tests.swift Sources/SessionState.swift Sources/AppSupport.swift -o "$TMPDIR/csbt"
// Run:   "$TMPDIR/csbt"

var failures = 0
func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !cond { print("FAIL \(file):\(line) — \(msg)"); failures += 1 }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String) { check(a == b, "\(a) != \(b) — \(msg)") }

// NOTE: Swift forbids top-level expressions outside main.swift. The build command pins
// this file's name (logic_tests.swift), so we wrap the executable body in an @main type.
@main
struct LogicTests {
    static func main() {
// ---- elapsedSeconds: net time ----
let now: TimeInterval = 1_000_000
eq(elapsedSeconds(now: now, startedAt: now - 100, pausedTotal: 30, pauseStart: 0), 70, "basic net")
eq(elapsedSeconds(now: now, startedAt: now - 100, pausedTotal: 0, pauseStart: 0), 100, "no pause")
eq(elapsedSeconds(now: now, startedAt: now - 100, pausedTotal: 30, pauseStart: now - 10), 60, "in active pause subtracts current pause")
eq(elapsedSeconds(now: now, startedAt: 0, pausedTotal: 0, pauseStart: 0), 0, "no startedAt -> 0")
eq(elapsedSeconds(now: now, startedAt: now + 50, pausedTotal: 0, pauseStart: 0), 0, "future startedAt clamps to 0")

// ---- display eligibility: global owners cannot keep old active sessions visible ----
func owned(_ state: String, _ pid: Int, _ ownerKind: String, _ age: TimeInterval = 0) -> SessionState {
    SessionState(state: state, label: "", tool: "", project: "", sessionId: "o", transcript: "", startedAt: 1, pausedTotal: 0, pauseStart: 0, ts: now - age, ownerPid: pid, ownerKind: ownerKind)
}

check(owned("thinking", 4242, "session").endedByOwnerExit(ownerAlive: false), "thinking + dead session owner -> ended")
check(!owned("thinking", 4242, "session").endedByOwnerExit(ownerAlive: true), "thinking + live session owner -> not ended")
check(!owned("thinking", 4242, "global").endedByOwnerExit(ownerAlive: false), "global owner is not a session owner exit")
check(!owned("done", 4242, "session").endedByOwnerExit(ownerAlive: false), "done is never ended by owner exit")
check(!owned("thinking", 0, "unknown").endedByOwnerExit(ownerAlive: false), "unknown owner -> freshness governs")

check(owned("thinking", 4242, "session").isDisplayEligible(now: now, ownerAlive: true), "live session owner keeps active state eligible")
check(!owned("thinking", 4242, "session").isDisplayEligible(now: now, ownerAlive: false), "dead session owner removes active state")
check(owned("tool", 79378, "global", 30).isDisplayEligible(now: now, ownerAlive: true), "recent global owner active state stays briefly visible")
check(!owned("tool", 79378, "global", 61).isDisplayEligible(now: now, ownerAlive: true), "old global owner active state stops displaying")
check(owned("permission", 0, "unknown", 30).isDisplayEligible(now: now, ownerAlive: false), "recent unknown owner active state stays briefly visible")
check(!owned("permission", 0, "unknown", 61).isDisplayEligible(now: now, ownerAlive: false), "old unknown owner active state stops displaying")
check(owned("done", 0, "unknown", 600).isDisplayEligible(now: now, ownerAlive: false), "recent done state remains selectable for done rendering")
check(!owned("done", 0, "unknown", 901).isDisplayEligible(now: now, ownerAlive: false), "stale done state is not selectable")

if let parsedOwner = SessionState(json: ["state": "thinking", "ownerKind": "session", "ownerPid": 123]) {
    eq(parsedOwner.ownerKind, "session", "json ownerKind parses")
    eq(parsedOwner.ownerPid, 123, "json ownerPid parses")
} else {
    check(false, "json with owner fields parses")
}

if let parsedDefaultOwner = SessionState(json: ["state": "thinking"]) {
    eq(parsedDefaultOwner.ownerKind, "unknown", "missing json ownerKind defaults to unknown")
    eq(parsedDefaultOwner.ownerPid, 0, "missing json ownerPid defaults to 0")
} else {
    check(false, "json without owner fields parses")
}

// ---- selectDisplay: pinned wins if alive, else most recent alive, else nil ----
let sA = SessionState(state: "thinking", label: "A", tool: "", project: "A", sessionId: "a", transcript: "", startedAt: 1, pausedTotal: 0, pauseStart: 0, ts: now - 5)
let sB = SessionState(state: "tool", label: "B", tool: "Bash", project: "B", sessionId: "b", transcript: "", startedAt: 1, pausedTotal: 0, pauseStart: 0, ts: now - 1)
let sC = SessionState(state: "idle", label: "", tool: "", project: "C", sessionId: "c", transcript: "", startedAt: 0, pausedTotal: 0, pauseStart: 0, ts: now - 1000) // stale
let doneRecent = SessionState(state: "done", label: "Done", tool: "", project: "D", sessionId: "done-recent", transcript: "", startedAt: 0, pausedTotal: 0, pauseStart: 0, ts: now - 1)
let doneExpired = SessionState(state: "done", label: "Done", tool: "", project: "D", sessionId: "done-expired", transcript: "", startedAt: 0, pausedTotal: 0, pauseStart: 0, ts: now - 1)
let doneStaleNoSentinel = SessionState(state: "done", label: "Done", tool: "", project: "D", sessionId: "done-stale", transcript: "", startedAt: 0, pausedTotal: 0, pauseStart: 0, ts: now - 3)

eq(selectDisplay(pinned: nil, sessions: [sA, sB], now: now)?.sessionId, "b", "most recent wins when no pin")
eq(selectDisplay(pinned: "a", sessions: [sA, sB], now: now)?.sessionId, "a", "pinned wins when alive")
eq(selectDisplay(pinned: "c", sessions: [sA, sB, sC], now: now)?.sessionId, "b", "stale pinned falls back to recent alive")
eq(selectDisplay(pinned: nil, sessions: [sC], now: now).map { $0.sessionId }, .none, "only stale -> nil")
eq(selectDisplay(pinned: nil, sessions: [sA, doneExpired], now: now, doneShownAt: ["done-expired": now - 3])?.sessionId, "a", "expired recent done falls back to older active session")
eq(selectDisplay(pinned: nil, sessions: [sA, doneRecent], now: now, doneShownAt: ["done-recent": now - 1])?.sessionId, "done-recent", "non-expired done still wins by recency")
eq(selectDisplay(pinned: "done-expired", sessions: [sA, doneExpired], now: now, doneShownAt: ["done-expired": now - 3])?.sessionId, "a", "pinned expired done falls back to active session")
eq(selectDisplay(pinned: nil, sessions: [sA, doneStaleNoSentinel], now: now)?.sessionId, "a", "done without sentinel uses state timestamp and does not replay after window")

// ---- installer launch and private log helpers ----
let oddInstaller = "/Applications/Codex \" $(touch /tmp/nope) Status Bar.app/Contents/Resources/install.js"
let installConfig = installerLaunchConfiguration(installer: oddInstaller, environment: ["PATH": "/usr/bin"])
eq(installConfig.executablePath, "/usr/bin/env", "installer runs through env")
eq(installConfig.arguments, ["node", oddInstaller], "installer path stays a literal argument")
check(!(installConfig.arguments.joined(separator: " ").contains("-lc")), "installer launch does not build a shell command")
eq(installConfig.environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin", "installer PATH is augmented")
eq(shellQuoted(oddInstaller), "'/Applications/Codex \" $(touch /tmp/nope) Status Bar.app/Contents/Resources/install.js'", "manual fallback command is single-quoted")

let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("csb-log-\(UUID().uuidString)")
let logPath = logDir.appendingPathComponent("app.log").path
appendPrivateLogLine("one\n", toPath: logPath)
appendPrivateLogLine("two\n", toPath: logPath)
eq((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "", "one\ntwo\n", "private log appends lines")
if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
   let perms = attrs[.posixPermissions] as? NSNumber {
    eq(perms.intValue & 0o777, 0o600, "private log file mode")
} else {
    check(false, "private log permissions readable")
}
try? FileManager.default.removeItem(at: logDir)

// ---- menuOrder: pinned first (if alive), then by ts desc, capped at limit ----
let ordered = menuOrder(pinned: "a", sessions: [sA, sB, sC], now: now, limit: 5)
eq(ordered.count, 2, "stale excluded from menu")
eq(ordered.first?.sessionId, "a", "pinned first")
eq(ordered.last?.sessionId, "b", "non-pinned after, by recency")

let orderedNoPin = menuOrder(pinned: nil, sessions: [sA, sB], now: now, limit: 5)
eq(orderedNoPin.first?.sessionId, "b", "no pin: pure recency")

// cap at 5: pinned counts toward 5
var many: [SessionState] = []
for i in 0..<7 {
    many.append(SessionState(state: "thinking", label: "x", tool: "", project: "p\(i)", sessionId: "s\(i)", transcript: "", startedAt: 1, pausedTotal: 0, pauseStart: 0, ts: now - Double(i)))
}
let capped = menuOrder(pinned: "s3", sessions: many, now: now, limit: 5)
eq(capped.count, 5, "capped at 5")
eq(capped.first?.sessionId, "s3", "pinned stays first within cap")

if failures == 0 { print("ALL OK"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
    }
}
