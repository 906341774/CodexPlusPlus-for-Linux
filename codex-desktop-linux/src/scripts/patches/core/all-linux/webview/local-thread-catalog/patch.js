"use strict";

const { webviewAssetPatch } = require("../../../../descriptor.js");
const {
  applyLinuxLocalThreadCatalogInitialSnapshotPatch,
} = require("../../../../impl/webview/index.js");

module.exports = [
  webviewAssetPatch({
    id: "linux-local-thread-catalog-initial-snapshot",
    phase: "webview-asset",
    order: 1044,
    ciPolicy: "optional",
    pattern: /^app-initial~app-main~.*\.js$/,
    missingDescription: "local thread catalog webview bundle",
    skipDescription: "Linux local thread catalog initial snapshot patch",
    apply: applyLinuxLocalThreadCatalogInitialSnapshotPatch,
  }),
];
