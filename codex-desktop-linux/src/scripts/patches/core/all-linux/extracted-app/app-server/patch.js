"use strict";

const {
  extractedAppPatch,
} = require("../../../../descriptor.js");
const { patchStatusFromChange } = require("../../../../../lib/patch-report.js");
const {
  patchLinuxAppServerInitializeTimeoutAssets,
} = require("../../../../impl/main-process/app-server.js");

module.exports = extractedAppPatch({
  id: "linux-app-server-initialize-timeout",
  phase: "extracted-app:pre-webview",
  order: 183,
  ciPolicy: "required-upstream",
  apply: patchLinuxAppServerInitializeTimeoutAssets,
  status: (result, warnings) => ({
    status: result?.matched === 1
      ? patchStatusFromChange(Boolean(result?.changed), warnings, "required-upstream")
      : "failed-required",
    reason: result?.matched === 1
      ? warnings[0] ?? null
      : warnings[0] ?? `Expected one initialize timeout bundle, found ${result?.matched ?? 0}`,
  }),
});
