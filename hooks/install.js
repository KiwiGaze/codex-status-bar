#!/usr/bin/env node
// Installs the status-bar hooks into ~/.codex/hooks.json (merging, never
// clobbering existing hooks) and copies update.js + lifecycle.js to
// ~/.codex/statusbar/. Re-runnable: existing status-bar hooks are stripped before
// re-adding.

const fs = require("fs");
const os = require("os");
const path = require("path");

const home = os.homedir();
const sbDir = path.join(home, ".codex", "statusbar");
const MARKER = sbDir; // every hook command we add points inside this dir
const updateDest = path.join(sbDir, "update.js");
const lifecycleDest = path.join(sbDir, "lifecycle.js");
const hooksPath = path.join(home, ".codex", "hooks.json");
const node = process.execPath;

fs.mkdirSync(sbDir, { recursive: true });
fs.copyFileSync(path.join(__dirname, "update.js"), updateDest);
fs.copyFileSync(path.join(__dirname, "lifecycle.js"), lifecycleDest);

const cmd = (evt) => `"${node}" "${updateDest}" ${evt}`;
const life = (evt) => `"${node}" "${lifecycleDest}" ${evt}`;

let obj = { hooks: {} };
let backedUp = false;
if (fs.existsSync(hooksPath)) {
  obj = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
  const bak = hooksPath + ".bak-statusbar";
  if (!fs.existsSync(bak)) { fs.copyFileSync(hooksPath, bak); backedUp = true; }
}
obj.hooks = obj.hooks || {};

const stripOurs = (arr) =>
  (arr || [])
    .map((entry) => ({
      ...entry,
      hooks: (entry.hooks || []).filter((h) => !(h.command || "").includes(MARKER)),
    }))
    .filter((entry) => (entry.hooks || []).length > 0);

const addHook = (evt, command, matched = false) => {
  obj.hooks[evt] = stripOurs(obj.hooks[evt]);
  const hook = { type: "command", command };
  obj.hooks[evt].push(matched ? { matcher: "*", hooks: [hook] } : { hooks: [hook] });
};

// Lifecycle hook (launch the app on open; the app quits itself when no longer needed)
addHook("SessionStart", life("start"));
// Status hooks (drive the animation/label)
addHook("UserPromptSubmit", cmd("prompt"));
addHook("PreToolUse", cmd("pre"), true);
addHook("PostToolUse", cmd("post"), true);
addHook("PermissionRequest", cmd("permission"));
addHook("Stop", cmd("stop"));

fs.writeFileSync(hooksPath, JSON.stringify({ hooks: obj.hooks }, null, 2) + "\n");
console.log("Installed status-bar hooks into", hooksPath);
console.log("Scripts:", updateDest, "and", lifecycleDest);
if (backedUp) console.log("Backup (first run only):", hooksPath + ".bak-statusbar");
console.log("");
console.log("IMPORTANT: Codex reviews command hooks before running them. Start Codex once");
console.log("(`codex`) and APPROVE the Codex Status Bar hooks in the startup review — the");
console.log("indicator stays idle until you do. After an app update that changes the hooks,");
console.log("approve again.");
