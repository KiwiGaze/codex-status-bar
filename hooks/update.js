#!/usr/bin/env node
// Invoked by Codex hooks. Reads the hook JSON payload on stdin, maps the
// event to a status, and atomically writes ~/.codex/statusbar/states.d/<session_id>.json
// (one file per session, so concurrent sessions never overwrite each other).
// Usage: node update.js <prompt|pre|post|permission|stop>

const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".codex", "statusbar");
const sessDir = path.join(dir, "sessions.d");
const statesDir = path.join(dir, "states.d");
const event = process.argv[2] || "";

const TOOL_LABELS = {
  Bash: "Running command", apply_patch: "Editing", read_file: "Reading",
  read: "Reading", view_image: "Viewing", update_plan: "Planning",
  spawn_agent: "Delegating", web_search: "Searching web",
};
const truncate = (s, n) => (s.length <= n ? s : s.slice(0, n));
const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}

  if (process.env.CODEX_STATUSBAR_DEBUG === "1") {
    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.appendFileSync(path.join(dir, "hooks.log"),
        `${new Date().toISOString()} [${event}] tool=${p.tool_name || "-"} mode=${p.permission_mode || "-"} keys=${Object.keys(p).join(",")}\n`);
    } catch {}
  }

  const sessionId = safeId(p.session_id);
  const statePath = path.join(statesDir, sessionId);
  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}

  const project = p.cwd ? path.basename(p.cwd) : prev.project || "";
  const ts = Math.floor(Date.now() / 1000);
  let state = "idle", label = "";
  let startedAt = prev.startedAt || 0;
  let pausedTotal = prev.pausedTotal || 0;
  let pauseStart = prev.pauseStart || 0;

  switch (event) {
    case "prompt":
      state = "thinking"; label = "Thinking…";
      startedAt = ts; pausedTotal = 0; pauseStart = 0;
      break;
    case "pre": {
      const t = p.tool_name || "";
      state = "tool"; label = TOOL_LABELS[t] || (t ? truncate(t, 20) : "Working…");
      if (!startedAt) startedAt = ts;
      break;
    }
    case "post":
      state = "thinking"; label = "Thinking…";
      if (!startedAt) startedAt = ts;
      if (pauseStart > 0) { pausedTotal += (ts - pauseStart); pauseStart = 0; }
      break;
    case "permission":
      state = "permission"; label = "Awaiting permission";
      if (!pauseStart) pauseStart = ts;   // don't overwrite an existing pause window
      break;
    case "stop":
      state = "done"; label = "Done";
      if (pauseStart > 0) { pausedTotal += (ts - pauseStart); }   // close any open pause first
      startedAt = 0; pauseStart = 0;
      break;
    default:
      return;
  }

  const out = {
    state, label, tool: p.tool_name || "", project,
    sessionId: p.session_id || "", transcript: p.transcript_path || prev.transcript || "",
    startedAt, pausedTotal, pauseStart, ts,
  };
  try {
    fs.mkdirSync(statesDir, { recursive: true });
    const tmp = statePath + "." + process.pid + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, statePath);
  } catch {}

  // Refresh the session liveness file (unchanged behavior).
  if (p.session_id) {
    try {
      fs.mkdirSync(sessDir, { recursive: true });
      fs.writeFileSync(path.join(sessDir, safeId(p.session_id)), "");
    } catch {}
  }
});
