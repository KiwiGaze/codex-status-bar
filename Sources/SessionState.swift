import Foundation

// Pure data + pure logic for the status-bar state model. Foundation-only so it can be
// unit-tested by compiling alongside Tests/logic_tests.swift WITHOUT main.swift (which
// would otherwise launch the GUI via `app.run()`).

struct SessionState {
    var state: String       // thinking | tool | permission | done | idle
    var label: String
    var tool: String
    var project: String
    var sessionId: String
    var transcript: String
    var startedAt: TimeInterval   // unix seconds the current turn began; 0 = no clock
    var pausedTotal: TimeInterval // seconds already spent awaiting permission this turn
    var pauseStart: TimeInterval  // unix seconds the current pause began; 0 = not paused
    var ts: TimeInterval          // unix seconds the writer last touched this file
    var ownerPid: Int = 0
    var ownerKind: String = "unknown"

    /// A session counts as alive while its writer has updated it within this window.
    /// Mirrors the 900s safety net in main.swift's evaluate().
    static let staleAfter: TimeInterval = 900
    static let unreliableOwnerDisplayAfter: TimeInterval = 60
}

extension SessionState {
    init?(json: [String: Any]) {
        guard let state = json["state"] as? String else { return nil }
        self.state = state
        self.label = (json["label"] as? String) ?? ""
        self.tool = (json["tool"] as? String) ?? ""
        self.project = (json["project"] as? String) ?? ""
        self.sessionId = (json["sessionId"] as? String) ?? ""
        self.transcript = (json["transcript"] as? String) ?? ""
        self.startedAt = (json["startedAt"] as? NSNumber)?.doubleValue ?? 0
        self.pausedTotal = (json["pausedTotal"] as? NSNumber)?.doubleValue ?? 0
        self.pauseStart = (json["pauseStart"] as? NSNumber)?.doubleValue ?? 0
        self.ts = (json["ts"] as? NSNumber)?.doubleValue ?? 0
        self.ownerPid = (json["ownerPid"] as? NSNumber)?.intValue ?? 0
        self.ownerKind = (json["ownerKind"] as? String) ?? "unknown"
    }

    func isAlive(now: TimeInterval) -> Bool {
        now - ts <= SessionState.staleAfter
    }

    func hasReliableOwner() -> Bool {
        ownerKind == "session" && ownerPid > 0
    }

    func isDisplayEligible(now: TimeInterval, ownerAlive: Bool) -> Bool {
        guard isAlive(now: now) else { return false }
        switch state {
        case "thinking", "tool", "permission":
            if hasReliableOwner() { return ownerAlive }
            return now - ts <= SessionState.unreliableOwnerDisplayAfter
        default:
            return true
        }
    }

    func endedByOwnerExit(ownerAlive: Bool) -> Bool {
        guard hasReliableOwner() else { return false }
        switch state {
        case "thinking", "tool", "permission": return !ownerAlive
        default: return false
        }
    }
}

/// Net working time for the current turn, subtracting accumulated + in-progress pauses.
/// Pure. Returns 0 when there is no clock (startedAt == 0) or the inputs are non-sensical.
func elapsedSeconds(now: TimeInterval, startedAt: TimeInterval, pausedTotal: TimeInterval, pauseStart: TimeInterval) -> Int {
    guard startedAt > 0 else { return 0 }
    var elapsed = now - startedAt - pausedTotal
    if pauseStart > 0 { elapsed -= (now - pauseStart) }
    return max(0, Int(elapsed))
}

/// Decide which session to render in the single menu-bar slot.
/// Priority: pinned (if alive) → most-recently-updated alive → none.
///
/// Tradeoff (spec §8 "文档明示"): when two or more sessions are active and none is
/// pinned, the slot follows the most recently written session. Fast interleaved writes
/// therefore make the displayed session jump between ticks — an inherent cost of the
/// click-to-pin model; pinning is the escape hatch when stable focus is needed.
/// Pure.
func selectDisplay(pinned: String?, sessions: [SessionState], now: TimeInterval) -> SessionState? {
    let alive = sessions.filter { $0.isAlive(now: now) }
    if let p = pinned, let match = alive.first(where: { $0.sessionId == p }) {
        return match
    }
    return alive.max(by: { $0.ts < $1.ts })
}

/// Build the ordered list of sessions for the dropdown menu.
/// Pinned (if alive) is always first and counts toward `limit`; remaining slots fill by
/// most-recent ts. Stale sessions are excluded. Pure.
func menuOrder(pinned: String?, sessions: [SessionState], now: TimeInterval, limit: Int) -> [SessionState] {
    var alive = sessions.filter { $0.isAlive(now: now) }
    var result: [SessionState] = []
    if let p = pinned, let idx = alive.firstIndex(where: { $0.sessionId == p }) {
        result.append(alive.remove(at: idx))
    }
    alive.sort { $0.ts > $1.ts }
    while result.count < limit, !alive.isEmpty {
        result.append(alive.removeFirst())
    }
    return result
}
