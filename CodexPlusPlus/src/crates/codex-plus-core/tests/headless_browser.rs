use std::net::TcpListener;
use std::time::Duration;

use codex_plus_core::headless_browser::{
    BrowserAuthMode, BrowserGateway, BrowserGatewayConfig, BrowserInstanceState,
    BrowserInstanceStatus, BrowserSessionToken, BrowserStateStore, GatewayPeerRole,
    MAX_GATEWAY_MESSAGE_BYTES, TerminationPolicy, is_allowed_browser_origin,
    reserve_browser_gateway_port,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio_tungstenite::tungstenite::Message;

#[test]
fn automatic_gateway_port_is_high_and_reserved_until_released() {
    let reservation = reserve_browser_gateway_port(None).unwrap();
    let port = reservation.port();

    assert!((49_152..=65_535).contains(&port));
    let duplicate = TcpListener::bind(("127.0.0.1", port)).unwrap_err();
    assert_eq!(duplicate.kind(), std::io::ErrorKind::AddrInUse);
}

#[test]
fn requested_gateway_port_must_be_high_and_available() {
    let (_occupied, occupied_port) = (49_152..=65_535)
        .find_map(|port| {
            TcpListener::bind(("127.0.0.1", port))
                .ok()
                .map(|listener| (listener, port))
        })
        .unwrap();

    assert!(reserve_browser_gateway_port(Some(1024)).is_err());
    let error = reserve_browser_gateway_port(Some(occupied_port)).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::AddrInUse);
}

#[test]
fn browser_session_token_verification_rejects_modified_values() {
    let token = BrowserSessionToken::generate();
    let exposed = token.expose_for_launch().to_string();
    let mut modified = exposed.clone().into_bytes();
    modified[0] = if modified[0] == b'a' { b'b' } else { b'a' };
    let modified = String::from_utf8(modified).unwrap();

    assert!(exposed.len() >= 64);
    assert!(token.verify(&exposed));
    assert!(!token.verify(&modified));
    assert!(!token.verify("short"));
}

#[test]
fn browser_session_token_can_be_reconstructed_from_an_explicit_secret() {
    let generated = BrowserSessionToken::generate();
    let exposed = generated.expose_for_launch().to_string();
    let reconstructed = BrowserSessionToken::from_exposed(&exposed).unwrap();

    assert!(reconstructed.verify(&exposed));
    assert!(BrowserSessionToken::from_exposed("not-a-token").is_none());
}

#[test]
fn browser_origin_must_match_the_loopback_gateway_port() {
    assert!(is_allowed_browser_origin("http://127.0.0.1:57340", 57340));
    assert!(is_allowed_browser_origin("http://localhost:57340", 57340));
    assert!(is_allowed_browser_origin("http://[::1]:57340", 57340));
    assert!(!is_allowed_browser_origin("null", 57340));
    assert!(!is_allowed_browser_origin("http://127.0.0.1:57341", 57340));
    assert!(!is_allowed_browser_origin(
        "https://example.com:57340",
        57340
    ));
}

#[test]
fn browser_shim_matches_the_current_electron_route_contract() {
    let shim = include_str!("../assets/browser-shim.js");

    assert!(shim.contains("getBuildFlavor: function () { return \"prod\"; }"));
    assert!(shim.contains("usesOwlAppShell: function () { return true; }"));
}

#[test]
fn browser_shim_seeds_and_tracks_shared_object_snapshots() {
    let shim = include_str!("../assets/browser-shim.js");

    assert!(
        shim.contains(r#"["host_config", { id: "local", display_name: "Local", kind: "local" }]"#)
    );
    assert!(
        shim.contains("sharedObjectSnapshots.set(message.payload.key, message.payload.value);")
    );
    assert!(shim.contains(
        "getSharedObjectSnapshotValue: function (key) { return sharedObjectSnapshots.get(key); }"
    ));
}

#[test]
fn browser_shim_queues_apphost_frames_until_the_renderer_port_connects() {
    let shim = include_str!("../assets/browser-shim.js");

    assert!(shim.contains("var inboundAppHostQueue = [];"));
    assert!(shim.contains("inboundAppHostQueue.push(payload);"));
    assert!(shim.contains("while (appHostPort && inboundAppHostQueue.length > 0)"));
    let connect = shim.find("appHostPort.onmessage = function").unwrap();
    let flush = shim.find("flushInboundAppHostQueue();").unwrap();
    assert!(connect < flush);
}

#[test]
fn browser_shim_reports_the_browser_document_focus_instead_of_the_hidden_relay_focus() {
    let shim = include_str!("../assets/browser-shim.js");

    assert!(shim.contains("function dispatchBrowserFocusState()"));
    assert!(shim.contains("isFocused: document.hasFocus()"));
    assert!(shim.contains("message.payload.type === \"electron-window-focus-changed\""));
    assert!(shim.contains("window.addEventListener(\"focus\", dispatchBrowserFocusState);"));
    assert!(shim.contains("window.addEventListener(\"blur\", dispatchBrowserFocusState);"));
}

#[test]
fn persisted_browser_state_contains_no_session_secret() {
    let temp = tempfile::tempdir().unwrap();
    let store = BrowserStateStore::new(temp.path().join("browser-instance.json"));
    let state = BrowserInstanceState {
        instance_id: "browser-1".to_string(),
        status: BrowserInstanceStatus::Running,
        message: "ready".to_string(),
        started_at_ms: 123,
        tmux_session: "codexpp-browser-1".to_string(),
        access_port: Some(57340),
        auth_mode: BrowserAuthMode::PureApi,
        gateway_pid: Some(101),
        relay_pid: Some(102),
        electron_pid: Some(103),
        owned_pids: vec![101, 102, 103],
        failure_code: None,
    };

    store.save(&state).unwrap();
    let serialized = std::fs::read_to_string(store.path()).unwrap();

    assert_eq!(store.load().unwrap(), Some(state));
    assert!(!serialized.to_ascii_lowercase().contains("token"));
    assert!(!serialized.to_ascii_lowercase().contains("secret"));
}

#[test]
fn default_termination_policy_waits_ten_seconds_before_kill() {
    let policy = TerminationPolicy::default();

    assert_eq!(policy.term_grace_period(), Duration::from_secs(10));
}

#[tokio::test]
async fn gateway_serves_the_original_index_with_the_browser_shim_injected() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(
        temp.path().join("index.html"),
        r#"<!doctype html><html><head><title>Codex</title><meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; script-src &#39;self&#39; &#39;wasm-unsafe-eval&#39;; connect-src &#39;self&#39;;"></head><body>original</body></html>"#,
    )
    .unwrap();
    std::fs::write(temp.path().join("asset.js"), "window.originalAsset = true;").unwrap();
    let browser_token = BrowserSessionToken::generate();
    let relay_token = BrowserSessionToken::generate();
    let gateway = BrowserGateway::start(
        reserve_browser_gateway_port(None).unwrap(),
        BrowserGatewayConfig {
            webview_root: temp.path().to_path_buf(),
            browser_token,
            relay_token,
            browser_injection_script: String::new(),
            browser_helper_origin: "http://127.0.0.1:58421".to_string(),
        },
    )
    .await
    .unwrap();

    let index = reqwest::get(format!("http://127.0.0.1:{}/", gateway.port()))
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    let asset = reqwest::get(format!("http://127.0.0.1:{}/asset.js", gateway.port()))
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    let shim = reqwest::get(format!(
        "http://127.0.0.1:{}/__codexpp/browser-shim.js",
        gateway.port()
    ))
    .await
    .unwrap()
    .text()
    .await
    .unwrap();

    assert!(index.contains("/__codexpp/browser-shim.js"));
    assert!(index.contains("&#39;wasm-unsafe-eval&#39; &#39;unsafe-eval&#39;"));
    assert!(index.contains("connect-src http://127.0.0.1:58421 &#39;self&#39;"));
    assert!(index.contains("original"));
    assert_eq!(asset, "window.originalAsset = true;");
    assert!(shim.contains("message.type === \"window-message\""));
    assert!(shim.contains("message.type === \"worker-message\""));
    assert!(shim.contains("unsubscribeFromWorkerMessages"));
    assert!(shim.contains("var outboundQueue = []"));
    assert!(shim.contains("outboundQueue.push(envelope)"));
    assert!(shim.contains("getSentryInitOptions: function () { return null; }"));
    assert!(shim.contains("sessionStorage.setItem(SESSION_TOKEN_KEY, fragmentToken)"));
    assert!(shim.contains("sessionStorage.getItem(SESSION_TOKEN_KEY)"));
    assert!(shim.contains("message.type === \"authenticated\""));
    assert!(shim.contains("message.type === \"codex-plus-injection\""));
    assert!(shim.contains("(0, eval)(message.script);"));
    assert!(shim.contains("scheduleReconnect();"));
    assert!(shim.contains("socket.readyState !== WebSocket.OPEN || !socketAuthenticated"));
    let restore_token = shim
        .find("sessionStorage.getItem(SESSION_TOKEN_KEY)")
        .unwrap();
    let connect = shim.find("new WebSocket(endpoint()").unwrap();
    assert!(restore_token < connect);
    let authenticate = shim
        .find("currentSocket.send(JSON.stringify({ type: \"authenticate\"")
        .unwrap();
    let flush = shim.find("flushOutboundQueue();").unwrap();
    assert!(authenticate < flush);
    assert!(shim.contains("outboundQueue.length = 0"));
    gateway.shutdown().await;
}

#[tokio::test]
async fn gateway_acknowledges_an_authenticated_browser_controller() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join("index.html"), "<html><head></head></html>").unwrap();
    let browser_token = BrowserSessionToken::generate();
    let browser_secret = browser_token.expose_for_launch().to_string();
    let gateway = BrowserGateway::start(
        reserve_browser_gateway_port(None).unwrap(),
        BrowserGatewayConfig {
            webview_root: temp.path().to_path_buf(),
            browser_token,
            relay_token: BrowserSessionToken::generate(),
            browser_injection_script: "window.__CODEX_PLUS_VERSION__ = '1.2.41';".to_string(),
            browser_helper_origin: String::new(),
        },
    )
    .await
    .unwrap();

    let mut browser =
        connect_gateway_result(gateway.port(), GatewayPeerRole::Browser, &browser_secret)
            .await
            .unwrap();
    let acknowledgement = tokio::time::timeout(Duration::from_secs(1), browser.next())
        .await
        .expect("gateway did not acknowledge browser authentication")
        .unwrap()
        .unwrap()
        .into_text()
        .unwrap();

    assert_eq!(
        acknowledgement,
        json!({ "type": "authenticated", "role": "browser" }).to_string()
    );
    let injection = tokio::time::timeout(Duration::from_secs(1), browser.next())
        .await
        .expect("gateway did not send the Codex++ browser injection")
        .unwrap()
        .unwrap()
        .into_text()
        .unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&injection).unwrap(),
        json!({
            "type": "codex-plus-injection",
            "script": "window.__CODEX_PLUS_VERSION__ = '1.2.41';",
        })
    );
    gateway.shutdown().await;
}

#[tokio::test]
async fn gateway_forwards_apphost_frames_without_mutating_them() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join("index.html"), "<html><head></head></html>").unwrap();
    let browser_token = BrowserSessionToken::generate();
    let browser_secret = browser_token.expose_for_launch().to_string();
    let relay_token = BrowserSessionToken::generate();
    let relay_secret = relay_token.expose_for_launch().to_string();
    let gateway = BrowserGateway::start(
        reserve_browser_gateway_port(None).unwrap(),
        BrowserGatewayConfig {
            webview_root: temp.path().to_path_buf(),
            browser_token,
            relay_token,
            browser_injection_script: String::new(),
            browser_helper_origin: String::new(),
        },
    )
    .await
    .unwrap();

    let mut relay = connect_gateway(gateway.port(), GatewayPeerRole::Relay, &relay_secret).await;
    let mut browser =
        connect_gateway(gateway.port(), GatewayPeerRole::Browser, &browser_secret).await;
    assert_eq!(
        relay.next().await.unwrap().unwrap().into_text().unwrap(),
        json!({ "type": "gateway-browser-session-started" }).to_string()
    );
    let frame = json!({
        "type": "apphost",
        "payload": "{\"method\":\"thread/list\",\"id\":7}"
    })
    .to_string();

    browser
        .send(Message::Text(frame.clone().into()))
        .await
        .unwrap();

    assert_eq!(
        relay.next().await.unwrap().unwrap().into_text().unwrap(),
        frame
    );
    gateway.shutdown().await;
}

#[tokio::test]
async fn gateway_replaces_a_stale_browser_controller_with_a_new_authenticated_one() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join("index.html"), "<html><head></head></html>").unwrap();
    let browser_token = BrowserSessionToken::generate();
    let browser_secret = browser_token.expose_for_launch().to_string();
    let relay_token = BrowserSessionToken::generate();
    let relay_secret = relay_token.expose_for_launch().to_string();
    let gateway = BrowserGateway::start(
        reserve_browser_gateway_port(None).unwrap(),
        BrowserGatewayConfig {
            webview_root: temp.path().to_path_buf(),
            browser_token,
            relay_token,
            browser_injection_script: String::new(),
            browser_helper_origin: String::new(),
        },
    )
    .await
    .unwrap();

    let mut relay = connect_gateway(gateway.port(), GatewayPeerRole::Relay, &relay_secret).await;
    let mut first =
        connect_gateway(gateway.port(), GatewayPeerRole::Browser, &browser_secret).await;
    assert_eq!(
        relay.next().await.unwrap().unwrap().into_text().unwrap(),
        json!({ "type": "gateway-browser-session-started" }).to_string()
    );
    let _replacement =
        connect_gateway(gateway.port(), GatewayPeerRole::Browser, &browser_secret).await;

    let first_closed = tokio::time::timeout(Duration::from_secs(1), first.next())
        .await
        .expect("stale browser controller was not closed after takeover");
    assert!(
        first_closed.is_none()
            || first_closed.as_ref().is_some_and(|event| match event {
                Err(_) => true,
                Ok(message) => message.is_close(),
            }),
        "stale browser event after takeover: {first_closed:?}"
    );
    assert_eq!(
        relay.next().await.unwrap().unwrap().into_text().unwrap(),
        json!({ "type": "gateway-browser-session-started" }).to_string()
    );
    assert!(gateway.peer_connected(GatewayPeerRole::Browser));
    gateway.shutdown().await;
}

#[tokio::test]
async fn gateway_rejects_messages_larger_than_the_protocol_limit() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join("index.html"), "<html><head></head></html>").unwrap();
    let browser_token = BrowserSessionToken::generate();
    let browser_secret = browser_token.expose_for_launch().to_string();
    let gateway = BrowserGateway::start(
        reserve_browser_gateway_port(None).unwrap(),
        BrowserGatewayConfig {
            webview_root: temp.path().to_path_buf(),
            browser_token,
            relay_token: BrowserSessionToken::generate(),
            browser_injection_script: String::new(),
            browser_helper_origin: String::new(),
        },
    )
    .await
    .unwrap();
    let mut browser =
        connect_gateway(gateway.port(), GatewayPeerRole::Browser, &browser_secret).await;

    let oversized = "x".repeat(MAX_GATEWAY_MESSAGE_BYTES + 1);
    browser.send(Message::Text(oversized.into())).await.unwrap();
    let response = browser.next().await.unwrap().unwrap().into_text().unwrap();

    assert!(response.contains("message-too-large"));
    gateway.shutdown().await;
}

#[tokio::test]
async fn gateway_rebind_rotates_browser_token_and_preserves_the_relay() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join("index.html"), "<html><head></head></html>").unwrap();
    let browser_token = BrowserSessionToken::generate();
    let browser_secret = browser_token.expose_for_launch().to_string();
    let relay_token = BrowserSessionToken::generate();
    let relay_secret = relay_token.expose_for_launch().to_string();
    let gateway = BrowserGateway::start(
        reserve_browser_gateway_port(None).unwrap(),
        BrowserGatewayConfig {
            webview_root: temp.path().to_path_buf(),
            browser_token,
            relay_token,
            browser_injection_script: String::new(),
            browser_helper_origin: String::new(),
        },
    )
    .await
    .unwrap();
    let old_port = gateway.port();
    let mut relay = connect_gateway(old_port, GatewayPeerRole::Relay, &relay_secret).await;
    let mut old_browser =
        connect_gateway(old_port, GatewayPeerRole::Browser, &browser_secret).await;
    assert_eq!(
        relay.next().await.unwrap().unwrap().into_text().unwrap(),
        json!({ "type": "gateway-browser-session-started" }).to_string()
    );
    tokio::time::sleep(Duration::from_millis(20)).await;
    let preflight = json!({ "type": "apphost", "payload": "preflight" }).to_string();
    old_browser
        .send(Message::Text(preflight.clone().into()))
        .await
        .unwrap();
    assert_eq!(
        relay.next().await.unwrap().unwrap().into_text().unwrap(),
        preflight
    );

    let replacement_token = BrowserSessionToken::generate();
    let replacement_secret = replacement_token.expose_for_launch().to_string();
    let replacement = reserve_browser_gateway_port(None).unwrap();
    let replacement_port = replacement.port();
    gateway
        .rebind(replacement, replacement_token)
        .await
        .unwrap();

    assert_eq!(gateway.port(), replacement_port);
    let old_browser_closed = tokio::time::timeout(Duration::from_secs(1), old_browser.next())
        .await
        .expect("old browser controller was not closed after rebind");
    assert!(
        old_browser_closed.is_none()
            || old_browser_closed
                .as_ref()
                .is_some_and(|event| match event {
                    Err(_) => true,
                    Ok(message) => message.is_close(),
                }),
        "old browser event after rebind: {old_browser_closed:?}"
    );
    assert!(
        reqwest::get(format!("http://127.0.0.1:{old_port}/__codexpp/health"))
            .await
            .is_err()
    );

    let mut stale =
        connect_gateway_result(replacement_port, GatewayPeerRole::Browser, &browser_secret)
            .await
            .unwrap();
    let stale_response = stale.next().await.unwrap().unwrap().into_text().unwrap();
    assert!(stale_response.contains("unauthorized"));

    let mut browser = connect_gateway(
        replacement_port,
        GatewayPeerRole::Browser,
        &replacement_secret,
    )
    .await;
    assert_eq!(
        relay.next().await.unwrap().unwrap().into_text().unwrap(),
        json!({ "type": "gateway-browser-session-started" }).to_string()
    );
    let frame = json!({
        "type": "apphost",
        "payload": "{\"method\":\"thread/read\",\"id\":8}"
    })
    .to_string();
    browser
        .send(Message::Text(frame.clone().into()))
        .await
        .unwrap();

    assert_eq!(
        relay.next().await.unwrap().unwrap().into_text().unwrap(),
        frame
    );
    gateway.shutdown().await;
}

#[tokio::test]
async fn gateway_readiness_waits_for_the_hidden_relay_peer() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join("index.html"), "<html><head></head></html>").unwrap();
    let relay_token = BrowserSessionToken::generate();
    let relay_secret = relay_token.expose_for_launch().to_string();
    let gateway = BrowserGateway::start(
        reserve_browser_gateway_port(None).unwrap(),
        BrowserGatewayConfig {
            webview_root: temp.path().to_path_buf(),
            browser_token: BrowserSessionToken::generate(),
            relay_token,
            browser_injection_script: String::new(),
            browser_helper_origin: String::new(),
        },
    )
    .await
    .unwrap();

    assert!(
        !gateway
            .wait_for_peer(GatewayPeerRole::Relay, Duration::from_millis(20))
            .await
    );
    let _relay = connect_gateway(gateway.port(), GatewayPeerRole::Relay, &relay_secret).await;
    assert!(
        gateway
            .wait_for_peer(GatewayPeerRole::Relay, Duration::from_secs(1))
            .await
    );
    assert!(gateway.peer_connected(GatewayPeerRole::Relay));
    gateway.shutdown().await;
}

#[tokio::test]
async fn gateway_file_origin_is_restricted_to_the_hidden_relay() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join("index.html"), "<html><head></head></html>").unwrap();
    let browser_token = BrowserSessionToken::generate();
    let browser_secret = browser_token.expose_for_launch().to_string();
    let relay_token = BrowserSessionToken::generate();
    let relay_secret = relay_token.expose_for_launch().to_string();
    let gateway = BrowserGateway::start(
        reserve_browser_gateway_port(None).unwrap(),
        BrowserGatewayConfig {
            webview_root: temp.path().to_path_buf(),
            browser_token,
            relay_token,
            browser_injection_script: String::new(),
            browser_helper_origin: String::new(),
        },
    )
    .await
    .unwrap();

    let _relay = connect_gateway_result_with_origin(
        gateway.port(),
        GatewayPeerRole::Relay,
        &relay_secret,
        "file://",
    )
    .await
    .unwrap();
    assert!(
        gateway
            .wait_for_peer(GatewayPeerRole::Relay, Duration::from_secs(1))
            .await
    );

    let mut browser = connect_gateway_result_with_origin(
        gateway.port(),
        GatewayPeerRole::Browser,
        &browser_secret,
        "file://",
    )
    .await
    .unwrap();
    let unauthorized = browser.next().await.unwrap().unwrap().into_text().unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&unauthorized).unwrap(),
        json!({ "type": "error", "code": "unauthorized" })
    );
    assert!(!gateway.peer_connected(GatewayPeerRole::Browser));
    gateway.shutdown().await;
}

async fn connect_gateway(
    port: u16,
    role: GatewayPeerRole,
    token: &str,
) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>> {
    let mut socket = connect_gateway_result(port, role, token).await.unwrap();
    if role == GatewayPeerRole::Browser {
        let acknowledgement = tokio::time::timeout(Duration::from_secs(1), socket.next())
            .await
            .expect("gateway did not acknowledge browser authentication")
            .unwrap()
            .unwrap()
            .into_text()
            .unwrap();
        assert_eq!(
            acknowledgement,
            json!({ "type": "authenticated", "role": "browser" }).to_string()
        );
    }
    socket
}

async fn connect_gateway_result(
    port: u16,
    role: GatewayPeerRole,
    token: &str,
) -> Result<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    tokio_tungstenite::tungstenite::Error,
> {
    connect_gateway_result_with_origin(port, role, token, &format!("http://127.0.0.1:{port}")).await
}

async fn connect_gateway_result_with_origin(
    port: u16,
    role: GatewayPeerRole,
    token: &str,
    origin: &str,
) -> Result<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    tokio_tungstenite::tungstenite::Error,
> {
    let request = tokio_tungstenite::tungstenite::http::Request::builder()
        .uri(format!("ws://127.0.0.1:{port}/__codexpp/ws"))
        .header("Host", format!("127.0.0.1:{port}"))
        .header("Origin", origin)
        .header("Upgrade", "websocket")
        .header("Connection", "Upgrade")
        .header("Sec-WebSocket-Version", "13")
        .header("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
        .header("Sec-WebSocket-Protocol", "codexpp-browser-v1")
        .body(())
        .unwrap();
    let (mut socket, _) = tokio_tungstenite::connect_async(request).await?;
    socket
        .send(Message::Text(
            json!({
                "type": "authenticate",
                "role": role,
                "token": token
            })
            .to_string()
            .into(),
        ))
        .await?;
    Ok(socket)
}
