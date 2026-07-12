"use strict";

const {
  extractedAppPatch,
  PHASE_EXTRACTED_APP_POST_WEBVIEW,
} = require("../../../../descriptor.js");
const {
  finalizeGeneratedWebviewAssetCacheKeys,
} = require("../../../../impl/generated-asset-cache.js");

module.exports = [
  extractedAppPatch({
    id: "generated-webview-asset-cache-keys",
    phase: PHASE_EXTRACTED_APP_POST_WEBVIEW,
    // This must see assets after every core and optional feature patch.
    order: 1_000_000_000,
    ciPolicy: "optional",
    apply: (extractedDir) => finalizeGeneratedWebviewAssetCacheKeys(extractedDir),
    status: (result, warnings) => ({
      status: result?.changed
        ? "applied"
        : result?.matched
          ? "already-applied"
          : "skipped-optional",
      reason: result?.reason ?? warnings[0] ?? null,
    }),
  }),
];
