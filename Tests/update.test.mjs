import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const REPO = path.resolve(import.meta.dirname, "..");
const HOOK = path.join(REPO, "hooks", "update.js");

function withTempHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "csb-"));
  return { home, [Symbol.dispose]: () => fs.rmSync(home, { recursive: true, force: true }) };
}

function runHook(home, event, payload, extraEnv = {}) {
  return spawnSync(process.execPath, [HOOK, event], {
    input: JSON.stringify(payload),
    env: { ...process.env, HOME: home, ...extraEnv },
    encoding: "utf8",
  });
}

function readState(home, sessionId) {
  const p = path.join(home, ".codex", "statusbar", "states.d", sessionId);
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

function writeFakePs(home, output) {
  const bin = path.join(home, "bin");
  fs.mkdirSync(bin, { recursive: true });
  const ps = path.join(bin, "ps");
  fs.writeFileSync(ps, `#!/bin/sh\nprintf '%s\\n' '${output}'\n`);
  fs.chmodSync(ps, 0o755);
  return bin;
}

test("prompt writes per-session file with paused fields reset", () => {
  using h = withTempHome();
  const r = runHook(h.home, "prompt", { session_id: "sess-a", cwd: "/proj/foo" });
  assert.equal(r.status, 0);
  const s = readState(h.home, "sess-a");
  assert.equal(s.state, "thinking");
  assert.equal(s.label, "Thinking…");
  assert.equal(s.pausedTotal, 0);
  assert.equal(s.pauseStart, 0);
  assert.ok(s.startedAt > 0);
});

test("prompt records owner pid and owner kind fields", () => {
  using h = withTempHome();
  runHook(h.home, "prompt", { session_id: "own-1", cwd: "/p" });
  const s = readState(h.home, "own-1");
  assert.equal(typeof s.ownerPid, "number", "ownerPid is written as a number");
  assert.ok(s.ownerPid >= 0, "ownerPid is non-negative");
  assert.equal(typeof s.ownerKind, "string", "ownerKind is written as a string");
  assert.match(s.ownerKind, /^(session|global|unknown)$/);
});

test("app-server owner is recorded as global", () => {
  using h = withTempHome();
  runHook(h.home, "prompt", { session_id: "global-1", cwd: "/p" }, {
    CODEX_STATUSBAR_TEST: "1",
    CODEX_STATUSBAR_TEST_OWNER_PID: "1234",
    CODEX_STATUSBAR_TEST_OWNER_ARGS: "/Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled",
  });
  const s = readState(h.home, "global-1");
  assert.equal(s.ownerPid, 1234);
  assert.equal(s.ownerKind, "global");
});

test("plain codex owner is recorded as session", () => {
  using h = withTempHome();
  runHook(h.home, "prompt", { session_id: "session-1", cwd: "/p" }, {
    CODEX_STATUSBAR_TEST: "1",
    CODEX_STATUSBAR_TEST_OWNER_PID: "2345",
    CODEX_STATUSBAR_TEST_OWNER_ARGS: "codex --sandbox workspace-write",
  });
  const s = readState(h.home, "session-1");
  assert.equal(s.ownerPid, 2345);
  assert.equal(s.ownerKind, "session");
});

test("forced owner env is ignored outside test mode", () => {
  using h = withTempHome();
  const bin = writeFakePs(h.home, "1 codex codex --sandbox workspace-write");
  runHook(h.home, "prompt", { session_id: "guard-1", cwd: "/p" }, {
    CODEX_STATUSBAR_TEST_OWNER_PID: "9999",
    CODEX_STATUSBAR_TEST_OWNER_ARGS: "/Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled",
    PATH: `${bin}${path.delimiter}${process.env.PATH}`,
  });
  const s = readState(h.home, "guard-1");
  assert.notEqual(s.ownerPid, 9999);
  assert.equal(s.ownerKind, "session");
});

test("ps owner output records app-server owner as global", () => {
  using h = withTempHome();
  const bin = writeFakePs(h.home, "1 codex /Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled");
  runHook(h.home, "prompt", { session_id: "ps-global-1", cwd: "/p" }, {
    PATH: `${bin}${path.delimiter}${process.env.PATH}`,
  });
  const s = readState(h.home, "ps-global-1");
  assert.equal(s.ownerKind, "global");
});

test("two sessions do not overwrite each other", () => {
  using h = withTempHome();
  runHook(h.home, "prompt", { session_id: "sess-a", cwd: "/proj/a" });
  runHook(h.home, "prompt", { session_id: "sess-b", cwd: "/proj/b" });
  assert.equal(readState(h.home, "sess-a").project, "a");
  assert.equal(readState(h.home, "sess-b").project, "b");
});

test("permission sets pauseStart without clearing startedAt", () => {
  using h = withTempHome();
  runHook(h.home, "prompt", { session_id: "s1", cwd: "/p" });
  const startedAt = readState(h.home, "s1").startedAt;
  runHook(h.home, "permission", { session_id: "s1" });
  const s = readState(h.home, "s1");
  assert.equal(s.state, "permission");
  assert.equal(s.startedAt, startedAt, "startedAt must be preserved");
  assert.ok(s.pauseStart >= startedAt, "pauseStart set");
});

test("post after permission accumulates pausedTotal and clears pauseStart", () => {
  using h = withTempHome();
  runHook(h.home, "prompt", { session_id: "s1", cwd: "/p" });
  const t0 = readState(h.home, "s1").startedAt;
  runHook(h.home, "permission", { session_id: "s1" });
  // simulate a 5s pause that already elapsed: backdate pauseStart INTO THE PAST
  // (post computes pausedTotal += ts - pauseStart, so pauseStart must be < post's ts)
  const raw = readState(h.home, "s1");
  raw.pauseStart = t0 - 5;
  fs.writeFileSync(path.join(h.home, ".codex", "statusbar", "states.d", "s1"), JSON.stringify(raw));
  runHook(h.home, "post", { session_id: "s1" });
  const s = readState(h.home, "s1");
  assert.equal(s.pauseStart, 0);
  assert.ok(s.pausedTotal >= 5, `pausedTotal>=5, got ${s.pausedTotal}`);
});

test("unknown tool shows truncated tool name, not 'Using tool'", () => {
  using h = withTempHome();
  runHook(h.home, "pre", { session_id: "s1", tool_name: "some_custom_tool" });
  assert.equal(readState(h.home, "s1").label, "some_custom_tool");
});

test("known tool still maps to friendly label", () => {
  using h = withTempHome();
  runHook(h.home, "pre", { session_id: "s1", tool_name: "Bash" });
  assert.equal(readState(h.home, "s1").label, "Running command");
});

test("long tool name is truncated to 20 chars", () => {
  using h = withTempHome();
  const long = "x".repeat(50);
  runHook(h.home, "pre", { session_id: "s1", tool_name: long });
  const label = readState(h.home, "s1").label;
  assert.equal(label.length, 20);
});

test("stop writes done with startedAt cleared", () => {
  using h = withTempHome();
  runHook(h.home, "prompt", { session_id: "s1", cwd: "/p" });
  runHook(h.home, "stop", { session_id: "s1" });
  const s = readState(h.home, "s1");
  assert.equal(s.state, "done");
  assert.equal(s.startedAt, 0);
  assert.equal(s.pauseStart, 0);
});

test("post without a preceding permission leaves pausedTotal at 0", () => {
  using h = withTempHome();
  runHook(h.home, "prompt", { session_id: "s1", cwd: "/p" });
  const t0 = readState(h.home, "s1").startedAt;
  runHook(h.home, "post", { session_id: "s1" });
  const s = readState(h.home, "s1");
  assert.equal(s.pauseStart, 0, "pauseStart stays 0");
  assert.equal(s.pausedTotal, 0, "pausedTotal stays 0 when no pause occurred");
  assert.equal(s.startedAt, t0, "turn start preserved");
});

test("lifecycle start purges states.d files older than 1h when app not running", () => {
  using h = withTempHome();
  const statesDir = path.join(h.home, ".codex", "statusbar", "states.d");
  fs.mkdirSync(statesDir, { recursive: true });
  // stale file (>1h)
  const stale = path.join(statesDir, "old");
  fs.writeFileSync(stale, "{}");
  const old = Date.now() / 1000 - 3700;
  fs.utimesSync(stale, old, old);
  // fresh file
  const fresh = path.join(statesDir, "fresh");
  fs.writeFileSync(fresh, "{}");

  const life = path.join(REPO, "hooks", "lifecycle.js");
  const r = spawnSync(process.execPath, [life, "start"], {
    input: JSON.stringify({ session_id: "new-sess" }),
    env: { ...process.env, HOME: h.home, CODEX_STATUSBAR_TEST: "1" },
    encoding: "utf8",
  });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(!fs.existsSync(stale), "stale state file should be removed");
  assert.ok(fs.existsSync(fresh), "fresh state file should be kept");
});

test("path-traversal session_id (\"..\" / \".\") is sanitized to a safe filename", () => {
  using h = withTempHome();
  const statesDir = path.join(h.home, ".codex", "statusbar", "states.d");

  runHook(h.home, "prompt", { session_id: "..", cwd: "/p" });
  runHook(h.home, "prompt", { session_id: ".", cwd: "/p" });

  const names = fs.readdirSync(statesDir);
  // Must never materialize the bare traversal segments as on-disk names, and must
  // not escape states.d (the parent dir must contain no new stray files).
  assert.ok(!names.includes(".."), "id '..' must not write to the parent dir");
  assert.ok(!names.includes("."), "id '.' must not alias the states.d dir");
  assert.ok(names.includes("unknown"), "traversal ids sanitized to 'unknown'");

  // The RAW id is still preserved in the JSON content for display/pin (only the
  // filename used as the dict key is sanitized).
  const s = JSON.parse(fs.readFileSync(path.join(statesDir, "unknown"), "utf8"));
  assert.ok(s.sessionId === ".." || s.sessionId === ".", "raw id preserved in content");
});

test("status directories, state files, session files, and debug logs are private under permissive umask", () => {
  using h = withTempHome();
  const priorUmask = process.umask(0o022);
  try {
    const r = runHook(h.home, "prompt", { session_id: "perm-1", cwd: "/p" }, {
      CODEX_STATUSBAR_DEBUG: "1",
    });
    assert.equal(r.status, 0, r.stderr);
  } finally {
    process.umask(priorUmask);
  }

  const statusDir = path.join(h.home, ".codex", "statusbar");
  const statesDir = path.join(statusDir, "states.d");
  const sessionsDir = path.join(statusDir, "sessions.d");
  const stateFile = path.join(statesDir, "perm-1");
  const sessionFile = path.join(sessionsDir, "perm-1");
  const hooksLog = path.join(statusDir, "hooks.log");

  assert.equal(fs.statSync(statusDir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(statesDir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(sessionsDir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(stateFile).mode & 0o777, 0o600);
  assert.equal(fs.statSync(sessionFile).mode & 0o777, 0o600);
  assert.equal(fs.statSync(hooksLog).mode & 0o777, 0o600);
});
