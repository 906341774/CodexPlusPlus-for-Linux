"use strict";

const fs = require("node:fs");
const path = require("node:path");

const INITIALIZE_TIMEOUT_MESSAGE = "Codex app-server initialize handshake timed out";
const INITIALIZE_TIMEOUT_SIGNATURE =
  /([A-Za-z_$][\w$]*)=3e4,([A-Za-z_$][\w$]*)=3e4,([A-Za-z_$][\w$]*)=9e4,([A-Za-z_$][\w$]*)=`Codex app-server initialize handshake timed out`/u;
const PATCHED_INITIALIZE_TIMEOUT_SIGNATURE =
  /([A-Za-z_$][\w$]*)=12e4,([A-Za-z_$][\w$]*)=3e4,([A-Za-z_$][\w$]*)=9e4,([A-Za-z_$][\w$]*)=`Codex app-server initialize handshake timed out`/u;

function applyLinuxAppServerInitializeTimeoutPatch(currentSource) {
  if (PATCHED_INITIALIZE_TIMEOUT_SIGNATURE.test(currentSource)) {
    return currentSource;
  }

  const matches = currentSource.match(
    new RegExp(INITIALIZE_TIMEOUT_SIGNATURE.source, "gu"),
  ) ?? [];
  if (matches.length === 1) {
    return currentSource.replace(
      INITIALIZE_TIMEOUT_SIGNATURE,
      (_match, initializeTimeout, adjacentTimeout, reconnectTimeout, message) =>
        `${initializeTimeout}=12e4,${adjacentTimeout}=3e4,${reconnectTimeout}=9e4,${message}=\`${INITIALIZE_TIMEOUT_MESSAGE}\``,
    );
  }

  if (currentSource.includes(INITIALIZE_TIMEOUT_MESSAGE)) {
    console.warn(
      "WARN: Could not find the app-server initialize handshake timeout signature - refusing a broad timeout rewrite",
    );
  }
  return currentSource;
}

function patchLinuxAppServerInitializeTimeoutAssets(extractedDir) {
  const buildDir = path.join(extractedDir, ".vite", "build");
  if (!fs.existsSync(buildDir)) {
    console.warn(
      `WARN: Could not find main-process build chunks in ${buildDir} - app-server initialize timeout was not extended`,
    );
    return { matched: 0, changed: 0 };
  }

  const candidates = fs.readdirSync(buildDir)
    .filter((name) => name.endsWith(".js"))
    .sort()
    .map((name) => path.join(buildDir, name))
    .filter((filePath) => fs.readFileSync(filePath, "utf8").includes(INITIALIZE_TIMEOUT_MESSAGE));

  if (candidates.length !== 1) {
    console.warn(
      `WARN: Expected exactly one app-server initialize handshake timeout bundle, found ${candidates.length} - refusing an ambiguous timeout rewrite`,
    );
    return { matched: candidates.length, changed: 0 };
  }

  const target = candidates[0];
  const source = fs.readFileSync(target, "utf8");
  const patched = applyLinuxAppServerInitializeTimeoutPatch(source);
  if (patched === source) {
    return { matched: 1, changed: 0 };
  }
  fs.writeFileSync(target, patched, "utf8");
  return { matched: 1, changed: 1 };
}

module.exports = {
  applyLinuxAppServerInitializeTimeoutPatch,
  patchLinuxAppServerInitializeTimeoutAssets,
};
