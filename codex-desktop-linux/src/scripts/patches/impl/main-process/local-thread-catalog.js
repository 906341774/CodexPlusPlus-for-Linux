"use strict";

const fs = require("node:fs");
const path = require("node:path");

const preserveBackfilledRolloutCondition =
  "AND NOT (source_kind = 'rollout' AND COALESCE(source_detail, '') <> '')";

function countPreserveBackfilledRolloutConditions(source) {
  return source.split(preserveBackfilledRolloutCondition).length - 1;
}

function pruningSqlPatchSpecs(separator) {
  return [
    {
      needle: [
        "AND missing_candidate = 0",
        "             AND observation_sequence <= ?",
        "             AND NOT EXISTS (",
      ].join(separator),
      replacement: [
        "AND missing_candidate = 0",
        "             AND observation_sequence <= ?",
        `             ${preserveBackfilledRolloutCondition}`,
        "             AND NOT EXISTS (",
      ].join(separator),
    },
    {
      needle: [
        "AND missing_candidate != 0",
        "               AND observation_sequence < ?",
        "               AND NOT EXISTS (",
      ].join(separator),
      replacement: [
        "AND missing_candidate != 0",
        "               AND observation_sequence < ?",
        `               ${preserveBackfilledRolloutCondition}`,
        "               AND NOT EXISTS (",
      ].join(separator),
    },
  ];
}

function applyLinuxLocalThreadCatalogPreserveBackfillPatch(currentSource) {
  if (countPreserveBackfilledRolloutConditions(currentSource) >= 2) {
    return currentSource;
  }

  let patchedSource = currentSource;
  let replacements = 0;
  for (const separator of ["\n", "\\n"]) {
    for (const { needle, replacement } of pruningSqlPatchSpecs(separator)) {
      if (!patchedSource.includes(replacement) && patchedSource.includes(needle)) {
        patchedSource = patchedSource.replace(needle, replacement);
        replacements += 1;
      }
    }
  }

  if (replacements === 0) {
    console.warn(
      "WARN: Could not find local thread catalog full-scan pruning SQL - provider-sync backfilled local sessions may be hidden",
    );
    return currentSource;
  }
  if (countPreserveBackfilledRolloutConditions(patchedSource) < 2) {
    console.warn(
      "WARN: Only partially patched local thread catalog full-scan pruning SQL - provider-sync backfilled local sessions may still be hidden",
    );
  }
  return patchedSource;
}

function isLocalThreadCatalogPruningChunk(source) {
  return source.includes("local_thread_catalog AS catalog") &&
    source.includes("local_thread_catalog_seen") &&
    source.includes("missing_candidate");
}

function patchLinuxLocalThreadCatalogBackfillAssets(extractedDir) {
  const buildDir = path.join(extractedDir, ".vite", "build");
  if (!fs.existsSync(buildDir)) {
    console.warn(
      `WARN: Could not find main-process build chunks in ${buildDir} - provider-sync backfilled local sessions may be hidden`,
    );
    return { matched: 0, changed: 0 };
  }

  let matched = 0;
  let changed = 0;
  for (const name of fs.readdirSync(buildDir).sort()) {
    if (!name.endsWith(".js")) {
      continue;
    }
    const filePath = path.join(buildDir, name);
    const source = fs.readFileSync(filePath, "utf8");
    if (!isLocalThreadCatalogPruningChunk(source)) {
      continue;
    }
    matched += 1;
    const patched = applyLinuxLocalThreadCatalogPreserveBackfillPatch(source);
    if (patched !== source) {
      fs.writeFileSync(filePath, patched, "utf8");
      changed += 1;
    }
  }

  if (matched === 0) {
    console.warn(
      `WARN: Could not find local thread catalog pruning chunk in ${buildDir} - provider-sync backfilled local sessions may be hidden`,
    );
  }
  return { matched, changed };
}

module.exports = {
  applyLinuxLocalThreadCatalogPreserveBackfillPatch,
  patchLinuxLocalThreadCatalogBackfillAssets,
};
