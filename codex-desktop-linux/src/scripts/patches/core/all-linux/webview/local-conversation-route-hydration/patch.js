"use strict";

const {
  webviewAssetPatch,
} = require("../../../../descriptor.js");
const {
  applyLinuxLocalConversationRouteHydrationPatch,
} = require("../../../../impl/webview/index.js");

module.exports = webviewAssetPatch({
  id: "linux-local-conversation-route-hydration",
  phase: "webview-asset",
  order: 1093,
  ciPolicy: "optional",
  pattern: /^local-conversation-thread-.*\.js$/,
  missingDescription: "local conversation thread webview bundle",
  skipDescription: "Linux local conversation route hydration patch",
  apply: applyLinuxLocalConversationRouteHydrationPatch,
});
