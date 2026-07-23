#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const {
  enabledLinuxFeatureIds,
  enabledLinuxFeatureInstallPlan,
  loadLinuxFeaturePatchDescriptors,
} = require("../../scripts/lib/linux-features.js");
const { applyBrowserRelayMainPatch, descriptors } = require("./patch.js");

function withFeatureConfig(enabled, callback) {
  const original = process.env.CODEX_LINUX_FEATURES_CONFIG;
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "codex-browser-rehost-feature-"));
  process.env.CODEX_LINUX_FEATURES_CONFIG = path.join(temp, "features.json");
  fs.writeFileSync(process.env.CODEX_LINUX_FEATURES_CONFIG, JSON.stringify({ enabled }));
  try {
    return callback(path.resolve(__dirname, ".."));
  } finally {
    if (original == null) delete process.env.CODEX_LINUX_FEATURES_CONFIG;
    else process.env.CODEX_LINUX_FEATURES_CONFIG = original;
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

const syntheticMain = [
  'let e=require("electron"),p=require("node:path");',
  'let z={isTrustedIpcSender(){return true},async ensureWindow(){return {}},getPrimaryWindow(){return {}},getContextForWebContents(){return {}}},B=e=>z.isTrustedIpcSender(e.sender,e.senderFrame??null);',
  'async function start(){await e.app.whenReady();install({getContextForWebContents:z.getContextForWebContents,getPrimaryWindow:z.getPrimaryWindow});',
  'let Re=await z.ensureWindow();Re&&show(Re);return true}',
  'exports.runMainAppStartup=start;',
].join("");

const currentElectron42Main = [
  'const a=require("./src-C7E6KJ89.js"),l=require("electron");',
  'async function start(){let F=Date.now();await l.app.whenReady(),A(`main app.whenReady resolved`,F);',
  'let z={isTrustedIpcSender(){return true},async ensureWindow(){return {}},getPrimaryWindow(){return {}},getContextForWebContents(){return {}}},B=e=>z.isTrustedIpcSender(e.sender,e.senderFrame??null);',
  'install({getContextForWebContents:z.getContextForWebContents,getPrimaryWindow:z.getPrimaryWindow});',
  'let Re=await z.ensureWindow();Re&&show(Re),await Dy()}',
].join("");

test("browser rehost feature stays disabled until explicitly enabled", () => {
  withFeatureConfig([], (root) => {
    assert.deepEqual(enabledLinuxFeatureIds({ featuresRoot: root }), []);
    assert.deepEqual(loadLinuxFeaturePatchDescriptors({ featuresRoot: root }), []);
  });
});

test("browser rehost feature stages relay assets and one main descriptor", () => {
  withFeatureConfig(["browser-rehost"], (root) => {
    assert.deepEqual(enabledLinuxFeatureIds({ featuresRoot: root }), ["browser-rehost"]);
    const plan = enabledLinuxFeatureInstallPlan({ featuresRoot: root });
    assert.deepEqual(
      plan.resources.map((resource) => [resource.source.endsWith(resource.target.split("/").pop()), resource.target, resource.mode]),
      [
        [true, ".codex-linux/features/browser-rehost/browser-relay.html", 0o644],
        [true, ".codex-linux/features/browser-rehost/browser-relay.js", 0o644],
      ],
    );
    const patches = loadLinuxFeaturePatchDescriptors({ featuresRoot: root });
    assert.deepEqual(
      patches.map((patch) => [patch.name, patch.phase, patch.ciPolicy]),
      [["feature:browser-rehost:browser-relay-main", "main-bundle", "required-upstream"]],
    );
  });
});

test("browser relay main patch is idempotent and fail-soft on drift", () => {
  const patched = applyBrowserRelayMainPatch(syntheticMain);
  assert.match(patched, /codexLinuxStartBrowserRelay/);
  assert.match(patched, /browser-relay\.html/);
  assert.match(patched, /CODEX_LINUX_BROWSER_GATEWAY_URL/);
  assert.equal(applyBrowserRelayMainPatch(patched), patched);
  assert.equal(applyBrowserRelayMainPatch("unrelated bundle"), "unrelated bundle");
});

test("browser relay main patch accepts the Electron 42 compressed ready expression", () => {
  const patched = applyBrowserRelayMainPatch(currentElectron42Main);

  assert.match(patched, /codexLinuxStartBrowserRelay/);
  assert.match(patched, /let Re=await z\.ensureWindow\(\);codexLinuxStartBrowserRelay\(z\);Re&&/);
  assert.doesNotMatch(patched, /app\.whenReady\(\),codexLinuxStartBrowserRelay\(\)/);
  assert.match(
    patched,
    /windowManager\?\.registerAuxiliaryWindow\?\.\(o,`browserRelay`,`register`\)/,
  );
  assert.match(
    patched,
    /B=e=>codexLinuxIsBrowserRelaySender\(e\)\|\|z\.isTrustedIpcSender\(e\.sender,e\.senderFrame\?\?null\)/,
  );
  assert.match(
    patched,
    /getContextForWebContents:e=>codexLinuxIsBrowserRelaySender\(\{sender:e\}\)\?z\.getContextForWebContents\(z\.getPrimaryWindow\(\)\?\.webContents\):z\.getContextForWebContents\(e\)/,
  );
  assert.doesNotThrow(() => new Function(patched));
});

test("browser relay assets do not expose credentials or enable node integration", () => {
  const html = fs.readFileSync(path.join(__dirname, "browser-relay.html"), "utf8");
  const script = fs.readFileSync(path.join(__dirname, "browser-relay.js"), "utf8");
  const main = applyBrowserRelayMainPatch(syntheticMain);
  assert.match(html, /browser-relay\.js/);
  assert.match(main, /contextIsolation:!0,nodeIntegration:!1/);
  assert.match(main, /preload:\(0,[A-Za-z_$][\w$]*\.join\)\(__dirname,`preload\.js`\)/);
  assert.match(script, /appHostPort\.postMessage\(message\.payload\)/);
  assert.match(script, /sendWorkerMessageFromView/);
  assert.match(script, /unsubscribeFromWorkerMessages/);
  assert.match(script, /sendMessageFromView\(\{ type: "ready" \}\)/);
  assert.match(script, /message\.type === "gateway-browser-session-started"/);
  assert.match(script, /appHostPort\.postMessage\(null\)/);
  assert.doesNotMatch(script, /window\.postMessage\(message\.payload/);
  assert.doesNotMatch(script, /OPENAI_API_KEY|auth\.json|Cookie/i);
});
