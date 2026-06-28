import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const REPO = path.resolve(import.meta.dirname, "..");
const INSTALL = path.join(REPO, "hooks", "install.js");
const UNINSTALL = path.join(REPO, "hooks", "uninstall.js");
const require = createRequire(import.meta.url);
const { writeFileAtomic } = require(path.join(REPO, "hooks", "fs-utils.js"));

function withTempHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "csb-inst-"));
  return { home, [Symbol.dispose]: () => fs.rmSync(home, { recursive: true, force: true }) };
}

function run(script, home) {
  return spawnSync(process.execPath, [script], {
    env: { ...process.env, HOME: home, CODEX_STATUSBAR_TEST: "1" },
    encoding: "utf8",
  });
}

function readHooks(home) {
  return JSON.parse(fs.readFileSync(path.join(home, ".codex", "hooks.json"), "utf8"));
}

function ourCommands(hooksObj) {
  const out = [];
  for (const arr of Object.values(hooksObj.hooks || {}))
    for (const entry of arr)
      for (const h of entry.hooks || [])
        if ((h.command || "").includes("statusbar")) out.push(h.command);
  return out;
}

const OTHER_HOOKS = { hooks: { Stop: [{ hooks: [{ type: "command", command: "echo other" }] }] } };

function seedHooks(home, obj) {
  const codexDir = path.join(home, ".codex");
  fs.mkdirSync(codexDir, { recursive: true });
  fs.writeFileSync(path.join(codexDir, "hooks.json"), JSON.stringify(obj) + "\n");
  return codexDir;
}

test("install merges our hooks and quotes interpolated paths (M6)", () => {
  using h = withTempHome();
  const r = run(INSTALL, h.home);
  assert.equal(r.status, 0, r.stderr);
  const hooks = readHooks(h.home);
  assert.ok(hooks.hooks.SessionStart?.length, "SessionStart hook added");
  const cmds = ourCommands(hooks);
  assert.ok(cmds.length >= 6, "all status-bar hooks present");
  for (const c of cmds) {
    const quoted = c.match(/"/g) || [];
    assert.ok(quoted.length >= 4, `command must quote node + script path: ${c}`);
  }
});

test("install is idempotent and preserves unrelated hooks", () => {
  using h = withTempHome();
  seedHooks(h.home, OTHER_HOOKS);

  assert.equal(run(INSTALL, h.home).status, 0);
  assert.equal(run(INSTALL, h.home).status, 0);
  const hooks = readHooks(h.home);
  const stopCmds = hooks.hooks.Stop.flatMap((e) => e.hooks).map((h) => h.command);
  assert.ok(stopCmds.includes("echo other"), "unrelated Stop hook preserved");
  assert.equal(ourCommands(hooks).filter((c) => c.includes("update.js")).length, 5,
    "status update hooks present exactly once after double install");
});

test("install creates the .bak-statusbar backup exactly once", () => {
  using h = withTempHome();
  const codexDir = seedHooks(h.home, { hooks: {} });
  run(INSTALL, h.home);
  const bak = path.join(codexDir, "hooks.json.bak-statusbar");
  assert.ok(fs.existsSync(bak), "backup created on first run");
  fs.writeFileSync(bak, "SENTINEL");
  run(INSTALL, h.home);
  assert.equal(fs.readFileSync(bak, "utf8"), "SENTINEL", "backup not overwritten on re-run");
});

test("install writes private hooks config, backups, and copied hook scripts under permissive umask", () => {
  using h = withTempHome();
  seedHooks(h.home, OTHER_HOOKS);
  const priorUmask = process.umask(0o022);
  try {
    const r = run(INSTALL, h.home);
    assert.equal(r.status, 0, r.stderr);
  } finally {
    process.umask(priorUmask);
  }

  const codexDir = path.join(h.home, ".codex");
  const statusDir = path.join(codexDir, "statusbar");
  assert.equal(fs.statSync(statusDir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(path.join(codexDir, "hooks.json")).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.join(codexDir, "hooks.json.bak-statusbar")).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.join(statusDir, "update.js")).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.join(statusDir, "lifecycle.js")).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.join(statusDir, "fs-utils.js")).mode & 0o777, 0o600);
});

test("atomic writer preserves the original file if rename fails and removes temp files", () => {
  using h = withTempHome();
  const target = path.join(h.home, "hooks.json");
  fs.writeFileSync(target, "original", { mode: 0o600 });
  const fsModule = require("node:fs");
  const originalRename = fsModule.renameSync;
  fsModule.renameSync = () => { throw new Error("rename failed"); };
  try {
    assert.throws(() => writeFileAtomic(target, "replacement"), /rename failed/);
  } finally {
    fsModule.renameSync = originalRename;
  }

  assert.equal(fs.readFileSync(target, "utf8"), "original");
  assert.deepEqual(fs.readdirSync(h.home).filter((name) => name.includes(".tmp")), []);

  writeFileAtomic(target, "replacement");
  assert.equal(fs.readFileSync(target, "utf8"), "replacement");
  assert.equal(fs.statSync(target).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(h.home).filter((name) => name.includes(".tmp")), []);
});

test("uninstall removes only our hooks and drops emptied event arrays", () => {
  using h = withTempHome();
  seedHooks(h.home, OTHER_HOOKS);
  const install = run(INSTALL, h.home);
  assert.equal(install.status, 0, install.stderr);
  assert.ok(readHooks(h.home).hooks.SessionStart?.length, "install added SessionStart hook");
  const priorUmask = process.umask(0o022);
  try {
    assert.equal(run(UNINSTALL, h.home).status, 0);
  } finally {
    process.umask(priorUmask);
  }
  const hooks = readHooks(h.home);
  assert.equal(ourCommands(hooks).length, 0, "no status-bar hooks remain");
  assert.ok(!("SessionStart" in hooks.hooks), "emptied SessionStart event removed");
  assert.ok(hooks.hooks.Stop.flatMap((e) => e.hooks).some((h) => h.command === "echo other"),
    "unrelated Stop hook preserved through uninstall");
  assert.equal(fs.statSync(path.join(h.home, ".codex", "hooks.json")).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(path.join(h.home, ".codex")).filter((name) => name.includes(".tmp")), []);
});
