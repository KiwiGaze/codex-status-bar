const fs = require("fs");
const path = require("path");

const PRIVATE_DIR_MODE = 0o700;
const PRIVATE_FILE_MODE = 0o600;

function ensurePrivateDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: PRIVATE_DIR_MODE });
  fs.chmodSync(dir, PRIVATE_DIR_MODE);
}

function writePrivateFile(file, data = "") {
  fs.writeFileSync(file, data, { mode: PRIVATE_FILE_MODE });
  fs.chmodSync(file, PRIVATE_FILE_MODE);
}

function appendPrivateFile(file, data) {
  fs.appendFileSync(file, data, { mode: PRIVATE_FILE_MODE });
  fs.chmodSync(file, PRIVATE_FILE_MODE);
}

function copyPrivateFile(src, dest) {
  fs.copyFileSync(src, dest);
  fs.chmodSync(dest, PRIVATE_FILE_MODE);
}

function writeFileAtomic(file, data, mode = PRIVATE_FILE_MODE) {
  const dir = path.dirname(file);
  const tmp = path.join(dir, `${path.basename(file)}.${process.pid}.${Date.now()}.tmp`);
  let fd;
  try {
    fd = fs.openSync(tmp, "w", mode);
    fs.writeFileSync(fd, data);
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    fs.chmodSync(tmp, mode);
    fs.renameSync(tmp, file);
    fs.chmodSync(file, mode);
  } finally {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch {}
    }
    try { fs.rmSync(tmp, { force: true }); } catch {}
  }
}

module.exports = {
  PRIVATE_DIR_MODE,
  PRIVATE_FILE_MODE,
  ensurePrivateDir,
  writePrivateFile,
  appendPrivateFile,
  copyPrivateFile,
  writeFileAtomic,
};
