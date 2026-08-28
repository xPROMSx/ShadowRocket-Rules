#!/bin/sh
set -u

# PassWall2 APK manager for OpenWrt 25.12+
#
# Design for PassWall2 26.8.27-1 and newer:
#   - APK manages luci-app-passwall2 and its dependency graph.
#   - PassWall2 App Update may replace runtime binaries such as /usr/bin/xray
#     and /usr/bin/geoview directly, so APK package metadata can legitimately
#     differ from the actual runtime binary version.
#   - PassWall2 Rule Manage may replace geoip.dat/geosite.dat directly.
#   - Therefore this script NEVER upgrades/downgrades runtime-managed components
#     during a normal PassWall2 update or rollback.
#
# Commands:
#   status
#   setup
#   check
#   update [--force]
#   install [--force]
#   rollback TAG
#   repair-world
#   backup
#
# Normal workflow:
#   sh /root/passwall2-apk-repo.sh check
#   sh /root/passwall2-apk-repo.sh update
#
# Emergency rollback:
#   sh /root/passwall2-apk-repo.sh rollback 26.8.27-1
#
# Optional proxy override:
#   PROXY="http://192.168.1.11:1088" sh /root/passwall2-apk-repo.sh check

SCRIPT_VERSION="3.1.0"

MAIN_PKG="luci-app-passwall2"
BASELINE_TAG="26.8.27-1"

PROXY="${PROXY:-http://192.168.1.11:1088}"

REPO_FILE="/etc/apk/repositories.d/passwall2.list"

KEY_FILE="/etc/apk/keys/openwrt-passwall-build.pem"
KEY_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub"

# Pinned SHA-256 of moetayuko/openwrt-passwall-build apk.pub
# verified on 2026-08-28.
#
# A future legitimate repository key rotation must be reviewed
# before changing this value.
KEY_SHA256="52802b143489214e13b78f96599a147a638205cc22d9dd6d71229504e38ddc00"

GITHUB_REPO="Openwrt-Passwall/openwrt-passwall2"

BACKUP_DIR="/root/passwall2-backups"

# Packages whose actual files may be replaced directly by PassWall2.
#
# Normal update/rollback MUST NOT modify these via APK.
RUNTIME_MANAGED_PKGS="
xray-core
sing-box
geoview
v2ray-geoip
v2ray-geosite
"

# Packages which may have stale APK identity-hash constraints
# after old manual GitHub installations.
WORLD_REPAIR_PKGS="
luci-app-passwall2
xray-core
sing-box
geoview
tcping
chinadns-ng
v2ray-geoip
v2ray-geosite
"

TMP_ROOT=""
LAST_BACKUP=""
LOG_MARK_SIZE="0"
RELEASE_SAFETY="unknown"


line() {
    printf '%s\n' \
        '============================================================'
}


subline() {
    printf '%s\n' \
        '------------------------------------------------------------'
}


info() {
    printf '[INFO] %s\n' "$*"
}


warn() {
    printf '[WARN] %s\n' "$*" >&2
}


die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}


cleanup() {
    [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"
    return 0
}


trap cleanup EXIT INT TERM


confirm() {
    printf '%s [y/N]: ' "$1"

    read -r answer || return 1

    case "$answer" in
        y|Y|yes|YES|Yes)
            return 0
            ;;

        *)
            return 1
            ;;
    esac
}


confirm_token() {
    message="$1"
    token="$2"

    printf '%s\n' "$message"
    printf 'Type %s to continue: ' "$token"

    read -r answer || return 1

    [ "$answer" = "$token" ]
}


require_root() {
    [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || \
        die "Run this script as root."
}


require_apk() {
    command -v apk >/dev/null 2>&1 || \
        die "apk was not found. This script is only for OpenWrt APK builds."
}


require_local_apk_support() {
    apk add --help 2>&1 |
        grep -q -- '--force-non-repository' || \
        die "This APK build does not expose --force-non-repository; GitHub rollback was aborted."
}


make_tmp() {
    [ -n "${TMP_ROOT:-}" ] && return 0

    TMP_ROOT="$(
        mktemp -d /tmp/passwall2-apk.XXXXXX
    )" || die "Cannot create temporary directory."
}


proxy_env_run() {
    (
        export http_proxy="$PROXY"
        export https_proxy="$PROXY"
        export HTTP_PROXY="$PROXY"
        export HTTPS_PROXY="$PROXY"

        export no_proxy="localhost,127.0.0.1,::1,192.168.1.1,192.168.1.11"
        export NO_PROXY="$no_proxy"

        "$@"
    )
}


fetch_url() {
    out="$1"
    url="$2"

    rm -f "$out"

    info "Download directly: $url"

    if wget -T 30 -O "$out" "$url"; then
        [ -s "$out" ] || \
            die "Downloaded file is empty: $url"

        return 0
    fi

    warn "Direct download failed. Retrying through $PROXY ..."

    rm -f "$out"

    if proxy_env_run wget -T 30 -O "$out" "$url"; then
        [ -s "$out" ] || \
            die "Downloaded file is empty: $url"

        return 0
    fi

    rm -f "$out"

    return 1
}


apk_update() {
    info "Refresh APK indexes: trying direct connection..."

    if apk update; then
        return 0
    fi

    warn "Direct APK update failed. Retrying through $PROXY ..."

    proxy_env_run apk update || \
        die "apk update failed both directly and through the proxy."
}


apk_commit_with_fallback() {
    info "Trying direct package operation..."

    if "$@"; then
        return 0
    fi

    warn "Direct package operation failed. Retrying through $PROXY ..."

    proxy_env_run "$@" || \
        die "Package operation failed both directly and through the proxy."
}


detect_system() {
    [ -r /etc/openwrt_release ] || \
        die "/etc/openwrt_release was not found."

    . /etc/openwrt_release

    RELEASE_FULL="${DISTRIB_RELEASE:-}"
    ARCH="${DISTRIB_ARCH:-}"
    TARGET="${DISTRIB_TARGET:-unknown}"

    [ -n "$RELEASE_FULL" ] || \
        die "Cannot detect OpenWrt release."

    [ -n "$ARCH" ] || \
        die "Cannot detect package architecture."

    case "$RELEASE_FULL" in
        *.*)
            RELEASE_BRANCH="${RELEASE_FULL%.*}"
            ;;

        *)
            die "Unexpected OpenWrt release format: $RELEASE_FULL"
            ;;
    esac

    REPO_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${RELEASE_BRANCH}/${ARCH}"

    REPO_PASSWALL_PACKAGES="${REPO_BASE}/passwall_packages/packages.adb"
    REPO_PASSWALL_LUCI="${REPO_BASE}/passwall_luci/packages.adb"
    REPO_PASSWALL2="${REPO_BASE}/passwall2/packages.adb"
}


repo_file_is_current() {
    [ -s "$REPO_FILE" ] || return 1

    grep -Fxq "$REPO_PASSWALL_PACKAGES" "$REPO_FILE" || \
        return 1

    grep -Fxq "$REPO_PASSWALL_LUCI" "$REPO_FILE" || \
        return 1

    grep -Fxq "$REPO_PASSWALL2" "$REPO_FILE" || \
        return 1

    count="$(
        grep -c \
            '^https://.*openwrt-passwall-build.*packages\.adb$' \
            "$REPO_FILE" \
            2>/dev/null ||
            true
    )"

    [ "$count" = "3" ] || return 1

    return 0
}


key_looks_valid() {
    [ -s "$KEY_FILE" ] || return 1

    grep -q \
        '^-----BEGIN PUBLIC KEY-----' \
        "$KEY_FILE" ||
        return 1

    grep -q \
        '^-----END PUBLIC KEY-----' \
        "$KEY_FILE" ||
        return 1

    if command -v sha256sum >/dev/null 2>&1; then
        current_key_sha="$(
            sha256sum "$KEY_FILE" 2>/dev/null |
                awk '{print $1}'
        )"

        [ "$current_key_sha" = "$KEY_SHA256" ] || \
            return 1
    fi

    return 0
}


remove_duplicate_repo_lines() {
    for file in \
        /etc/apk/repositories \
        /etc/apk/repositories.d/*
    do
        [ -f "$file" ] || continue

        [ "$file" = "$REPO_FILE" ] && continue

        if grep -q \
            'openwrt-passwall-build' \
            "$file" \
            2>/dev/null
        then
            tmp="${file}.pw2tmp.$$"

            grep -v \
                'openwrt-passwall-build' \
                "$file" \
                > "$tmp" ||
                true

            mv "$tmp" "$file" || \
                die "Cannot clean duplicate repository entries in $file"

            info "Removed old PassWall repository entries from $file"
        fi
    done
}


write_repo_file() {
    mkdir -p /etc/apk/repositories.d || \
        die "Cannot create /etc/apk/repositories.d"

    tmp="${REPO_FILE}.tmp.$$"

    cat > "$tmp" <<EOF_REPOS
$REPO_PASSWALL_PACKAGES
$REPO_PASSWALL_LUCI
$REPO_PASSWALL2
EOF_REPOS

    chmod 0644 "$tmp"

    mv "$tmp" "$REPO_FILE" || \
        die "Cannot install $REPO_FILE"
}


install_signing_key() {
    make_tmp

    mkdir -p /etc/apk/keys || \
        die "Cannot create /etc/apk/keys"

    tmp_key="$TMP_ROOT/openwrt-passwall-build.pem"

    fetch_url "$tmp_key" "$KEY_URL" || \
        die "Cannot download repository signing key."

    grep -q \
        '^-----BEGIN PUBLIC KEY-----' \
        "$tmp_key" || \
        die "Downloaded signing key has an unexpected format."

    grep -q \
        '^-----END PUBLIC KEY-----' \
        "$tmp_key" || \
        die "Downloaded signing key is incomplete."

    if command -v sha256sum >/dev/null 2>&1; then
        actual_key_sha="$(
            sha256sum "$tmp_key" 2>/dev/null |
                awk '{print $1}'
        )"

        [ "$actual_key_sha" = "$KEY_SHA256" ] || \
            die "Repository signing key SHA-256 mismatch. Expected $KEY_SHA256, got ${actual_key_sha:-unknown}. Refusing to trust a changed key automatically."
    else
        warn "sha256sum is unavailable; repository key fingerprint could not be pinned."
    fi

    chmod 0644 "$tmp_key"

    mv "$tmp_key" "$KEY_FILE" || \
        die "Cannot install signing key."
}


policy_output() {
    apk policy "$1" 2>/dev/null || true
}


verify_repository() {
    policy="$(
        policy_output "$MAIN_PKG"
    )"

    printf '%s\n' "$policy" |
        grep -q 'openwrt-passwall-build' || \
        die "The signed repository is configured, but $MAIN_PKG is not visible in apk policy."
}


setup_repo() {
    detect_system

    info "Configure signed PassWall2 repository for OpenWrt $RELEASE_BRANCH / $ARCH"

    remove_duplicate_repo_lines
    write_repo_file
    install_signing_key

    apk_update
    verify_repository

    info "Signed PassWall2 repository is ready."
}


ensure_repo() {
    detect_system

    if repo_file_is_current && key_looks_valid; then
        return 0
    fi

    warn "PassWall2 repository configuration is missing, invalid or does not match this OpenWrt build."

    setup_repo
}


installed_version() {
    pkg="$1"

    apk list \
        --installed \
        --manifest \
        2>/dev/null |
    while IFS=' ' read -r name version rest
    do
        [ "$name" = "$pkg" ] || continue

        printf '%s\n' "$version"

        break
    done
}


is_pkg_world_constraint() {
    pkg="$1"
    value="$2"

    case "$value" in
        "$pkg" | \
        "$pkg@"* | \
        "$pkg="* | \
        "$pkg<"* | \
        "$pkg>"* | \
        "$pkg~"* | \
        "!$pkg" | \
        "!$pkg@"* | \
        "!$pkg="* | \
        "!$pkg<"* | \
        "!$pkg>"* | \
        "!$pkg~"*)
            return 0
            ;;

        *)
            return 1
            ;;
    esac
}


world_constraint_for_pkg() {
    pkg="$1"

    [ -r /etc/apk/world ] || \
        return 0

    while IFS= read -r value || [ -n "$value" ]
    do
        if is_pkg_world_constraint "$pkg" "$value"; then
            printf '%s\n' "$value"

            return 0
        fi
    done < /etc/apk/world
}


normalize_world_constraint_for_pkg() {
    pkg="$1"
    ensure_present="${2:-0}"

    current="$(
        world_constraint_for_pkg "$pkg"
    )"

    if [ -z "$current" ]; then
        [ "$ensure_present" = "1" ] || \
            return 0
    elif [ "$current" = "$pkg" ]; then
        return 0
    fi

    make_tmp

    world_tmp="$TMP_ROOT/world.normalized.$$"

    : > "$world_tmp" || \
        die "Cannot create a temporary world file."

    written=0

    if [ -r /etc/apk/world ]; then
        while IFS= read -r value || [ -n "$value" ]
        do
            if is_pkg_world_constraint "$pkg" "$value"; then
                if [ "$written" = "0" ]; then
                    printf '%s\n' "$pkg" \
                        >> "$world_tmp"

                    written=1
                fi
            else
                printf '%s\n' "$value" \
                    >> "$world_tmp"
            fi
        done < /etc/apk/world
    fi

    if [ "$written" = "0" ]; then
        printf '%s\n' "$pkg" \
            >> "$world_tmp"
    fi

    cp "$world_tmp" /etc/apk/world || \
        die "Cannot normalize /etc/apk/world for $pkg."

    chmod 0644 /etc/apk/world \
        2>/dev/null ||
        true

    if [ -n "$current" ]; then
        warn "Normalized APK world constraint: $current -> $pkg"
    else
        info "WORLD constraint added: $pkg"
    fi
}


normalize_main_world_constraint() {
    normalize_world_constraint_for_pkg \
        "$MAIN_PKG" \
        1
}


print_world_constraints() {
    found=0

    for pkg in $WORLD_REPAIR_PKGS
    do
        constraint="$(
            world_constraint_for_pkg "$pkg"
        )"

        [ -n "$constraint" ] || \
            continue

        found=1

        case "$constraint" in
            "$pkg><"*)
                printf \
                    '  %-24s %s  [IDENTITY HASH]\n' \
                    "$pkg" \
                    "$constraint"
                ;;

            *)
                printf \
                    '  %-24s %s\n' \
                    "$pkg" \
                    "$constraint"
                ;;
        esac
    done

    legacy="$(
        world_constraint_for_pkg hysteria
    )"

    if [ -n "$legacy" ]; then
        found=1

        printf \
            '  %-24s %s  [LEGACY]\n' \
            "hysteria" \
            "$legacy"
    fi

    [ "$found" = "1" ] || \
        printf '  none\n'
}


repository_versions() {
    pkg="$1"

    version=""

    policy_output "$pkg" |
    while IFS= read -r value || [ -n "$value" ]
    do
        case "$value" in
            "  "*":")
                candidate="${value#  }"

                case "$candidate" in
                    " "* | "")
                        version=""
                        ;;

                    *)
                        version="${candidate%:}"
                        ;;
                esac
                ;;

            "    "*)
                case "$value" in
                    *openwrt-passwall-build*)
                        [ -n "$version" ] && \
                            printf '%s\n' "$version"
                        ;;
                esac
                ;;
        esac
    done
}


repository_best_version() {
    pkg="$1"

    best=""

    for version in $(repository_versions "$pkg")
    do
        if [ -z "$best" ]; then
            best="$version"

            continue
        fi

        result="$(
            apk version \
                -t \
                "$best" \
                "$version" \
                2>/dev/null ||
                true
        )"

        [ "$result" = "<" ] && \
            best="$version"
    done

    printf '%s\n' "$best"
}


tag_to_apk_version() {
    tag="$1"

    case "$tag" in
        *-*)
            base="${tag%-*}"
            release="${tag##*-}"
            ;;

        *)
            return 1
            ;;
    esac

    [ -n "$base" ] || return 1
    [ -n "$release" ] || return 1

    printf '%s-r%s\n' \
        "$base" \
        "$release"
}


apk_version_to_tag() {
    version="$1"

    case "$version" in
        *-r*)
            base="${version%-r*}"
            release="${version##*-r}"
            ;;

        *)
            return 1
            ;;
    esac

    [ -n "$base" ] || return 1
    [ -n "$release" ] || return 1

    printf '%s-%s\n' \
        "$base" \
        "$release"
}


ensure_supported_rollback_tag() {
    tag="$1"

    target_version="$(
        tag_to_apk_version "$tag"
    )" || \
        die "Unsupported PassWall2 release tag format: $tag"

    baseline_version="$(
        tag_to_apk_version "$BASELINE_TAG"
    )" || \
        die "Internal baseline version error."

    result="$(
        apk version \
            -t \
            "$target_version" \
            "$baseline_version" \
            2>/dev/null ||
            true
    )"

    case "$result" in
        "<")
            die "Rollback below $BASELINE_TAG is intentionally blocked by this script."
            ;;

        "=" | ">")
            return 0
            ;;

        *)
            die "Cannot compare rollback tag $tag with baseline $BASELINE_TAG."
            ;;
    esac
}


inspect_release() {
    tag="$1"

    make_tmp

    metadata="$TMP_ROOT/release-${tag}.json"

    url="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${tag}"

    RELEASE_SAFETY="unknown"

    if ! fetch_url "$metadata" "$url"; then
        return 0
    fi

    if grep -Eiq \
        'configuration structure|configuration format|restore the default config|restore default config|breaking change|breaking configuration|reconfigur|incompatible config|migration logic' \
        "$metadata"
    then
        RELEASE_SAFETY="breaking"

        return 0
    fi

    if grep -Eiq \
        'remove[^"\\]*(core|component|support)|removed[^"\\]*(core|component|support)|deprecat' \
        "$metadata"
    then
        RELEASE_SAFETY="attention"

        return 0
    fi

    RELEASE_SAFETY="ok"
}


print_release_safety() {
    tag="$1"

    inspect_release "$tag"

    printf \
        'Release notes: https://github.com/%s/releases/tag/%s\n' \
        "$GITHUB_REPO" \
        "$tag"

    case "$RELEASE_SAFETY" in
        breaking)
            printf \
                'Release safety:  BREAKING CONFIG WARNING\n'
            ;;

        attention)
            printf \
                'Release safety:  ATTENTION / manual review recommended\n'
            ;;

        ok)
            printf \
                'Release safety:  no known breaking warning detected\n'
            ;;

        *)
            printf \
                'Release safety:  UNKNOWN - release metadata was not verified\n'
            ;;
    esac
}


enforce_release_safety() {
    tag="$1"
    override="${2:-}"

    inspect_release "$tag"

    case "$RELEASE_SAFETY" in
        breaking)
            warn "GitHub release notes contain a configuration-breaking warning."

            [ "$override" = "--force" ] || \
                die "Update blocked. Review the release first. If you intentionally accept the risk, run: $0 update --force"

            confirm_token \
                "This release may require reset/reconfiguration of PassWall2." \
                "BREAKING" || {
                    info "Cancelled. Nothing was installed."

                    return 1
                }
            ;;

        unknown)
            warn "GitHub release metadata could not be verified. Failing closed."

            [ "$override" = "--force" ] || \
                die "Update blocked because release notes could not be verified. Retry later or use '$0 update --force' after manual review."

            confirm_token \
                "Release metadata is unverified." \
                "UNVERIFIED" || {
                    info "Cancelled. Nothing was installed."

                    return 1
                }
            ;;

        attention)
            warn "Release notes contain removal/deprecation language. Review the release before continuing."
            ;;
    esac

    return 0
}


configured_app_path() {
    key="$1"
    fallback="$2"

    value="$(
        uci -q get \
            "passwall2.@global_app[0].${key}_file" \
            2>/dev/null ||
            true
    )"

    [ -n "$value" ] || \
        value="$fallback"

    printf '%s\n' "$value"
}


runtime_xray_version() {
    path="$(
        configured_app_path \
            xray \
            /usr/bin/xray
    )"

    [ -x "$path" ] || \
        return 0

    "$path" version \
        2>/dev/null |
        head -n 1
}


runtime_singbox_version() {
    path="$(
        configured_app_path \
            sing_box \
            /usr/bin/sing-box
    )"

    [ -x "$path" ] || \
        return 0

    "$path" version \
        2>/dev/null |
        head -n 1
}


runtime_geoview_version() {
    path="$(
        configured_app_path \
            geoview \
            /usr/bin/geoview
    )"

    [ -x "$path" ] || \
        return 0

    "$path" -version \
        2>/dev/null |
        head -n 1
}


file_fingerprint() {
    file="$1"

    if [ ! -f "$file" ]; then
        printf 'MISSING\n'

        return 0
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" \
            2>/dev/null |
            awk '{print $1}'
    else
        size="$(
            wc -c \
                < "$file" \
                2>/dev/null ||
                echo unknown
        )"

        printf 'SIZE:%s\n' "$size"
    fi
}


runtime_snapshot() {
    out="$1"

    xray_path="$(
        configured_app_path \
            xray \
            /usr/bin/xray
    )"

    singbox_path="$(
        configured_app_path \
            sing_box \
            /usr/bin/sing-box
    )"

    geoview_path="$(
        configured_app_path \
            geoview \
            /usr/bin/geoview
    )"

    asset_dir="$(
        uci -q get \
            'passwall2.@global_rules[0].v2ray_location_asset' \
            2>/dev/null ||
            true
    )"

    [ -n "$asset_dir" ] || \
        asset_dir="/usr/share/v2ray/"

    case "$asset_dir" in
        */)
            ;;

        *)
            asset_dir="${asset_dir}/"
            ;;
    esac

    {
        printf \
            'xray|%s|%s\n' \
            "$xray_path" \
            "$(file_fingerprint "$xray_path")"

        printf \
            'sing-box|%s|%s\n' \
            "$singbox_path" \
            "$(file_fingerprint "$singbox_path")"

        printf \
            'geoview|%s|%s\n' \
            "$geoview_path" \
            "$(file_fingerprint "$geoview_path")"

        printf \
            'geoip|%s|%s\n' \
            "${asset_dir}geoip.dat" \
            "$(file_fingerprint "${asset_dir}geoip.dat")"

        printf \
            'geosite|%s|%s\n' \
            "${asset_dir}geosite.dat" \
            "$(file_fingerprint "${asset_dir}geosite.dat")"

    } > "$out"
}


assert_runtime_unchanged() {
    before="$1"
    after="$2"

    if cmp -s \
        "$before" \
        "$after" \
        2>/dev/null
    then
        info "Runtime-managed files were not changed by the APK operation."

        return 0
    fi

    warn "Runtime-managed files changed during a PassWall2 package operation."

    warn "This is unexpected because this script is designed to change only luci-app-passwall2."

    warn "Before:"
    sed 's/^/  /' "$before" >&2

    warn "After:"
    sed 's/^/  /' "$after" >&2

    return 1
}


print_runtime_status() {
    xray_path="$(
        configured_app_path \
            xray \
            /usr/bin/xray
    )"

    singbox_path="$(
        configured_app_path \
            sing_box \
            /usr/bin/sing-box
    )"

    geoview_path="$(
        configured_app_path \
            geoview \
            /usr/bin/geoview
    )"

    printf \
        'Runtime components (actual files used by PassWall2):\n'

    printf \
        '  %-10s %-24s %s\n' \
        'Xray' \
        "$xray_path" \
        "$(runtime_xray_version | head -n 1)"

    if [ -x "$singbox_path" ]; then
        printf \
            '  %-10s %-24s %s\n' \
            'Sing-Box' \
            "$singbox_path" \
            "$(runtime_singbox_version | head -n 1)"
    else
        printf \
            '  %-10s %-24s %s\n' \
            'Sing-Box' \
            "$singbox_path" \
            'not installed'
    fi

    printf \
        '  %-10s %-24s %s\n' \
        'Geoview' \
        "$geoview_path" \
        "$(runtime_geoview_version | head -n 1)"

    subline

    printf \
        'APK package metadata (informational; may differ from runtime):\n'

    for pkg in \
        xray-core \
        sing-box \
        geoview \
        v2ray-geoip \
        v2ray-geosite
    do
        version="$(
            installed_version "$pkg"
        )"

        [ -n "$version" ] || \
            version="not installed"

        printf \
            '  %-24s %s\n' \
            "$pkg" \
            "$version"
    done

    subline

    printf 'Rule data ownership:\n'

    printf \
        '  geoip.dat / geosite.dat are managed by PassWall2 Rule Manage.\n'

    printf \
        '  APK versions of v2ray-geoip/v2ray-geosite are NOT treated as runtime update status.\n'
}


simulation_action_count() {
    file="$1"

    count="$(
        grep -Ec \
            '^\([[:space:]]*[0-9]+/[0-9]+\)' \
            "$file" \
            2>/dev/null ||
            true
    )"

    [ -n "$count" ] || count=0

    printf '%s\n' "$count"
}


simulation_touches_pkg() {
    file="$1"
    pkg="$2"

    grep -Eiq \
        "(Installing|Upgrading|Replacing|Downgrading|Removing|Purging)[[:space:]]+${pkg}([[:space:]]|\\()" \
        "$file"
}


simulation_is_safe_for_pw2_change() {
    sim_file="$1"

    count="$(
        simulation_action_count "$sim_file"
    )"

    if [ "$count" -gt 15 ]; then
        warn "Simulation contains $count package actions. This is too large for a targeted PassWall2 package change."

        return 1
    fi

    if grep -Eiq \
        '(Installing|Upgrading|Replacing|Downgrading|Removing|Purging)[[:space:]]+(busybox|apk-tools|libc|firewall4|dnsmasq|dnsmasq-full|dropbear|hostapd|wpad-|kernel|kmod-|base-files)([[:space:]]|\()' \
        "$sim_file"
    then
        warn "Simulation touches critical OpenWrt system packages."

        return 1
    fi

    for pkg in $RUNTIME_MANAGED_PKGS
    do
        if simulation_touches_pkg \
            "$sim_file" \
            "$pkg"
        then
            warn "Simulation wants to modify runtime-managed package '$pkg'."

            warn "This could overwrite a binary/data file managed directly by PassWall2."

            return 1
        fi
    done

    return 0
}


simulation_is_safe_for_install() {
    sim_file="$1"

    count="$(
        simulation_action_count "$sim_file"
    )"

    if [ "$count" -gt 60 ]; then
        warn "Fresh installation simulation contains $count package actions, which is unexpectedly large."

        return 1
    fi

    if grep -Eiq \
        '(Upgrading|Replacing|Downgrading|Removing|Purging)[[:space:]]+(busybox|apk-tools|libc|firewall4|dropbear|hostapd|wpad-|kernel|base-files)([[:space:]]|\()' \
        "$sim_file"
    then
        warn "Installation simulation wants to replace/remove critical OpenWrt system packages."

        return 1
    fi

    return 0
}


backup_state() {
    reason="${1:-manual}"

    detect_system

    mkdir -p "$BACKUP_DIR" || \
        die "Cannot create backup directory $BACKUP_DIR"

    installed="$(
        installed_version "$MAIN_PKG"
    )"

    [ -n "$installed" ] || \
        installed="not-installed"

    stamp="$(
        date +%Y%m%d-%H%M%S
    )"

    LAST_BACKUP="${BACKUP_DIR}/passwall2-${installed}-${stamp}"

    mkdir -p \
        "$LAST_BACKUP/etc/config" \
        "$LAST_BACKUP/etc/apk" \
        "$LAST_BACKUP/usr/share/passwall2" || \
        die "Cannot create backup structure."

    [ -f /etc/config/passwall2 ] && \
        cp -p \
            /etc/config/passwall2 \
            "$LAST_BACKUP/etc/config/passwall2"

    [ -f /etc/config/passwall2_server ] && \
        cp -p \
            /etc/config/passwall2_server \
            "$LAST_BACKUP/etc/config/passwall2_server"

    [ -f /usr/share/passwall2/direct_ip ] && \
        cp -p \
            /usr/share/passwall2/direct_ip \
            "$LAST_BACKUP/usr/share/passwall2/direct_ip"

    [ -f /usr/share/passwall2/domains_excluded ] && \
        cp -p \
            /usr/share/passwall2/domains_excluded \
            "$LAST_BACKUP/usr/share/passwall2/domains_excluded"

    [ -f /usr/share/passwall2/0_default_config ] && \
        cp -p \
            /usr/share/passwall2/0_default_config \
            "$LAST_BACKUP/usr/share/passwall2/0_default_config"

    [ -f /etc/apk/world ] && \
        cp -p \
            /etc/apk/world \
            "$LAST_BACKUP/etc/apk/world"

    [ -f "$REPO_FILE" ] && \
        cp -p \
            "$REPO_FILE" \
            "$LAST_BACKUP/passwall2-repository.list"

    apk list \
        --installed \
        --manifest \
        2>/dev/null \
        > "$LAST_BACKUP/packages.manifest" ||
        true

    runtime_snapshot \
        "$LAST_BACKUP/runtime-files.txt"

    {
        printf \
            'reason=%s\n' \
            "$reason"

        printf \
            'date=%s\n' \
            "$(date)"

        printf \
            'openwrt=%s\n' \
            "$RELEASE_FULL"

        printf \
            'arch=%s\n' \
            "$ARCH"

        printf \
            'target=%s\n' \
            "$TARGET"

        printf \
            'passwall2=%s\n' \
            "$installed"

        printf \
            'xray_runtime=%s\n' \
            "$(runtime_xray_version | head -n 1)"

        printf \
            'geoview_runtime=%s\n' \
            "$(runtime_geoview_version | head -n 1)"

    } > "$LAST_BACKUP/metadata.txt"

    chmod 0700 \
        "$LAST_BACKUP" \
        2>/dev/null ||
        true

    chmod -R go-rwx \
        "$LAST_BACKUP" \
        2>/dev/null ||
        true

    info "Backup created: $LAST_BACKUP"
}


capture_log_mark() {
    if [ -f /tmp/log/passwall2.log ]; then
        LOG_MARK_SIZE="$(
            wc -c \
                < /tmp/log/passwall2.log \
                2>/dev/null ||
                echo 0
        )"
    else
        LOG_MARK_SIZE="0"
    fi
}


new_passwall2_log() {
    log="/tmp/log/passwall2.log"

    [ -f "$log" ] || \
        return 0

    current="$(
        wc -c \
            < "$log" \
            2>/dev/null ||
            echo 0
    )"

    case "$LOG_MARK_SIZE:$current" in
        *[!0-9:]*)
            cat "$log"

            return 0
            ;;
    esac

    if [ "$current" -ge "$LOG_MARK_SIZE" ] &&
       [ "$LOG_MARK_SIZE" -gt 0 ]
    then
        start=$((LOG_MARK_SIZE + 1))

        tail -c \
            "+$start" \
            "$log" \
            2>/dev/null ||
            cat "$log"
    else
        cat "$log"
    fi
}


restart_passwall2() {
    /etc/init.d/rpcd restart \
        2>/dev/null ||
        warn "rpcd restart failed."

    if [ ! -x /etc/init.d/passwall2 ]; then
        warn "/etc/init.d/passwall2 does not exist."

        return 1
    fi

    /etc/init.d/passwall2 enable \
        2>/dev/null ||
        true

    if /etc/init.d/passwall2 restart; then
        return 0
    fi

    warn "PassWall2 restart failed. Trying start..."

    /etc/init.d/passwall2 start
}


postcheck_passwall2() {
    sleep 3

    enabled="$(
        uci -q get \
            'passwall2.@global[0].enabled' \
            2>/dev/null ||
            echo 0
    )"

    if [ "$enabled" != "1" ]; then
        info "PassWall2 main switch is disabled; runtime proxy check skipped."

        return 0
    fi

    node="$(
        uci -q get \
            'passwall2.@global[0].node' \
            2>/dev/null ||
            true
    )"

    if [ -z "$node" ]; then
        warn "PassWall2 is enabled but no global node is configured."

        return 1
    fi

    node_type="$(
        uci -q get \
            "passwall2.${node}" \
            2>/dev/null ||
            true
    )"

    if [ "$node_type" != "nodes" ]; then
        warn "Global node '$node' does not resolve to a 'nodes' UCI section."

        return 1
    fi

    fresh_log="$(
        new_passwall2_log
    )"

    if printf '%s\n' "$fresh_log" |
        grep -q \
            'Running in no proxy mode'
    then
        warn "PassWall2 entered NO PROXY MODE after the package operation."

        [ -n "$LAST_BACKUP" ] && \
            warn "Backup: $LAST_BACKUP"

        return 1
    fi

    if printf '%s\n' "$fresh_log" |
        grep -Eiq \
            'failed to (start|load)|start failed|invalid (config|configuration)|syntax error|executable.*not found|binary.*not found|exit code[^0-9]*[1-9]'
    then
        warn "New PassWall2 log contains a likely fatal startup/configuration error."

        printf '%s\n' "$fresh_log" |
            tail -n 80 \
            >&2

        return 1
    fi

    info "PassWall2 post-check passed: configured node is valid and no new fatal/no-proxy condition was detected."

    return 0
}


find_and_download_luci_asset() {
    tag="$1"
    out="$2"

    apk_version="$(
        tag_to_apk_version "$tag"
    )" || \
        return 1

    base="https://github.com/${GITHUB_REPO}/releases/download/${tag}"

    FOUND_URL=""

    for url in \
        "${base}/luci-app-passwall2-${apk_version}.apk" \
        "${base}/luci-app-passwall2_${tag}_all.apk" \
        "${base}/luci-app-passwall2_${apk_version}_all.apk"
    do
        if fetch_url "$out" "$url"; then
            FOUND_URL="$url"

            return 0
        fi
    done

    return 1
}


cmd_status() {
    detect_system

    line

    printf \
        'PassWall2 APK manager %s\n' \
        "$SCRIPT_VERSION"

    line

    printf \
        'OpenWrt:           %s\n' \
        "$RELEASE_FULL"

    printf \
        'Feed branch:       %s\n' \
        "$RELEASE_BRANCH"

    printf \
        'Architecture:      %s\n' \
        "$ARCH"

    printf \
        'Target:            %s\n' \
        "$TARGET"

    printf \
        'Rollback baseline: %s\n' \
        "$BASELINE_TAG"

    printf \
        'Fallback proxy:    %s\n' \
        "$PROXY"

    subline

    printf 'PassWall2 package:\n'

    installed="$(
        installed_version "$MAIN_PKG"
    )"

    printf \
        '  Installed:          %s\n' \
        "${installed:-not installed}"

    constraint="$(
        world_constraint_for_pkg "$MAIN_PKG"
    )"

    [ -n "$constraint" ] || \
        constraint="not present"

    printf \
        '  WORLD constraint:   %s\n' \
        "$constraint"

    subline

    print_runtime_status

    subline

    printf \
        'Managed APK world constraints:\n'

    print_world_constraints

    legacy_hysteria="$(
        installed_version hysteria
    )"

    if [ -n "$legacy_hysteria" ]; then
        subline

        warn "Standalone hysteria $legacy_hysteria is installed, but PassWall2 >= $BASELINE_TAG no longer uses that standalone core."
    fi

    subline

    printf \
        'Signing key: %s\n' \
        "$KEY_FILE"

    if key_looks_valid; then
        printf \
            'Key status:  OK\n'
    else
        printf \
            'Key status:  missing/invalid/fingerprint mismatch\n'
    fi

    printf \
        'Repository:  %s\n' \
        "$REPO_FILE"

    if [ -f "$REPO_FILE" ]; then
        sed \
            's/^/  /' \
            "$REPO_FILE"
    else
        printf \
            '  missing\n'
    fi

    line
}


cmd_check() {
    ensure_repo

    apk_update
    verify_repository

    installed="$(
        installed_version "$MAIN_PKG"
    )"

    available="$(
        repository_best_version "$MAIN_PKG"
    )"

    line

    printf \
        'PassWall2 update check\n'

    line

    printf \
        'Installed package:  %s\n' \
        "${installed:-not installed}"

    printf \
        'Repository package: %s\n' \
        "${available:-not found}"

    [ -n "$available" ] || \
        die "Cannot determine repository version of $MAIN_PKG."

    if [ -z "$installed" ]; then
        printf \
            'State:               not installed\n'
    else
        result="$(
            apk version \
                -t \
                "$installed" \
                "$available" \
                2>/dev/null ||
                true
        )"

        case "$result" in
            "=")
                printf \
                    'State:               up to date\n'
                ;;

            "<")
                printf \
                    'State:               UPDATE AVAILABLE\n'

                tag="$(
                    apk_version_to_tag \
                        "$available" \
                        2>/dev/null ||
                        true
                )"

                if [ -n "$tag" ]; then
                    subline

                    print_release_safety "$tag"
                else
                    warn "Could not map repository version $available to a GitHub release tag."
                fi
                ;;

            ">")
                printf \
                    'State:               installed version is newer than repository\n'
                ;;

            *)
                warn "Cannot compare installed and repository versions."
                ;;
        esac
    fi

    subline

    print_runtime_status

    subline

    printf \
        'Important: runtime Xray/Geoview and rule data are NOT updated by this script.\n'

    printf \
        'Use PassWall2 App Update / Rule Manage for those components.\n'

    line
}


cmd_update() {
    override="${1:-}"

    case "$override" in
        "" | --force)
            ;;

        *)
            die "Usage: $0 update [--force]"
            ;;
    esac

    ensure_repo

    apk_update
    verify_repository

    installed="$(
        installed_version "$MAIN_PKG"
    )"

    [ -n "$installed" ] || \
        die "$MAIN_PKG is not installed. Use: $0 install"

    normalize_main_world_constraint

    available="$(
        repository_best_version "$MAIN_PKG"
    )"

    [ -n "$available" ] || \
        die "Cannot determine repository version of $MAIN_PKG."

    info "Installed PassWall2 package:  $installed"
    info "Repository PassWall2 package: $available"

    result="$(
        apk version \
            -t \
            "$installed" \
            "$available" \
            2>/dev/null ||
            true
    )"

    case "$result" in
        "=")
            info "PassWall2 is already up to date."

            return 0
            ;;

        ">")
            warn "Installed PassWall2 is newer than the repository. No downgrade will be performed."

            return 0
            ;;

        "<")
            ;;

        *)
            die "Cannot compare installed and repository versions."
            ;;
    esac

    tag="$(
        apk_version_to_tag \
            "$available" \
            2>/dev/null ||
            true
    )"

    if [ -n "$tag" ]; then
        enforce_release_safety \
            "$tag" \
            "$override" || \
            return 0
    else
        [ "$override" = "--force" ] || \
            die "Cannot determine GitHub release tag; update blocked."

        confirm_token \
            "GitHub release tag could not be determined." \
            "UNVERIFIED" || \
            return 0
    fi

    make_tmp

    sim="$TMP_ROOT/update-simulation.txt"

    info "Simulate targeted update of $MAIN_PKG only..."

    if ! apk upgrade \
        --simulate \
        "$MAIN_PKG" \
        > "$sim" \
        2>&1
    then
        cat "$sim"

        die "Targeted update simulation failed."
    fi

    cat "$sim"

    simulation_is_safe_for_pw2_change "$sim" || \
        die "Update aborted by safety checks. Nothing was installed."

    confirm \
        "Apply this targeted PassWall2 package update?" || {
            info "Cancelled. Nothing was installed."

            return 0
        }

    backup_state \
        "before-update-${installed}-to-${available}"

    before_runtime="$TMP_ROOT/runtime-before.txt"
    after_runtime="$TMP_ROOT/runtime-after.txt"

    runtime_snapshot \
        "$before_runtime"

    capture_log_mark

    apk_commit_with_fallback \
        apk upgrade \
        "$MAIN_PKG"

    normalize_main_world_constraint

    restart_passwall2 || \
        die "PassWall2 was updated but could not be restarted. Backup: $LAST_BACKUP"

    runtime_snapshot \
        "$after_runtime"

    assert_runtime_unchanged \
        "$before_runtime" \
        "$after_runtime" || \
        die "Unexpected runtime file change detected. Backup: $LAST_BACKUP"

    postcheck_passwall2 || \
        die "PassWall2 post-check failed. Backup: $LAST_BACKUP"

    after="$(
        installed_version "$MAIN_PKG"
    )"

    info "PassWall2 after update: ${after:-unknown}"

    [ "$after" = "$available" ] || \
        warn "Installed version does not exactly match the repository candidate."
}


cmd_install() {
    override="${1:-}"

    case "$override" in
        "" | --force)
            ;;

        *)
            die "Usage: $0 install [--force]"
            ;;
    esac

    ensure_repo

    apk_update
    verify_repository

    installed="$(
        installed_version "$MAIN_PKG"
    )"

    if [ -n "$installed" ]; then
        die "$MAIN_PKG is already installed ($installed). Use '$0 check' / '$0 update' instead."
    fi

    available="$(
        repository_best_version "$MAIN_PKG"
    )"

    [ -n "$available" ] || \
        die "Cannot determine repository version of $MAIN_PKG."

    tag="$(
        apk_version_to_tag \
            "$available" \
            2>/dev/null ||
            true
    )"

    if [ -n "$tag" ]; then
        enforce_release_safety \
            "$tag" \
            "$override" || \
            return 0
    else
        [ "$override" = "--force" ] || \
            die "Cannot determine GitHub release tag; install blocked."

        confirm_token \
            "GitHub release tag could not be determined." \
            "UNVERIFIED" || \
            return 0
    fi

    line

    printf \
        'Fresh PassWall2 installation\n'

    line

    printf \
        'Explicit package: %s\n' \
        "$MAIN_PKG"

    printf \
        'Dependencies will be resolved by APK from the configured repositories.\n'

    printf \
        'This script does NOT explicitly install Xray, Sing-Box, Geoview or geodata.\n'

    line

    make_tmp

    sim="$TMP_ROOT/install-simulation.txt"

    if ! apk add \
        --simulate \
        "$MAIN_PKG" \
        > "$sim" \
        2>&1
    then
        cat "$sim"

        die "PassWall2 installation simulation failed."
    fi

    cat "$sim"

    simulation_is_safe_for_install "$sim" || \
        die "Installation aborted by safety checks."

    confirm \
        "Install PassWall2 and its repository-defined dependencies?" || {
            info "Cancelled. Nothing was changed."

            return 0
        }

    backup_state \
        "before-install"

    capture_log_mark

    apk_commit_with_fallback \
        apk add \
        "$MAIN_PKG"

    normalize_main_world_constraint

    restart_passwall2 || \
        die "Installation completed, but PassWall2 could not be started. Backup: $LAST_BACKUP"

    installed="$(
        installed_version "$MAIN_PKG"
    )"

    [ -n "$installed" ] || \
        die "Installation finished, but $MAIN_PKG is not present in the package database."

    postcheck_passwall2 || \
        die "PassWall2 post-check failed. Backup: $LAST_BACKUP"

    info "PassWall2 installed: $installed"
}


cmd_rollback() {
    tag="${1:-}"

    [ -n "$tag" ] || \
        die "Usage: $0 rollback TAG"

    case "$tag" in
        *[!A-Za-z0-9._-]*)
            die "Unsafe TAG value: $tag"
            ;;
    esac

    detect_system
    ensure_supported_rollback_tag "$tag"
    require_local_apk_support
    make_tmp

    current="$(
        installed_version "$MAIN_PKG"
    )"

    [ -n "$current" ] || \
        die "$MAIN_PKG is not installed. Rollback is not applicable."

    target_version="$(
        tag_to_apk_version "$tag"
    )" || \
        die "Invalid release tag: $tag"

    result="$(
        apk version \
            -t \
            "$current" \
            "$target_version" \
            2>/dev/null ||
            true
    )"

    case "$result" in
        "=")
            info "PassWall2 is already at $tag ($current)."

            return 0
            ;;

        "<")
            warn "Target $tag is newer than installed $current; this command will perform a manual version change, not a rollback."
            ;;

        ">")
            ;;

        *)
            die "Cannot compare installed version $current with target $target_version."
            ;;
    esac

    line

    printf \
        'Emergency PassWall2 LuCI-only rollback\n'

    line

    printf \
        'Installed:        %s\n' \
        "$current"

    printf \
        'Target release:   %s\n' \
        "$tag"

    printf \
        'Target APK ver.:  %s\n' \
        "$target_version"

    printf \
        'Minimum allowed:  %s\n' \
        "$BASELINE_TAG"

    printf \
        'Runtime cores:    WILL NOT BE TOUCHED\n'

    subline

    print_release_safety "$tag"

    luci_apk="$TMP_ROOT/luci-app-passwall2.apk"

    find_and_download_luci_asset \
        "$tag" \
        "$luci_apk" || \
        die "Cannot find a supported official LuCI APK asset for release $tag."

    info "LuCI asset: $FOUND_URL"

    sim="$TMP_ROOT/rollback-simulation.txt"

    if ! apk add \
        --allow-untrusted \
        --force-non-repository \
        --simulate \
        "$luci_apk" \
        > "$sim" \
        2>&1
    then
        cat "$sim"

        die "Rollback simulation failed. Nothing was installed."
    fi

    cat "$sim"

    simulation_is_safe_for_pw2_change "$sim" || \
        die "Rollback aborted by safety checks. Nothing was installed."

    confirm_token \
        "Rollback changes only luci-app-passwall2. Configuration compatibility is NOT guaranteed across breaking releases." \
        "ROLLBACK" || {
            info "Cancelled. Nothing was changed."

            return 0
        }

    backup_state \
        "before-rollback-${current}-to-${tag}"

    before_runtime="$TMP_ROOT/runtime-before.txt"
    after_runtime="$TMP_ROOT/runtime-after.txt"

    runtime_snapshot \
        "$before_runtime"

    capture_log_mark

    apk_commit_with_fallback \
        apk add \
        --allow-untrusted \
        --force-non-repository \
        "$luci_apk"

    normalize_main_world_constraint

    after="$(
        installed_version "$MAIN_PKG"
    )"

    if [ "$after" != "$target_version" ]; then
        die "Rollback transaction finished, but installed version is '$after' instead of '$target_version'. Backup: $LAST_BACKUP"
    fi

    restart_passwall2 || \
        die "Rollback package was installed, but PassWall2 could not be restarted. Backup: $LAST_BACKUP"

    runtime_snapshot \
        "$after_runtime"

    assert_runtime_unchanged \
        "$before_runtime" \
        "$after_runtime" || \
        die "Unexpected runtime file change detected during rollback. Backup: $LAST_BACKUP"

    postcheck_passwall2 || \
        die "Rollback completed, but PassWall2 post-check failed. Backup: $LAST_BACKUP"

    info "PassWall2 rollback complete: $after"

    info "Backup from before rollback: $LAST_BACKUP"

    warn "If the target release uses a different configuration structure, restore/rebuild the configuration separately."
}


cmd_repair_world() {
    detect_system

    line

    printf \
        'APK world identity-hash repair\n'

    line

    printf \
        'Before:\n'

    print_world_constraints

    subline

    need_repair=0

    for pkg in $WORLD_REPAIR_PKGS
    do
        constraint="$(
            world_constraint_for_pkg "$pkg"
        )"

        case "$constraint" in
            "$pkg><"*)
                need_repair=1
                ;;
        esac
    done

    if [ "$need_repair" = "0" ]; then
        info "No managed identity-hash constraints need repair."

        line

        return 0
    fi

    confirm \
        "Replace managed identity-hash constraints with normal package constraints?" || {
            info "Cancelled. Nothing was changed."

            return 0
        }

    backup_state \
        "before-world-repair"

    for pkg in $WORLD_REPAIR_PKGS
    do
        installed="$(
            installed_version "$pkg"
        )"

        [ -n "$installed" ] || \
            continue

        constraint="$(
            world_constraint_for_pkg "$pkg"
        )"

        case "$constraint" in
            "$pkg><"*)
                normalize_world_constraint_for_pkg \
                    "$pkg" \
                    1
                ;;
        esac
    done

    subline

    printf \
        'After:\n'

    print_world_constraints

    line
}


cmd_backup() {
    backup_state \
        "manual"
}


usage() {
    cat <<EOF_USAGE
PassWall2 APK manager $SCRIPT_VERSION

Usage:
  $0 status
  $0 setup
  $0 check
  $0 update [--force]
  $0 install [--force]
  $0 rollback TAG
  $0 repair-world
  $0 backup

Normal workflow:
  $0 check
  $0 update

After Attended Sysupgrade with configuration preservation,
if PassWall2 package is absent:
  $0 install

Emergency rollback:
  $0 rollback 26.8.27-1

Important:
  - Rollback below $BASELINE_TAG is blocked.
  - Normal update/rollback changes only luci-app-passwall2.
  - Xray/Sing-Box/Geoview are runtime-managed by PassWall2 App Update.
  - GeoIP/GeoSite data are runtime-managed by PassWall2 Rule Manage.
  - APK package metadata for those components may legitimately differ
    from runtime files.
EOF_USAGE
}


main() {
    require_root
    require_apk

    command="${1:-help}"

    case "$command" in
        status)
            cmd_status
            ;;

        setup)
            setup_repo
            ;;

        check)
            cmd_check
            ;;

        update)
            shift
            cmd_update "${1:-}"
            ;;

        install)
            shift
            cmd_install "${1:-}"
            ;;

        rollback | github)
            shift
            cmd_rollback "${1:-}"
            ;;

        repair-world)
            cmd_repair_world
            ;;

        backup)
            cmd_backup
            ;;

        help | -h | --help)
            usage
            ;;

        *)
            usage >&2
            exit 1
            ;;
    esac
}


main "$@"
