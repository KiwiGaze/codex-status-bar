import Foundation

// Standalone assertion harness. Compiled WITHOUT main.swift so it does not launch the GUI.
// Build: swiftc Tests/logic_tests.swift Sources/SessionState.swift -o "$TMPDIR/csbt"
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

// ---- selectDisplay: pinned wins if alive, else most recent alive, else nil ----
let sA = SessionState(state: "thinking", label: "A", tool: "", project: "A", sessionId: "a", transcript: "", startedAt: 1, pausedTotal: 0, pauseStart: 0, ts: now - 5)
let sB = SessionState(state: "tool", label: "B", tool: "Bash", project: "B", sessionId: "b", transcript: "", startedAt: 1, pausedTotal: 0, pauseStart: 0, ts: now - 1)
let sC = SessionState(state: "idle", label: "", tool: "", project: "C", sessionId: "c", transcript: "", startedAt: 0, pausedTotal: 0, pauseStart: 0, ts: now - 1000) // stale

eq(selectDisplay(pinned: nil, sessions: [sA, sB], now: now)?.sessionId, "b", "most recent wins when no pin")
eq(selectDisplay(pinned: "a", sessions: [sA, sB], now: now)?.sessionId, "a", "pinned wins when alive")
eq(selectDisplay(pinned: "c", sessions: [sA, sB, sC], now: now)?.sessionId, "b", "stale pinned falls back to recent alive")
eq(selectDisplay(pinned: nil, sessions: [sC], now: now).map { $0.sessionId }, .none, "only stale -> nil")

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
