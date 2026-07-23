"use strict";

const { inferModuleAlias } = require("../../scripts/patches/lib/minified-js.js");

const PATCH_MARKER = "codexLinuxBrowserRelayFeatureV1";

function browserRelayHelperSource(electronVar) {
  return (
    `function codexLinuxIsBrowserRelaySender(e){let t=globalThis.codexLinuxBrowserRelayWindow;return process.platform===\`linux\`&&t!=null&&!t.isDestroyed()&&e?.sender===t.webContents}function codexLinuxStartBrowserRelay(w){if(process.platform!==\`linux\`||globalThis.${PATCH_MARKER}===!0)return;let e=String(process.env.CODEX_LINUX_BROWSER_GATEWAY_URL??\`\`).trim(),t=String(process.env.CODEX_LINUX_BROWSER_RELAY_TOKEN??\`\`).trim();if(!e||!t)return;globalThis.${PATCH_MARKER}=!0;let n=require(\`node:fs\`),r=require(\`node:path\`),i=(0,r.join)(process.resourcesPath,\`..\`),a=(0,r.join)(i,\`.codex-linux\`,\`features\`,\`browser-rehost\`,\`browser-relay.html\`);if(!n.existsSync(a)){globalThis.${PATCH_MARKER}=!1;return}let o=new ${electronVar}.BrowserWindow({show:!1,skipTaskbar:!0,width:1280,height:900,webPreferences:{preload:(0,r.join)(__dirname,\`preload.js\`),contextIsolation:!0,nodeIntegration:!1,sandbox:!1}});globalThis.codexLinuxBrowserRelayWindow=o;w?.windowManager?.registerAuxiliaryWindow?.(o,\`browserRelay\`,\`register\`);let s=JSON.stringify({gatewayUrl:e,relayToken:t});o.loadFile(a).then(()=>o.webContents.executeJavaScript(\`window.codexLinuxBrowserRelayStart(\${s})\`,!0)).catch(e=>{console.warn(\`[codex-linux-browser] relay start failed: \${e?.message??e}\`);try{o.destroy()}catch{}});${electronVar}.app.once(\`before-quit\`,()=>{try{o.isDestroyed()||o.destroy()}catch{}})}`
  );
}

function applyBrowserRelayMainPatch(currentSource) {
  if (currentSource.includes(PATCH_MARKER)) return currentSource;

  const electronVar =
    currentSource.match(/([A-Za-z_$][\w$]*)\.app\.whenReady\(\)/)?.[1] ??
    inferModuleAlias(currentSource, "electron") ??
    currentSource.match(/(?:let|const|var)\s+([A-Za-z_$][\w$]*)\s*=\s*require\([`"']electron[`"']\)/)?.[1];
  if (electronVar == null) {
    console.warn("WARN: Could not find Electron alias - skipping browser relay patch");
    return currentSource;
  }

  const readyNeedle = `${electronVar}.app.whenReady()`;
  const readyIndex = currentSource.indexOf(readyNeedle);
  if (readyIndex < 0) {
    console.warn("WARN: Could not find Electron app ready point - skipping browser relay patch");
    return currentSource;
  }
  const startupMatch = currentSource.match(
    /let ([A-Za-z_$][\w$]*)=await ([A-Za-z_$][\w$]*)\.ensureWindow\(\);\1&&/,
  );
  if (startupMatch == null) {
    console.warn("WARN: Could not find primary window startup point - skipping browser relay patch");
    return currentSource;
  }
  const windowServicesVar = startupMatch[2];
  const contextNeedle = `getContextForWebContents:${windowServicesVar}.getContextForWebContents,getPrimaryWindow:${windowServicesVar}.getPrimaryWindow`;
  if (!currentSource.includes(contextNeedle)) {
    console.warn("WARN: Could not find primary window context mapping - skipping browser relay patch");
    return currentSource;
  }
  const trustMatch = currentSource.match(
    /([A-Za-z_$][\w$]*)=e=>([A-Za-z_$][\w$]*)\.isTrustedIpcSender\(e\.sender,e\.senderFrame\?\?null\)/,
  );
  if (trustMatch == null) {
    console.warn("WARN: Could not find Electron trusted sender predicate - skipping browser relay patch");
    return currentSource;
  }

  const helper = browserRelayHelperSource(electronVar);
  const strictDirective = '"use strict";';
  const helperIndex = currentSource.startsWith(strictDirective) ? strictDirective.length : 0;
  let patched =
    currentSource.slice(0, helperIndex) + helper + currentSource.slice(helperIndex);
  const startupNeedle = startupMatch[0];
  const startupInsertion = `let ${startupMatch[1]}=await ${windowServicesVar}.ensureWindow();codexLinuxStartBrowserRelay(${windowServicesVar});${startupMatch[1]}&&`;
  patched = patched.replace(startupNeedle, startupInsertion);
  const contextInsertion = `getContextForWebContents:e=>codexLinuxIsBrowserRelaySender({sender:e})?${windowServicesVar}.getContextForWebContents(${windowServicesVar}.getPrimaryWindow()?.webContents):${windowServicesVar}.getContextForWebContents(e),getPrimaryWindow:${windowServicesVar}.getPrimaryWindow`;
  patched = patched.replace(contextNeedle, contextInsertion);
  const trustNeedle = trustMatch[0];
  const trustInsertion = `${trustMatch[1]}=e=>codexLinuxIsBrowserRelaySender(e)||${trustMatch[2]}.isTrustedIpcSender(e.sender,e.senderFrame??null)`;
  patched = patched.replace(trustNeedle, trustInsertion);
  return patched;
}

const descriptors = [
  {
    id: "browser-relay-main",
    phase: "main-bundle",
    order: 21_000,
    ciPolicy: "required-upstream",
    apply: applyBrowserRelayMainPatch,
  },
];

module.exports = {
  applyBrowserRelayMainPatch,
  browserRelayHelperSource,
  descriptors,
};
