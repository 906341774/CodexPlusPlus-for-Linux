#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const {
  applyLinuxLocalConversationRouteHydrationPatch,
  applyLinuxLocalThreadCatalogInitialSnapshotPatch,
} = require("./patches/impl/webview/index.js");
const {
  applyLinuxLocalThreadCatalogPreserveBackfillPatch,
  patchLinuxLocalThreadCatalogBackfillAssets,
} = require("./patches/impl/main-process/local-thread-catalog.js");
const localConversationRouteHydrationDescriptor = require(
  "./patches/core/all-linux/webview/local-conversation-route-hydration/patch.js",
);

function applyPatchTwice(patchFn, source, ...args) {
  const patched = patchFn(source, ...args);
  assert.equal(patchFn(patched, ...args), patched, "patch must be idempotent");
  return patched;
}

test("treats direct local conversation route hydration as required", () => {
  assert.equal(localConversationRouteHydrationDescriptor.ciPolicy, "required-upstream");
});

const catalogProviderSource = [
  "function nU(e){let t=(0,iU.c)(5),n;t[0]===e?n=t[1]:(n=e===void 0?{}:e,t[0]=e,t[1]=n);let{enabled:r}=n,i=qr(`567837310`),a=$n.localThreadCatalog,o;return t[2]!==r||t[3]!==i?(o=!(r??i)||a==null?null:(0,oU.jsx)(rU,{service:a}),t[2]=r,t[3]=i,t[4]=o):o=t[4],o}",
  "function rU({service:e}){let t=G(V),n=z(cU),r=z(yee),i=(0,aU.useRef)(!1),a=(0,aU.useRef)(new Set);return(0,aU.useEffect)(()=>{try{var n=yc();Ro(t,!0);let r=!1,i=0,a=!1,o=async()=>{if(!r){r=!0;try{let n;do{n=i;let r=await e.readSnapshot();if(a)return;Sn(t,{type:`snapshot`,snapshot:r})}while(n!==i)}finally{r=!1}}};return n.u(e.subscribe(e=>{Sn(t,e)===`gap`&&(i+=1,o())})),()=>{try{var n=yc();a=!0,Ro(t,!1),n.u(e.unsubscribe())}catch(e){n.e=e}finally{n.d()}}}catch(e){n.e=e}finally{n.d()}},[t,e]),(0,aU.useEffect)(()=>{if(!r.initialized)return;let t,n=globalThis.setTimeout(()=>{let n=window.requestIdleCallback?.bind(window),r=window.cancelIdleCallback?.bind(window),a=()=>{i.current=!0,e.requestStartupSync()}},sU);return()=>{globalThis.clearTimeout(n),t?.()}},[r.initialized,e]),(0,aU.useEffect)(()=>{let t=new Set(n),r=n.some(e=>!a.current.has(e));a.current=t,i.current&&r&&e.requestSync()},[n,e]),null}",
].join("");

const catalogSummarySource =
  "function cFt(e){return{conversationId:J(e.threadId),hostId:e.hostId,createdAt:e.sourceCreatedAt,updatedAt:e.sourceUpdatedAt,recencyAt:e.sourceUpdatedAt,title:e.displayTitle,cwd:e.cwd,gitInfo:null,hasUnreadTurn:!1,modelProvider:e.modelProvider,parentThreadId:null,source:null,threadSource:null,threadRuntimeStatus:{type:`idle`},workspaceKind:e.cwd===`~`?`projectless`:`project`}}";

test("loads the local thread catalog snapshot immediately after subscribing", () => {
  const patched = applyPatchTwice(
    applyLinuxLocalThreadCatalogInitialSnapshotPatch,
    catalogProviderSource,
  );

  assert.match(
    patched,
    /e\.subscribe\(e=>\{Sn\(t,e\)===`gap`&&\(i\+=1,o\(\)\)\}\)\),o\(\),\(\)=>/,
  );
});

test("enables the local thread catalog provider on Linux when its rollout gate is off", () => {
  const patched = applyPatchTwice(
    applyLinuxLocalThreadCatalogInitialSnapshotPatch,
    catalogProviderSource,
  );

  assert.match(
    patched,
    /o=\(!\(r\?\?i\)&&document\.documentElement\.dataset\.codexOs!==`linux`\)\|\|a==null\?null:/,
  );
});

test("normalizes local catalog timestamps and marks summaries resumable", () => {
  const patched = applyPatchTwice(
    applyLinuxLocalThreadCatalogInitialSnapshotPatch,
    catalogSummarySource,
  );
  const context = { result: null };
  vm.runInNewContext(
    `const J = (value) => value; ${patched}; result = cFt({threadId:'thread-1',hostId:'local',sourceCreatedAt:1782237000.5,sourceUpdatedAt:1782237420.117,displayTitle:'Real title',cwd:'/tmp/project',modelProvider:'openai'});`,
    context,
  );

  assert.equal(context.result.title, "Real title");
  assert.equal(context.result.createdAt, 1782237000500);
  assert.equal(context.result.updatedAt, 1782237420117);
  assert.equal(context.result.recencyAt, 1782237420117);
  assert.equal(context.result.resumeState, "needs_resume");
  assert.equal(context.result.streamRole, null);
});

test("preserves provider-sync rollout rows during local catalog full scans", () => {
  const source =
    "class F7{completeScan(e){if(e.mode===`full`){this.db.prepare(`UPDATE local_thread_catalog AS catalog\\n           SET missing_candidate = 1\\n           WHERE host_id = ?\\n             AND missing_candidate = 0\\n             AND observation_sequence <= ?\\n             AND NOT EXISTS (\\n               SELECT 1 FROM local_thread_catalog_seen AS seen\\n             )`);this.db.prepare(`DELETE FROM local_thread_catalog AS catalog\\n             WHERE host_id = ?\\n               AND missing_candidate != 0\\n               AND observation_sequence < ?\\n               AND NOT EXISTS (\\n                 SELECT 1 FROM local_thread_catalog_seen AS seen\\n               )`)}}";

  const patched = applyPatchTwice(
    applyLinuxLocalThreadCatalogPreserveBackfillPatch,
    source,
  );

  assert.equal((patched.match(/source_kind = 'rollout'/g) || []).length, 2);
  assert.match(
    patched,
    /AND NOT \(source_kind = 'rollout' AND COALESCE\(source_detail, ''\) <> ''\)(?:\\n|\n)             AND NOT EXISTS/,
  );
  assert.match(
    patched,
    /AND NOT \(source_kind = 'rollout' AND COALESCE\(source_detail, ''\) <> ''\)(?:\\n|\n)               AND NOT EXISTS/,
  );
});

test("scans every main-process chunk for local catalog pruning SQL", (t) => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "codex-local-catalog-"));
  t.after(() => fs.rmSync(tempRoot, { recursive: true, force: true }));
  const buildDir = path.join(tempRoot, ".vite", "build");
  fs.mkdirSync(buildDir, { recursive: true });
  fs.writeFileSync(path.join(buildDir, "main-current.js"), "function main(){return true}");
  const catalogPath = path.join(buildDir, "src-current.js");
  fs.writeFileSync(
    catalogPath,
    "local_thread_catalog AS catalog local_thread_catalog_seen missing_candidate AND missing_candidate = 0\\n             AND observation_sequence <= ?\\n             AND NOT EXISTS ( AND missing_candidate != 0\\n               AND observation_sequence < ?\\n               AND NOT EXISTS (",
  );

  assert.deepEqual(
    patchLinuxLocalThreadCatalogBackfillAssets(tempRoot),
    { matched: 1, changed: 1 },
  );
  assert.equal(
    (fs.readFileSync(catalogPath, "utf8").match(/source_kind = 'rollout'/g) || []).length,
    2,
  );
  assert.deepEqual(
    patchLinuxLocalThreadCatalogBackfillAssets(tempRoot),
    { matched: 1, changed: 0 },
  );
});

test("hydrates a direct local conversation route before attempting resume", () => {
  const source =
    "function yS(e){let t=ht(oe),n=xr(),{activeMode:i}=Ua(e),{data:a}=k(Bn),o=a?.roots,c=Y(In,e);Y(s,e);let[l,u]=(0,wS.useState)(c),d=(0,wS.useRef)(null),_=(0,wS.useEffectEvent)(async e=>{try{u(!0),d.current=e;let n=t.get(s,e);await Mt(`maybe-resume-conversation`,{hostId:n,conversationId:e,model:null,serviceTier:await Js(t,n,i?.settings.model??null),reasoningEffort:null,workspaceRoots:o??[],collaborationMode:i})}catch(i){}});return(0,wS.useEffect)(()=>{e&&c&&e!==d.current&&_(e)},[c,e]),{isResuming:c&&l}}";

  const patched = applyPatchTwice(
    applyLinuxLocalConversationRouteHydrationPatch,
    source,
  );

  assert.match(patched, /function codexLinuxHydrateRouteConversation/);
  assert.match(
    patched,
    /Mt\(`load-recent-conversation-ids-for-host`,\{hostId:n,conversationIds:\[t\]\}\)/,
  );
  assert.match(
    patched,
    /let n=t\.get\(s,e\);await codexLinuxHydrateRouteConversation\(n,e\);await Mt\(`maybe-resume-conversation`/,
  );
  assert.match(
    patched,
    /,c=Y\(In,e\)\?\?!0;Y\(s,e\);let\[l,u\]=\(0,wS\.useState\)\(c\)/,
  );
});

test("hydrates the current guarded local conversation route before attempting resume", () => {
  const source =
    "function IS(e){let t=G(re),n=Xt(),{activeMode:r}=Ao(e),{data:i}=ue(Wi),a=i?.roots,o=W(_i,e),[s,c]=(0,VS.useState)(o),l=(0,VS.useRef)(null),u=(0,VS.useRef)(null),g=(0,VS.useEffectEvent)(async e=>{try{c(!0),l.current=e;let n=t.get(v,e);if(u.current==null){let r=!0,i=Bd(t,n,e,()=>r);u.current=()=>{r=!1,i()}}await Ba(`maybe-resume-conversation`,{hostId:n,conversationId:e,model:null,serviceTier:n===`durable`?null:await pe(t,n,r?.settings.model??null),reasoningEffort:null,workspaceRoots:a??[],collaborationMode:r})}catch(r){}});return{isResuming:o&&s}}";

  const patched = applyPatchTwice(
    applyLinuxLocalConversationRouteHydrationPatch,
    source,
  );

  assert.match(patched, /function codexLinuxHydrateRouteConversation/);
  assert.match(
    patched,
    /Ba\(`load-recent-conversation-ids-for-host`,\{hostId:n,conversationIds:\[t\]\}\)/,
  );
  assert.match(
    patched,
    /u\.current=\(\)=>\{r=!1,i\(\)\}\}await codexLinuxHydrateRouteConversation\(n,e\);await Ba\(`maybe-resume-conversation`/,
  );
  assert.match(
    patched,
    /,o=W\(_i,e\)\?\?!0,\[s,c\]=\(0,VS\.useState\)\(o\)/,
  );
});
