#!/bin/bash
# Bundled-plugin staging — Browser Use, Chrome, Linux Computer Use, manifests, marketplace.
#
# Sourced by install.sh. Do not run directly.
# shellcheck shell=bash

# ---- Install Linux-safe bundled plugin resources ----
list_portable_bundled_plugins() {
    local marketplace="$1"

    node - "$marketplace" <<'NODE'
const fs = require("fs");
const path = require("path");

const marketplacePath = process.argv[2];
const marketplace = JSON.parse(fs.readFileSync(marketplacePath, "utf8"));
const plugins = Array.isArray(marketplace.plugins) ? marketplace.plugins : [];
const portableNames = new Set(["sites", "deep-research", "visualize"]);
const emittedNames = new Set();

for (const plugin of plugins) {
  if (plugin == null || typeof plugin !== "object" || !portableNames.has(plugin.name)) {
    continue;
  }
  const source = plugin.source;
  if (source == null || source.source !== "local" || typeof source.path !== "string") {
    continue;
  }
  const normalized = path.posix.normalize(source.path.replace(/\\/g, "/"));
  if (normalized === `plugins/${plugin.name}` && !emittedNames.has(plugin.name)) {
    emittedNames.add(plugin.name);
    process.stdout.write(`${plugin.name}\n`);
  }
}
NODE
}

validate_portable_bundled_plugin() {
    local plugin_dir="$1"
    local expected_name="$2"

    python3 - "$plugin_dir" "$expected_name" <<'PY'
import json
import os
from pathlib import Path
import re
import stat
import sys

root = Path(sys.argv[1])
expected_name = sys.argv[2]
manifest_path = root / ".codex-plugin" / "plugin.json"

if root.is_symlink():
    print("plugin root cannot be a symlink", file=sys.stderr)
    sys.exit(1)
if not root.is_dir():
    print("plugin root must be a directory", file=sys.stderr)
    sys.exit(1)
if manifest_path.is_symlink():
    print("plugin manifest cannot be a symlink", file=sys.stderr)
    sys.exit(1)

try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    print(f"invalid plugin manifest: {exc}", file=sys.stderr)
    sys.exit(1)

if manifest.get("name") != expected_name:
    print("plugin manifest name does not match its marketplace entry", file=sys.stderr)
    sys.exit(1)
version = manifest.get("version")
if not isinstance(version, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", version.strip()) is None:
    print("plugin manifest version is missing or invalid", file=sys.stderr)
    sys.exit(1)

native_suffixes = {
    ".app",
    ".dll",
    ".dylib",
    ".exe",
    ".framework",
    ".node",
    ".so",
}
native_magics = {
    b"\x7fELF",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
}

def fail_walk(error):
    print(f"cannot inspect plugin tree: {error}", file=sys.stderr)
    sys.exit(1)


for current_root, directories, files in os.walk(root, followlinks=False, onerror=fail_walk):
    current = Path(current_root)
    for name in directories:
        path = current / name
        if path.is_symlink():
            print(f"symlink is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        try:
            metadata = path.lstat()
        except OSError as exc:
            print(f"cannot inspect {path.relative_to(root)}: {exc}", file=sys.stderr)
            sys.exit(1)
        if not stat.S_ISDIR(metadata.st_mode):
            print(f"non-directory entry is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        if metadata.st_mode & 0o6000:
            print(f"privileged mode is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        if path.suffix.lower() in native_suffixes:
            print(f"native bundle is not portable: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)

    for name in files:
        path = current / name
        if path.is_symlink():
            print(f"symlink is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        try:
            metadata = path.lstat()
        except OSError as exc:
            print(f"cannot inspect {path.relative_to(root)}: {exc}", file=sys.stderr)
            sys.exit(1)
        if not stat.S_ISREG(metadata.st_mode):
            print(f"non-regular file is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        if metadata.st_mode & 0o6000:
            print(f"privileged mode is not allowed: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        if path.suffix.lower() in native_suffixes:
            print(f"native file is not portable: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
        try:
            with path.open("rb") as stream:
                header = stream.read(4)
        except OSError as exc:
            print(f"cannot read {path.relative_to(root)}: {exc}", file=sys.stderr)
            sys.exit(1)
        if header in native_magics or header[:2] == b"MZ":
            print(f"native executable is not portable: {path.relative_to(root)}", file=sys.stderr)
            sys.exit(1)
PY
}

stage_portable_bundled_plugin_from_upstream() {
    local source_plugin="$1"
    local target_plugins="$2"
    local plugin_name="$3"
    local target_plugin="$target_plugins/$plugin_name"
    local staging_plugin=""
    local backup_plugin="$target_plugins/.${plugin_name}.backup.$$"

    if [ ! -d "$source_plugin" ]; then
        info "Portable bundled plugin $plugin_name not present in upstream app; skipping"
        return 1
    fi
    if ! validate_portable_bundled_plugin "$source_plugin" "$plugin_name"; then
        warn "Portable bundled plugin $plugin_name contains unsupported content; skipping"
        return 1
    fi

    if ! staging_plugin="$(mktemp -d "$target_plugins/.${plugin_name}.tmp.XXXXXX")"; then
        warn "Failed to create staging directory for portable bundled plugin $plugin_name"
        return 1
    fi
    if ! cp -R "$source_plugin/." "$staging_plugin/"; then
        rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
        warn "Failed to stage portable bundled plugin $plugin_name"
        return 1
    fi
    if ! remove_macos_sidecar_files "$staging_plugin"; then
        rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
        warn "Failed to clean macOS sidecar files for portable bundled plugin $plugin_name"
        return 1
    fi
    if ! validate_portable_bundled_plugin "$staging_plugin" "$plugin_name"; then
        rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
        warn "Portable bundled plugin $plugin_name failed post-copy validation"
        return 1
    fi

    if ! rm -rf -- "$backup_plugin"; then
        rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
        warn "Failed to prepare backup for portable bundled plugin $plugin_name"
        return 1
    fi
    if [ -e "$target_plugin" ] || [ -L "$target_plugin" ]; then
        if ! mv -- "$target_plugin" "$backup_plugin"; then
            rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
            warn "Failed to preserve existing portable bundled plugin $plugin_name"
            return 1
        fi
    else
        backup_plugin=""
    fi
    if ! mv -- "$staging_plugin" "$target_plugin"; then
        rm -rf -- "$staging_plugin" || warn "Failed to clean staging directory for portable bundled plugin $plugin_name"
        if [ -n "$backup_plugin" ]; then
            if mv -- "$backup_plugin" "$target_plugin"; then
                warn "Failed to install portable bundled plugin $plugin_name; previous target was restored"
            else
                warn "Failed to install portable bundled plugin $plugin_name and previous target could not be restored"
            fi
        else
            warn "Failed to install portable bundled plugin $plugin_name"
        fi
        return 1
    fi
    if [ -n "$backup_plugin" ] && ! rm -rf -- "$backup_plugin"; then
        warn "Failed to clean previous portable bundled plugin backup: $backup_plugin"
    fi
    info "Portable bundled plugin $plugin_name staged from upstream DMG"
    return 0
}

find_cargo_for_linux_computer_use() {
    if command -v cargo >/dev/null 2>&1; then
        command -v cargo
        return 0
    fi

    if [ -x "$HOME/.cargo/bin/cargo" ]; then
        echo "$HOME/.cargo/bin/cargo"
        return 0
    fi

    return 1
}

build_linux_computer_use_backend() {
    local crate_dir="$SCRIPT_DIR/computer-use-linux"
    local backend_binary="$SCRIPT_DIR/target/release/codex-computer-use-linux"
    local cosmic_helper_binary="$SCRIPT_DIR/target/release/codex-computer-use-cosmic"
    local cargo_cmd=""

    if [ -n "${CODEX_LINUX_COMPUTER_USE_BACKEND_SOURCE:-}" ] || [ -n "${CODEX_LINUX_COMPUTER_USE_COSMIC_SOURCE:-}" ]; then
        [ -n "${CODEX_LINUX_COMPUTER_USE_BACKEND_SOURCE:-}" ] || warn "CODEX_LINUX_COMPUTER_USE_BACKEND_SOURCE is not set"
        [ -n "${CODEX_LINUX_COMPUTER_USE_COSMIC_SOURCE:-}" ] || warn "CODEX_LINUX_COMPUTER_USE_COSMIC_SOURCE is not set"
        [ -x "${CODEX_LINUX_COMPUTER_USE_BACKEND_SOURCE:-}" ] || return 1
        [ -x "${CODEX_LINUX_COMPUTER_USE_COSMIC_SOURCE:-}" ] || return 1
        info "Using prebuilt Linux Computer Use backend"
        printf '%s\n%s\n' "$CODEX_LINUX_COMPUTER_USE_BACKEND_SOURCE" "$CODEX_LINUX_COMPUTER_USE_COSMIC_SOURCE"
        return 0
    fi

    if [ ! -d "$crate_dir" ]; then
        warn "Linux Computer Use backend source not found at $crate_dir"
        return 1
    fi

    if ! cargo_cmd="$(find_cargo_for_linux_computer_use)"; then
        warn "cargo not found; Linux Computer Use plugin will be unavailable"
        return 1
    fi

    info "Building Linux Computer Use backend..."
    if ! (cd "$SCRIPT_DIR" && "$cargo_cmd" build --release -p codex-computer-use-linux >&2); then
        warn "Failed to build Linux Computer Use backend"
        return 1
    fi

    [ -x "$backend_binary" ] || {
        warn "Linux Computer Use backend binary missing after build: $backend_binary"
        return 1
    }

    [ -x "$cosmic_helper_binary" ] || {
        warn "Linux Computer Use COSMIC helper binary missing after build: $cosmic_helper_binary"
        return 1
    }

    printf '%s\n%s\n' "$backend_binary" "$cosmic_helper_binary"
}

stage_linux_computer_use_plugin() {
    local target_plugins="$1"
    local plugin_template="$SCRIPT_DIR/plugins/openai-bundled/plugins/computer-use"
    local build_outputs=""
    local backend_binary=""
    local cosmic_helper_binary=""
    local target_plugin="$target_plugins/computer-use"

    if [ ! -d "$plugin_template" ]; then
        warn "Linux Computer Use plugin template not found at $plugin_template"
        return 1
    fi

    if ! build_outputs="$(build_linux_computer_use_backend)"; then
        return 1
    fi
    backend_binary="$(printf '%s\n' "$build_outputs" | sed -n '1p')"
    cosmic_helper_binary="$(printf '%s\n' "$build_outputs" | sed -n '2p')"

    rm -rf "$target_plugin"
    mkdir -p "$target_plugin"
    cp -R "$plugin_template/." "$target_plugin/"
    mkdir -p "$target_plugin/bin"
    cp "$backend_binary" "$target_plugin/bin/codex-computer-use-linux"
    cp "$cosmic_helper_binary" "$target_plugin/bin/codex-computer-use-cosmic"
    chmod 0755 "$target_plugin/bin/codex-computer-use-linux"
    chmod 0755 "$target_plugin/bin/codex-computer-use-cosmic"

    local plugin_icon_source="${LINUX_ICON_SOURCE:-$ICON_SOURCE}"
    if [ -f "$plugin_icon_source" ]; then
        mkdir -p "$target_plugin/assets"
        cp "$plugin_icon_source" "$target_plugin/assets/app-icon.png"
    fi

    find "$target_plugin" \( -name '*:com.apple.*' -o -name '.gitkeep' \) -delete
    return 0
}

is_host_linux_elf_executable() {
    local file="$1"
    python3 - "$file" "$ARCH" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
arch = sys.argv[2]
expected_machine = {
    "x86_64": 62,
    "aarch64": 183,
    "armv7l": 40,
    "armv6l": 40,
    "armhf": 40,
}.get(arch)
if expected_machine is None:
    sys.exit(1)

try:
    header = path.read_bytes()[:20]
except OSError:
    sys.exit(1)

if len(header) < 20 or header[:4] != b"\x7fELF":
    sys.exit(1)

is_little_endian = header[5] == 1
if not is_little_endian:
    sys.exit(1)

machine = int.from_bytes(header[18:20], "little")
sys.exit(0 if machine == expected_machine else 1)
PY
}

install_linux_executable_resource() {
    local source="$1"
    local destination="$2"
    local label="$3"
    local log_level="${4:-warn}"

    if [ ! -f "$source" ]; then
        if [ "$log_level" = "info" ]; then
            info "Browser Use $label not found in upstream resources; skipping"
        else
            warn "Browser Use $label not found in upstream resources; skipping"
        fi
        return 1
    fi

    if ! is_host_linux_elf_executable "$source"; then
        if [ "$log_level" = "info" ]; then
            info "Browser Use $label is not a Linux executable for $ARCH; skipping"
        else
            warn "Browser Use $label is not a Linux executable for $ARCH; skipping"
        fi
        return 1
    fi

    install -m 0755 "$source" "$destination"
}

patch_browser_use_node_repl_glibc_228() {
    local file="$1"
    local patcher="$SCRIPT_DIR/scripts/lib/patch-node-repl-glibc.py"

    [ -f "$patcher" ] || {
        echo "node_repl glibc patcher is missing: $patcher" >&2
        return 1
    }
    python3 "$patcher" "$file"
}

install_browser_use_node_repl_glibc_compat() {
    local destination="$1"
    local runtime_dir
    local runtime_library
    local compatibility_source="$SCRIPT_DIR/scripts/lib/node-repl-glibc-compat.c"
    local cc_command="${CC:-cc}"

    command -v patchelf >/dev/null 2>&1 || {
        echo "patchelf is required for the glibc 2.28 node_repl compatibility patch" >&2
        return 1
    }
    command -v "$cc_command" >/dev/null 2>&1 || {
        echo "$cc_command is required for the glibc 2.28 node_repl compatibility patch" >&2
        return 1
    }
    [ -f "$compatibility_source" ] || {
        echo "node_repl glibc compatibility source is missing: $compatibility_source" >&2
        return 1
    }

    runtime_dir="$(dirname "$destination")/node-repl-runtime"
    runtime_library="$runtime_dir/libcodex-node-repl-glibc-compat.so"
    rm -rf "$runtime_dir"
    mkdir -p "$runtime_dir"
    if ! "$cc_command" -shared -fPIC -O2 -Wall -Wextra -Werror \
        -Wl,-soname,libcodex-node-repl-glibc-compat.so \
        "$compatibility_source" -o "$runtime_library"; then
        rm -rf "$runtime_dir"
        return 1
    fi

    patchelf --add-needed libdl.so.2 "$destination"
    patchelf --add-needed libpthread.so.0 "$destination"
    patchelf --add-needed libcodex-node-repl-glibc-compat.so "$destination"
    patchelf --set-rpath '$ORIGIN/node-repl-runtime' "$destination"
}

is_browser_use_node_repl_ldd_output_compatible() {
    local output="$1"
    ! printf '%s\n' "$output" | grep -Eq "=> not found|version .* not found"
}

install_browser_use_node_repl_executable_resource() {
    local source="$1"
    local destination="$2"
    local label="$3"
    local log_level="${4:-warn}"
    local ldd_output
    local patch_status

    if ! install_linux_executable_resource "$source" "$destination" "$label" "$log_level"; then
        return 1
    fi

    if ! patch_status="$(patch_browser_use_node_repl_glibc_228 "$destination" 2>&1)"; then
        warn "Browser Use $label has unsupported glibc runtime references; skipping"
        [ -z "$patch_status" ] || warn "$patch_status"
        rm -f "$destination"
        return 1
    fi

    if [ "$patch_status" = "patched" ]; then
        if ! install_browser_use_node_repl_glibc_compat "$destination"; then
            warn "Browser Use $label glibc 2.28 compatibility runtime could not be installed; skipping"
            rm -f "$destination"
            rm -rf "$(dirname "$destination")/node-repl-runtime"
            return 1
        fi
        info "Patched Browser Use $label for glibc 2.28+ compatibility"
    fi

    if command -v ldd >/dev/null 2>&1; then
        if ! ldd_output="$(ldd "$destination" 2>&1)" \
            || ! is_browser_use_node_repl_ldd_output_compatible "$ldd_output"; then
            if [ "$log_level" = "info" ]; then
                info "Browser Use $label is not compatible with this host runtime; skipping"
            else
                warn "Browser Use $label is not compatible with this host runtime; skipping"
            fi
            rm -f "$destination"
            return 1
        fi
    fi
}

browser_use_node_repl_runtime_url() {
    case "$ARCH" in
        x86_64)
            echo "${CODEX_BROWSER_USE_NODE_REPL_RUNTIME_URL:-https://persistent.oaistatic.com/codex-primary-runtime/26.426.12240/codex-primary-runtime-linux-x64-26.426.12240.tar.xz}"
            ;;
        *)
            return 1
            ;;
    esac
}

browser_use_node_repl_runtime_sha256() {
    case "$ARCH" in
        x86_64)
            echo "${CODEX_BROWSER_USE_NODE_REPL_RUNTIME_SHA256:-db5624eb6efa36b66ec6f6dd0488cefb966e49636862aab6209a4336c1ca90c4}"
            ;;
        *)
            return 1
            ;;
    esac
}

install_node_repl_from_primary_runtime_archive() {
    local destination="$1"
    local url
    local expected_sha
    local cache_dir
    local archive
    local extract_dir
    local source

    if ! url="$(browser_use_node_repl_runtime_url)"; then
        warn "Browser Use node_repl primary-runtime fallback is unavailable for $ARCH"
        return 1
    fi
    expected_sha="$(browser_use_node_repl_runtime_sha256)"

    cache_dir="${CODEX_BROWSER_USE_RUNTIME_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-desktop/browser-use}"
    archive="$cache_dir/$(basename "$url")"
    extract_dir="$WORK_DIR/browser-use-node-repl-runtime"
    source="$extract_dir/codex-primary-runtime/dependencies/bin/node_repl"

    mkdir -p "$cache_dir" "$extract_dir"
    if [ ! -f "$archive" ]; then
        info "Downloading Browser Use node_repl fallback runtime..."
        if ! curl -L --fail --progress-bar -o "$archive.part" "$url"; then
            rm -f "$archive.part"
            warn "Failed to download Browser Use node_repl fallback runtime"
            return 1
        fi
        mv "$archive.part" "$archive"
    else
        info "Using cached Browser Use node_repl fallback runtime: $archive"
    fi

    if ! printf '%s  %s\n' "$expected_sha" "$archive" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$archive"
        warn "Browser Use node_repl fallback runtime checksum mismatch; removed cached archive"
        return 1
    fi

    if ! tar -xJf "$archive" -C "$extract_dir" codex-primary-runtime/dependencies/bin/node_repl; then
        warn "Failed to extract Browser Use node_repl from fallback runtime"
        return 1
    fi

    install_browser_use_node_repl_executable_resource "$source" "$destination" "node_repl fallback runtime"
}

install_browser_use_node_repl_resource() {
    local upstream_resources="$1"
    local destination="$2"
    local source

    for source in \
        "${CODEX_LINUX_NODE_REPL_SOURCE:-}" \
        "${CODEX_NODE_REPL_PATH:-}"
    do
        [ -n "$source" ] || continue
        if install_browser_use_node_repl_executable_resource "$source" "$destination" "node_repl runtime"; then
            return 0
        fi
    done

    source="${XDG_CACHE_HOME:-$HOME/.cache}/codex-runtimes/codex-primary-runtime/dependencies/bin/node_repl"
    if [ -f "$source" ] && install_browser_use_node_repl_executable_resource "$source" "$destination" "node_repl runtime"; then
        return 0
    fi

    for source in \
        "$upstream_resources/cua_node/bin/node_repl" \
        "$upstream_resources/node_repl"
    do
        [ -f "$source" ] || continue
        if install_browser_use_node_repl_executable_resource "$source" "$destination" "node_repl runtime" "info"; then
            return 0
        fi
    done

    install_node_repl_from_primary_runtime_archive "$destination"
}

remove_macos_sidecar_files() {
    local root="$1"
    find "$root" -type f -name '*:com.apple.*' -delete
}

chrome_extension_host_arch() {
    case "$ARCH" in
        x86_64) echo "x64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

build_chrome_extension_host() {
    local source_binary="$SCRIPT_DIR/target/release/codex-chrome-extension-host"
    local cargo_cmd=""

    if [ -n "${CODEX_CHROME_EXTENSION_HOST_SOURCE:-}" ]; then
        [ -x "$CODEX_CHROME_EXTENSION_HOST_SOURCE" ] || {
            warn "CODEX_CHROME_EXTENSION_HOST_SOURCE is not executable: $CODEX_CHROME_EXTENSION_HOST_SOURCE"
            return 1
        }
        info "Using prebuilt Chrome extension host"
        printf '%s\n' "$CODEX_CHROME_EXTENSION_HOST_SOURCE"
        return 0
    fi

    if ! cargo_cmd="$(find_cargo_for_linux_computer_use)"; then
        warn "cargo not found; Chrome extension host will be unavailable"
        return 1
    fi

    info "Building Chrome extension host..."
    if ! (cd "$SCRIPT_DIR" && "$cargo_cmd" build --release -p codex-computer-use-linux --bin codex-chrome-extension-host >&2); then
        warn "Failed to build Chrome extension host"
        return 1
    fi

    if [ ! -x "$source_binary" ]; then
        warn "Chrome extension host binary missing after build: $source_binary"
        return 1
    fi

    printf '%s\n' "$source_binary"
}

install_chrome_extension_host_resource() {
    local target_plugin="$1"
    local source_host=""
    local extension_arch
    local target_host

    if ! extension_arch="$(chrome_extension_host_arch)"; then
        warn "Chrome extension host is unavailable for $ARCH; skipping Chrome plugin"
        return 1
    fi

    if ! source_host="$(build_chrome_extension_host)"; then
        return 1
    fi

    target_host="$target_plugin/extension-host/linux/$extension_arch/extension-host"
    mkdir -p "$(dirname "$target_host")"
    install -m 0755 "$source_host" "$target_host"
}

patch_chrome_plugin_for_linux() {
    local target_plugin="$1"
    local patcher="$SCRIPT_DIR/scripts/lib/patch-chrome-plugin.js"

    if [ ! -f "$patcher" ]; then
        warn "Chrome plugin patch helper not found at $patcher; leaving upstream scripts unchanged"
        return 0
    fi

    if ! node "$patcher" "$target_plugin" >&2; then
        warn "Chrome plugin Linux patch helper failed; leaving upstream scripts as-is"
    fi
}

normalize_plugin_script_executable_modes() {
    local target_plugin="$1"
    local scripts_dir="$target_plugin/scripts"
    local script

    [ -d "$scripts_dir" ] || return 0

    while IFS= read -r -d '' script; do
        if [ "$(head -c 2 "$script" 2>/dev/null || true)" = "#!" ]; then
            chmod 0755 "$script"
        fi
    done < <(find "$scripts_dir" -maxdepth 1 -type f -name '*.js' -print0)
}

stage_chrome_plugin_from_upstream() {
    local source_plugin="$1"
    local target_plugins="$2"
    local target_plugin="$target_plugins/chrome"
    local source_manifest="$source_plugin/.codex-plugin/plugin.json"
    local source_client="$source_plugin/scripts/browser-client.mjs"
    local source_install_manifest="$source_plugin/scripts/installManifest.mjs"

    if [ ! -d "$source_plugin" ]; then
        warn "Chrome bundled plugin resources not found in upstream app; skipping Chrome"
        return 1
    fi

    if [ ! -f "$source_manifest" ]; then
        warn "Chrome plugin manifest not found in upstream app; skipping Chrome"
        return 1
    fi

    if [ ! -f "$source_client" ] || [ ! -f "$source_install_manifest" ]; then
        warn "Chrome plugin scripts not found in upstream app; skipping Chrome"
        return 1
    fi

    rm -rf "$target_plugin"
    cp -R "$source_plugin" "$target_plugin"
    remove_macos_sidecar_files "$target_plugin"
    patch_chrome_plugin_for_linux "$target_plugin"
    patch_browser_use_node_repl_env_guard "$target_plugin/scripts/browser-client.mjs"
    patch_browser_use_node_repl_config_shim "$target_plugin/scripts/browser-client.mjs"
    patch_browser_use_native_pipe_import_meta_bridge "$target_plugin/scripts/browser-client.mjs"
    patch_browser_use_site_status_allowlist_fallback "$target_plugin/scripts/browser-client.mjs"
    normalize_plugin_script_executable_modes "$target_plugin"
    if ! install_chrome_extension_host_resource "$target_plugin"; then
        rm -rf "$target_plugin"
        return 1
    fi

    info "Chrome plugin staged from upstream DMG"
    return 0
}

patch_browser_use_site_status_allowlist_fallback() {
    local client="$1"

    if grep -q "codexLinuxSiteStatusAllowlistFallback" "$client"; then
        return 0
    fi

    python3 - "$client" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
patterns = [
    re.compile(
        r'async fetchBlocked\((?P<url>[A-Za-z_$][\w$]*)\)\{'
        r'let (?P<response>[A-Za-z_$][\w$]*)=await (?P<fetch>[A-Za-z_$][\w$]*)'
        r'\((?P=url)\.endpoint,\{method:"GET"\}\);'
        r'if\(!(?P=response)\.ok\)throw new Error\((?P<format>[A-Za-z_$][\w$]*)'
        r'\(`Browser Use cannot determine if \$\{(?P=url)\.displayUrl\} is allowed\. '
        r'Please try again later or use another source\.`\)\);'
        r'let (?P<json>[A-Za-z_$][\w$]*)=await (?P=response)\.json\(\);'
        r'return (?P<status>[A-Za-z_$][\w$]*)\((?P=json)\)\}'
    ),
    re.compile(
        r'async fetchBlocked\((?P<url>[A-Za-z_$][\w$]*),(?P<label>[A-Za-z_$][\w$]*)\)\{'
        r'let (?P<response>[A-Za-z_$][\w$]*)=await (?P<fetch>[A-Za-z_$][\w$]*)'
        r'\((?P=url)\.endpoint,\{method:"GET"\}\);'
        r'if\(!(?P=response)\.ok\)throw new Error\((?P<format>[A-Za-z_$][\w$]*)'
        r'\(`\$\{(?P=label)\} cannot determine if \$\{(?P=url)\.displayUrl\} is allowed\. '
        r'Please try again later or use another source\.`\)\);'
        r'let (?P<json>[A-Za-z_$][\w$]*)=await (?P=response)\.json\(\);'
        r'return (?P<status>[A-Za-z_$][\w$]*)\((?P=json)\)\}'
    ),
]
match = None
for pattern in patterns:
    match = pattern.search(source)
    if match is not None:
        break
if match is None:
    if "/aura/site_status" not in source and "fetchBlocked(" not in source:
        raise SystemExit(0)
    print(
        "WARN: Could not find Browser Use site_status allowlist fallback insertion point — leaving browser-client.mjs unchanged",
        file=sys.stderr,
    )
    raise SystemExit(0)

url = match.group("url")
response = match.group("response")
fetch = match.group("fetch")
formatter = match.group("format")
json_value = match.group("json")
status = match.group("status")
label = match.groupdict().get("label")
error = "__codexLinuxErr"
error_message = (
    f'Browser Use cannot determine if ${{{url}.displayUrl}} is allowed. Please try again later or use another source.'
    if label is None
    else f'${{{label}}} cannot determine if ${{{url}.displayUrl}} is allowed. Please try again later or use another source.'
)
args = url if label is None else f"{url},{label}"
replacement = (
    f'async fetchBlocked({args}){{let {response};try{{{response}=await {fetch}({url}.endpoint,{{method:"GET"}})}}'
    f'catch({error}){{if(String({url}?.endpoint??"").includes("/aura/site_status")&&'
    f'String({error}?.message??{error}).toLowerCase().includes("allowlist"))return console.warn'
    f'("codexLinuxSiteStatusAllowlistFallback",{url}.endpoint),!1;throw {error}}}'
    f'if(!{response}.ok)throw new Error({formatter}(`{error_message}`));'
    f'let {json_value}=await {response}.json();return {status}({json_value})}}'
)
path.write_text(source[:match.start()] + replacement + source[match.end():], encoding="utf-8")
PY
}

patch_browser_use_file_url_policy() {
    local client="$1"

    if grep -q "codexLinuxFileUrlPolicy" "$client"; then
        return 0
    fi

    python3 - "$client" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
patterns = [
    re.compile(
        r'function\s+(?P<helper>[A-Za-z_$][\w$]*)\((?P<url>[A-Za-z_$][\w$]*)\)\{'
        r'if\((?P<allowlist>[A-Za-z_$][\w$]*)\.has\((?P=url)\)\)return\s*(?:true|!0);'
        r'let\s+(?P<parsed>[A-Za-z_$][\w$]*);'
        r'try\{\s*(?P=parsed)\s*=\s*new URL\((?P=url)\);?\s*\}'
        r'catch\{\s*return\s*(?:false|!1);?\s*\}'
        r'return\s+(?P=parsed)\.protocol\s*===\s*"http:"\s*\|\|\s*'
        r'(?P=parsed)\.protocol\s*===\s*"https:"(?P<semicolon>;?)\}'
    ),
    re.compile(
        r'function\s+(?P<helper>[A-Za-z_$][\w$]*)\((?P<url>[A-Za-z_$][\w$]*)\)\{'
        r'if\((?P<allowlist>[A-Za-z_$][\w$]*)\.has\((?P=url)\)\)return\s*(?:true|!0);'
        r'(?:const|let|var)\s+(?P<parsed>[A-Za-z_$][\w$]*)\s*=\s*new URL\((?P=url)\);'
        r'return\s+(?P=parsed)\.protocol\s*===\s*"http:"\s*\|\|\s*'
        r'(?P=parsed)\.protocol\s*===\s*"https:"(?P<semicolon>;?)\}'
    ),
]

for pattern in patterns:
    match = pattern.search(source)
    if match is None:
        continue

    parsed = match.group("parsed")
    semicolon = match.group("semicolon")
    old_body = match.group(0)
    old_return = re.compile(
        rf'return\s+{re.escape(parsed)}\.protocol\s*===\s*"http:"\s*\|\|\s*'
        rf'{re.escape(parsed)}\.protocol\s*===\s*"https:"{re.escape(semicolon)}'
    )
    file_policy = (
        f'{parsed}.protocol==="file:"&&'
        f'({parsed}.hostname===""||{parsed}.hostname==="localhost")'
        f'/*codexLinuxFileUrlPolicy*/'
    )
    new_return = (
        f'return {parsed}.protocol==="http:"||{parsed}.protocol==="https:"||'
        f'{file_policy}{semicolon}'
    )
    new_body, count = old_return.subn(new_return, old_body, count=1)
    if count != 1:
        continue

    path.write_text(source[:match.start()] + new_body + source[match.end():], encoding="utf-8")
    raise SystemExit(0)

print(
    "WARN: Could not find Browser Use URL policy insertion point — leaving browser-client.mjs unchanged",
    file=sys.stderr,
)
PY
}

patch_browser_use_node_repl_env_guard() {
    local client="$1"

    if grep -Eq 'globalThis\.nodeRepl\?\.env\?\.\[[^]]+\]' "$client"; then
        return 0
    fi

    python3 - "$client" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'function (?P<helper>[A-Za-z_$][\w$]*)\((?P<key>[A-Za-z_$][\w$]*)\)\{'
    r'let (?P<value>[A-Za-z_$][\w$]*)=globalThis\.nodeRepl\?\.env\[(?P=key)\];'
    r'return typeof (?P=value)=="string"\?(?P=value):void 0\}'
)
match = pattern.search(source)
if match is None:
    print(
        "WARN: Could not find Browser Use nodeRepl env guard insertion point — leaving browser-client.mjs unchanged",
        file=sys.stderr,
    )
    raise SystemExit(0)

helper = match.group("helper")
key = match.group("key")
value = match.group("value")
replacement = (
    f'function {helper}({key}){{'
    f'let {value}=globalThis.nodeRepl?.env?.[{key}];'
    f'return typeof {value}=="string"?{value}:void 0}}'
)
path.write_text(source[:match.start()] + replacement + source[match.end():], encoding="utf-8")
PY
}

patch_browser_use_node_repl_config_shim() {
    local client="$1"

    if grep -q "codexLinuxBrowserUseConfigShim" "$client"; then
        return 0
    fi

    python3 - "$client" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'function (?P<helper>[A-Za-z_$][\w$]*)\(\)\{'
    r'let (?P<value>[A-Za-z_$][\w$]*)=globalThis\.nodeRepl;'
    r'return (?P=value)\?\.config==null\?void 0:(?P=value)\}'
)
match = pattern.search(source)
if match is None:
    print(
        "WARN: Could not find Browser Use nodeRepl config shim insertion point — leaving browser-client.mjs unchanged",
        file=sys.stderr,
    )
    raise SystemExit(0)

helper = match.group("helper")
value = match.group("value")
shim = r'''
function codexLinuxBrowserUseConfigShim() {
  let repl = globalThis.nodeRepl;
  if (repl == null || repl.config != null) return;
  let config = {
    read: async () => ({ config: await codexLinuxBrowserUseReadToml("config.toml") }),
    readRequirements: async () => ({ requirements: null }),
    readToml: async (filePath) => codexLinuxBrowserUseReadToml(filePath),
    writeToml: codexLinuxBrowserUseIgnoreConfigWrite,
    writeValue: codexLinuxBrowserUseIgnoreConfigWrite,
    batchWrite: codexLinuxBrowserUseIgnoreConfigWrite,
  };

  try {
    repl.config = config;
    if (repl.config != null) return;
  } catch {}

  try {
    let prototype = Object.getPrototypeOf(repl);
    if (prototype != null && Object.getOwnPropertyDescriptor(prototype, "config") == null) {
      Object.defineProperty(prototype, "config", {
        configurable: true,
        get: () => config,
      });
    }
  } catch {}
}

function codexLinuxBrowserUseCodexHome() {
  let codexHome = globalThis.nodeRepl?.env?.CODEX_HOME;
  if (typeof codexHome == "string" && codexHome.length > 0) {
    return codexHome.replace(/\/+$/, "");
  }

  let homeDir = globalThis.nodeRepl?.homeDir;
  return typeof homeDir == "string" && homeDir.length > 0
    ? `${homeDir.replace(/\/+$/, "")}/.codex`
    : null;
}

function codexLinuxBrowserUseConfigPath(filePath) {
  let codexHome = codexLinuxBrowserUseCodexHome();
  if (codexHome == null || typeof filePath != "string" || filePath.length === 0) {
    return null;
  }

  let normalized = filePath.replaceAll("\\", "/");
  if (normalized.startsWith("/")) {
    return normalized === codexHome || normalized.startsWith(`${codexHome}/`)
      ? normalized
      : null;
  }

  normalized = normalized.replace(/^\/+/, "");
  return normalized.split("/").includes("..") ? null : `${codexHome}/${normalized}`;
}

async function codexLinuxBrowserUseReadToml(filePath) {
  let configPath = codexLinuxBrowserUseConfigPath(filePath);
  if (configPath == null) return {};

  try {
    let { readFile } = await import("node:fs/promises");
    return codexLinuxBrowserUseParseToml(await readFile(configPath, "utf8"));
  } catch (error) {
    if (error && typeof error == "object" && error.code === "ENOENT") return {};
    throw error;
  }
}

async function codexLinuxBrowserUseIgnoreConfigWrite() {
  return undefined;
}

function codexLinuxBrowserUseParseToml(source) {
  let root = {};
  let section = root;

  for (let line of String(source).split(/\r?\n/)) {
    let trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith("#")) continue;

    let sectionMatch = trimmed.match(/^\[([A-Za-z0-9_.-]+)\]$/);
    if (sectionMatch) {
      section = root;
      for (let part of sectionMatch[1].split(".")) {
        section = section[part] && typeof section[part] == "object" && !Array.isArray(section[part])
          ? section[part]
          : (section[part] = {});
      }
      continue;
    }

    let separator = trimmed.indexOf("=");
    if (separator < 0) continue;

    let key = trimmed.slice(0, separator).trim();
    let value = trimmed.slice(separator + 1).trim();
    if (key) section[key] = codexLinuxBrowserUseParseTomlValue(value);
  }

  return root;
}

function codexLinuxBrowserUseParseTomlValue(value) {
  if (value === "true") return true;
  if (value === "false") return false;
  if (/^-?\d+(?:\.\d+)?$/.test(value)) return Number(value);

  if (value.startsWith("[") && value.endsWith("]")) {
    let body = value.slice(1, -1).trim();
    return body.length === 0
      ? []
      : body.split(",").map((item) => codexLinuxBrowserUseParseTomlValue(item.trim()));
  }

  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    try {
      return JSON.parse(value);
    } catch {
      return value.slice(1, -1);
    }
  }

  return value;
}
'''
replacement = (
    shim
    + f'function {helper}(){{codexLinuxBrowserUseConfigShim();let {value}=globalThis.nodeRepl;'
    + f'return {value}?.config==null?void 0:{value}}}'
)
path.write_text(source[:match.start()] + replacement + source[match.end():], encoding="utf-8")
PY
}

patch_browser_use_native_pipe_import_meta_bridge() {
    local client="$1"

    if grep -Fq "globalThis.nodeRepl?.nativePipe??import.meta.__codexNativePipe" "$client"; then
        return 0
    fi

    python3 - "$client" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
pattern = re.compile(
    r'function (?P<helper>[A-Za-z_$][\w$]*)\(\)\{'
    r'let (?P<bridge>[A-Za-z_$][\w$]*)='
    r'(?:globalThis\.nodeRepl\?\.nativePipe|import\.meta\.__codexNativePipe);'
    r'return (?P=bridge)==null\|\|typeof (?P=bridge)\.createConnection!="function"\?null:(?P=bridge)\}'
)
match = pattern.search(source)
if match is None:
    print(
        "WARN: Could not find Browser Use nativePipe bridge helper — leaving browser-client.mjs unchanged",
        file=sys.stderr,
    )
    raise SystemExit(0)

helper = match.group("helper")
bridge = match.group("bridge")
replacement = (
    f'function {helper}(){{let {bridge}=globalThis.nodeRepl?.nativePipe??import.meta.__codexNativePipe;'
    f'return {bridge}==null||typeof {bridge}.createConnection!="function"?null:{bridge}}}'
)
path.write_text(source[:match.start()] + replacement + source[match.end():], encoding="utf-8")
PY
}

find_browser_plugin_source() {
    local bundled_root="$1"
    local source_marketplace="$2"

    node - "$bundled_root" "$source_marketplace" <<'NODE'
const fs = require("fs");
const path = require("path");

const bundledRoot = process.argv[2];
const marketplacePath = process.argv[3];
const candidates = [];

try {
  const marketplace = JSON.parse(fs.readFileSync(marketplacePath, "utf8"));
  const plugins = Array.isArray(marketplace.plugins) ? marketplace.plugins : [];
  const plugin = plugins.find((entry) => entry && entry.name === "browser");
  const source = plugin && plugin.source;
  if (
    source &&
    source.source === "local" &&
    typeof source.path === "string" &&
    source.path.length > 0
  ) {
    candidates.push(path.resolve(bundledRoot, source.path));
  }
} catch (_err) {
  // Fall back to the known upstream directory name below.
}

candidates.push(path.join(bundledRoot, "plugins", "browser"));

const seen = new Set();
for (const candidate of candidates) {
  const normalized = path.normalize(candidate);
  if (seen.has(normalized)) {
    continue;
  }
  seen.add(normalized);

  if (
    fs.existsSync(path.join(normalized, ".codex-plugin", "plugin.json")) &&
    fs.existsSync(path.join(normalized, "scripts", "browser-client.mjs"))
  ) {
    console.log(normalized);
    process.exit(0);
  }
}

process.exit(1);
NODE
}

stage_browser_plugin_from_upstream() {
    local source_plugin="$1"
    local target_plugins="$2"
    local target_name
    target_name="$(basename "$source_plugin")"
    local target_plugin="$target_plugins/$target_name"
    local source_client="$source_plugin/scripts/browser-client.mjs"
    local target_client="$target_plugin/scripts/browser-client.mjs"

    if [ ! -d "$source_plugin" ]; then
        info "Browser bundled plugin resources not present in upstream app; skipping Browser"
        return 1
    fi

    if [ ! -f "$source_plugin/.codex-plugin/plugin.json" ]; then
        warn "Browser plugin manifest not found in upstream app; skipping Browser"
        return 1
    fi

    if [ ! -f "$source_client" ]; then
        warn "Browser browser-client.mjs not found in upstream app; skipping Browser"
        return 1
    fi

    rm -rf "$target_plugin"
    cp -R "$source_plugin" "$target_plugin"
    remove_macos_sidecar_files "$target_plugin"
    patch_browser_use_node_repl_env_guard "$target_client"
    patch_browser_use_node_repl_config_shim "$target_client"
    patch_browser_use_native_pipe_import_meta_bridge "$target_client"
    patch_browser_use_site_status_allowlist_fallback "$target_client"
    patch_browser_use_file_url_policy "$target_client"

    info "Browser plugin staged from upstream DMG"
    return 0
}

write_bundled_plugins_marketplace() {
    local source="$1"
    local destination="$2"
    local include_browser="$3"
    local include_chrome="$4"
    local include_computer_use="$5"

    shift 5

    node - "$source" "$destination" "$include_browser" "$include_chrome" "$include_computer_use" "$@" <<'NODE'
const fs = require("fs");
const path = require("path");

const sourcePath = process.argv[2];
const destinationPath = process.argv[3];
const includeBrowser = process.argv[4] === "1";
const includeChrome = process.argv[5] === "1";
const includeComputerUse = process.argv[6] === "1";
const portablePluginNames = process.argv.slice(7);
const marketplace = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
const sourcePlugins = marketplace.plugins || [];
const plugins = [];

if (includeBrowser) {
  const marketplaceRoot = path.resolve(path.dirname(destinationPath), "..", "..");
  const browser = sourcePlugins.find((plugin) => {
    if (plugin == null || typeof plugin !== "object") {
      return false;
    }
    if (plugin.name !== "browser") {
      return false;
    }
    const source = plugin.source || {};
    if (source.source !== "local" || typeof source.path !== "string") {
      return true;
    }
    const stagedManifest = path.join(
      path.resolve(marketplaceRoot, source.path),
      ".codex-plugin",
      "plugin.json",
    );
    return fs.existsSync(stagedManifest);
  });
  if (browser == null) {
    let fallback = null;
    const stagedManifestPath = path.join(
      marketplaceRoot,
      "plugins",
      "browser",
      ".codex-plugin",
      "plugin.json",
    );
    try {
      const manifest = JSON.parse(fs.readFileSync(stagedManifestPath, "utf8"));
      const name =
        typeof manifest.name === "string" && manifest.name.length > 0 ? manifest.name : "browser";
      const category =
        manifest &&
        manifest.interface &&
        typeof manifest.interface.category === "string" &&
        manifest.interface.category.length > 0
          ? manifest.interface.category
          : "Engineering";
      fallback = {
        name,
        source: {
          source: "local",
          path: "./plugins/browser",
        },
        policy: {
          installation: "AVAILABLE",
          authentication: "ON_INSTALL",
        },
        category,
      };
    } catch (_err) {
      // Fall through to the explicit error below.
    }
    if (fallback == null) {
      throw new Error("Bundled marketplace does not contain browser plugin");
    }
    plugins.push(fallback);
  } else {
    plugins.push(browser);
  }
}

if (includeChrome) {
  const chrome = sourcePlugins.find((plugin) => plugin.name === "chrome");
  if (chrome != null) {
    plugins.push(chrome);
  } else {
    let name = "chrome";
    let category = "Productivity";
    const stagedManifestPath = path.join(
      path.dirname(destinationPath),
      "..",
      "..",
      "plugins",
      "chrome",
      ".codex-plugin",
      "plugin.json",
    );
    try {
      const manifest = JSON.parse(fs.readFileSync(stagedManifestPath, "utf8"));
      if (typeof manifest.name === "string" && manifest.name.length > 0) {
        name = manifest.name;
      }
      const manifestCategory =
        manifest && manifest.interface ? manifest.interface.category : undefined;
      if (typeof manifestCategory === "string" && manifestCategory.length > 0) {
        category = manifestCategory;
      }
    } catch (_err) {
      // Fall through to defaults when the staged plugin manifest is
      // missing or malformed — stage_chrome_plugin_from_upstream only
      // existence-checks plugin.json, so it can still be unparseable here.
    }
    plugins.push({
      name,
      source: {
        source: "local",
        path: "./plugins/chrome",
      },
      policy: {
        installation: "AVAILABLE",
        authentication: "ON_INSTALL",
      },
      category,
    });
  }
}

if (includeComputerUse) {
  plugins.push({
    name: "computer-use",
    source: {
      source: "local",
      path: "./plugins/computer-use",
    },
    policy: {
      installation: "AVAILABLE",
      authentication: "ON_INSTALL",
    },
    category: "Productivity",
  });
}

for (const name of portablePluginNames) {
  const plugin = sourcePlugins.find((entry) => {
    if (entry == null || typeof entry !== "object" || entry.name !== name) {
      return false;
    }
    const source = entry.source;
    if (source == null || source.source !== "local" || typeof source.path !== "string") {
      return false;
    }
    const normalized = path.posix.normalize(source.path.replace(/\\/g, "/"));
    return normalized === `plugins/${name}`;
  });
  if (plugin == null) {
    throw new Error(`Bundled marketplace does not contain ${name} plugin`);
  }
  plugins.push({
    ...plugin,
    source: {
      source: "local",
      path: `./plugins/${name}`,
    },
  });
}

const sourceOrder = new Map(sourcePlugins.map((plugin, index) => [plugin?.name, index]));
plugins.sort((left, right) => {
  const leftIndex = sourceOrder.get(left.name) ?? Number.MAX_SAFE_INTEGER;
  const rightIndex = sourceOrder.get(right.name) ?? Number.MAX_SAFE_INTEGER;
  return leftIndex - rightIndex;
});

marketplace.plugins = plugins;
fs.mkdirSync(path.dirname(destinationPath), { recursive: true });
fs.writeFileSync(destinationPath, `${JSON.stringify(marketplace, null, 2)}\n`);
NODE
}

install_bundled_plugin_resources() {
    local app_dir="$1"
    local upstream_resources="$app_dir/Contents/Resources"
    local bundled_source_root="$upstream_resources/plugins/openai-bundled"
    local source_marketplace="$bundled_source_root/.agents/plugins/marketplace.json"
    local source_browser_plugin=""
    local source_chrome_plugin="$upstream_resources/plugins/openai-bundled/plugins/chrome"
    local resources_dir="$INSTALL_DIR/resources"
    local bundled_plugins_dir="$resources_dir/plugins/openai-bundled"
    local include_browser=0
    local include_chrome=0
    local include_computer_use=0
    local portable_plugin_names=""
    local portable_plugins=()

    if [ ! -f "$source_marketplace" ]; then
        warn "Bundled plugin marketplace not found in upstream app; skipping bundled plugins"
        return 0
    fi

    mkdir -p "$bundled_plugins_dir/plugins" "$bundled_plugins_dir/.agents/plugins"

    if ! portable_plugin_names="$(list_portable_bundled_plugins "$source_marketplace")"; then
        warn "Could not parse portable bundled plugins from upstream marketplace"
        portable_plugin_names=""
    fi
    while IFS= read -r plugin_name; do
        [ -n "$plugin_name" ] || continue
        if stage_portable_bundled_plugin_from_upstream \
            "$bundled_source_root/plugins/$plugin_name" \
            "$bundled_plugins_dir/plugins" \
            "$plugin_name"; then
            portable_plugins+=("$plugin_name")
        fi
    done <<< "$portable_plugin_names"

    if source_browser_plugin="$(find_browser_plugin_source "$bundled_source_root" "$source_marketplace")" &&
        stage_browser_plugin_from_upstream "$source_browser_plugin" "$bundled_plugins_dir/plugins"; then
        include_browser=1
    else
        info "Browser bundled plugin resources not present in upstream app; skipping Browser"
    fi

    if stage_chrome_plugin_from_upstream "$source_chrome_plugin" "$bundled_plugins_dir/plugins"; then
        include_chrome=1
    fi

    if stage_linux_computer_use_plugin "$bundled_plugins_dir/plugins"; then
        include_computer_use=1
    else
        warn "Linux Computer Use plugin will be unavailable"
    fi

    if [ "$include_browser" -eq 0 ] && [ "$include_chrome" -eq 0 ] && [ "$include_computer_use" -eq 0 ] && [ "${#portable_plugins[@]}" -eq 0 ]; then
        warn "No Linux-safe bundled plugins were staged"
        return 0
    fi

    write_bundled_plugins_marketplace \
        "$source_marketplace" \
        "$bundled_plugins_dir/.agents/plugins/marketplace.json" \
        "$include_browser" \
        "$include_chrome" \
        "$include_computer_use" \
        "${portable_plugins[@]}"

    install_linux_executable_resource "$upstream_resources/node" "$resources_dir/node" "node runtime" "info" || true
    install_browser_use_node_repl_resource "$upstream_resources" "$resources_dir/node_repl" || true

    info "Linux-safe bundled plugins installed"
}
