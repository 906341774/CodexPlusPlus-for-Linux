#!/usr/bin/env bash
set -Eeuo pipefail

warn() {
    echo "WARN: $*" >&2
}

files_match() {
    local left="$1"
    local right="$2"

    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$left" "$right"
        return
    fi
    command -v cksum >/dev/null 2>&1 || return 1
    [ "$(cksum <"$left")" = "$(cksum <"$right")" ]
}

if [ -z "${CODEX_LINUX_FEATURES_DIR:-}" ]; then
    warn "CODEX_LINUX_FEATURES_DIR is not set; skipping Agent Workspaces skill install"
    exit 0
fi

skill_source="$CODEX_LINUX_FEATURES_DIR/agent-workspace/skills/agent-workspace-linux/SKILL.md"
if [ ! -f "$skill_source" ]; then
    warn "Agent Workspaces skill source not found at $skill_source; skipping skill install"
    exit 0
fi

codex_home="${CODEX_HOME:-}"
if [ -z "$codex_home" ]; then
    if [ -z "${HOME:-}" ]; then
        warn "CODEX_HOME is not set and HOME is unavailable; skipping Agent Workspaces skill install"
        exit 0
    fi
    codex_home="$HOME/.codex"
fi

target_dir="$codex_home/skills/agent-workspace-linux"
target_skill="$target_dir/SKILL.md"

if ! mkdir -p "$target_dir"; then
    warn "Could not create Agent Workspaces skill directory at $target_dir"
    exit 0
fi

if [ -f "$target_skill" ] && files_match "$skill_source" "$target_skill"; then
    echo "Agent Workspaces skill already current at $target_skill" >&2
    exit 0
fi

if ! install -m 0644 "$skill_source" "$target_skill"; then
    warn "Could not install Agent Workspaces skill to $target_skill"
    exit 0
fi

echo "Installed Agent Workspaces skill to $target_skill" >&2
