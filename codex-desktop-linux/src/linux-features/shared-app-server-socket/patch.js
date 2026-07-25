"use strict";

const IDENT = "[A-Za-z_$][\\w$]*";

function findTransportSymbols(source) {
  const classMatch = source.match(
    new RegExp(
      `var (${IDENT})=class\\{options;kind=\\\`websocket\\\`;logger=${IDENT}\\.${IDENT}\\(\\\`AppServerTransportSshWebsocket\\\`\\)`,
    ),
  );
  const selectionLogIndex = source.indexOf("selected app-server transport");
  if (classMatch == null || selectionLogIndex < 0 || classMatch.index >= selectionLogIndex) return null;

  const sshClassSource = source.slice(classMatch.index, selectionLogIndex);
  const webSocketMatch = sshClassSource.match(
    new RegExp(`new (${IDENT})\\.(${IDENT})\\((${IDENT}),\\{perMessageDeflate:!1,createConnection:`),
  );
  if (webSocketMatch == null) return null;
  const [, namespace, webSocketClass, webSocketUrl] = webSocketMatch;
  const lifecycleMatch = sshClassSource.match(
    new RegExp(
      `return ${namespace}\\.(${IDENT})\\((${IDENT}),\\{onPongTimeout:[\\s\\S]{0,160}?\\}\\),new ${namespace}\\.(${IDENT})\\(\\2\\)`,
    ),
  );
  if (lifecycleMatch == null) return null;

  return {
    namespace,
    webSocketClass,
    webSocketUrl,
    adapterClass: lifecycleMatch[3],
    keepAlive: lifecycleMatch[1],
  };
}

function sharedTransportClassSource(symbols) {
  return (
    "class CodexLinuxSharedAppServerSocketTransport{" +
    "kind=`websocket`;proxyStreams=new Set;authority=null;authorityError=null;authorityReady=null;lockIdentity=null;socketIdentity=null;" +
    "constructor(e){this.socketPath=e;this.lockPath=`${e}.lock`}" +
    "supportsReconnect(){return!0}" +
    "sameIdentity(e,t){return e!=null&&t.dev===e.dev&&t.ino===e.ino}" +
    "processStat(e){try{let t=require(`node:fs`).readFileSync(`/proc/${e}/stat`,`utf8`),n=t.lastIndexOf(`)`);if(n<0)return null;let r=t.slice(n+1).trim().split(/\\s+/),i=Number(r[2]);return typeof r[0]==`string`&&Number.isInteger(i)?{state:r[0],group:i}:null}catch(e){return e?.code===`ENOENT`?!1:null}}" +
    "deadProcessState(e){return e===`Z`||e===`X`}" +
    "ownerPidAlive(e){if(!Number.isInteger(e)||e<=0)return null;try{process.kill(e,0)}catch(e){return e?.code===`ESRCH`?!1:!0}let t=this.processStat(e);return t===!1?!1:t==null?!0:!this.deadProcessState(t.state)}" +
    "childGroupAlive(e){if(!Number.isInteger(e)||e<=0)return null;try{process.kill(-e,0)}catch(e){return e?.code===`ESRCH`?!1:!0}let t=require(`node:fs`),n;try{n=t.readdirSync(`/proc`)}catch{return!0}let r=!1;for(let t of n){let n=Number(t);if(!Number.isInteger(n)||n<=0)continue;let i=this.processStat(n);if(!i||i.group!==e)continue;r=!0;if(!this.deadProcessState(i.state))return!0}return!r}" +
    "signalChildGroup(e,t=`SIGTERM`){if(Number.isInteger(e?.pid))try{return process.kill(-e.pid,t),!0}catch(n){if(n?.code!==`ESRCH`)throw n}return e?.kill?.(t)??!1}" +
    "lockRecord(){return{version:1,ownerPid:process.pid,...Number.isInteger(this.authority?.pid)?{authorityPid:this.authority.pid}:{},...this.socketIdentity?{socketDev:this.socketIdentity.dev,socketIno:this.socketIdentity.ino}:{}}}" +
    "writeLockRecord(e=null){let t=require(`node:fs`),n=e;try{if(n==null){n=t.openSync(this.lockPath,`r+`);let e=t.fstatSync(n);if(!this.sameIdentity(this.lockIdentity,e))throw Error(`shared app-server ownership changed: ${this.socketPath}`)}t.ftruncateSync(n,0),t.writeFileSync(n,`${JSON.stringify(this.lockRecord())}\\n`)}finally{e==null&&n!=null&&t.closeSync(n)}}" +
    "processGroupId(e){let t=this.processStat(e);return t?t.group:null}" +
    "authorityCommandMatches(e){try{let t=require(`node:fs`).readFileSync(`/proc/${e}/cmdline`).toString(`utf8`).split(`\\0`);return t.includes(`app-server`)&&t.includes(`--listen`)&&t.includes(`unix://${this.socketPath}`)}catch{return!1}}" +
    "pidOwnedByUser(e){if(typeof process.getuid!=`function`)return!0;try{return require(`node:fs`).lstatSync(`/proc/${e}`).uid===process.getuid()}catch{return!1}}" +
    "authorityGroupMatches(e){let t=require(`node:fs`),n=[];try{n=t.readdirSync(`/proc`)}catch{}n.unshift(`${e}`);let r=new Set;for(let t of n){let n=Number(t);if(!Number.isInteger(n)||n<=0||r.has(n))continue;r.add(n);if(!this.pidOwnedByUser(n))continue;if(n===e&&this.authorityCommandMatches(n)||this.processGroupId(n)===e&&this.authorityCommandMatches(n))return!0}return!1}" +
    "waitForChildGroupExit(e,t=2e3){return new Promise(n=>{let r=!1,i,a,o=e=>{if(r)return;r=!0,clearTimeout(i),clearTimeout(a),n(e)},s=()=>{if(this.childGroupAlive(e)===!1)return o(!0);i=setTimeout(s,50),i.unref?.()};a=setTimeout(()=>o(!1),t),a.unref?.(),s()})}" +
    "waitForChildExit(e,t=2e3){if(!e||e.exitCode!=null||e.signalCode!=null)return Promise.resolve(!0);return new Promise(n=>{let r=!1,i=o=>{if(r)return;r=!0,clearTimeout(a),e.off(`exit`,s),e.off(`close`,s),e.off(`error`,l),n(o)},s=()=>i(!0),l=()=>i(!1),a=setTimeout(()=>i(!1),t);a.unref?.(),e.once(`exit`,s),e.once(`close`,s),e.once(`error`,l)})}" +
    "async stopChildGroup(e){if(!e)return!0;let t=Number.isInteger(e.pid)?e.pid:null,n=e.exitCode!=null||e.signalCode!=null,r=t==null||this.childGroupAlive(t)===!1;if(n&&r)return!0;let i=n?Promise.resolve(!0):this.waitForChildExit(e);this.signalChildGroup(e);[n,r]=await Promise.all([i,t==null?Promise.resolve(!0):this.waitForChildGroupExit(t)]);if(n&&r)return!0;i=n?Promise.resolve(!0):this.waitForChildExit(e,1e3);this.signalChildGroup(e,`SIGKILL`);return[n,r]=await Promise.all([i,t==null?Promise.resolve(!0):this.waitForChildGroupExit(t,1e3)]),n&&r}" +
    "removeRecordedSocket(e){let t=require(`node:fs`),n;try{n=t.lstatSync(this.socketPath)}catch(e){if(e?.code===`ENOENT`)return!0;throw e}if(!n.isSocket()||typeof process.getuid==`function`&&n.uid!==process.getuid()||!Number.isFinite(e?.socketDev)||!Number.isFinite(e?.socketIno)||!this.sameIdentity({dev:e.socketDev,ino:e.socketIno},n))return!1;return t.unlinkSync(this.socketPath),!0}" +
    "async reclaimStaleLock(){let e=require(`node:fs`),t;try{t=e.lstatSync(this.lockPath)}catch(e){if(e?.code===`ENOENT`)return!0;throw e}let n=null;try{n=JSON.parse(e.readFileSync(this.lockPath,`utf8`))}catch{}if(n?.version===1&&Number.isInteger(n.ownerPid)){if(this.ownerPidAlive(n.ownerPid)!==!1)return!1;if(Number.isInteger(n.authorityPid)&&this.childGroupAlive(n.authorityPid)){if(!this.authorityGroupMatches(n.authorityPid))return!1;try{process.kill(-n.authorityPid,`SIGTERM`)}catch(e){if(e?.code!==`ESRCH`)return!1}if(!await this.waitForChildGroupExit(n.authorityPid)){try{process.kill(-n.authorityPid,`SIGKILL`)}catch(e){if(e?.code!==`ESRCH`)return!1}if(!await this.waitForChildGroupExit(n.authorityPid,1e3))return!1}}if(!this.removeRecordedSocket(n))return!1}else{if(Date.now()-t.mtimeMs<1e4)return!1;try{e.lstatSync(this.socketPath);return!1}catch(e){if(e?.code!==`ENOENT`)throw e}}let r;try{r=e.lstatSync(this.lockPath)}catch(e){if(e?.code===`ENOENT`)return!0;throw e}return!!this.sameIdentity(t,r)&&(e.unlinkSync(this.lockPath),!0)}" +
    "releaseOwnedPaths(e=!1){let t=require(`node:fs`),n=[];if(this.socketIdentity)try{let e=t.lstatSync(this.socketPath);this.sameIdentity(this.socketIdentity,e)&&t.unlinkSync(this.socketPath),this.socketIdentity=null}catch(e){e?.code===`ENOENT`?this.socketIdentity=null:n.push(e)}if(this.lockIdentity)try{let e=t.lstatSync(this.lockPath);this.sameIdentity(this.lockIdentity,e)&&t.unlinkSync(this.lockPath),this.lockIdentity=null}catch(e){e?.code===`ENOENT`?this.lockIdentity=null:n.push(e)}if(n.length&&!e)throw n[0];n.length&&console.warn(`WARN: shared app-server socket cleanup failed: ${n[0].message}`)}" +
    "dispose(){for(let e of this.proxyStreams)e.destroy();this.proxyStreams.clear();let e=this.authority;this.authority=null;e?this.stopAuthority(e).then(e=>{e?this.releaseOwnedPaths(!0):console.warn(`WARN: shared app-server authority did not exit; ownership retained: ${this.socketPath}`)}).catch(e=>console.warn(`WARN: shared app-server authority stop failed: ${e.message}`)):this.releaseOwnedPaths(!0)}" +
    "acquireOwnership(e=!1){let t=require(`node:fs`),n=require(`node:path`);t.mkdirSync(n.dirname(this.socketPath),{recursive:!0,mode:448});let r;try{r=t.openSync(this.lockPath,`wx`,384),this.lockIdentity=t.fstatSync(r),this.writeLockRecord(r)}catch(n){if(this.lockIdentity)try{this.releaseOwnedPaths(!0)}catch{}if(n?.code===`EEXIST`&&!e)return this.reclaimStaleLock().then(e=>{if(!e)throw Error(`shared app-server socket is already owned: ${this.socketPath}`);return this.acquireOwnership(!0)});if(n?.code===`EEXIST`)throw Error(`shared app-server socket is already owned: ${this.socketPath}`);throw n}finally{r!=null&&t.closeSync(r)}try{t.lstatSync(this.socketPath);throw Error(`shared app-server socket path already exists: ${this.socketPath}`)}catch(e){if(e?.code!==`ENOENT`){this.releaseOwnedPaths();throw e}}return null}" +
    "async stopAuthority(e){try{return await this.stopChildGroup(e)}catch(e){return this.authorityError??=e,!1}}" +
    "stopProxy(e){this.stopChildGroup(e).then(e=>{e||console.warn(`WARN: shared app-server proxy process group did not exit`)}).catch(e=>console.warn(`WARN: shared app-server proxy stop failed: ${e.message}`))}" +
    "async ensureAuthority(){if(this.authorityReady)return this.authorityReady;if(this.authority&&this.authority.exitCode==null&&this.authority.signalCode==null){if(this.authorityError)throw this.authorityError;return}let e=this.startAuthority();this.authorityReady=e;try{return await e}finally{this.authorityReady===e&&(this.authorityReady=null)}}" +
    "async startAuthority(){let e=process.env.CODEX_CLI_PATH;if(!e)throw Error(`shared app-server socket requires CODEX_CLI_PATH`);this.authorityError=null;let t=this.acquireOwnership();t&&await t;let n=require(`node:fs`),r;try{r=require(`node:child_process`).spawn(e,[`app-server`,`--listen`,`unix://${this.socketPath}`],{env:process.env,stdio:`ignore`,detached:!0}),this.authority=r,this.writeLockRecord()}catch(e){this.releaseOwnedPaths();throw e}try{await new Promise((e,t)=>{let i=!1,a,o=()=>{clearTimeout(a),clearTimeout(u),r.off(`error`,s),r.off(`exit`,l),r.off(`close`,l)},c=(n,r)=>{if(i)return;i=!0,o(),n?t(n):e(r)},s=e=>{this.authorityError=e,c(e)},l=()=>c(Error(`shared app-server authority exited before socket creation`)),h=()=>{if(i)return;try{let e=n.lstatSync(this.socketPath);if(e.isSocket()){if(typeof process.getuid==`function`&&e.uid!==process.getuid())return c(Error(`shared app-server socket has unexpected owner`));this.socketIdentity={dev:e.dev,ino:e.ino},this.writeLockRecord();return c(null)}}catch(e){if(e?.code!==`ENOENT`)return c(e)}a=setTimeout(h,100),a.unref?.()},u=setTimeout(()=>c(Error(`shared app-server socket creation timed out`)),1e4);r.once(`error`,s),r.once(`exit`,l),r.once(`close`,l),h(),u.unref?.()}),r.on(`error`,e=>{this.authorityError=e;for(let t of this.proxyStreams)t.destroy(e)}),r.once(`exit`,async()=>{if(this.authority!==r)return;this.authority=null;try{(await this.stopAuthority(r))?this.releaseOwnedPaths(!0):console.warn(`WARN: shared app-server authority group did not exit; ownership retained: ${this.socketPath}`)}catch(e){console.warn(`WARN: shared app-server authority group cleanup failed: ${e.message}`)}})}catch(e){this.authority=null;(await this.stopAuthority(r))&&this.releaseOwnedPaths();throw e}}" +
    "createProxyStream(){let c=process.env.CODEX_CLI_PATH;if(!c)throw Error(`shared app-server socket requires CODEX_CLI_PATH`);let e=require(`node:child_process`).spawn(c,[`app-server`,`proxy`,`--sock`,this.socketPath],{env:process.env,stdio:[`pipe`,`pipe`,`pipe`],detached:!0}),t=e.stdin,n=e.stdout,r=e.stderr;if(t==null||n==null||r==null)throw this.stopProxy(e),Error(`shared app-server proxy stdio was unavailable`);let i=``;r.on(`data`,e=>{i=`${i}${e.toString(`utf8`)}`.slice(-4000)});let a=this,o=new(require(`node:stream`).Duplex)({read(){n.resume()},write(e,n,r){t.write(e,n,r)},final(e){t.end(),e()},destroy(t,n){a.stopProxy(e),n(t)}});Object.assign(o,{setKeepAlive:()=>o,setNoDelay:()=>o,setTimeout:()=>o});let s=e=>o.destroy(e);t.on(`error`,s),n.on(`data`,e=>{o.push(e)||n.pause()}),n.on(`end`,()=>o.push(null)),e.on(`error`,s),e.on(`close`,(e,n)=>{t.removeListener(`error`,s),e===0?o.push(null):o.destroy(Error(`shared app-server proxy exited (${e??n??`unknown`}): ${i.trim()}`))}),this.proxyStreams.add(o),o.once(`close`,()=>this.proxyStreams.delete(o));return o}" +
    `async connect(){await this.ensureAuthority();let e={current:null},t=new ${symbols.namespace}.${symbols.webSocketClass}(${symbols.webSocketUrl},{perMessageDeflate:!1,createConnection:()=>(e.current=this.createProxyStream(),e.current)});t.once(\`close\`,()=>e.current?.destroy());try{await new Promise((n,r)=>{let i=setTimeout(()=>o(Error(\`shared app-server websocket open timed out\`)),3e4);i.unref();let a=()=>{clearTimeout(i),t.off(\`error\`,o),t.off(\`close\`,s)},o=e=>{a(),r(e)},s=()=>o(Error(\`shared app-server websocket closed before opening\`));t.once(\`open\`,()=>{a(),n()}),t.once(\`error\`,o),t.once(\`close\`,s)})}catch(n){e.current?.destroy(),t.terminate(),await new Promise(e=>setTimeout(e,0));throw n}${symbols.namespace}.${symbols.keepAlive}(t,{onPongTimeout:()=>t.terminate()});return new ${symbols.namespace}.${symbols.adapterClass}(t)}}`
  );
}

function applySharedAppServerSocketPatch(source) {
  if (source.includes("class CodexLinuxSharedAppServerSocketTransport")) return source;

  const symbols = findTransportSymbols(source);
  if (symbols == null) {
    console.warn("WARN: Could not find SSH WebSocket transport for shared app-server socket patch");
    return source;
  }

  const selectionLogIndex = source.indexOf("selected app-server transport");
  const factoryStart = source.lastIndexOf("function ", selectionLogIndex);
  const factoryEnd = source.indexOf("function ", selectionLogIndex + 1);
  if (selectionLogIndex < 0 || factoryStart < 0 || factoryEnd < 0) {
    console.warn("WARN: Could not find local transport factory for shared app-server socket patch");
    return source;
  }
  const factorySource = source.slice(factoryStart, factoryEnd);
  const localFallbackPattern = new RegExp(
    `(if\\(${symbols.namespace}\\.(${IDENT})\\(e\\.hostConfig\\)\\)return new (${IDENT})\\(\\{hostConfig:e\\.hostConfig,repoRoot:e\\.repoRoot,resourcesPath:e\\.resourcesPath,defaultOriginator:e\\.defaultOriginator\\}\\);)(?=let (${IDENT})=(${IDENT})\\(e\\.hostConfig\\);if\\(\\4\\)\\{)`,
  );
  const localFallbackMatch = factorySource.match(localFallbackPattern);
  if (localFallbackMatch == null) {
    console.warn("WARN: Could not find local transport fallback for shared app-server socket patch");
    return source;
  }

  const classSource = sharedTransportClassSource(symbols);

  const patchedFactory = factorySource.replace(
    localFallbackPattern,
    (match) =>
      `${match}if(process.env.CODEX_LINUX_APP_SERVER_BRIDGE_SOCKET&&e.hostConfig.kind===\`local\`)return new CodexLinuxSharedAppServerSocketTransport(process.env.CODEX_LINUX_APP_SERVER_BRIDGE_SOCKET);`,
  );
  return source.slice(0, factoryStart) + classSource + patchedFactory + source.slice(factoryEnd);
}

const descriptors = [
  {
    id: "main-process-shared-app-server-socket",
    phase: "main-bundle",
    order: 140,
    ciPolicy: "optional",
    apply: applySharedAppServerSocketPatch,
  },
];

module.exports = {
  applySharedAppServerSocketPatch,
  descriptors,
  findTransportSymbols,
  sharedTransportClassSource,
};
