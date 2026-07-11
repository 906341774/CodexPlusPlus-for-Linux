use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const DEFAULT_PROVIDER: &str = "openai";
const SESSION_DIRS: [&str; 2] = ["sessions", "archived_sessions"];
const BACKUP_KEEP_COUNT: usize = 5;
const LOCK_STALE_AFTER_SECS: u64 = 6 * 60 * 60;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderSyncStatus {
    Disabled,
    Skipped,
    Synced,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderSyncResult {
    pub status: ProviderSyncStatus,
    pub message: String,
    pub target_provider: String,
    pub backup_dir: Option<PathBuf>,
    pub changed_session_files: usize,
    pub skipped_locked_rollout_files: Vec<PathBuf>,
    pub sqlite_rows_updated: usize,
    pub sqlite_provider_rows_updated: usize,
    pub sqlite_user_event_rows_updated: usize,
    pub sqlite_cwd_rows_updated: usize,
    pub updated_workspace_roots: usize,
    pub encrypted_content_warning: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderSyncTargetSource {
    Config,
    Rollout,
    Sqlite,
    Manual,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSyncTargetOption {
    pub id: String,
    pub sources: Vec<ProviderSyncTargetSource>,
    pub is_current_provider: bool,
    pub is_manual: bool,
    pub is_saved: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSyncTargetList {
    pub current_provider: String,
    pub targets: Vec<ProviderSyncTargetOption>,
}

#[derive(Debug, Clone)]
struct SessionChange {
    path: PathBuf,
    original_text: String,
    next_text: String,
    original_session_meta_lines: Vec<String>,
    thread_id: Option<String>,
    cwd: Option<String>,
    has_user_event: bool,
    rewrite_needed: bool,
    original_mtime: Option<SystemTime>,
}

#[derive(Debug, Default)]
struct RolloutRewrite {
    next_text: String,
    rewrite_needed: bool,
    thread_id: Option<String>,
    cwd: Option<String>,
    providers: Vec<String>,
    original_session_meta_lines: Vec<String>,
    session_meta_count: usize,
}

#[derive(Debug, Default)]
struct SessionChanges {
    changes: Vec<SessionChange>,
    skipped_locked_rollout_files: Vec<PathBuf>,
    encrypted_content_counts: HashMap<String, usize>,
}

#[derive(Debug, Default)]
struct AppliedSessionChanges {
    changes: Vec<SessionChange>,
    skipped_locked_rollout_files: Vec<PathBuf>,
}

#[derive(Debug, Default)]
struct SqliteUpdateCounts {
    provider_rows: usize,
    user_event_rows: usize,
    cwd_rows: usize,
    local_catalog_rows: usize,
}

impl SqliteUpdateCounts {
    fn total(&self) -> usize {
        self.provider_rows + self.user_event_rows + self.cwd_rows + self.local_catalog_rows
    }

    fn add(&mut self, other: Self) {
        self.provider_rows += other.provider_rows;
        self.user_event_rows += other.user_event_rows;
        self.cwd_rows += other.cwd_rows;
        self.local_catalog_rows += other.local_catalog_rows;
    }
}

#[derive(Debug, Clone, PartialEq)]
struct LocalCatalogThread {
    thread_id: String,
    display_title: String,
    source_created_at: f64,
    source_updated_at: f64,
    cwd: String,
    source_kind: String,
    source_detail: Option<String>,
    model_provider: String,
    git_branch: Option<String>,
}

#[derive(Debug, Deserialize)]
struct LockOwner {
    pid: Option<u64>,
    #[serde(rename = "startedAt")]
    started_at: Option<u64>,
}

pub fn run_provider_sync(codex_home: Option<&Path>) -> ProviderSyncResult {
    run_provider_sync_with_target(codex_home, None)
}

pub fn run_provider_sync_with_target(
    codex_home: Option<&Path>,
    explicit_target_provider: Option<&str>,
) -> ProviderSyncResult {
    let home = codex_home
        .map(Path::to_path_buf)
        .unwrap_or_else(|| dirs_home().join(".codex"));
    if !home.exists() {
        return result(
            ProviderSyncStatus::Skipped,
            format!("Codex home not found: {}", home.to_string_lossy()),
            DEFAULT_PROVIDER,
            None,
            0,
            0,
        );
    }
    let target_provider =
        match resolve_target_provider(&home.join("config.toml"), explicit_target_provider) {
            Ok(provider) => provider,
            Err(message) => {
                return result(
                    ProviderSyncStatus::Skipped,
                    message,
                    DEFAULT_PROVIDER,
                    None,
                    0,
                    0,
                );
            }
        };
    let lock_dir = home.join("tmp/provider-sync.lock");
    if acquire_lock(&lock_dir).is_err() {
        return result(
            ProviderSyncStatus::Skipped,
            format!("Provider sync lock exists: {}", lock_dir.to_string_lossy()),
            &target_provider,
            None,
            0,
            0,
        );
    }
    let sync_result = (|| -> anyhow::Result<ProviderSyncResult> {
        let collected = collect_session_changes(&home, &target_provider)?;
        let encrypted_content_warning =
            build_encrypted_content_warning(&collected.encrypted_content_counts, &target_provider);
        let rewrite_changes = collected
            .changes
            .iter()
            .filter(|change| change.rewrite_needed)
            .cloned()
            .collect::<Vec<_>>();
        let thread_ids_with_user_events = collected
            .changes
            .iter()
            .filter(|change| change.has_user_event)
            .filter_map(|change| change.thread_id.clone())
            .collect::<HashSet<_>>();
        let mut projectless_thread_ids =
            load_projectless_thread_ids(&home.join(".codex-global-state.json"))?;
        projectless_thread_ids.extend(
            collected
                .changes
                .iter()
                .filter(|change| change.has_user_event)
                .filter(|change| change.cwd.is_none())
                .filter_map(|change| change.thread_id.clone()),
        );
        let cwd_by_thread_id = collected
            .changes
            .iter()
            .filter_map(|change| Some((change.thread_id.clone()?, change.cwd.clone()?)))
            .filter(|(thread_id, _)| !projectless_thread_ids.contains(thread_id))
            .collect::<HashMap<_, _>>();
        let rollout_path_by_thread_id = collected
            .changes
            .iter()
            .filter_map(|change| {
                Some((
                    change.thread_id.clone()?,
                    change.path.to_string_lossy().to_string(),
                ))
            })
            .collect::<HashMap<_, _>>();
        let sqlite_paths = codex_plus_core::codex_sqlite::codex_session_db_paths_from_home(&home);
        let local_catalog_threads = collect_local_catalog_threads(
            &sqlite_paths,
            &target_provider,
            &thread_ids_with_user_events,
            &cwd_by_thread_id,
            &projectless_thread_ids,
            &rollout_path_by_thread_id,
        )?;
        let sqlite_update_count = count_sqlite_updates_for_paths(
            &sqlite_paths,
            &target_provider,
            &thread_ids_with_user_events,
            &cwd_by_thread_id,
            &local_catalog_threads,
        )?;
        let global_state_update_count =
            count_global_state_updates(&home.join(".codex-global-state.json"))?;
        if rewrite_changes.is_empty() && sqlite_update_count == 0 && global_state_update_count == 0
        {
            let mut synced = result(
                ProviderSyncStatus::Synced,
                "Provider sync already up to date",
                &target_provider,
                None,
                0,
                0,
            );
            synced.skipped_locked_rollout_files = collected.skipped_locked_rollout_files;
            synced.encrypted_content_warning = encrypted_content_warning;
            return Ok(synced);
        }
        let backup_dir = create_backup(&home, &target_provider, &rewrite_changes)?;
        let applied = apply_session_changes(&rewrite_changes)?;
        let apply_result = (|| -> anyhow::Result<(SqliteUpdateCounts, usize)> {
            let sqlite_updates = apply_sqlite_update_for_paths(
                &sqlite_paths,
                &target_provider,
                &thread_ids_with_user_events,
                &cwd_by_thread_id,
                &local_catalog_threads,
            )?;
            let updated_workspace_roots =
                apply_global_state_update(&home.join(".codex-global-state.json"))?;
            prune_backups(&home)?;
            Ok((sqlite_updates, updated_workspace_roots))
        })();
        let (sqlite_updates, updated_workspace_roots) = match apply_result {
            Ok(counts) => counts,
            Err(err) => {
                let _ = restore_session_changes(&applied.changes);
                return Err(err);
            }
        };
        let mut synced = result(
            ProviderSyncStatus::Synced,
            "Provider sync complete",
            &target_provider,
            Some(backup_dir),
            applied.changes.len(),
            sqlite_updates.total(),
        );
        synced.skipped_locked_rollout_files = collected.skipped_locked_rollout_files;
        synced
            .skipped_locked_rollout_files
            .extend(applied.skipped_locked_rollout_files);
        synced.skipped_locked_rollout_files.sort();
        synced.skipped_locked_rollout_files.dedup();
        synced.sqlite_provider_rows_updated = sqlite_updates.provider_rows;
        synced.sqlite_user_event_rows_updated = sqlite_updates.user_event_rows;
        synced.sqlite_cwd_rows_updated = sqlite_updates.cwd_rows;
        synced.updated_workspace_roots = updated_workspace_roots;
        synced.encrypted_content_warning = encrypted_content_warning;
        Ok(synced)
    })();
    let _ = release_lock(&lock_dir);
    sync_result.unwrap_or_else(|err| {
        result(
            ProviderSyncStatus::Skipped,
            format!("Provider sync skipped: {err}"),
            &target_provider,
            None,
            0,
            0,
        )
    })
}

fn result(
    status: ProviderSyncStatus,
    message: impl Into<String>,
    target_provider: &str,
    backup_dir: Option<PathBuf>,
    changed_session_files: usize,
    sqlite_rows_updated: usize,
) -> ProviderSyncResult {
    ProviderSyncResult {
        status,
        message: message.into(),
        target_provider: target_provider.to_string(),
        backup_dir,
        changed_session_files,
        skipped_locked_rollout_files: Vec::new(),
        sqlite_rows_updated,
        sqlite_provider_rows_updated: 0,
        sqlite_user_event_rows_updated: 0,
        sqlite_cwd_rows_updated: 0,
        updated_workspace_roots: 0,
        encrypted_content_warning: None,
    }
}

fn dirs_home() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn load_provider_sync_targets(codex_home: Option<&Path>) -> ProviderSyncTargetList {
    let home = codex_home
        .map(Path::to_path_buf)
        .unwrap_or_else(|| dirs_home().join(".codex"));
    let current_provider = read_current_provider(&home.join("config.toml"));
    let mut sources: HashMap<String, HashSet<ProviderSyncTargetSource>> = HashMap::new();

    fn add_sources(
        sources: &mut HashMap<String, HashSet<ProviderSyncTargetSource>>,
        ids: impl IntoIterator<Item = String>,
        source: ProviderSyncTargetSource,
    ) {
        for id in ids {
            if !is_valid_provider_id_for_discovery(&id) {
                continue;
            }
            sources.entry(id).or_default().insert(source);
        }
    }

    add_sources(
        &mut sources,
        list_configured_provider_ids(&home.join("config.toml")),
        ProviderSyncTargetSource::Config,
    );
    add_sources(
        &mut sources,
        [current_provider.clone()],
        ProviderSyncTargetSource::Config,
    );
    if let Ok(ids) = rollout_provider_ids(&home) {
        add_sources(&mut sources, ids, ProviderSyncTargetSource::Rollout);
    }
    for db_path in codex_plus_core::codex_sqlite::codex_session_db_paths_from_home(&home) {
        if let Ok(ids) = sqlite_provider_ids(&db_path) {
            add_sources(&mut sources, ids, ProviderSyncTargetSource::Sqlite);
        }
    }

    let mut targets = sources
        .into_iter()
        .map(|(id, source_set)| {
            let mut source_list = source_set.into_iter().collect::<Vec<_>>();
            source_list.sort();
            ProviderSyncTargetOption {
                is_current_provider: id == current_provider,
                is_manual: source_list.contains(&ProviderSyncTargetSource::Manual),
                is_saved: false,
                id,
                sources: source_list,
            }
        })
        .collect::<Vec<_>>();
    targets.sort_by(|left, right| {
        right
            .is_current_provider
            .cmp(&left.is_current_provider)
            .then_with(|| left.id.cmp(&right.id))
    });

    ProviderSyncTargetList {
        current_provider,
        targets,
    }
}

fn read_current_provider(path: &Path) -> String {
    let Ok(text) = fs::read_to_string(path) else {
        return DEFAULT_PROVIDER.to_string();
    };
    let provider = root_toml_string_value(&text, "model_provider").unwrap_or_default();
    if provider.trim().is_empty() {
        DEFAULT_PROVIDER.to_string()
    } else {
        provider
    }
}

fn resolve_target_provider(
    config_path: &Path,
    explicit_target_provider: Option<&str>,
) -> Result<String, String> {
    if let Some(raw) = explicit_target_provider {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return Ok(read_current_provider(config_path));
        }
        if !is_valid_explicit_provider_id(trimmed) {
            return Err(format!("Invalid provider sync target: {trimmed:?}"));
        }
        return Ok(trimmed.to_string());
    }
    Ok(read_current_provider(config_path))
}

fn is_valid_explicit_provider_id(value: &str) -> bool {
    !value.is_empty()
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.'))
}

fn list_configured_provider_ids(path: &Path) -> Vec<String> {
    let mut ids = HashSet::new();
    ids.insert(DEFAULT_PROVIDER.to_string());
    let Ok(text) = fs::read_to_string(path) else {
        return sorted_provider_ids(ids);
    };
    for line in text.lines() {
        let stripped = line.trim();
        let Some(section) = stripped
            .strip_prefix("[model_providers.")
            .and_then(|rest| rest.strip_suffix(']'))
        else {
            continue;
        };
        let id = section.trim();
        if is_valid_provider_id_for_discovery(id) {
            ids.insert(id.to_string());
        }
    }
    sorted_provider_ids(ids)
}

fn sorted_provider_ids(ids: HashSet<String>) -> Vec<String> {
    let mut ids = ids
        .into_iter()
        .filter(|id| !id.trim().is_empty())
        .collect::<Vec<_>>();
    ids.sort();
    ids
}

fn is_valid_provider_id_for_discovery(value: &str) -> bool {
    !value.trim().is_empty() && !value.chars().any(char::is_control)
}

fn root_toml_string_value(text: &str, key: &str) -> Option<String> {
    for line in text.lines() {
        let stripped = line.trim();
        if stripped.starts_with('[') {
            break;
        }
        let Some(raw) = toml_key_raw_value(stripped, key) else {
            continue;
        };
        return toml_string_value(raw);
    }
    None
}

fn toml_key_raw_value<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let rest = line.strip_prefix(key)?.trim_start();
    rest.strip_prefix('=').map(str::trim_start)
}

fn toml_string_value(raw: &str) -> Option<String> {
    let quote = raw.chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    let mut value = String::new();
    let mut escaping = false;
    for ch in raw[quote.len_utf8()..].chars() {
        if quote == '"' && escaping {
            value.push(ch);
            escaping = false;
        } else if quote == '"' && ch == '\\' {
            escaping = true;
        } else if ch == quote {
            return Some(value);
        } else {
            value.push(ch);
        }
    }
    None
}

fn acquire_lock(path: &Path) -> std::io::Result<()> {
    fs::create_dir_all(path.parent().unwrap_or_else(|| Path::new(".")))?;
    match create_lock(path) {
        Ok(()) => Ok(()),
        Err(error)
            if error.kind() == std::io::ErrorKind::AlreadyExists
                && provider_sync_lock_is_stale(path) =>
        {
            fs::remove_dir_all(path)?;
            create_lock(path)
        }
        Err(error) => Err(error),
    }
}

fn create_lock(path: &Path) -> std::io::Result<()> {
    fs::create_dir(path)?;
    if let Err(error) = fs::write(
        path.join("owner.json"),
        json!({"pid": std::process::id(), "startedAt": now_secs()}).to_string(),
    ) {
        let _ = fs::remove_dir_all(path);
        return Err(error);
    }
    Ok(())
}

fn provider_sync_lock_is_stale(path: &Path) -> bool {
    let now = now_secs();
    if let Ok(text) = fs::read_to_string(path.join("owner.json")) {
        if let Ok(owner) = serde_json::from_str::<LockOwner>(&text) {
            if let Some(pid) = owner.pid {
                if pid == u64::from(std::process::id()) {
                    return false;
                }
                if matches!(process_is_running(pid), Some(false)) {
                    return true;
                }
            }
            if let Some(started_at) = owner.started_at {
                return now.saturating_sub(started_at) > LOCK_STALE_AFTER_SECS;
            }
        }
    }

    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| {
            SystemTime::now()
                .duration_since(modified)
                .ok()
                .map(|duration| duration.as_secs())
        })
        .is_some_and(|age| age > LOCK_STALE_AFTER_SECS)
}

#[cfg(target_os = "linux")]
fn process_is_running(pid: u64) -> Option<bool> {
    if pid == 0 || pid > i32::MAX as u64 {
        return Some(false);
    }
    Some(Path::new("/proc").join(pid.to_string()).exists())
}

#[cfg(not(target_os = "linux"))]
fn process_is_running(_pid: u64) -> Option<bool> {
    None
}

fn release_lock(path: &Path) -> std::io::Result<()> {
    if path.exists() {
        fs::remove_dir_all(path)?;
    }
    Ok(())
}

fn collect_session_changes(home: &Path, target_provider: &str) -> anyhow::Result<SessionChanges> {
    let mut collected = SessionChanges::default();
    for path in rollout_files(home)? {
        let text = match fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if is_locked_io_error(&error) => {
                collected.skipped_locked_rollout_files.push(path);
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        let rewrite = rewrite_rollout_session_meta_providers(&text, target_provider)?;
        if rewrite.session_meta_count == 0 {
            continue;
        }
        let has_user_event = text.contains("\"user_message\"") || text.contains("\"user_input\"");
        if text.contains("encrypted_content") {
            for provider in &rewrite.providers {
                *collected
                    .encrypted_content_counts
                    .entry(provider.clone())
                    .or_insert(0) += 1;
            }
        }
        let original_mtime = fs::metadata(&path).and_then(|m| m.modified()).ok();
        collected.changes.push(SessionChange {
            path,
            original_text: text,
            next_text: rewrite.next_text,
            original_session_meta_lines: rewrite.original_session_meta_lines,
            thread_id: rewrite.thread_id,
            cwd: rewrite.cwd,
            has_user_event,
            rewrite_needed: rewrite.rewrite_needed,
            original_mtime,
        });
    }
    Ok(collected)
}

fn rewrite_rollout_session_meta_providers(
    text: &str,
    target_provider: &str,
) -> anyhow::Result<RolloutRewrite> {
    let mut rewrite = RolloutRewrite::default();
    for segment in text.split_inclusive('\n') {
        let (line, line_ending) = split_line_ending(segment);
        let mut next_line = line.to_string();
        if !line.trim().is_empty() {
            if let Ok(mut record) = serde_json::from_str::<Value>(line) {
                if record.get("type").and_then(Value::as_str) == Some("session_meta") {
                    let Some(payload) = record.get_mut("payload").and_then(Value::as_object_mut)
                    else {
                        rewrite.next_text.push_str(&next_line);
                        rewrite.next_text.push_str(line_ending);
                        continue;
                    };
                    rewrite.session_meta_count += 1;
                    rewrite.original_session_meta_lines.push(line.to_string());
                    if rewrite.thread_id.is_none() {
                        rewrite.thread_id = payload
                            .get("id")
                            .and_then(Value::as_str)
                            .map(ToString::to_string);
                    }
                    if rewrite.cwd.is_none() {
                        rewrite.cwd = payload
                            .get("cwd")
                            .and_then(Value::as_str)
                            .and_then(to_desktop_workspace_path);
                    }
                    let provider = payload
                        .get("model_provider")
                        .and_then(Value::as_str)
                        .unwrap_or("(missing)")
                        .to_string();
                    rewrite.providers.push(provider);
                    if payload.get("model_provider").and_then(Value::as_str)
                        != Some(target_provider)
                    {
                        payload.insert("model_provider".to_string(), json!(target_provider));
                        next_line = serde_json::to_string(&record)?;
                        rewrite.rewrite_needed = true;
                    }
                }
            }
        }
        rewrite.next_text.push_str(&next_line);
        rewrite.next_text.push_str(line_ending);
    }
    Ok(rewrite)
}

fn rollout_files(home: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    for dirname in SESSION_DIRS {
        let root = home.join(dirname);
        if root.exists() {
            collect_rollout_files(&root, &mut files)?;
        }
    }
    files.sort();
    Ok(files)
}

fn rollout_provider_ids(home: &Path) -> anyhow::Result<Vec<String>> {
    let mut ids = HashSet::new();
    for path in rollout_files(home)? {
        let text = match fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if is_locked_io_error(&error) => continue,
            Err(error) => return Err(error.into()),
        };
        for segment in text.split_inclusive('\n') {
            let (line, _) = split_line_ending(segment);
            let Ok(record) = serde_json::from_str::<Value>(line) else {
                continue;
            };
            if record.get("type").and_then(Value::as_str) != Some("session_meta") {
                continue;
            }
            let Some(provider) = record
                .get("payload")
                .and_then(Value::as_object)
                .and_then(|payload| payload.get("model_provider"))
                .and_then(Value::as_str)
            else {
                continue;
            };
            if is_valid_provider_id_for_discovery(provider) {
                ids.insert(provider.to_string());
            }
        }
    }
    Ok(sorted_provider_ids(ids))
}

fn collect_rollout_files(root: &Path, files: &mut Vec<PathBuf>) -> anyhow::Result<()> {
    for entry in fs::read_dir(root)? {
        let path = entry?.path();
        if path.is_dir() {
            collect_rollout_files(&path, files)?;
        } else if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("rollout-") && name.ends_with(".jsonl"))
        {
            files.push(path);
        }
    }
    Ok(())
}

fn split_line_ending(segment: &str) -> (&str, &str) {
    if let Some(line) = segment.strip_suffix("\r\n") {
        (line, "\r\n")
    } else if let Some(line) = segment.strip_suffix('\n') {
        (line, "\n")
    } else {
        (segment, "")
    }
}

fn to_desktop_workspace_path(value: &str) -> Option<String> {
    let stripped = value.trim();
    if stripped.is_empty() {
        return None;
    }
    let lower = stripped.to_ascii_lowercase();
    if lower.starts_with(r"\\?\unc\") {
        return Some(format!(r"\\{}", stripped[8..].replace('/', r"\")));
    }
    if stripped.starts_with(r"\\?\") {
        return Some(stripped[4..].replace('\\', "/"));
    }
    Some(stripped.to_string())
}

fn is_locked_io_error(error: &std::io::Error) -> bool {
    matches!(error.kind(), std::io::ErrorKind::PermissionDenied)
        || matches!(error.raw_os_error(), Some(32 | 33))
}

fn build_encrypted_content_warning(
    encrypted_content_counts: &HashMap<String, usize>,
    target_provider: &str,
) -> Option<String> {
    let risky_providers = encrypted_content_counts
        .iter()
        .filter(|(provider, count)| provider.as_str() != target_provider && **count > 0)
        .map(|(provider, _)| provider.as_str())
        .collect::<Vec<_>>();
    if risky_providers.is_empty() {
        return None;
    }
    let total = encrypted_content_counts.values().sum::<usize>();
    Some(format!(
        "检测到 {total} 个会话文件包含来自 {} 的 encrypted_content。可见会话元数据已同步到 {target_provider}，但继续或压缩这些历史可能出现 invalid_encrypted_content；需要可靠续聊时请切回原供应商/账号或开启新会话。",
        risky_providers.join(", ")
    ))
}

fn create_backup(
    home: &Path,
    target_provider: &str,
    changes: &[SessionChange],
) -> anyhow::Result<PathBuf> {
    let backup_root = home.join("backups_state/provider-sync");
    let mut backup_dir = backup_root.join(timestamp_name());
    let mut suffix = 0;
    while backup_dir.exists() {
        suffix += 1;
        backup_dir = backup_root.join(format!("{}-{suffix}", timestamp_name()));
    }
    fs::create_dir_all(&backup_dir)?;
    for name in [
        "config.toml",
        ".codex-global-state.json",
        ".codex-global-state.json.bak",
    ] {
        let source = home.join(name);
        if source.exists() {
            fs::copy(&source, backup_dir.join(name))?;
        }
    }
    let db_dir = backup_dir.join("db");
    let mut db_files = Vec::new();
    for db_path in codex_plus_core::codex_sqlite::codex_session_db_paths_from_home(home) {
        for source in codex_plus_core::codex_sqlite::codex_sqlite_sidecar_paths(&db_path) {
            if !source.exists() {
                continue;
            }
            let relative = codex_plus_core::codex_sqlite::relative_to_codex_home(home, &source);
            let target = db_dir.join(&relative);
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(&source, &target)?;
            db_files.push(relative.to_string_lossy().replace('\\', "/"));
        }
    }
    let manifest = changes
        .iter()
        .map(|change| {
            json!({
                "path": change.path.to_string_lossy(),
                "originalSessionMetaLines": change.original_session_meta_lines,
            })
        })
        .collect::<Vec<_>>();
    fs::write(
        backup_dir.join("session-meta-backup.json"),
        serde_json::to_string_pretty(&manifest)?,
    )?;
    fs::write(
        backup_dir.join("metadata.json"),
        serde_json::to_string_pretty(&json!({
            "version": 1,
            "namespace": "provider-sync",
            "codexHome": home.to_string_lossy(),
            "targetProvider": target_provider,
            "createdAt": chrono::Utc::now().to_rfc3339(),
            "dbFiles": db_files,
            "changedSessionFiles": changes.len(),
            "managedBy": "Codex++ provider sync"
        }))?,
    )?;
    Ok(backup_dir)
}

fn apply_session_changes(changes: &[SessionChange]) -> anyhow::Result<AppliedSessionChanges> {
    let mut applied = AppliedSessionChanges::default();
    for change in changes {
        match fs::write(&change.path, &change.next_text) {
            Ok(()) => {}
            Err(error) if is_locked_io_error(&error) => {
                applied
                    .skipped_locked_rollout_files
                    .push(change.path.clone());
                continue;
            }
            Err(error) => return Err(error.into()),
        }
        restore_file_mtime(&change.path, change.original_mtime);
        applied.changes.push(change.clone());
    }
    Ok(applied)
}

fn restore_session_changes(changes: &[SessionChange]) -> anyhow::Result<()> {
    for change in changes {
        fs::write(&change.path, &change.original_text)?;
        restore_file_mtime(&change.path, change.original_mtime);
    }
    Ok(())
}

fn restore_file_mtime(path: &Path, mtime: Option<SystemTime>) {
    let Some(mtime) = mtime else { return };
    let Ok(file) = fs::File::options().write(true).open(path) else {
        return;
    };
    let times = std::fs::FileTimes::new().set_modified(mtime);
    let _ = file.set_times(times);
}

fn table_columns(db: &Connection, table: &str) -> anyhow::Result<HashSet<String>> {
    let mut stmt = db.prepare(&format!(
        "PRAGMA table_info(\"{}\")",
        table.replace('"', "\"\"")
    ))?;
    Ok(stmt
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<HashSet<_>>>()?)
}

fn has_table(db: &Connection, table: &str) -> anyhow::Result<bool> {
    Ok(db
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1",
            [table],
            |_| Ok(()),
        )
        .is_ok())
}

fn sqlite_provider_ids(path: &Path) -> anyhow::Result<Vec<String>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let db = Connection::open(path)?;
    let columns = table_columns(&db, "threads")?;
    if !columns.contains("model_provider") {
        return Ok(Vec::new());
    }
    let mut stmt = db.prepare(
        "SELECT DISTINCT COALESCE(model_provider, '') FROM threads WHERE COALESCE(model_provider, '') <> ''",
    )?;
    let mut ids = HashSet::new();
    for item in stmt.query_map([], |row| row.get::<_, String>(0))? {
        let id = item?;
        if is_valid_provider_id_for_discovery(&id) {
            ids.insert(id);
        }
    }
    Ok(sorted_provider_ids(ids))
}

fn collect_local_catalog_threads(
    paths: &[PathBuf],
    target_provider: &str,
    user_event_thread_ids: &HashSet<String>,
    cwd_by_thread_id: &HashMap<String, String>,
    projectless_thread_ids: &HashSet<String>,
    rollout_path_by_thread_id: &HashMap<String, String>,
) -> anyhow::Result<Vec<LocalCatalogThread>> {
    let mut by_id = HashMap::new();
    for path in paths {
        if !path.exists() {
            continue;
        }
        let db = Connection::open(path)?;
        if !has_table(&db, "threads")? {
            continue;
        }
        let columns = table_columns(&db, "threads")?;
        if !["id", "cwd", "archived", "has_user_event"]
            .iter()
            .all(|column| columns.contains(*column))
        {
            continue;
        }
        let selected_columns = [
            ("id", true),
            ("has_user_event", true),
            ("title", columns.contains("title")),
            ("created_at", columns.contains("created_at")),
            ("updated_at", columns.contains("updated_at")),
            ("cwd", true),
            ("rollout_path", columns.contains("rollout_path")),
            ("model_provider", columns.contains("model_provider")),
            ("git_branch", columns.contains("git_branch")),
            ("created_at_ms", columns.contains("created_at_ms")),
            ("updated_at_ms", columns.contains("updated_at_ms")),
            ("recency_at", columns.contains("recency_at")),
            ("recency_at_ms", columns.contains("recency_at_ms")),
        ]
        .into_iter()
        .filter_map(|(column, include)| include.then_some(column))
        .collect::<Vec<_>>();
        let sql = format!(
            "SELECT {} FROM threads WHERE COALESCE(archived, 0) = 0",
            selected_columns.join(", ")
        );
        let mut stmt = db.prepare(&sql)?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let mut index_by_column = HashMap::new();
            for (index, column) in selected_columns.iter().enumerate() {
                index_by_column.insert(*column, index);
            }
            let Some(thread) = local_catalog_thread_from_row(
                row,
                &index_by_column,
                target_provider,
                user_event_thread_ids,
                cwd_by_thread_id,
                rollout_path_by_thread_id,
            )?
            else {
                continue;
            };
            if projectless_thread_ids.contains(&thread.thread_id) {
                continue;
            }
            let replace = by_id
                .get(&thread.thread_id)
                .map(|existing: &LocalCatalogThread| {
                    thread.source_updated_at > existing.source_updated_at
                })
                .unwrap_or(true);
            if replace {
                by_id.insert(thread.thread_id.clone(), thread);
            }
        }
    }
    let mut threads = by_id.into_values().collect::<Vec<_>>();
    threads.sort_by(|left, right| left.thread_id.cmp(&right.thread_id));
    Ok(threads)
}

fn local_catalog_thread_from_row(
    row: &rusqlite::Row<'_>,
    index_by_column: &HashMap<&str, usize>,
    target_provider: &str,
    user_event_thread_ids: &HashSet<String>,
    cwd_by_thread_id: &HashMap<String, String>,
    rollout_path_by_thread_id: &HashMap<String, String>,
) -> anyhow::Result<Option<LocalCatalogThread>> {
    let Some(thread_id) = optional_string(row, index_by_column, "id")? else {
        return Ok(None);
    };
    if thread_id.trim().is_empty() {
        return Ok(None);
    }
    let has_user_event = optional_i64(row, index_by_column, "has_user_event")?.unwrap_or(0) != 0
        || user_event_thread_ids.contains(&thread_id);
    if !has_user_event {
        return Ok(None);
    }
    let raw_cwd = if let Some(cwd) = cwd_by_thread_id.get(&thread_id) {
        Some(cwd.clone())
    } else {
        optional_string(row, index_by_column, "cwd")?
    };
    let Some(cwd) = raw_cwd.and_then(|value| to_desktop_workspace_path(&value)) else {
        return Ok(None);
    };
    if cwd.trim().is_empty() {
        return Ok(None);
    }
    let title = optional_string(row, index_by_column, "title")?
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| thread_id.clone());
    let source_created_at =
        optional_timestamp_seconds(row, index_by_column, "created_at_ms", "created_at")?
            .unwrap_or(0.0);
    let source_updated_at =
        optional_timestamp_seconds(row, index_by_column, "updated_at_ms", "updated_at")?
            .or(optional_timestamp_seconds(
                row,
                index_by_column,
                "recency_at_ms",
                "recency_at",
            )?)
            .unwrap_or(source_created_at);
    let source_detail = optional_string(row, index_by_column, "rollout_path")?
        .filter(|value| !value.trim().is_empty())
        .or_else(|| rollout_path_by_thread_id.get(&thread_id).cloned())
        .filter(|value| !value.trim().is_empty());
    if source_detail.is_none() {
        return Ok(None);
    }
    let model_provider = optional_string(row, index_by_column, "model_provider")?
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| target_provider.to_string());
    Ok(Some(LocalCatalogThread {
        thread_id,
        display_title: title,
        source_created_at,
        source_updated_at,
        cwd,
        source_kind: "rollout".to_string(),
        source_detail,
        model_provider: if model_provider == target_provider {
            model_provider
        } else {
            target_provider.to_string()
        },
        git_branch: optional_string(row, index_by_column, "git_branch")?
            .filter(|value| !value.trim().is_empty()),
    }))
}

fn optional_string(
    row: &rusqlite::Row<'_>,
    index_by_column: &HashMap<&str, usize>,
    column: &str,
) -> anyhow::Result<Option<String>> {
    let Some(index) = index_by_column.get(column) else {
        return Ok(None);
    };
    Ok(row.get::<_, Option<String>>(*index)?)
}

fn optional_i64(
    row: &rusqlite::Row<'_>,
    index_by_column: &HashMap<&str, usize>,
    column: &str,
) -> anyhow::Result<Option<i64>> {
    let Some(index) = index_by_column.get(column) else {
        return Ok(None);
    };
    Ok(row.get::<_, Option<i64>>(*index)?)
}

fn optional_timestamp_seconds(
    row: &rusqlite::Row<'_>,
    index_by_column: &HashMap<&str, usize>,
    millis_column: &str,
    seconds_column: &str,
) -> anyhow::Result<Option<f64>> {
    if let Some(index) = index_by_column.get(millis_column) {
        if let Some(value) = row.get::<_, Option<i64>>(*index)? {
            return Ok(Some(value as f64 / 1000.0));
        }
    }
    if let Some(index) = index_by_column.get(seconds_column) {
        return Ok(row.get::<_, Option<f64>>(*index)?);
    }
    Ok(None)
}

fn count_sqlite_updates(
    path: &Path,
    target_provider: &str,
    user_event_thread_ids: &HashSet<String>,
    cwd_by_thread_id: &HashMap<String, String>,
    local_catalog_threads: &[LocalCatalogThread],
) -> anyhow::Result<usize> {
    if !path.exists() {
        return Ok(0);
    }
    let db = Connection::open(path)?;
    let mut total = 0;
    if has_table(&db, "threads")? {
        let columns = table_columns(&db, "threads")?;
        if columns.contains("model_provider") {
            total += db.query_row(
                "SELECT COUNT(*) FROM threads WHERE COALESCE(model_provider, '') <> ?1",
                [target_provider],
                |row| row.get::<_, i64>(0),
            )? as usize;
            if columns.contains("has_user_event") {
                for thread_id in user_event_thread_ids {
                    total += db.query_row(
                        "SELECT COUNT(*) FROM threads WHERE id = ?1 AND COALESCE(has_user_event, 0) <> 1",
                        [thread_id],
                        |row| row.get::<_, i64>(0),
                    )? as usize;
                }
            }
            if columns.contains("cwd") {
                for (thread_id, cwd) in cwd_by_thread_id {
                    total += db.query_row(
                        "SELECT COUNT(*) FROM threads WHERE id = ?1 AND COALESCE(cwd, '') <> ?2",
                        (thread_id, cwd),
                        |row| row.get::<_, i64>(0),
                    )? as usize;
                }
            }
        }
    }
    if is_local_thread_catalog_db(&db)? {
        total += count_local_thread_catalog_updates(&db, local_catalog_threads)?;
    }
    Ok(total)
}

fn count_sqlite_updates_for_paths(
    paths: &[PathBuf],
    target_provider: &str,
    user_event_thread_ids: &HashSet<String>,
    cwd_by_thread_id: &HashMap<String, String>,
    local_catalog_threads: &[LocalCatalogThread],
) -> anyhow::Result<usize> {
    let mut total = 0;
    for path in paths {
        total += count_sqlite_updates(
            path,
            target_provider,
            user_event_thread_ids,
            cwd_by_thread_id,
            local_catalog_threads,
        )?;
    }
    Ok(total)
}

fn apply_sqlite_update(
    path: &Path,
    target_provider: &str,
    user_event_thread_ids: &HashSet<String>,
    cwd_by_thread_id: &HashMap<String, String>,
    local_catalog_threads: &[LocalCatalogThread],
) -> anyhow::Result<SqliteUpdateCounts> {
    if !path.exists() {
        return Ok(SqliteUpdateCounts::default());
    }
    let mut db = Connection::open(path)?;
    let tx = db.transaction()?;
    let mut counts = SqliteUpdateCounts::default();
    if has_table(&tx, "threads")? {
        let columns = table_columns(&tx, "threads")?;
        if columns.contains("model_provider") {
            counts.provider_rows = tx.execute(
                "UPDATE threads SET model_provider = ?1 WHERE COALESCE(model_provider, '') <> ?1",
                [target_provider],
            )?;
            if columns.contains("has_user_event") {
                for thread_id in user_event_thread_ids {
                    counts.user_event_rows += tx.execute(
                        "UPDATE threads SET has_user_event = 1 WHERE id = ?1 AND COALESCE(has_user_event, 0) <> 1",
                        [thread_id],
                    )?;
                }
            }
            if columns.contains("cwd") {
                for (thread_id, cwd) in cwd_by_thread_id {
                    counts.cwd_rows += tx.execute(
                        "UPDATE threads SET cwd = ?1 WHERE id = ?2 AND COALESCE(cwd, '') <> ?1",
                        (cwd, thread_id),
                    )?;
                }
            }
        }
    }
    if is_local_thread_catalog_db(&tx)? {
        counts.local_catalog_rows = apply_local_thread_catalog_update(&tx, local_catalog_threads)?;
    }
    tx.commit()?;
    Ok(counts)
}

fn apply_sqlite_update_for_paths(
    paths: &[PathBuf],
    target_provider: &str,
    user_event_thread_ids: &HashSet<String>,
    cwd_by_thread_id: &HashMap<String, String>,
    local_catalog_threads: &[LocalCatalogThread],
) -> anyhow::Result<SqliteUpdateCounts> {
    let mut total = SqliteUpdateCounts::default();
    for path in paths {
        total.add(apply_sqlite_update(
            path,
            target_provider,
            user_event_thread_ids,
            cwd_by_thread_id,
            local_catalog_threads,
        )?);
    }
    Ok(total)
}

fn is_local_thread_catalog_db(db: &Connection) -> anyhow::Result<bool> {
    Ok(has_table(db, "local_thread_catalog")?
        && has_table(db, "local_thread_catalog_hosts")?
        && has_table(db, "local_thread_catalog_metadata")?
        && has_table(db, "local_thread_catalog_sync_state")?)
}

fn count_local_thread_catalog_updates(
    db: &Connection,
    threads: &[LocalCatalogThread],
) -> anyhow::Result<usize> {
    let mut total = usize::from(!local_catalog_host_exists(db)?);
    total += usize::from(!local_catalog_metadata_exists(db)?);
    for thread in threads {
        let existing = local_thread_catalog_row(db, &thread.thread_id)?;
        if existing.as_ref() != Some(thread) {
            total += 1;
        }
    }
    total += count_unopenable_local_thread_catalog_rows(db, threads)?;
    let sync_state_needs_update = db
        .query_row(
            "SELECT COALESCE(initial_build_complete, 0), watermark_updated_at FROM local_thread_catalog_sync_state WHERE host_id = 'local'",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, Option<f64>>(1)?,
                ))
            },
        )
        .map(|(complete, watermark)| {
            complete != 1 || watermark != latest_local_catalog_updated_at(threads)
        })
        .unwrap_or(true);
    if sync_state_needs_update {
        total += 1;
    }
    Ok(total)
}

fn apply_local_thread_catalog_update(
    tx: &rusqlite::Transaction<'_>,
    threads: &[LocalCatalogThread],
) -> anyhow::Result<usize> {
    let pending_changes = count_local_thread_catalog_updates(tx, threads)?;
    if pending_changes == 0 {
        return Ok(0);
    }
    tx.execute(
        "INSERT OR IGNORE INTO local_thread_catalog_hosts (host_id, host_kind) VALUES ('local', 'local')",
        [],
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO local_thread_catalog_metadata (id, catalog_revision) VALUES (1, 0)",
        [],
    )?;
    let next_sequence = next_local_catalog_observation_sequence(tx)?;
    for thread in threads {
        let existing = local_thread_catalog_row(tx, &thread.thread_id)?;
        if existing.as_ref() == Some(thread) {
            continue;
        }
        tx.execute(
            "INSERT INTO local_thread_catalog (
                host_id,
                thread_id,
                display_title,
                source_created_at,
                source_updated_at,
                cwd,
                source_kind,
                source_detail,
                model_provider,
                git_branch,
                observation_sequence,
                missing_candidate
            ) VALUES (
                'local',
                ?1,
                ?2,
                ?3,
                ?4,
                ?5,
                ?6,
                ?7,
                ?8,
                ?9,
                ?10,
                0
            )
            ON CONFLICT(host_id, thread_id) DO UPDATE SET
                display_title = excluded.display_title,
                source_created_at = excluded.source_created_at,
                source_updated_at = excluded.source_updated_at,
                cwd = excluded.cwd,
                source_kind = excluded.source_kind,
                source_detail = excluded.source_detail,
                model_provider = excluded.model_provider,
                git_branch = excluded.git_branch,
                observation_sequence = excluded.observation_sequence,
                missing_candidate = 0",
            (
                &thread.thread_id,
                &thread.display_title,
                thread.source_created_at,
                thread.source_updated_at,
                &thread.cwd,
                &thread.source_kind,
                thread.source_detail.as_deref(),
                &thread.model_provider,
                thread.git_branch.as_deref(),
                next_sequence,
            ),
        )?;
    }
    mark_unopenable_local_thread_catalog_rows_missing(tx, threads, next_sequence)?;
    let latest_updated_at = latest_local_catalog_updated_at(threads);
    tx.execute(
        "INSERT INTO local_thread_catalog_sync_state (
            host_id,
            watermark_updated_at,
            initial_build_complete,
            observation_sequence
        ) VALUES (
            'local',
            ?1,
            1,
            ?2
        )
        ON CONFLICT(host_id) DO UPDATE SET
            watermark_updated_at = excluded.watermark_updated_at,
            initial_build_complete = 1,
            observation_sequence = excluded.observation_sequence",
        (latest_updated_at, next_sequence),
    )?;
    tx.execute(
        "UPDATE local_thread_catalog_metadata SET catalog_revision = catalog_revision + 1 WHERE id = 1",
        [],
    )?;
    Ok(pending_changes)
}

fn local_catalog_host_exists(db: &Connection) -> anyhow::Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM local_thread_catalog_hosts WHERE host_id = 'local')",
        [],
        |row| row.get::<_, i64>(0),
    )? != 0)
}

fn local_catalog_metadata_exists(db: &Connection) -> anyhow::Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM local_thread_catalog_metadata WHERE id = 1)",
        [],
        |row| row.get::<_, i64>(0),
    )? != 0)
}

fn count_unopenable_local_thread_catalog_rows(
    db: &Connection,
    _threads: &[LocalCatalogThread],
) -> anyhow::Result<usize> {
    Ok(db.query_row(
        "SELECT COUNT(*) FROM local_thread_catalog
         WHERE missing_candidate = 0
           AND COALESCE(source_detail, '') = ''",
        [],
        |row| row.get::<_, i64>(0),
    )? as usize)
}

fn mark_unopenable_local_thread_catalog_rows_missing(
    tx: &rusqlite::Transaction<'_>,
    _threads: &[LocalCatalogThread],
    observation_sequence: i64,
) -> anyhow::Result<usize> {
    Ok(tx.execute(
        "UPDATE local_thread_catalog
         SET missing_candidate = 1,
             observation_sequence = ?1
         WHERE missing_candidate = 0
           AND COALESCE(source_detail, '') = ''",
        [observation_sequence],
    )?)
}

fn local_thread_catalog_row(
    db: &Connection,
    thread_id: &str,
) -> anyhow::Result<Option<LocalCatalogThread>> {
    let mut stmt = db.prepare(
        "SELECT thread_id, display_title, source_created_at, source_updated_at, cwd, source_kind, source_detail, model_provider, git_branch, missing_candidate FROM local_thread_catalog WHERE host_id = 'local' AND thread_id = ?1",
    )?;
    let mut rows = stmt.query([thread_id])?;
    let Some(row) = rows.next()? else {
        return Ok(None);
    };
    if row.get::<_, i64>(9)? != 0 {
        return Ok(None);
    }
    Ok(Some(LocalCatalogThread {
        thread_id: row.get(0)?,
        display_title: row.get(1)?,
        source_created_at: row.get(2)?,
        source_updated_at: row.get(3)?,
        cwd: row.get(4)?,
        source_kind: row.get(5)?,
        source_detail: row.get(6)?,
        model_provider: row.get(7)?,
        git_branch: row.get(8)?,
    }))
}

fn next_local_catalog_observation_sequence(db: &Connection) -> anyhow::Result<i64> {
    let current = db
        .query_row(
            "SELECT COALESCE(MAX(observation_sequence), 0) FROM local_thread_catalog_sync_state",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap_or(0);
    Ok(current + 1)
}

fn latest_local_catalog_updated_at(threads: &[LocalCatalogThread]) -> Option<f64> {
    threads
        .iter()
        .map(|thread| thread.source_updated_at)
        .max_by(f64::total_cmp)
}

fn load_global_state(path: &Path) -> anyhow::Result<Map<String, Value>> {
    if !path.exists() {
        return Ok(Map::new());
    }
    Ok(serde_json::from_str::<Value>(&fs::read_to_string(path)?)?
        .as_object()
        .cloned()
        .unwrap_or_default())
}

fn load_projectless_thread_ids(path: &Path) -> anyhow::Result<HashSet<String>> {
    let state = load_global_state(path)?;
    Ok(state
        .get("projectless-thread-ids")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .map(str::to_string)
        .collect())
}

fn normalized_global_state(state: &Map<String, Value>) -> Map<String, Value> {
    let mut next = Map::new();
    if let Some(value) = state.get("electron-saved-workspace-roots") {
        next.insert(
            "electron-saved-workspace-roots".to_string(),
            json!(dedupe_paths(path_array(value))),
        );
    }
    if let Some(value) = state.get("project-order") {
        next.insert(
            "project-order".to_string(),
            json!(dedupe_paths(path_array(value))),
        );
    }
    if let Some(value) = state.get("active-workspace-roots") {
        let normalized = dedupe_paths(path_array(value));
        let next_value = if value.is_array() {
            json!(normalized)
        } else if let Some(first) = normalized.first() {
            json!(first)
        } else {
            value.clone()
        };
        next.insert("active-workspace-roots".to_string(), next_value);
    }
    if let Some(value) = state
        .get("electron-workspace-root-labels")
        .and_then(Value::as_object)
    {
        let mut labels = Map::new();
        for (key, item) in value {
            labels.insert(
                to_desktop_workspace_path(key).unwrap_or_else(|| key.clone()),
                item.clone(),
            );
        }
        next.insert(
            "electron-workspace-root-labels".to_string(),
            Value::Object(labels),
        );
    }
    if let Some(open_targets) = state
        .get("open-in-target-preferences")
        .and_then(Value::as_object)
    {
        let mut next_open_targets = open_targets.clone();
        if let Some(per_path) =
            copy_resolved_object_keys(open_targets.get("perPath").and_then(Value::as_object))
        {
            next_open_targets.insert("perPath".to_string(), Value::Object(per_path));
        }
        next.insert(
            "open-in-target-preferences".to_string(),
            Value::Object(next_open_targets),
        );
    }
    next
}

fn copy_resolved_object_keys(value: Option<&Map<String, Value>>) -> Option<Map<String, Value>> {
    let value = value?;
    let mut next = Map::new();
    for (key, item) in value {
        next.insert(
            to_desktop_workspace_path(key).unwrap_or_else(|| key.clone()),
            item.clone(),
        );
    }
    Some(next)
}

fn count_global_state_updates(path: &Path) -> anyhow::Result<usize> {
    let state = load_global_state(path)?;
    let next = normalized_global_state(&state);
    Ok(next
        .iter()
        .filter(|(key, value)| state.get(*key) != Some(*value))
        .count())
}

fn apply_global_state_update(path: &Path) -> anyhow::Result<usize> {
    let mut state = load_global_state(path)?;
    let next = normalized_global_state(&state);
    let count = next
        .iter()
        .filter(|(key, value)| state.get(*key) != Some(*value))
        .count();
    if count > 0 {
        for (key, value) in next {
            state.insert(key, value);
        }
        let text = serde_json::to_string_pretty(&Value::Object(state))?;
        fs::write(path, &text)?;
        if let Some(parent) = path.parent() {
            fs::write(parent.join(".codex-global-state.json.bak"), text)?;
        }
    }
    Ok(count)
}

fn path_array(value: &Value) -> Vec<String> {
    if let Some(items) = value.as_array() {
        items
            .iter()
            .filter_map(Value::as_str)
            .filter(|item| !item.trim().is_empty())
            .map(ToString::to_string)
            .collect()
    } else if let Some(value) = value.as_str().filter(|item| !item.trim().is_empty()) {
        vec![value.to_string()]
    } else {
        Vec::new()
    }
}

fn dedupe_paths(paths: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for path in paths {
        let Some(desktop) = to_desktop_workspace_path(&path) else {
            continue;
        };
        let comparable = desktop
            .replace('/', r"\")
            .trim_end_matches('\\')
            .to_ascii_lowercase();
        if seen.insert(comparable) {
            result.push(desktop);
        }
    }
    result
}

fn prune_backups(home: &Path) -> anyhow::Result<()> {
    let root = home.join("backups_state/provider-sync");
    if !root.exists() {
        return Ok(());
    }
    let mut managed = Vec::new();
    for entry in fs::read_dir(&root)? {
        let path = entry?.path();
        if !path.is_dir() {
            continue;
        }
        let Ok(text) = fs::read_to_string(path.join("metadata.json")) else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(&text) else {
            continue;
        };
        if value.get("managedBy").and_then(Value::as_str) == Some("Codex++ provider sync") {
            managed.push(path);
        }
    }
    managed.sort_by(|a, b| b.file_name().cmp(&a.file_name()));
    for path in managed.into_iter().skip(BACKUP_KEEP_COUNT) {
        let _ = fs::remove_dir_all(path);
    }
    Ok(())
}

fn timestamp_name() -> String {
    chrono::Local::now().format("%Y%m%d%H%M%S").to_string()
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
