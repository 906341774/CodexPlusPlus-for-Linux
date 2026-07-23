use std::fs;
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::time::Duration;

use anyhow::Context;
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener as TokioTcpListener, TcpStream};
use tokio::sync::{Mutex, Notify, mpsc, oneshot};
use tokio_tungstenite::accept_hdr_async;
use tokio_tungstenite::tungstenite::{
    Message,
    handshake::server::{Request, Response},
};

const MIN_BROWSER_PORT: u16 = 49_152;
const MAX_BROWSER_PORT: u16 = 65_535;
const AUTO_PORT_ATTEMPTS: usize = 256;
pub const MAX_GATEWAY_MESSAGE_BYTES: usize = 8 * 1024 * 1024;
const BROWSER_WEBSOCKET_PATH: &str = "/__codexpp/ws";
const BROWSER_SHIM_PATH: &str = "/__codexpp/browser-shim.js";
const GATEWAY_BROWSER_SESSION_STARTED: &str = "gateway-browser-session-started";
const MAX_HTTP_HEADER_BYTES: usize = 64 * 1024;

#[derive(Debug)]
pub struct ReservedBrowserPort {
    listener: TcpListener,
    port: u16,
}

impl ReservedBrowserPort {
    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn into_listener(self) -> TcpListener {
        self.listener
    }
}

pub fn reserve_browser_gateway_port(
    requested: Option<u16>,
) -> std::io::Result<ReservedBrowserPort> {
    if let Some(port) = requested {
        if !(MIN_BROWSER_PORT..=MAX_BROWSER_PORT).contains(&port) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!(
                    "browser gateway port must be between {MIN_BROWSER_PORT} and {MAX_BROWSER_PORT}"
                ),
            ));
        }
        return reserve_port(port);
    }

    let span = u32::from(MAX_BROWSER_PORT - MIN_BROWSER_PORT) + 1;
    let seed = uuid::Uuid::new_v4().as_u128();
    for attempt in 0..AUTO_PORT_ATTEMPTS {
        let offset = ((seed.wrapping_add(attempt as u128)) % u128::from(span)) as u16;
        let port = MIN_BROWSER_PORT + offset;
        match reserve_port(port) {
            Ok(reservation) => return Ok(reservation),
            Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => continue,
            Err(error) => return Err(error),
        }
    }

    Err(std::io::Error::new(
        std::io::ErrorKind::AddrNotAvailable,
        "could not reserve a high loopback port for the browser gateway",
    ))
}

fn reserve_port(port: u16) -> std::io::Result<ReservedBrowserPort> {
    let listener = TcpListener::bind(("127.0.0.1", port))?;
    Ok(ReservedBrowserPort { listener, port })
}

#[derive(Debug, Clone)]
pub struct BrowserSessionToken {
    exposed: String,
    digest: [u8; 32],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GatewayPeerRole {
    Browser,
    Relay,
}

#[derive(Debug, Clone)]
pub struct BrowserGatewayConfig {
    pub webview_root: PathBuf,
    pub browser_token: BrowserSessionToken,
    pub relay_token: BrowserSessionToken,
    pub browser_injection_script: String,
    pub browser_helper_origin: String,
}

#[derive(Debug)]
pub struct BrowserGateway {
    port: std::sync::Arc<AtomicU16>,
    presence: std::sync::Arc<GatewayPresence>,
    commands: mpsc::UnboundedSender<GatewayCommand>,
    task: tokio::task::JoinHandle<()>,
}

struct GatewayState {
    port: std::sync::Arc<AtomicU16>,
    webview_root: PathBuf,
    browser_token: std::sync::RwLock<BrowserSessionToken>,
    relay_token: BrowserSessionToken,
    browser_injection_script: String,
    browser_helper_origin: String,
    presence: std::sync::Arc<GatewayPresence>,
    connections: Mutex<GatewayConnections>,
    next_connection_id: std::sync::atomic::AtomicU64,
}

#[derive(Debug, Default)]
struct GatewayPresence {
    browser: AtomicBool,
    relay: AtomicBool,
    changed: Notify,
}

impl GatewayPresence {
    fn connected(&self, role: GatewayPeerRole) -> bool {
        match role {
            GatewayPeerRole::Browser => self.browser.load(Ordering::Relaxed),
            GatewayPeerRole::Relay => self.relay.load(Ordering::Relaxed),
        }
    }

    fn set_connected(&self, role: GatewayPeerRole, connected: bool) {
        match role {
            GatewayPeerRole::Browser => self.browser.store(connected, Ordering::Relaxed),
            GatewayPeerRole::Relay => self.relay.store(connected, Ordering::Relaxed),
        }
        self.changed.notify_waiters();
    }
}

enum GatewayCommand {
    Rebind {
        listener: TokioTcpListener,
        port: u16,
        browser_token: BrowserSessionToken,
        response: oneshot::Sender<anyhow::Result<()>>,
    },
    Shutdown,
}

#[derive(Default)]
struct GatewayConnections {
    browser: Option<GatewayPeer>,
    relay: Option<GatewayPeer>,
}

struct GatewayPeer {
    id: u64,
    sender: mpsc::UnboundedSender<Message>,
}

#[derive(Debug, Deserialize)]
struct GatewayAuthentication {
    #[serde(rename = "type")]
    message_type: String,
    role: GatewayPeerRole,
    token: String,
}

impl BrowserGateway {
    pub async fn start(
        reservation: ReservedBrowserPort,
        config: BrowserGatewayConfig,
    ) -> anyhow::Result<Self> {
        let port = reservation.port();
        let listener = reservation.into_listener();
        listener.set_nonblocking(true)?;
        let listener = TokioTcpListener::from_std(listener)?;
        let root = config.webview_root.canonicalize().with_context(|| {
            format!(
                "webview root does not exist: {}",
                config.webview_root.display()
            )
        })?;
        let port = std::sync::Arc::new(AtomicU16::new(port));
        let presence = std::sync::Arc::new(GatewayPresence::default());
        let state = std::sync::Arc::new(GatewayState {
            port: std::sync::Arc::clone(&port),
            webview_root: root,
            browser_token: std::sync::RwLock::new(config.browser_token),
            relay_token: config.relay_token,
            browser_injection_script: config.browser_injection_script,
            browser_helper_origin: config.browser_helper_origin,
            presence: std::sync::Arc::clone(&presence),
            connections: Mutex::new(GatewayConnections::default()),
            next_connection_id: std::sync::atomic::AtomicU64::new(1),
        });
        let (commands, mut command_rx) = mpsc::unbounded_channel();
        let task = tokio::spawn(async move {
            let mut listener = listener;
            loop {
                tokio::select! {
                    command = command_rx.recv() => {
                        match command {
                            Some(GatewayCommand::Rebind { listener: replacement, port, browser_token, response }) => {
                                listener = replacement;
                                state.port.store(port, Ordering::Relaxed);
                                let result = state.browser_token.write()
                                    .map(|mut current| {
                                        *current = browser_token;
                                        ()
                                    })
                                    .map_err(|_| anyhow::anyhow!("browser gateway token lock was poisoned"));
                                if result.is_ok() {
                                    disconnect_browser(&state).await;
                                }
                                let _ = response.send(result);
                            }
                            Some(GatewayCommand::Shutdown) | None => break,
                        }
                    }
                    accepted = listener.accept() => {
                        let Ok((stream, _address)) = accepted else { continue };
                        let state = std::sync::Arc::clone(&state);
                        tokio::spawn(async move {
                            let _ = handle_gateway_connection(stream, state).await;
                        });
                    }
                }
            }
        });
        Ok(Self {
            port,
            presence,
            commands,
            task,
        })
    }

    pub fn port(&self) -> u16 {
        self.port.load(Ordering::Relaxed)
    }

    pub fn peer_connected(&self, role: GatewayPeerRole) -> bool {
        self.presence.connected(role)
    }

    pub async fn wait_for_peer(&self, role: GatewayPeerRole, timeout: Duration) -> bool {
        if self.peer_connected(role) {
            return true;
        }
        tokio::time::timeout(timeout, async {
            loop {
                self.presence.changed.notified().await;
                if self.peer_connected(role) {
                    return;
                }
            }
        })
        .await
        .is_ok()
    }

    pub async fn rebind(
        &self,
        reservation: ReservedBrowserPort,
        browser_token: BrowserSessionToken,
    ) -> anyhow::Result<()> {
        let port = reservation.port();
        let listener = reservation.into_listener();
        listener.set_nonblocking(true)?;
        let listener = TokioTcpListener::from_std(listener)?;
        let (response, result) = oneshot::channel();
        self.commands
            .send(GatewayCommand::Rebind {
                listener,
                port,
                browser_token,
                response,
            })
            .map_err(|_| anyhow::anyhow!("browser gateway task has stopped"))?;
        result
            .await
            .map_err(|_| anyhow::anyhow!("browser gateway rebind response was dropped"))?
    }

    pub async fn shutdown(self) {
        let _ = self.commands.send(GatewayCommand::Shutdown);
        let _ = self.task.await;
    }
}

async fn handle_gateway_connection(
    mut stream: TcpStream,
    state: std::sync::Arc<GatewayState>,
) -> anyhow::Result<()> {
    let mut probe = [0_u8; 4096];
    let read = stream.peek(&mut probe).await?;
    let request = String::from_utf8_lossy(&probe[..read]).to_ascii_lowercase();
    if request.contains("\r\nupgrade: websocket") || request.contains("\r\nsec-websocket-key:") {
        handle_gateway_websocket(stream, state).await
    } else {
        handle_gateway_http(&mut stream, &state).await
    }
}

async fn handle_gateway_websocket(
    stream: TcpStream,
    state: std::sync::Arc<GatewayState>,
) -> anyhow::Result<()> {
    let port = state.port.load(Ordering::Relaxed);
    let relay_only_origin = std::sync::Arc::new(AtomicBool::new(false));
    let handshake_relay_only_origin = std::sync::Arc::clone(&relay_only_origin);
    let websocket = accept_hdr_async(stream, move |request: &Request, response: Response| {
        let origin = request
            .headers()
            .get("origin")
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default();
        let allowed_path = request.uri().path() == BROWSER_WEBSOCKET_PATH;
        let browser_origin = is_allowed_browser_origin(origin, port);
        let relay_origin = is_allowed_relay_origin(origin);
        if !allowed_path || !browser_origin && !relay_origin {
            let error = Response::builder()
                .status(403)
                .body(Some("forbidden".to_string()))
                .unwrap();
            return Err(error);
        }
        handshake_relay_only_origin.store(relay_origin && !browser_origin, Ordering::Relaxed);
        let mut response = response;
        response.headers_mut().insert(
            "Sec-WebSocket-Protocol",
            "codexpp-browser-v1".parse().unwrap(),
        );
        Ok(response)
    })
    .await
    .context("browser gateway websocket handshake failed")?;
    let (mut outgoing, mut incoming) = websocket.split();
    let auth = tokio::time::timeout(Duration::from_secs(10), incoming.next())
        .await
        .context("browser gateway authentication timed out")?
        .transpose()
        .context("browser gateway authentication read failed")?
        .context("browser gateway closed before authentication")?;
    let auth = parse_gateway_authentication(auth)?;
    if relay_only_origin.load(Ordering::Relaxed) && auth.role != GatewayPeerRole::Relay
        || !verify_gateway_authentication(&state, &auth)
    {
        outgoing
            .send(Message::Text(gateway_error("unauthorized").into()))
            .await
            .ok();
        return Ok(());
    }

    let id = state
        .next_connection_id
        .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let (sender, mut receiver) = mpsc::unbounded_channel();
    if !register_gateway_peer(&state, auth.role, id, sender.clone()).await {
        outgoing
            .send(Message::Text(gateway_error("controller-in-use").into()))
            .await
            .ok();
        return Ok(());
    }
    if auth.role == GatewayPeerRole::Browser {
        sender
            .send(Message::Text(
                serde_json::json!({
                    "type": "authenticated",
                    "role": GatewayPeerRole::Browser,
                })
                .to_string()
                .into(),
            ))
            .ok();
        if !state.browser_injection_script.is_empty() {
            sender
                .send(Message::Text(
                    serde_json::json!({
                        "type": "codex-plus-injection",
                        "script": state.browser_injection_script,
                    })
                    .to_string()
                    .into(),
                ))
                .ok();
        }
    }
    let writer = tokio::spawn(async move {
        while let Some(message) = receiver.recv().await {
            let close = message.is_close();
            if outgoing.send(message).await.is_err() {
                break;
            }
            if close {
                let _ = outgoing.close().await;
                break;
            }
        }
    });

    while let Some(message) = incoming.next().await {
        let message = message.context("browser gateway websocket read failed")?;
        if message.is_close() {
            break;
        }
        if message.len() > MAX_GATEWAY_MESSAGE_BYTES {
            sender
                .send(Message::Text(gateway_error("message-too-large").into()))
                .ok();
            break;
        }
        forward_gateway_message(&state, auth.role, id, message).await;
    }

    unregister_gateway_peer(&state, auth.role, id).await;
    drop(sender);
    let _ = writer.await;
    Ok(())
}

fn parse_gateway_authentication(message: Message) -> anyhow::Result<GatewayAuthentication> {
    let text = message
        .into_text()
        .context("browser gateway authentication must be text")?;
    let auth: GatewayAuthentication =
        serde_json::from_str(&text).context("browser gateway authentication is not valid JSON")?;
    if auth.message_type != "authenticate" || auth.token.is_empty() {
        anyhow::bail!("invalid browser gateway authentication message");
    }
    Ok(auth)
}

fn verify_gateway_authentication(
    state: &GatewayState,
    authentication: &GatewayAuthentication,
) -> bool {
    match authentication.role {
        GatewayPeerRole::Browser => state
            .browser_token
            .read()
            .map(|token| token.verify(&authentication.token))
            .unwrap_or(false),
        GatewayPeerRole::Relay => state.relay_token.verify(&authentication.token),
    }
}

async fn disconnect_browser(state: &std::sync::Arc<GatewayState>) {
    let peer = state.connections.lock().await.browser.take();
    if let Some(peer) = peer {
        state
            .presence
            .set_connected(GatewayPeerRole::Browser, false);
        let _ = peer.sender.send(Message::Close(None));
    }
}

async fn register_gateway_peer(
    state: &GatewayState,
    role: GatewayPeerRole,
    id: u64,
    sender: mpsc::UnboundedSender<Message>,
) -> bool {
    let mut connections = state.connections.lock().await;
    match role {
        GatewayPeerRole::Browser => {
            if let Some(previous) = connections.browser.replace(GatewayPeer { id, sender }) {
                previous.sender.send(Message::Close(None)).ok();
            }
            if let Some(relay) = connections.relay.as_ref() {
                relay
                    .sender
                    .send(Message::Text(
                        serde_json::json!({ "type": GATEWAY_BROWSER_SESSION_STARTED })
                            .to_string()
                            .into(),
                    ))
                    .ok();
            }
        }
        GatewayPeerRole::Relay => {
            if connections.relay.is_some() {
                return false;
            }
            if connections.browser.is_some() {
                sender
                    .send(Message::Text(
                        serde_json::json!({ "type": GATEWAY_BROWSER_SESSION_STARTED })
                            .to_string()
                            .into(),
                    ))
                    .ok();
            }
            connections.relay = Some(GatewayPeer { id, sender });
        }
    }
    state.presence.set_connected(role, true);
    true
}

async fn unregister_gateway_peer(state: &GatewayState, role: GatewayPeerRole, id: u64) {
    let mut connections = state.connections.lock().await;
    let slot = match role {
        GatewayPeerRole::Browser => &mut connections.browser,
        GatewayPeerRole::Relay => &mut connections.relay,
    };
    if slot.as_ref().is_some_and(|peer| peer.id == id) {
        *slot = None;
        state.presence.set_connected(role, false);
    }
}

async fn forward_gateway_message(
    state: &GatewayState,
    sender_role: GatewayPeerRole,
    sender_id: u64,
    message: Message,
) {
    if message
        .to_text()
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(text).ok())
        .and_then(|message| {
            message
                .get("type")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned)
        })
        .as_deref()
        == Some(GATEWAY_BROWSER_SESSION_STARTED)
    {
        return;
    }
    let connections = state.connections.lock().await;
    let sender_is_current = match sender_role {
        GatewayPeerRole::Browser => connections
            .browser
            .as_ref()
            .is_some_and(|peer| peer.id == sender_id),
        GatewayPeerRole::Relay => connections
            .relay
            .as_ref()
            .is_some_and(|peer| peer.id == sender_id),
    };
    if !sender_is_current {
        return;
    }
    let target = match sender_role {
        GatewayPeerRole::Browser => connections.relay.as_ref(),
        GatewayPeerRole::Relay => connections.browser.as_ref(),
    };
    if let Some(target) = target {
        target.sender.send(message).ok();
    }
}

fn gateway_error(code: &str) -> String {
    serde_json::json!({ "type": "error", "code": code }).to_string()
}

async fn handle_gateway_http(stream: &mut TcpStream, state: &GatewayState) -> anyhow::Result<()> {
    let mut buffer = vec![0_u8; MAX_HTTP_HEADER_BYTES];
    let read = stream.read(&mut buffer).await?;
    if read == buffer.len()
        && !buffer[..read]
            .windows(4)
            .any(|window| window == b"\r\n\r\n")
    {
        write_http_response(
            stream,
            431,
            "text/plain; charset=utf-8",
            b"request headers too large",
        )
        .await?;
        return Ok(());
    }
    let request = String::from_utf8_lossy(&buffer[..read]);
    let request_line = request.lines().next().unwrap_or_default();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let raw_path = parts.next().unwrap_or_default();
    if method != "GET" {
        write_http_response(
            stream,
            405,
            "text/plain; charset=utf-8",
            b"method not allowed",
        )
        .await?;
        return Ok(());
    }
    let path = raw_path.split('?').next().unwrap_or("/");
    if path == "/__codexpp/health" {
        write_http_response(
            stream,
            200,
            "application/json; charset=utf-8",
            br#"{"status":"ok","service":"codex-plus-browser-gateway"}"#,
        )
        .await?;
        return Ok(());
    }
    if path == BROWSER_SHIM_PATH {
        write_http_response(
            stream,
            200,
            "application/javascript; charset=utf-8",
            BROWSER_SHIM.as_bytes(),
        )
        .await?;
        return Ok(());
    }

    let relative = if path == "/" {
        "index.html"
    } else {
        path.trim_start_matches('/')
    };
    if relative.is_empty() || relative.contains("..") || relative.contains('\\') {
        write_http_response(stream, 404, "text/plain; charset=utf-8", b"not found").await?;
        return Ok(());
    }
    let candidate = state.webview_root.join(relative);
    let canonical = match candidate.canonicalize() {
        Ok(path) => path,
        Err(_) => {
            write_http_response(stream, 404, "text/plain; charset=utf-8", b"not found").await?;
            return Ok(());
        }
    };
    if !canonical.starts_with(&state.webview_root) || !canonical.is_file() {
        write_http_response(stream, 404, "text/plain; charset=utf-8", b"not found").await?;
        return Ok(());
    }
    let mut body = fs::read(&canonical)?;
    let content_type = content_type_for_path(&canonical);
    if relative == "index.html" {
        let source = String::from_utf8_lossy(&body);
        let injected = inject_browser_shim(&source, &state.browser_helper_origin);
        body = injected.into_bytes();
    }
    write_http_response(stream, 200, content_type, &body).await
}

fn inject_browser_shim(source: &str, browser_helper_origin: &str) -> String {
    let source = allow_browser_rpc_eval(source);
    let source = allow_browser_helper_connect(&source, browser_helper_origin);
    let script = format!("<script src=\"{BROWSER_SHIM_PATH}\"></script>");
    if source.contains(BROWSER_SHIM_PATH) {
        return source;
    }
    if let Some(index) = source.find("</head>") {
        let mut result = String::with_capacity(source.len() + script.len());
        result.push_str(&source[..index]);
        result.push_str(&script);
        result.push_str(&source[index..]);
        return result;
    }
    format!("{script}{source}")
}

fn allow_browser_helper_connect(source: &str, browser_helper_origin: &str) -> String {
    let origin = browser_helper_origin.trim().trim_end_matches('/');
    let Ok(url) = url::Url::parse(origin) else {
        return source.to_string();
    };
    if url.scheme() != "http"
        || !matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "::1"))
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return source.to_string();
    }
    if source.contains(origin) {
        return source.to_string();
    }
    if source.contains("connect-src ") {
        return source.replacen("connect-src ", &format!("connect-src {origin} "), 1);
    }
    let Some(meta) = source.find("http-equiv=\"Content-Security-Policy\"") else {
        return source.to_string();
    };
    let Some(relative_content) = source[meta..].find("content=\"") else {
        return source.to_string();
    };
    let insert = meta + relative_content + "content=\"".len();
    let directive = format!("connect-src {origin}; ");
    let mut result = String::with_capacity(source.len() + directive.len());
    result.push_str(&source[..insert]);
    result.push_str(&directive);
    result.push_str(&source[insert..]);
    result
}

fn allow_browser_rpc_eval(source: &str) -> String {
    const ENCODED_WASM_EVAL: &str = "&#39;wasm-unsafe-eval&#39;";
    const ENCODED_UNSAFE_EVAL: &str = "&#39;unsafe-eval&#39;";
    const WASM_EVAL: &str = "'wasm-unsafe-eval'";
    const UNSAFE_EVAL: &str = "'unsafe-eval'";

    if source.contains(ENCODED_WASM_EVAL) && !source.contains(ENCODED_UNSAFE_EVAL) {
        return source.replacen(
            ENCODED_WASM_EVAL,
            &format!("{ENCODED_WASM_EVAL} {ENCODED_UNSAFE_EVAL}"),
            1,
        );
    }
    if source.contains(WASM_EVAL) && !source.contains(UNSAFE_EVAL) {
        return source.replacen(WASM_EVAL, &format!("{WASM_EVAL} {UNSAFE_EVAL}"), 1);
    }
    source.to_string()
}

fn content_type_for_path(path: &Path) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("js") => "application/javascript; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("woff" | "woff2") => "font/woff2",
        _ => "application/octet-stream",
    }
}

async fn write_http_response(
    stream: &mut TcpStream,
    status: u16,
    content_type: &str,
    body: &[u8],
) -> anyhow::Result<()> {
    let reason = match status {
        200 => "OK",
        404 => "Not Found",
        405 => "Method Not Allowed",
        431 => "Request Header Fields Too Large",
        _ => "Error",
    };
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(header.as_bytes()).await?;
    stream.write_all(body).await?;
    Ok(())
}

const BROWSER_SHIM: &str = include_str!("../assets/browser-shim.js");

impl BrowserSessionToken {
    pub fn generate() -> Self {
        let exposed = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        let digest = token_digest(&exposed);
        Self { exposed, digest }
    }

    pub fn from_exposed(exposed: &str) -> Option<Self> {
        if exposed.len() != 64 || !exposed.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return None;
        }
        let exposed = exposed.to_ascii_lowercase();
        Some(Self {
            digest: token_digest(&exposed),
            exposed,
        })
    }

    pub fn expose_for_launch(&self) -> &str {
        &self.exposed
    }

    pub fn verify(&self, candidate: &str) -> bool {
        constant_time_eq(&self.digest, &token_digest(candidate))
    }
}

fn token_digest(value: &str) -> [u8; 32] {
    Sha256::digest(value.as_bytes()).into()
}

fn constant_time_eq(left: &[u8; 32], right: &[u8; 32]) -> bool {
    left.iter()
        .zip(right.iter())
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

pub fn is_allowed_browser_origin(origin: &str, gateway_port: u16) -> bool {
    let Ok(url) = url::Url::parse(origin) else {
        return false;
    };
    if url.scheme() != "http" || url.port_or_known_default() != Some(gateway_port) {
        return false;
    }
    matches!(
        url.host_str(),
        Some("127.0.0.1" | "localhost" | "::1" | "[::1]")
    )
}

fn is_allowed_relay_origin(origin: &str) -> bool {
    matches!(origin.trim(), "file://" | "null")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BrowserInstanceStatus {
    Starting,
    Running,
    Degraded,
    Reconfiguring,
    Stopping,
    Stopped,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BrowserAuthMode {
    ChatgptOauth,
    PureApi,
    MixedApi,
    NotAuthenticated,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserInstanceState {
    pub instance_id: String,
    pub status: BrowserInstanceStatus,
    pub message: String,
    pub started_at_ms: u64,
    pub tmux_session: String,
    pub access_port: Option<u16>,
    pub auth_mode: BrowserAuthMode,
    pub gateway_pid: Option<u32>,
    pub relay_pid: Option<u32>,
    pub electron_pid: Option<u32>,
    pub owned_pids: Vec<u32>,
    pub failure_code: Option<String>,
}

#[derive(Debug, Clone)]
pub struct BrowserStateStore {
    path: PathBuf,
}

impl BrowserStateStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn save(&self, state: &BrowserInstanceState) -> anyhow::Result<()> {
        let bytes = serde_json::to_vec_pretty(state)?;
        crate::settings::atomic_write(&self.path, &bytes)
    }

    pub fn load(&self) -> anyhow::Result<Option<BrowserInstanceState>> {
        let contents = match fs::read_to_string(&self.path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "failed to read browser instance state {}",
                        self.path.display()
                    )
                });
            }
        };
        Ok(serde_json::from_str(&contents).ok())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminationPolicy {
    term_grace_period: Duration,
}

impl Default for TerminationPolicy {
    fn default() -> Self {
        Self {
            term_grace_period: Duration::from_secs(10),
        }
    }
}

impl TerminationPolicy {
    pub fn term_grace_period(self) -> Duration {
        self.term_grace_period
    }
}
