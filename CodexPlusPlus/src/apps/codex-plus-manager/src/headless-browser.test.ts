import assert from "node:assert/strict";
import test from "node:test";

import {
  headlessBrowserIsActive,
  headlessBrowserSummaryPid,
  parseHeadlessBrowserPort,
  type HeadlessBrowserState,
} from "./headless-browser.ts";

const state = (status: HeadlessBrowserState["status"]): HeadlessBrowserState => ({
  instanceId: "codexpp-browser",
  status,
  message: "ready",
  startedAtMs: 1,
  tmuxSession: "codexpp-browser",
  accessPort: 58444,
  authMode: "pure_api",
  gatewayPid: 101,
  relayPid: 102,
  electronPid: 103,
  ownedPids: [101, 102, 103],
  failureCode: null,
});

test("headless browser ports are optional for auto selection and otherwise high", () => {
  assert.equal(parseHeadlessBrowserPort(""), undefined);
  assert.equal(parseHeadlessBrowserPort(" 58444 "), 58444);
  assert.throws(() => parseHeadlessBrowserPort("9229"), /49152/);
  assert.throws(() => parseHeadlessBrowserPort("not-a-port"), /49152/);
});

test("headless browser active states include transitions and degraded instances", () => {
  for (const status of ["starting", "running", "degraded", "reconfiguring", "stopping"] as const) {
    assert.equal(headlessBrowserIsActive(state(status)), true);
  }
  assert.equal(headlessBrowserIsActive(state("stopped")), false);
  assert.equal(headlessBrowserIsActive(state("failed")), false);
  assert.equal(headlessBrowserIsActive(null), false);
});

test("headless browser summary PID prefers Electron and falls back to owned processes", () => {
  assert.equal(headlessBrowserSummaryPid(state("running")), 103);
  assert.equal(
    headlessBrowserSummaryPid({
      ...state("running"),
      electronPid: null,
      gatewayPid: null,
      ownedPids: [201, 202],
    }),
    201,
  );
  assert.equal(headlessBrowserSummaryPid(null), null);
});
