#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: test-release-payload-compatibility.sh [--max-glibc VERSION] [--require-manager-elf] PAYLOAD_ROOT
USAGE
}

max_glibc="2.28"
require_manager_elf=0
payload_root=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --max-glibc)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            max_glibc="$2"
            shift 2
            ;;
        --require-manager-elf)
            require_manager_elf=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "Unknown option: $1" >&2
            usage
            exit 2
            ;;
        *)
            [ -z "$payload_root" ] || { usage; exit 2; }
            payload_root="$1"
            shift
            ;;
    esac
done

[ -n "$payload_root" ] || { usage; exit 2; }
[ -d "$payload_root" ] || { echo "Payload root does not exist: $payload_root" >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "readelf is required" >&2; exit 1; }

is_elf() {
    [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]
}

is_x86_64_elf() {
    is_elf "$1" || return 1
    readelf -h "$1" 2>/dev/null | grep -Eq 'Machine:[[:space:]]+(Advanced Micro Devices X86-64|X86-64)'
}

version_exceeds() {
    local actual="$1"
    local maximum="$2"
    [ "$(printf '%s\n%s\n' "$actual" "$maximum" | sort -V | tail -n 1)" = "$actual" ] &&
        [ "$actual" != "$maximum" ]
}

checked=0
failures=0
while IFS= read -r -d '' file_path; do
    is_x86_64_elf "$file_path" || continue
    checked=$((checked + 1))
    required_glibc="$({
        readelf --version-info "$file_path" 2>/dev/null |
            grep -o 'GLIBC_[0-9.]*' |
            sed 's/^GLIBC_//' |
            sort -V |
            tail -n 1
    } || true)"
    if [ -n "$required_glibc" ] && version_exceeds "$required_glibc" "$max_glibc"; then
        relative_path="${file_path#"$payload_root"/}"
        echo "$relative_path requires GLIBC_$required_glibc, which exceeds maximum GLIBC_$max_glibc" >&2
        failures=$((failures + 1))
    fi
done < <(find "$payload_root" -type f -print0)

if [ "$require_manager_elf" -eq 1 ]; then
    manager="$payload_root/.codex-plusplus/install/codex-plus-plus-manager"
    if [ ! -f "$manager" ]; then
        echo "Codex++ Manager is missing: $manager" >&2
        failures=$((failures + 1))
    elif ! is_x86_64_elf "$manager"; then
        echo "Codex++ Manager is not an ELF executable: $manager" >&2
        failures=$((failures + 1))
    else
        manager_ldd="$({ ldd "$manager" 2>&1 || true; })"
        if grep -q 'not found' <<<"$manager_ldd"; then
            echo "Codex++ Manager has unresolved dynamic dependencies:" >&2
            grep 'not found' <<<"$manager_ldd" >&2
            failures=$((failures + 1))
        fi
    fi
fi

if [ "$failures" -ne 0 ]; then
    echo "Release payload compatibility failed with $failures finding(s)." >&2
    exit 1
fi

echo "Release payload compatibility passed: $checked x86-64 ELF files require at most GLIBC_$max_glibc."
