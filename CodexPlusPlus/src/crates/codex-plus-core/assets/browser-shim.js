(function () {
  "use strict";

  var SESSION_TOKEN_KEY = "codexpp.browser-session-token";
  var fragment = new URLSearchParams(window.location.hash.slice(1));
  var fragmentToken = fragment.get("codexpp_session");
  var token = fragmentToken;
  try {
    if (fragmentToken) {
      sessionStorage.setItem(SESSION_TOKEN_KEY, fragmentToken);
    } else {
      token = sessionStorage.getItem(SESSION_TOKEN_KEY);
    }
  } catch (_) {}
  var socket = null;
  var socketAuthenticated = false;
  var reconnectTimer = null;
  var reconnectDelayMs = 100;
  var MAX_RECONNECT_DELAY_MS = 5000;
  var nextRequestId = 1;
  var pending = new Map();
  var appHostPort = null;
  var inboundAppHostQueue = [];
  var MAX_INBOUND_APPHOST_QUEUE = 1024;
  var workerSubscriptions = new Map();
  var sharedObjectSnapshots = new Map([
    ["host_config", { id: "local", display_name: "Local", kind: "local" }],
    ["remote_ssh_connections", []],
    ["remote_wsl_connections", []],
    ["pending_worktrees", []]
  ]);
  var outboundQueue = [];
  var MAX_OUTBOUND_QUEUE = 1024;

  function endpoint() {
    var protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    return protocol + "//" + window.location.host + "/__codexpp/ws";
  }

  function sendEnvelope(envelope) {
    if (!socket || socket.readyState !== WebSocket.OPEN || !socketAuthenticated) {
      if (outboundQueue.length >= MAX_OUTBOUND_QUEUE) {
        return Promise.reject(new Error("browser gateway outbound queue is full"));
      }
      outboundQueue.push(envelope);
      return Promise.resolve();
    }
    socket.send(JSON.stringify(envelope));
    return Promise.resolve();
  }

  function flushOutboundQueue() {
    while (
      outboundQueue.length > 0 &&
      socket &&
      socket.readyState === WebSocket.OPEN &&
      socketAuthenticated
    ) {
      socket.send(JSON.stringify(outboundQueue.shift()));
    }
  }

  function rejectPending(message) {
    pending.forEach(function (waiter) { waiter.reject(new Error(message)); });
    pending.clear();
  }

  function scheduleReconnect() {
    if (!token || reconnectTimer) return;
    var delay = reconnectDelayMs;
    reconnectDelayMs = Math.min(reconnectDelayMs * 2, MAX_RECONNECT_DELAY_MS);
    reconnectTimer = window.setTimeout(function () {
      reconnectTimer = null;
      connect();
    }, delay);
  }

  function request(method, args) {
    var id = String(nextRequestId++);
    return new Promise(function (resolve, reject) {
      pending.set(id, { resolve: resolve, reject: reject });
      sendEnvelope({ type: "bridge-request", id: id, method: method, args: args })
        .catch(function (error) {
          pending.delete(id);
          reject(error);
        });
    });
  }

  function deliverAppHostPayload(payload) {
    if (!appHostPort) {
      if (inboundAppHostQueue.length >= MAX_INBOUND_APPHOST_QUEUE) {
        inboundAppHostQueue.shift();
      }
      inboundAppHostQueue.push(payload);
      return;
    }
    appHostPort.postMessage(payload);
  }

  function flushInboundAppHostQueue() {
    while (appHostPort && inboundAppHostQueue.length > 0) {
      appHostPort.postMessage(inboundAppHostQueue.shift());
    }
  }

  function dispatchBrowserFocusState() {
    window.dispatchEvent(new MessageEvent("message", {
      data: {
        type: "electron-window-focus-changed",
        isFocused: document.hasFocus()
      }
    }));
  }

  window.addEventListener("focus", dispatchBrowserFocusState);
  window.addEventListener("blur", dispatchBrowserFocusState);

  function connectAppHost(event) {
    if (event.source !== window || !event.data || event.data.type !== "connect-app-host") {
      return;
    }
    appHostPort = event.ports && event.ports[0];
    if (!appHostPort) return;
    appHostPort.onmessage = function (message) {
      sendEnvelope({ type: "apphost", payload: message.data }).catch(function () {});
    };
    if (appHostPort.start) appHostPort.start();
    flushInboundAppHostQueue();
  }

  window.addEventListener("message", connectAppHost);

  function subscribeToWorkerMessages(worker, callback) {
    var id = String(nextRequestId++);
    workerSubscriptions.set(id, { worker: worker, callback: callback });
    sendEnvelope({
      type: "bridge-request",
      id: id,
      method: "subscribeToWorkerMessages",
      args: { worker: worker }
    }).catch(function () {});
    return function () {
      if (!workerSubscriptions.delete(id)) return;
      sendEnvelope({
        type: "bridge-request",
        id: String(nextRequestId++),
        method: "unsubscribeFromWorkerMessages",
        args: { subscriptionId: id }
      }).catch(function () {});
    };
  }

  window.electronBridge = {
    windowType: "electron",
    getPreloadStartedAtMs: function () { return performance.timeOrigin; },
    sendMessageFromView: function (payload) { return request("sendMessageFromView", payload); },
    sendWorkerMessageFromView: function (worker, payload) {
      return request("sendWorkerMessageFromView", { worker: worker, payload: payload });
    },
    subscribeToWorkerMessages: subscribeToWorkerMessages,
    getPathForFile: function () { return null; },
    startFileDrag: function () { return false; },
    showContextMenu: function (payload) { return request("showContextMenu", payload); },
    showApplicationMenu: function (menuId, x, y) {
      return request("showApplicationMenu", { menuId: menuId, x: x, y: y });
    },
    getFastModeRolloutMetrics: function (payload) {
      return request("getFastModeRolloutMetrics", payload);
    },
    getSharedObjectSnapshotValue: function (key) { return sharedObjectSnapshots.get(key); },
    getSystemThemeVariant: function () {
      return document.documentElement.classList.contains("electron-dark") ? "dark" : "light";
    },
    subscribeToSystemThemeVariant: function () { return function () {}; },
    getSentryInitOptions: function () { return null; },
    getAppSessionId: function () { return "codexpp-browser"; },
    getBuildFlavor: function () { return "prod"; },
    isDeviceCheckSupported: function () { return false; },
    isIntelMacBuild: function () { return false; },
    usesOwlAppShell: function () { return true; }
  };

  function connect() {
    if (
      !token ||
      socket && (socket.readyState === WebSocket.CONNECTING || socket.readyState === WebSocket.OPEN)
    ) {
      return;
    }

    var currentSocket;
    try {
      currentSocket = new WebSocket(endpoint(), "codexpp-browser-v1");
    } catch (_) {
      scheduleReconnect();
      return;
    }
    socket = currentSocket;
    socketAuthenticated = false;

    currentSocket.addEventListener("open", function () {
      if (socket !== currentSocket) return;
      currentSocket.send(JSON.stringify({ type: "authenticate", role: "browser", token: token }));
    });
    currentSocket.addEventListener("message", function (event) {
      if (socket !== currentSocket) return;
      var message;
      try { message = JSON.parse(event.data); } catch (_) { return; }
      if (message.type === "authenticated") {
        socketAuthenticated = true;
        reconnectDelayMs = 100;
        flushOutboundQueue();
        if (fragmentToken) {
          history.replaceState(null, "", window.location.pathname + window.location.search);
          fragmentToken = null;
        }
        return;
      }
      if (message.type === "codex-plus-injection" && typeof message.script === "string") {
        try {
          (0, eval)(message.script);
        } catch (error) {
          console.error("[codex-plus-browser] renderer injection failed", error);
        }
        return;
      }
      if (message.type === "error") {
        if (message.code === "unauthorized") {
          token = null;
          try { sessionStorage.removeItem(SESSION_TOKEN_KEY); } catch (_) {}
          outboundQueue.length = 0;
          rejectPending("browser gateway authentication failed");
        }
        return;
      }
      if (message.type === "apphost") {
        deliverAppHostPayload(message.payload);
        return;
      }
      if (message.type === "window-message") {
        if (
          message.payload &&
          message.payload.type === "electron-window-focus-changed"
        ) {
          dispatchBrowserFocusState();
          return;
        }
        if (
          message.payload &&
          message.payload.type === "shared-object-updated" &&
          typeof message.payload.key === "string"
        ) {
          sharedObjectSnapshots.set(message.payload.key, message.payload.value);
        }
        window.dispatchEvent(new MessageEvent("message", { data: message.payload }));
        return;
      }
      if (message.type === "worker-message") {
        workerSubscriptions.forEach(function (subscription) {
          if (subscription.worker === message.worker) subscription.callback(message.payload);
        });
        return;
      }
      if (message.type === "bridge-response") {
        var waiter = pending.get(String(message.id));
        if (!waiter) return;
        pending.delete(String(message.id));
        if (message.error) waiter.reject(new Error(message.error));
        else waiter.resolve(message.result);
      }
    });
    currentSocket.addEventListener("close", function () {
      if (socket !== currentSocket) return;
      var wasAuthenticated = socketAuthenticated;
      socket = null;
      socketAuthenticated = false;
      if (wasAuthenticated || !token) {
        outboundQueue.length = 0;
        rejectPending("browser gateway disconnected");
      }
      scheduleReconnect();
    });
  }

  if (!token) return;
  connect();
})();
