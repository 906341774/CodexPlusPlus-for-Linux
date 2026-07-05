"use strict";

const {
  patchLinuxLocalThreadCatalogBackfillAssets,
} = require("../../../../main-process.js");

module.exports = [
  {
    id: "linux-local-thread-catalog-preserve-backfill",
    phase: "extracted-app",
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
  },
];
