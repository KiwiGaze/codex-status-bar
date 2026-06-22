#!/usr/bin/env node
// Invoked by Codex hooks. Reads the hook JSON payload on stdin, maps the
// event to a status, and atomically writes ~/.codex/statusbar/state.json.
// Usage: node update.js <prompt|pre|post|permission|stop>

const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".codex", "statusbar");
const sessDir = path.join(dir, "sessions.d");
const statePath = path.join(dir, "state.json");
const event = process.argv[2] || "";

const TOOL_LABELS = {
  Bash: "Running command", apply_patch: "Editing", read_file: "Reading",
  read: "Reading", view_image: "Viewing", update_plan: "Planning",
  spawn_agent: "Delegating", web_search: "Searching web",
};

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}

  // Optional debug log of every hook invocation (event, tool, mode, payload keys).
  // Off by default; enable with CODEX_STATUSBAR_DEBUG=1 to inspect what fires.
  if (process.env.CODEX_STATUSBAR_DEBUG === "1") {
    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.appendFileSync(path.join(dir, "hooks.log"),
        `${new Date().toISOString()} [${event}] tool=${p.tool_name || "-"} mode=${p.permission_mode || "-"} keys=${Object.keys(p).join(",")}\n`);
    } catch {}
  }

  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}

  const project = p.cwd ? path.basename(p.cwd) : prev.project || "";
  const ts = Math.floor(Date.now() / 1000);
  let state = "idle", label = "", startedAt = prev.startedAt || 0;

  switch (event) {
    case "prompt":
      state = "thinking"; label = "Thinking…"; startedAt = ts; break;
    case "pre": {
      const t = p.tool_name || "";
      // Known tools get a friendly verb; everything else collapses to a generic
      // "Using tool".
      state = "tool"; label = TOOL_LABELS[t] || "Using tool";
      if (!startedAt) startedAt = ts;
      break;
    }
    case "post":
      state = "thinking"; label = "Thinking…";
      if (!startedAt) startedAt = ts;
      break;
    case "permission":
      state = "permission"; label = "Awaiting permission"; startedAt = 0; break;
    case "stop":
      state = "done"; label = "Done"; startedAt = 0; break;
    default:
      return;
  }

  const out = { state, label, tool: p.tool_name || "", project, sessionId: p.session_id || "", transcript: p.transcript_path || prev.transcript || "", startedAt, ts };
  try {
    fs.mkdirSync(dir, { recursive: true });
    const tmp = statePath + "." + process.pid + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, statePath);
  } catch {}

  // Refresh the session file mtime so the app's freshness check stays accurate
  // while a session is active.
  if (p.session_id) {
    try {
      fs.mkdirSync(sessDir, { recursive: true });
      fs.writeFileSync(path.join(sessDir, safeId(p.session_id)), "");
    } catch {}
  }
});
