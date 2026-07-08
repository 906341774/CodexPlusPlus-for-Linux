"use strict";

const {
  extractedAppPatch,
} = require("../../../../descriptor.js");
const {
  patchLinuxLocalThreadCatalogBackfillAssets,
} = require("../../../../impl/main-process/local-thread-catalog.js");

module.exports = [
  extractedAppPatch({
    id: "linux-local-thread-catalog-preserve-backfill",
    phase: "extracted-app:pre-webview",
    order: 1043,
    ciPolicy: "optional",
    apply: patchLinuxLocalThreadCatalogBackfillAssets,
    status: (result, warnings) => ({
      status: result?.changed
        ? "applied"
        : result?.matched
          ? warnings.length > 0
            ? "skipped-optional"
            : "already-applied"
          : "skipped-optional",
      reason:
        result?.reason ??
        warnings[0] ??
        (result?.matched ? null : "local thread catalog pruning chunk not found"),
    }),
  }),
];
