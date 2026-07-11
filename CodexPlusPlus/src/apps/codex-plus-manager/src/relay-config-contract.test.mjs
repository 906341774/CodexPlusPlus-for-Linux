import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const source = fs.readFileSync(new URL("./App.tsx", import.meta.url), "utf8");

test("Pure API base URL edits preserve requires_openai_auth false", () => {
  assert.match(
    source,
    /setCodexProviderStringKey\(next\.configContents, "base_url", baseUrlForConfig, next\.relayMode !== "pureApi"\)/,
  );
  assert.match(
    source,
    /function setCodexProviderStringKey\(contents: string, key: string, value: string, requiresOpenAiAuth = true\)/,
  );
  assert.match(
    source,
    /ensureCodexProviderDefaults\(next, provider, requiresOpenAiAuth\)/,
  );
});
