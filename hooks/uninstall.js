#!/usr/bin/env node
// Removes the status-bar hooks from ~/.codex/hooks.json. Leaves all other hooks intact.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const home = os.homedir();
// Match every hook command we added: they all point inside ~/.codex/statusbar/
// (update.js AND lifecycle.js). Never matches unrelated hooks.
const MARKER = path.join(home, ".codex", "statusbar");
const hooksPath = path.join(home, ".codex", "hooks.json");

try { cp.execFileSync("pkill", ["-x", "CodexStatusBar"], { stdio: "ignore" }); } catch {}

if (!fs.existsSync(hooksPath)) { console.log("No hooks.json; nothing to do."); process.exit(0); }

const obj = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
for (const evt of Object.keys(obj.hooks || {})) {
  obj.hooks[evt] = (obj.hooks[evt] || [])
    .map((e) => ({ ...e, hooks: (e.hooks || []).filter((h) => !(h.command || "").includes(MARKER)) }))
    .filter((e) => (e.hooks || []).length > 0);
  if (obj.hooks[evt].length === 0) delete obj.hooks[evt];
}
fs.writeFileSync(hooksPath, JSON.stringify({ hooks: obj.hooks }, null, 2) + "\n");
console.log("Removed status-bar hooks from", hooksPath);
