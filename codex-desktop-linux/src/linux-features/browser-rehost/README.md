# Browser-Native Headless Rehost

This optional Linux feature creates a hidden Electron `BrowserWindow` when
Codex++ starts a browser gateway instance. The hidden page uses the original
Electron preload and forwards AppHost and bridge messages to the gateway over a
loopback WebSocket.

The feature is disabled by default. It does not expose the Electron debugging
port, cookies, `auth.json`, or API keys. The launcher supplies
`CODEX_LINUX_BROWSER_GATEWAY_URL` and
`CODEX_LINUX_BROWSER_RELAY_TOKEN` only for an explicitly managed background
instance.

Run the feature test with:

```bash
node --test linux-features/browser-rehost/test.js
```
