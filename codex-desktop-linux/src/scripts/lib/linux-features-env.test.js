#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const { enabledLinuxFeatureIds } = require("./linux-features.js");

test("direct builds honor CODEX_LINUX_FEATURES when no config file exists", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-linux-features-env-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const previous = {
    CODEX_LINUX_FEATURES: process.env.CODEX_LINUX_FEATURES,
    CODEX_LINUX_DISABLE_FEATURES: process.env.CODEX_LINUX_DISABLE_FEATURES,
    CODEX_LINUX_FEATURES_CONFIG: process.env.CODEX_LINUX_FEATURES_CONFIG,
  };
  t.after(() => {
    for (const [name, value] of Object.entries(previous)) {
      if (value == null) {
        delete process.env[name];
      } else {
        process.env[name] = value;
      }
    }
  });

  delete process.env.CODEX_LINUX_FEATURES_CONFIG;
  process.env.CODEX_LINUX_FEATURES = "read-aloud, open-target-discovery";
  process.env.CODEX_LINUX_DISABLE_FEATURES = "open-target-discovery";

  assert.deepEqual(
    enabledLinuxFeatureIds({ featuresRoot: path.join(root, "linux-features") }),
    ["read-aloud"],
  );
});
