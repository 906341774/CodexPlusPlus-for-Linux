use anyhow::{Context, bail};
use serde::Deserialize;
use std::time::Duration;

const CDP_HTTP_TIMEOUT: Duration = Duration::from_secs(3);

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
        match query_targets_url(&client, &url).await {
            Ok(targets) => return Ok(targets),
            Err(error) => errors.push(format!("{url}: {error:#}")),
        }
    }

    bail!(
        "failed to query CDP targets on loopback addresses: {}",
        errors.join("; ")
    )
}

async fn query_targets_url(client: &reqwest::Client, url: &str) -> anyhow::Result<Vec<CdpTarget>> {
    let response = client
        .get(url)
        .send()
        .await
        .context("failed to query CDP targets")?
        .error_for_status()
        .context("CDP target query failed")?;

    response
        .json::<Vec<CdpTarget>>()
        .await
        .context("failed to deserialize CDP targets")
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
        .find(is_codex_page_target)
        .ok_or_else(|| anyhow::anyhow!("No injectable Codex page target found"))
}

pub fn pick_primary_page_target(targets: &[CdpTarget]) -> anyhow::Result<CdpTarget> {
    injectable_page_targets(targets)
        .into_iter()
        .find(is_primary_codex_window)
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

pub fn is_primary_codex_window(target: &CdpTarget) -> bool {
    let url = target.url.to_lowercase();
    let title = target.title.to_lowercase();
    !url.contains("initialroute=%2fhotkey-window")
        && !url.contains("initialroute=/hotkey-window")
        && !title.contains("initialroute=%2fhotkey-window")
        && !title.contains("initialroute=/hotkey-window")
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
}
