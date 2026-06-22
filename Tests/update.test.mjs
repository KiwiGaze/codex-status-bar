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

function runHook(home, event, payload) {
  return spawnSync(process.execPath, [HOOK, event], {
    input: JSON.stringify(payload),
    env: { ...process.env, HOME: home },
    encoding: "utf8",
  });
}

function readState(home, sessionId) {
  const p = path.join(home, ".codex", "statusbar", "states.d", sessionId);
  return JSON.parse(fs.readFileSync(p, "utf8"));
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
