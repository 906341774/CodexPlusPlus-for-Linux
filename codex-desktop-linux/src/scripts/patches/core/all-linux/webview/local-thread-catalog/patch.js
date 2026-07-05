"use strict";

const {
  applyLinuxLocalThreadCatalogInitialSnapshotPatch,
} = require("../../../../webview-assets.js");

module.exports = [
  {
    id: "linux-local-thread-catalog-initial-snapshot",
    phase: "webview-asset",
    order: 1044,
    ciPolicy: "optional",
    pattern: /^app-initial~app-main~.*\.js$/,
    missingDescription: "local thread catalog webview bundle",
    skipDescription: "Linux local thread catalog initial snapshot patch",
    apply: applyLinuxLocalThreadCatalogInitialSnapshotPatch,
  },
];
