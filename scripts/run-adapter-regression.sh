#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codexpp-regression.XXXXXX")"

cleanup() {
  rm -rf "$RUN_ROOT"
}
trap cleanup EXIT

# EN: Isolate PowerShell startup paths before pwsh initializes module discovery.
# ZH: 在 pwsh 初始化模块发现之前隔离 PowerShell 启动路径。
export HOME="$RUN_ROOT/home"
export XDG_DATA_HOME="$RUN_ROOT/data"
export XDG_CONFIG_HOME="$RUN_ROOT/config"
export XDG_CACHE_HOME="$RUN_ROOT/cache"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

cd "$REPO_ROOT"
pwsh -NoLogo -NoProfile -File "$REPO_ROOT/scripts/Run-AdapterRegression.ps1" "$@"
