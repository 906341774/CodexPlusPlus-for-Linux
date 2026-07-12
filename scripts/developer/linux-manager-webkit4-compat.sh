#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
compat_source="$script_dir/lib/linux-manager-webkit4-compat.c"

usage() {
    cat >&2 <<'USAGE'
Usage:
  linux-manager-webkit4-compat.sh selftest
  linux-manager-webkit4-compat.sh prepare WORK_ROOT
  linux-manager-webkit4-compat.sh verify MANAGER
  linux-manager-webkit4-compat.sh install-runtime MANAGER MANAGER_RUNTIME_DIR
USAGE
}

die() {
    echo "linux-manager-webkit4-compat: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

is_elf() {
    [ -f "$1" ] && [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]
}

pc_file() {
    local module="$1"
    local pc_dir
    pc_dir="$(pkg-config --variable=pcfiledir "$module")"
    [ -n "$pc_dir" ] || die "pkg-config did not report pcfiledir for $module"
    [ -f "$pc_dir/$module.pc" ] || die "pkg-config file is missing for $module: $pc_dir/$module.pc"
    printf '%s\n' "$pc_dir/$module.pc"
}

copy_pc_with_version() {
    local source_module="$1"
    local target_module="$2"
    local advertised_version="$3"
    local destination_dir="$4"
    local destination="$destination_dir/$target_module.pc"

    cp -- "$(pc_file "$source_module")" "$destination"
    sed -E -i "s/^Version:.*/Version: $advertised_version/" "$destination"
}

prepare_compatibility_build() {
    local work_root="$1"
    local staging_root
    local cc_command="${CC:-cc}"

    case "$work_root" in
        ''|/) die 'WORK_ROOT must be a dedicated non-root directory' ;;
    esac

    require_command pkg-config
    require_command "$cc_command"
    require_command sed
    require_command readlink
    [ -f "$compat_source" ] || die "compatibility source is missing: $compat_source"

    local required_modules=(
        glib-2.0
        gobject-2.0
        gio-2.0
        gio-unix-2.0
        webkit2gtk-4.0
        javascriptcoregtk-4.0
        libsoup-2.4
    )
    pkg-config --exists "${required_modules[@]}" ||
        die 'WebKitGTK 4.0 development dependencies are incomplete'

    staging_root="${work_root}.tmp.$$"
    rm -rf -- "$staging_root"
    mkdir -p -- "$staging_root/pkgconfig" "$staging_root/lib"

    copy_pc_with_version glib-2.0 glib-2.0 2.70.0 "$staging_root/pkgconfig"
    copy_pc_with_version gobject-2.0 gobject-2.0 2.70.0 "$staging_root/pkgconfig"
    copy_pc_with_version gio-2.0 gio-2.0 2.70.0 "$staging_root/pkgconfig"
    copy_pc_with_version gio-unix-2.0 gio-unix-2.0 2.70.0 "$staging_root/pkgconfig"
    copy_pc_with_version webkit2gtk-4.0 webkit2gtk-4.1 2.40.0 "$staging_root/pkgconfig"
    copy_pc_with_version javascriptcoregtk-4.0 javascriptcoregtk-4.1 2.40.0 "$staging_root/pkgconfig"
    copy_pc_with_version libsoup-2.4 libsoup-3.0 3.0.0 "$staging_root/pkgconfig"

    # Keep the old ABI in Libs/Cflags, but satisfy the dependency names queried
    # by the current webkit2gtk Rust bindings.
    sed -E -i '/^Requires(\.private)?:/ {
        s/libsoup-2\.4/libsoup-3.0/g
        s/javascriptcoregtk-4\.0/javascriptcoregtk-4.1/g
    }' "$staging_root/pkgconfig/webkit2gtk-4.1.pc"

    local webkit_libdir javascriptcore_libdir soup_libdir
    webkit_libdir="$(pkg-config --variable=libdir webkit2gtk-4.0)"
    javascriptcore_libdir="$(pkg-config --variable=libdir javascriptcoregtk-4.0)"
    soup_libdir="$(pkg-config --variable=libdir libsoup-2.4)"
    [ -e "$webkit_libdir/libwebkit2gtk-4.0.so" ] || die 'libwebkit2gtk-4.0 linker name is missing'
    [ -e "$javascriptcore_libdir/libjavascriptcoregtk-4.0.so" ] || die 'libjavascriptcoregtk-4.0 linker name is missing'
    [ -e "$soup_libdir/libsoup-2.4.so" ] || die 'libsoup-2.4 linker name is missing'
    ln -s -- "$webkit_libdir/libwebkit2gtk-4.0.so" "$staging_root/lib/libwebkit2gtk-4.1.so"
    ln -s -- "$javascriptcore_libdir/libjavascriptcoregtk-4.0.so" "$staging_root/lib/libjavascriptcoregtk-4.1.so"
    ln -s -- "$soup_libdir/libsoup-2.4.so" "$staging_root/lib/libsoup-3.0.so"

    "$cc_command" -fPIC -O2 -Wall -Wextra -Werror -c "$compat_source" \
        -o "$staging_root/linux-manager-webkit4-compat.o"

    rm -rf -- "$work_root"
    mv -- "$staging_root" "$work_root"
    printf 'PKG_CONFIG_PATH=%s\n' "$work_root/pkgconfig"
    printf 'LIBRARY_PATH=%s\n' "$work_root/lib"
    printf 'RUSTFLAGS=-C link-arg=%s\n' "$work_root/linux-manager-webkit4-compat.o"
}

verify_compatibility_manager() {
    local manager="$1"
    local dynamic_section
    local failures=0

    require_command readelf
    is_elf "$manager" || die "Manager is not an ELF executable: $manager"
    dynamic_section="$(readelf -d "$manager" 2>/dev/null)"

    local required_sonames=(
        libwebkit2gtk-4.0.so.37
        libjavascriptcoregtk-4.0.so.18
        libsoup-2.4.so.1
    )
    local forbidden_sonames=(
        libwebkit2gtk-4.1.so.0
        libjavascriptcoregtk-4.1.so.0
        libsoup-3.0.so.0
    )
    local soname
    for soname in "${required_sonames[@]}"; do
        if ! grep -Fq "Shared library: [$soname]" <<<"$dynamic_section"; then
            echo "Manager does not require the compatibility SONAME $soname" >&2
            failures=$((failures + 1))
        fi
    done
    for soname in "${forbidden_sonames[@]}"; do
        if grep -Fq "Shared library: [$soname]" <<<"$dynamic_section"; then
            echo "Manager still requires the unsupported SONAME $soname" >&2
            failures=$((failures + 1))
        fi
    done

    if command -v ldd >/dev/null 2>&1; then
        local unresolved
        unresolved="$(ldd "$manager" 2>&1 | grep 'not found' || true)"
        if [ -n "$unresolved" ]; then
            echo 'Manager has unresolved dynamic dependencies:' >&2
            echo "$unresolved" >&2
            failures=$((failures + 1))
        fi
    fi

    [ "$failures" -eq 0 ] || die "Manager compatibility verification failed with $failures finding(s)"
    echo 'Linux Manager WebKitGTK 4.0 compatibility verification passed.'
}

resolve_runtime_library() {
    local soname="$1"
    local candidate=""

    if command -v ldconfig >/dev/null 2>&1; then
        candidate="$(ldconfig -p 2>/dev/null | awk -v name="$soname" '$1 == name { print $NF; exit }')"
    fi
    if [ -z "$candidate" ] || [ ! -e "$candidate" ]; then
        local directory
        for directory in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
            if [ -e "$directory/$soname" ]; then
                candidate="$directory/$soname"
                break
            fi
        done
    fi
    [ -n "$candidate" ] && [ -e "$candidate" ] || die "runtime library is missing: $soname"
    readlink -f -- "$candidate"
}

install_manager_runtime() {
    local manager="$1"
    local runtime_dir="$2"
    local manager_dir expected_runtime_dir

    require_command patchelf
    require_command readelf
    verify_compatibility_manager "$manager" >/dev/null

    manager_dir="$(cd -- "$(dirname -- "$manager")" && pwd)"
    expected_runtime_dir="$manager_dir/manager-runtime"
    [ "$(readlink -m -- "$runtime_dir")" = "$expected_runtime_dir" ] ||
        die "MANAGER_RUNTIME_DIR must be the Manager sibling directory: $expected_runtime_dir"

    rm -rf -- "$runtime_dir"
    mkdir -p -- "$runtime_dir"

    local runtime_sonames=(
        libappindicator3.so.1
        libdbusmenu-glib.so.4
        libdbusmenu-gtk3.so.4
        libindicator3.so.7
    )
    local soname source_file real_name
    for soname in "${runtime_sonames[@]}"; do
        source_file="$(resolve_runtime_library "$soname")"
        real_name="$(basename -- "$source_file")"
        cp -L -- "$source_file" "$runtime_dir/$real_name"
        if [ "$real_name" != "$soname" ]; then
            ln -s -- "$real_name" "$runtime_dir/$soname"
        fi
    done

    while IFS= read -r -d '' library; do
        patchelf --set-rpath '$ORIGIN' "$library"
    done < <(find "$runtime_dir" -type f -print0)
    patchelf --set-rpath '$ORIGIN/manager-runtime' "$manager"

    [ "$(patchelf --print-rpath "$manager")" = '$ORIGIN/manager-runtime' ] ||
        die 'Manager RUNPATH was not installed correctly'
    local unresolved
    unresolved="$(LD_LIBRARY_PATH="$runtime_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$manager" 2>&1 | grep 'not found' || true)"
    [ -z "$unresolved" ] || die "Manager runtime still has unresolved dependencies: $unresolved"
    echo "Installed Linux Manager runtime: $runtime_dir"
}

selftest() {
    require_command "${CC:-cc}"
    require_command nm
    [ -f "$compat_source" ] || die "compatibility source is missing: $compat_source"

    local test_root object symbol
    test_root="$(mktemp -d)"
    trap 'rm -rf -- "$test_root"' RETURN
    "${CC:-cc}" -fPIC -O2 -Wall -Wextra -Werror -c "$compat_source" -o "$test_root/compat.o"
    local required_symbols=(
        webkit_uri_scheme_request_get_http_body
        soup_cookie_get_same_site_policy
        soup_cookie_set_same_site_policy
        soup_message_headers_ref
        soup_message_headers_unref
        g_source_set_dispose_function
        g_uri_error_quark
        webkit_cookie_manager_get_all_cookies
        webkit_cookie_manager_get_all_cookies_finish
    )
    for symbol in "${required_symbols[@]}"; do
        nm -g --defined-only "$test_root/compat.o" | grep -Eq "[[:space:]]$symbol$" ||
            die "compatibility object does not export $symbol"
    done
    echo 'Linux Manager WebKitGTK 4.0 helper selftest passed.'
}

command_name="${1:-}"
case "$command_name" in
    selftest)
        [ "$#" -eq 1 ] || { usage; exit 2; }
        selftest
        ;;
    prepare)
        [ "$#" -eq 2 ] || { usage; exit 2; }
        prepare_compatibility_build "$2"
        ;;
    verify)
        [ "$#" -eq 2 ] || { usage; exit 2; }
        verify_compatibility_manager "$2"
        ;;
    install-runtime)
        [ "$#" -eq 3 ] || { usage; exit 2; }
        install_manager_runtime "$2" "$3"
        ;;
    *)
        usage
        exit 2
        ;;
esac
