"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const CACHE_QUERY_PARAMETER = "codex-linux-cache";
const GENERATED_LINUX_ASSET_PATTERN = /^[A-Za-z0-9_-]+-linux\.js$/;

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function generatedLinuxAssetNames(assetsDir) {
  if (!fs.existsSync(assetsDir)) {
    return [];
  }
  return fs
    .readdirSync(assetsDir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && GENERATED_LINUX_ASSET_PATTERN.test(entry.name))
    .map((entry) => entry.name)
    .sort();
}

function generatedAssetReferencePattern(assetNames) {
  const alternatives = assetNames.map(escapeRegExp).join("|");
  return new RegExp(
    `(["'\\x60])((?:\\.\\/)?(?:${alternatives}))(?:\\?${CACHE_QUERY_PARAMETER}=[a-f0-9]+)?\\1`,
    "g",
  );
}

function rewriteGeneratedAssetReferences(source, assetNames, cacheKey = null) {
  if (assetNames.length === 0) {
    return source;
  }
  const pattern = generatedAssetReferencePattern(assetNames);
  return source.replace(pattern, (_match, quote, assetPath) => {
    const query = cacheKey == null ? "" : `?${CACHE_QUERY_PARAMETER}=${cacheKey}`;
    return `${quote}${assetPath}${query}${quote}`;
  });
}

function generatedAssetCacheKey(assetsDir, assetNames) {
  const hash = crypto.createHash("sha256");
  for (const assetName of assetNames) {
    const source = fs.readFileSync(path.join(assetsDir, assetName), "utf8");
    const normalized = rewriteGeneratedAssetReferences(source, assetNames);
    hash.update(assetName);
    hash.update("\0");
    hash.update(normalized);
    hash.update("\0");
  }
  return hash.digest("hex").slice(0, 16);
}

function finalizeGeneratedWebviewAssetCacheKeys(extractedDir) {
  const assetsDir = path.join(extractedDir, "webview", "assets");
  const assetNames = generatedLinuxAssetNames(assetsDir);
  if (assetNames.length === 0) {
    return {
      matched: false,
      changed: 0,
      reason: "no generated Linux webview assets are present",
    };
  }

  const cacheKey = generatedAssetCacheKey(assetsDir, assetNames);
  let changed = 0;
  for (const entry of fs.readdirSync(assetsDir, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith(".js")) {
      continue;
    }
    const filePath = path.join(assetsDir, entry.name);
    const source = fs.readFileSync(filePath, "utf8");
    const patched = rewriteGeneratedAssetReferences(source, assetNames, cacheKey);
    if (patched !== source) {
      fs.writeFileSync(filePath, patched, "utf8");
      changed += 1;
    }
  }

  return {
    matched: true,
    changed,
    cacheKey,
    assetNames,
  };
}

module.exports = {
  CACHE_QUERY_PARAMETER,
  GENERATED_LINUX_ASSET_PATTERN,
  finalizeGeneratedWebviewAssetCacheKeys,
  generatedAssetCacheKey,
  generatedLinuxAssetNames,
  rewriteGeneratedAssetReferences,
};
