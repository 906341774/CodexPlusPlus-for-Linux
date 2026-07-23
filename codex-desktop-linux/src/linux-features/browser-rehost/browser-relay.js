(function () {
  "use strict";

  var socket = null;
  var nextRequestId = 1;
  var workerSubscriptions = new Map();
  var pending = new Map();
  var appHostPort = null;
  var browserSessionId = 0;

  function send(message) {
    if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
  }

  function callBridge(method, args) {
    var id = String(nextRequestId++);
    var sessionId = browserSessionId;
    return new Promise(function (resolve, reject) {
      pending.set(id, { resolve: resolve, reject: reject });
      send({ type: "bridge-response-pending", id: id });
      Promise.resolve().then(function () {
        var bridge = window.electronBridge;
        if (!bridge || typeof bridge[method] !== "function") {
          throw new Error("Electron bridge method is unavailable: " + method);
        }
        if (method === "subscribeToWorkerMessages") {
          var worker = args && args.worker;
          var unsubscribe = bridge[method](worker, function (payload) {
            if (sessionId === browserSessionId) {
              send({ type: "worker-message", worker: worker, payload: payload });
            }
          });
          workerSubscriptions.set(id, unsubscribe);
          return id;
        }
        if (method === "unsubscribeFromWorkerMessages") {
          var unsubscribe = workerSubscriptions.get(args && args.subscriptionId);
          if (typeof unsubscribe === "function") unsubscribe();
          workerSubscriptions.delete(args && args.subscriptionId);
          return true;
        }
        if (method === "sendWorkerMessageFromView") {
          return bridge[method](args && args.worker, args && args.payload);
        }
        if (method === "showApplicationMenu") {
          return bridge[method](args && args.menuId, args && args.x, args && args.y);
        }
        return bridge[method].apply(bridge, Array.isArray(args) ? args : [args]);
      }).then(function (result) {
        pending.delete(id);
        if (sessionId === browserSessionId) {
          send({ type: "bridge-response", id: id, result: result });
        }
        resolve(result);
      }).catch(function (error) {
        pending.delete(id);
        if (sessionId === browserSessionId) {
          send({ type: "bridge-response", id: id, error: String(error && error.message || error) });
        }
        reject(error);
      });
    });
  }

  function handleMessage(event) {
    if (event.source != null && event.source !== window || !event.data) return;
    if (event.data.type === "connect-app-host") return;
    send({ type: "window-message", payload: event.data });
  }

  window.addEventListener("message", handleMessage);

  function resetAppHost() {
    browserSessionId += 1;
    workerSubscriptions.forEach(function (unsubscribe) {
      if (typeof unsubscribe === "function") unsubscribe();
    });
    workerSubscriptions.clear();
    pending.clear();
    if (appHostPort) {
      try { appHostPort.postMessage(null); } catch (_) {}
      try { appHostPort.close(); } catch (_) {}
    }
    var channel = new MessageChannel();
    appHostPort = channel.port1;
    channel.port1.onmessage = function (event) {
      send({ type: "apphost", payload: event.data });
    };
    channel.port1.start();
    window.postMessage({ type: "connect-app-host", port: channel.port2 }, window.location.origin, [channel.port2]);
  }

  window.codexLinuxBrowserRelayStart = function (config) {
    if (!config || !config.gatewayUrl || !config.relayToken) return;
    var gateway = new URL(config.gatewayUrl);
    gateway.pathname = "/__codexpp/ws";
    gateway.protocol = gateway.protocol === "https:" ? "wss:" : "ws:";
    socket = new WebSocket(gateway.toString(), "codexpp-browser-v1");
    socket.addEventListener("open", function () {
      send({ type: "authenticate", role: "relay", token: config.relayToken });
      setTimeout(function () {
        var bridge = window.electronBridge;
        if (!bridge || typeof bridge.sendMessageFromView !== "function") return;
        Promise.resolve(bridge.sendMessageFromView({ type: "ready" })).catch(function (error) {
          console.warn("[codex-linux-browser] relay ready failed:", error);
        });
      }, 0);
    });
    socket.addEventListener("message", function (event) {
      var message;
      try { message = JSON.parse(event.data); } catch (_) { return; }
      if (message.type === "gateway-browser-session-started") {
        resetAppHost();
        return;
      }
      if (message.type === "apphost") {
        appHostPort && appHostPort.postMessage(message.payload);
        return;
      }
      if (message.type === "window-message") {
        window.dispatchEvent(new MessageEvent("message", { data: message.payload }));
        return;
      }
      if (message.type === "bridge-request") {
        callBridge(message.method, message.args).catch(function () {});
        return;
      }
      if (message.type === "bridge-response-pending") return;
    });
  };
})();
