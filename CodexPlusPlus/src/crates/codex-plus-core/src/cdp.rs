use anyhow::{Context, bail};
use serde::Deserialize;
use std::net::IpAddr;
use std::time::Duration;
use url::{Host, Url};

const CDP_HTTP_TIMEOUT: Duration = Duration::from_secs(3);
const LINUX_CODEX_WEBVIEW_PORT_START: u16 = 5176;
const LINUX_CODEX_WEBVIEW_PORT_END: u16 = 5185;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct CdpTarget {
    pub id: String,
    #[serde(rename = "type")]
    pub target_type: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub url: String,
    #[serde(default, rename = "webSocketDebuggerUrl")]
    pub web_socket_debugger_url: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct CdpBrowserIdentity {
    #[serde(rename = "Browser")]
    pub browser: String,
    #[serde(rename = "webSocketDebuggerUrl")]
    pub web_socket_debugger_url: String,
}

impl CdpBrowserIdentity {
    pub fn browser_id(&self) -> anyhow::Result<String> {
        let url = reqwest::Url::parse(&self.web_socket_debugger_url)
            .context("invalid browser WebSocket URL")?;
        let mut segments = url
            .path_segments()
            .ok_or_else(|| anyhow::anyhow!("browser WebSocket URL has no path"))?;
        match (segments.next(), segments.next(), segments.next()) {
            (Some("devtools"), Some("browser"), Some(id)) if !id.is_empty() => Ok(id.to_string()),
            _ => bail!("browser WebSocket URL has no Browser ID"),
        }
    }
}

pub async fn list_targets(debug_port: u16) -> anyhow::Result<Vec<CdpTarget>> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(CDP_HTTP_TIMEOUT)
        .build()
        .context("failed to build CDP HTTP client")?;

    let urls = [
        format!("http://127.0.0.1:{debug_port}/json"),
        format!("http://[::1]:{debug_port}/json"),
    ];
    let mut errors = Vec::new();
    for url in urls {
        match query_targets_url(&client, &url, debug_port).await {
            Ok(targets) => return Ok(targets),
            Err(error) => errors.push(format!("{url}: {error:#}")),
        }
    }

    bail!(
        "failed to query CDP targets on loopback addresses: {}",
        errors.join("; ")
    )
}

pub async fn browser_identity(debug_port: u16) -> anyhow::Result<CdpBrowserIdentity> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(CDP_HTTP_TIMEOUT)
        .build()
        .context("failed to build CDP HTTP client")?;
    let urls = [
        format!("http://127.0.0.1:{debug_port}/json/version"),
        format!("http://[::1]:{debug_port}/json/version"),
    ];
    let mut errors = Vec::new();
    for url in urls {
        let result = async {
            let identity = client
                .get(&url)
                .send()
                .await
                .context("failed to query CDP browser identity")?
                .error_for_status()
                .context("CDP browser identity query failed")?
                .json::<CdpBrowserIdentity>()
                .await
                .context("failed to deserialize CDP browser identity")?;
            validate_cdp_websocket_url(&identity.web_socket_debugger_url, debug_port)?;
            identity.browser_id()?;
            anyhow::Ok(identity)
        }
        .await;
        match result {
            Ok(identity) => return Ok(identity),
            Err(error) => errors.push(format!("{url}: {error:#}")),
        }
    }
    bail!(
        "failed to query CDP browser identity on loopback addresses: {}",
        errors.join("; ")
    )
}

async fn query_targets_url(
    client: &reqwest::Client,
    url: &str,
    debug_port: u16,
) -> anyhow::Result<Vec<CdpTarget>> {
    let response = client
        .get(url)
        .send()
        .await
        .context("failed to query CDP targets")?
        .error_for_status()
        .context("CDP target query failed")?;

    let targets = response
        .json::<Vec<CdpTarget>>()
        .await
        .context("failed to deserialize CDP targets")?;
    for target in &targets {
        if let Some(websocket_url) = target.web_socket_debugger_url.as_deref() {
            validate_cdp_websocket_url(websocket_url, debug_port).with_context(|| {
                format!("unsafe CDP target WebSocket URL for target {}", target.id)
            })?;
        }
    }
    Ok(targets)
}

pub fn validate_cdp_websocket_url(url: &str, expected_port: u16) -> anyhow::Result<()> {
    let parsed = reqwest::Url::parse(url).context("invalid CDP WebSocket URL")?;
    if !matches!(parsed.scheme(), "ws" | "wss") {
        bail!("CDP WebSocket URL must use ws or wss");
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("CDP WebSocket URL has no host"))?;
    let address = host
        .trim_start_matches('[')
        .trim_end_matches(']')
        .parse::<IpAddr>()
        .with_context(|| "CDP WebSocket host must be a loopback IP address")?;
    if !address.is_loopback() {
        bail!("CDP WebSocket host must be loopback");
    }
    let port = parsed
        .port()
        .ok_or_else(|| anyhow::anyhow!("CDP WebSocket URL must include an explicit port"))?;
    if port != expected_port {
        bail!("CDP WebSocket port {port} does not match debug port {expected_port}");
    }
    Ok(())
}

pub fn pick_page_target(targets: &[CdpTarget]) -> anyhow::Result<CdpTarget> {
    injectable_page_targets(targets)
        .first()
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("No injectable page target found"))
}

pub fn pick_injectable_codex_page_target(targets: &[CdpTarget]) -> anyhow::Result<CdpTarget> {
    injectable_page_targets(targets)
        .into_iter()
        .find(is_primary_codex_page_target)
        .ok_or_else(|| anyhow::anyhow!("No injectable Codex page target found"))
}

pub fn injectable_page_targets(targets: &[CdpTarget]) -> Vec<CdpTarget> {
    let mut codex_pages = Vec::new();
    let mut fallback_pages = Vec::new();
    for target in targets
        .iter()
        .filter(|target| is_injectable_page_target(target))
    {
        if is_codex_page_target(target) {
            codex_pages.push(target.clone());
        } else {
            fallback_pages.push(target.clone());
        }
    }
    codex_pages.extend(fallback_pages);
    codex_pages
}

pub fn is_injectable_page_target(target: &CdpTarget) -> bool {
    target.target_type == "page"
        && target
            .web_socket_debugger_url
            .as_deref()
            .is_some_and(|url| !url.is_empty())
}

pub fn is_codex_page_target(target: &CdpTarget) -> bool {
    if target.target_type != "page" {
        return false;
    }
    let haystack = format!("{} {}", target.title, target.url).to_lowercase();
    haystack.contains("codex")
        || is_chatgpt_desktop_page(&target.title, &target.url)
        || is_linux_local_codex_app_url(&target.url)
}

pub fn is_primary_codex_page_target(target: &CdpTarget) -> bool {
    is_codex_page_target(target) && !is_avatar_overlay_page_target(target)
}

pub fn is_primary_codex_window(target: &CdpTarget) -> bool {
    if !is_primary_codex_page_target(target) {
        return false;
    }
    let url = target.url.to_ascii_lowercase();
    let title = target.title.to_ascii_lowercase();
    !url.contains("initialroute=%2fhotkey-window")
        && !url.contains("initialroute=/hotkey-window")
        && !title.contains("initialroute=%2fhotkey-window")
        && !title.contains("initialroute=/hotkey-window")
}

pub fn is_avatar_overlay_page_target(target: &CdpTarget) -> bool {
    if !is_injectable_page_target(target) {
        return false;
    }
    let url = target.url.trim().to_ascii_lowercase();
    url.starts_with("app://-/index.html?")
        && (url.contains("initialroute=%2favatar-overlay")
            || url.contains("initialroute=/avatar-overlay"))
}

fn is_chatgpt_desktop_page(title: &str, url: &str) -> bool {
    let title = title.trim().to_ascii_lowercase();
    let url = url.trim().to_ascii_lowercase();
    title == "chatgpt"
        && (url == "https://chatgpt.com"
            || url.starts_with("https://chatgpt.com/")
            || url == "https://chat.openai.com"
            || url.starts_with("https://chat.openai.com/")
            || url.starts_with("data:text/html"))
}

fn is_linux_local_codex_app_url(raw_url: &str) -> bool {
    let Ok(url) = Url::parse(raw_url) else {
        return false;
    };
    if !matches!(url.scheme(), "http" | "https") {
        return false;
    }
    let Some(port) = url.port_or_known_default() else {
        return false;
    };
    if !(LINUX_CODEX_WEBVIEW_PORT_START..=LINUX_CODEX_WEBVIEW_PORT_END).contains(&port) {
        return false;
    }
    let loopback = matches!(url.host(), Some(Host::Ipv4(address)) if address.is_loopback())
        || matches!(url.host(), Some(Host::Ipv6(address)) if address.is_loopback())
        || url
            .host_str()
            .is_some_and(|host| host.eq_ignore_ascii_case("localhost"));
    if !loopback {
        return false;
    }

    let path = url.path().trim_matches('/').to_ascii_lowercase();
    path.is_empty()
        || matches!(
            path.as_str(),
            "conversation" | "chat" | "settings" | "history" | "login" | "auth" | "hotkey-window"
        )
        || url.query_pairs().any(|(key, _)| {
            matches!(
                key.as_ref(),
                "thread_id" | "conversation_id" | "initialRoute" | "initialroute"
            )
        })
}
