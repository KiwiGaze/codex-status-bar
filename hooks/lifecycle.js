#!/usr/bin/env node
// SessionStart lifecycle: launch the menu bar app when a Codex session opens. The
// app quits ITSELF when it's no longer needed (no active session) — see
// main.swift checkLifecycle() — so this never kills the app.
//
// Active sessions are tracked as one file per session id (read from the hook JSON on
// stdin) under sessions.d/. This is race-free: distinct files don't drift under
// concurrency the way a shared counter would. The app counts the files to know a
// session is alive when there's no other process to watch.
// Usage: node lifecycle.js start   (hook JSON, incl. session_id, arrives on stdin)

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const BUNDLE_ID = "io.github.kiwigaze.codexstatusbar";
const EXEC = "CodexStatusBar";
const dir = path.join(os.homedir(), ".codex", "statusbar");
const sessDir = path.join(dir, "sessions.d");
const event = process.argv[2];
const testMode = process.env.CODEX_STATUSBAR_TEST === "1";

fs.mkdirSync(sessDir, { recursive: true });

const running = () => {
  if (testMode) return false; // headless test mode: assume app is down so the purge path runs
  try { cp.execFileSync("pgrep", ["-x", EXEC], { stdio: "ignore" }); return true; } catch { return false; }
};
// Reject the bare "."/".." segments so a crafted session_id can't escape sessions.d via
// path.join normalization.
const safeId = (s) => { const c = String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64); return (!c || c === "." || c === "..") ? "unknown" : c; };

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", () => run());
process.stdin.on("error", () => run());
setTimeout(run, 1000); // hooks always pipe stdin, but never hang the session

function run() {
  if (done) return; done = true;
  let id = "";
  try { id = JSON.parse(input).session_id; } catch {}
  id = safeId(id);

  const statesDir = path.join(dir, "states.d");
  const purgeOlder = (d, maxAge) => {
    try {
      const now = Date.now();
      for (const f of fs.readdirSync(d)) {
        const fp = path.join(d, f);
        const st = fs.statSync(fp);
        if (now - st.mtimeMs > maxAge) fs.rmSync(fp, { force: true });
      }
    } catch {}
  };

  if (event === "start") {
    // If the app isn't running, any leftover session files are stale (e.g. a prior
    // crash) — clear them so the count starts honest.
    if (!running()) {
      try { for (const f of fs.readdirSync(sessDir)) fs.rmSync(path.join(sessDir, f), { force: true }); } catch {}
      purgeOlder(statesDir, 3600_000); // drop state files untouched in the last hour
    }
    try { fs.writeFileSync(path.join(sessDir, id), ""); } catch {}
    if (!testMode) cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
  }
  process.exit(0);
}
