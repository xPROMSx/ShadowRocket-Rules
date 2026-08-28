#!/bin/sh
set -u

# PassWall2 APK manager for OpenWrt 25.12+
#
# Baseline: PassWall2 26.8.27-1 and newer.
#
# Modes:
#   status
#       Local diagnostics; no network changes.
#
#   setup
#       Add/repair signed PassWall2 APK repository.
#
#   check
#       Refresh indexes, show updates and inspect PassWall2 release notes.
#
#   update [--breaking]
#       Update ONLY luci-app-passwall2 from the signed repository.
#       Explicit --breaking is required when release notes contain a known
#       configuration-breaking warning.
#
#   install [--breaking]
#       Install PassWall2 + Xray.
#       PassWall2 dependencies such as geoview/tcping/geodata are resolved by APK.
#
#   rollback TAG [luci|stack]
#       Emergency rollback from an official GitHub release.
#       Default mode is "luci" and changes only luci-app-passwall2.
#       "stack" also rolls back currently installed PassWall components
#       for which matching APKs exist in the target release bundle.
#
#   github TAG [luci|stack]
#       Alias for rollback.
#
#   repair-world
#       Remove APK identity-hash constraints created by previous manual
#       local APK installations for managed PassWall packages.
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

SCRIPT_VERSION="3.0.0"

MAIN_PKG="luci-app-passwall2"
BASELINE_TAG="26.8.27-1"

# Standalone hysteria was removed from PassWall2 starting with our baseline.
MINIMAL_PKGS="luci-app-passwall2 xray-core"

DISPLAY_PKGS="luci-app-passwall2 xray-core sing-box chinadns-ng geoview tcping v2ray-geoip v2ray-geosite"

# Only packages that may be rolled back together with PassWall2 in "stack" mode.
# A package is included only if it is already installed on the router.
ROLLBACK_STACK_PKGS="xray-core sing-box chinadns-ng geoview tcping v2ray-geoip v2ray-geosite"

MANAGED_WORLD_PKGS="luci-app-passwall2 xray-core sing-box chinadns-ng geoview tcping v2ray-geoip v2ray-geosite"

PROXY="${PROXY:-http://192.168.1.11:1088}"

REPO_FILE="/etc/apk/repositories.d/passwall2.list"
KEY_FILE="/etc/apk/keys/openwrt-passwall-build.pem"
KEY_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub"

GITHUB_REPO="Openwrt-Passwall/openwrt-passwall2"

BACKUP_DIR="/root/passwall2-backups"

TMP_ROOT=""
LAST_BACKUP=""
RELEASE_SAFETY="unknown"

line() {
    printf '%s\n' '============================================================'
}

subline() {
    printf '%s\n' '------------------------------------------------------------'
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
    apk add --help 2>&1 | grep -q -- '--force-non-repository' || \
        die "This APK build does not expose --force-non-repository. Manual GitHub rollback was aborted."
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

make_tmp() {
    [ -n "${TMP_ROOT:-}" ] && return 0

    TMP_ROOT="$(mktemp -d /tmp/passwall2-apk.XXXXXX)" || \
        die "Cannot create temporary directory."
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

repo_file_is_current() {
    [ -s "$REPO_FILE" ] || return 1

    grep -Fxq "$REPO_PASSWALL_PACKAGES" "$REPO_FILE" || return 1
    grep -Fxq "$REPO_PASSWALL_LUCI" "$REPO_FILE" || return 1
    grep -Fxq "$REPO_PASSWALL2" "$REPO_FILE" || return 1

    count="$(
        grep -c '^https://.*openwrt-passwall-build.*packages\.adb$' \
            "$REPO_FILE" 2>/dev/null || true
    )"

    [ "$count" = "3" ] || return 1

    return 0
}

key_looks_valid() {
    [ -s "$KEY_FILE" ] || return 1

    grep -q '^-----BEGIN PUBLIC KEY-----' "$KEY_FILE" || return 1
    grep -q '^-----END PUBLIC KEY-----' "$KEY_FILE" || return 1

    return 0
}

remove_duplicate_repo_lines() {
    for file in /etc/apk/repositories /etc/apk/repositories.d/*; do
        [ -f "$file" ] || continue
        [ "$file" = "$REPO_FILE" ] && continue

        if grep -q 'openwrt-passwall-build' "$file" 2>/dev/null; then
            tmp="${file}.pw2tmp.$$"

            grep -v 'openwrt-passwall-build' "$file" > "$tmp" || true

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

    grep -q '^-----BEGIN PUBLIC KEY-----' "$tmp_key" || \
        die "Downloaded signing key has an unexpected format."

    grep -q '^-----END PUBLIC KEY-----' "$tmp_key" || \
        die "Downloaded signing key is incomplete."

    chmod 0644 "$tmp_key"

    mv "$tmp_key" "$KEY_FILE" || \
        die "Cannot install signing key."
}

policy_output() {
    apk policy "$1" 2>/dev/null || true
}

verify_repository() {
    policy="$(policy_output "$MAIN_PKG")"

    printf '%s\n' "$policy" | grep -q 'openwrt-passwall-build' || \
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

    warn "PassWall2 repository configuration is missing or does not match this OpenWrt build."

    setup_repo
}

installed_version() {
    pkg="$1"

    apk list --installed --manifest 2>/dev/null |
    while IFS=' ' read -r name version rest; do
        [ "$name" = "$pkg" ] || continue

        printf '%s\n' "$version"
        break
    done
}

is_pkg_world_constraint() {
    pkg="$1"
    value="$2"

    case "$value" in
        "$pkg"|\
        "$pkg@"*|\
        "$pkg="*|\
        "$pkg<"*|\
        "$pkg>"*|\
        "$pkg~"*|\
        "!$pkg"|\
        "!$pkg@"*|\
        "!$pkg="*|\
        "!$pkg<"*|\
        "!$pkg>"*|\
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

    [ -r /etc/apk/world ] || return 0

    while IFS= read -r value || [ -n "$value" ]; do
        if is_pkg_world_constraint "$pkg" "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
    done < /etc/apk/world
}

normalize_world_constraint_for_pkg() {
    pkg="$1"
    ensure_present="${2:-0}"

    current="$(world_constraint_for_pkg "$pkg")"

    if [ -z "$current" ]; then
        [ "$ensure_present" = "1" ] || return 0
    elif [ "$current" = "$pkg" ]; then
        return 0
    fi

    make_tmp

    world_tmp="$TMP_ROOT/world.normalized"
    : > "$world_tmp" || \
        die "Cannot create a temporary world file."

    written=0

    if [ -r /etc/apk/world ]; then
        while IFS= read -r value || [ -n "$value" ]; do
            if is_pkg_world_constraint "$pkg" "$value"; then
                if [ "$written" = "0" ]; then
                    printf '%s\n' "$pkg" >> "$world_tmp"
                    written=1
                fi
            else
                printf '%s\n' "$value" >> "$world_tmp"
            fi
        done < /etc/apk/world
    fi

    if [ "$written" = "0" ]; then
        printf '%s\n' "$pkg" >> "$world_tmp"
    fi

    cp "$world_tmp" /etc/apk/world || \
        die "Cannot normalize /etc/apk/world for $pkg."

    chmod 0644 /etc/apk/world 2>/dev/null || true

    if [ -n "$current" ]; then
        warn "Normalized APK world constraint: $current -> $pkg"
    else
        info "WORLD constraint added: $pkg"
    fi
}

normalize_main_world_constraint() {
    normalize_world_constraint_for_pkg "$MAIN_PKG" 1
}

repair_identity_hash_constraints() {
    changed=0

    for pkg in $MANAGED_WORLD_PKGS; do
        installed="$(installed_version "$pkg")"
        [ -n "$installed" ] || continue

        constraint="$(world_constraint_for_pkg "$pkg")"

        case "$constraint" in
            "$pkg><"*)
                normalize_world_constraint_for_pkg "$pkg" 1
                changed=1
                ;;
        esac
    done

    if [ "$changed" = "0" ]; then
        info "No managed APK identity-hash constraints were found."
    fi
}

repository_versions() {
    pkg="$1"
    version=""

    policy_output "$pkg" |
    while IFS= read -r value || [ -n "$value" ]; do
        case "$value" in
            "  "*":")
                candidate="${value#  }"

                case "$candidate" in
                    " "*|"")
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
                        [ -n "$version" ] && printf '%s\n' "$version"
                        ;;
                esac
                ;;
        esac
    done
}

repository_best_version() {
    pkg="$1"
    best=""

    for version in $(repository_versions "$pkg"); do
        if [ -z "$best" ]; then
            best="$version"
            continue
        fi

        result="$(
            apk version -t "$best" "$version" 2>/dev/null || true
        )"

        [ "$result" = "<" ] && best="$version"
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

    printf '%s-r%s\n' "$base" "$release"
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

    printf '%s-%s\n' "$base" "$release"
}

ensure_supported_rollback_tag() {
    tag="$1"

    target_version="$(tag_to_apk_version "$tag")" || \
        die "Unsupported PassWall2 release tag format: $tag"

    baseline_version="$(tag_to_apk_version "$BASELINE_TAG")" || \
        die "Internal baseline version error."

    result="$(
        apk version -t "$target_version" "$baseline_version" 2>/dev/null || true
    )"

    case "$result" in
        "<")
            die "Rollback below $BASELINE_TAG is intentionally blocked by this script."
            ;;
        "="|">")
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
        warn "Could not download GitHub release metadata for $tag."
        return 0
    fi

    if grep -Eiq \
        'configuration structure|configuration format|restore the default config|restore default config|breaking change|breaking configuration|reconfigur|incompatible config' \
        "$metadata"
    then
        RELEASE_SAFETY="breaking"
        return 0
    fi

    if grep -Eiq \
        'remove[^"]*(core|component|support)|removed[^"]*(core|component|support)|deprecat' \
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

    printf 'Release notes: https://github.com/%s/releases/tag/%s\n' \
        "$GITHUB_REPO" "$tag"

    case "$RELEASE_SAFETY" in
        breaking)
            printf 'Release safety:  BREAKING CONFIG WARNING\n'
            ;;
        attention)
            printf 'Release safety:  ATTENTION / manual review recommended\n'
            ;;
        ok)
            printf 'Release safety:  no known breaking warning detected\n'
            ;;
        *)
            printf 'Release safety:  UNKNOWN - release metadata was not verified\n'
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

            if [ "$override" != "--breaking" ]; then
                die "Update blocked. Review the release and run '$0 update --breaking' only when you are prepared for reconfiguration."
            fi

            confirm_token \
                "This release may require reset/reconfiguration of PassWall2." \
                "BREAKING" || {
                    info "Cancelled. Nothing was installed."
                    return 1
                }
            ;;

        attention)
            warn "Release notes contain removal/deprecation language. Review the release before continuing."
            ;;

        unknown)
            warn "GitHub release metadata could not be verified. Continue only after manual release review."
            ;;
    esac

    return 0
}

print_installed_versions() {
    for pkg in $DISPLAY_PKGS; do
        version="$(installed_version "$pkg")"

        [ -n "$version" ] || version="not installed"

        printf '  %-24s %s\n' "$pkg" "$version"
    done

    legacy_hysteria="$(installed_version hysteria)"

    if [ -n "$legacy_hysteria" ]; then
        printf '  %-24s %s  [legacy / not used by PW2 >= 26.8.27]\n' \
            "hysteria" "$legacy_hysteria"
    fi
}

print_world_constraints() {
    for pkg in $MANAGED_WORLD_PKGS; do
        constraint="$(world_constraint_for_pkg "$pkg")"
        [ -n "$constraint" ] || continue

        case "$constraint" in
            "$pkg><"*)
                printf '  %-24s %s  [IDENTITY HASH]\n' "$pkg" "$constraint"
                ;;
            *)
                printf '  %-24s %s\n' "$pkg" "$constraint"
                ;;
        esac
    done

    legacy_constraint="$(world_constraint_for_pkg hysteria)"

    if [ -n "$legacy_constraint" ]; then
        printf '  %-24s %s  [legacy]\n' "hysteria" "$legacy_constraint"
    fi
}

print_stack_updates() {
    found=0

    for pkg in $DISPLAY_PKGS; do
        installed="$(installed_version "$pkg")"
        [ -n "$installed" ] || continue

        available="$(repository_best_version "$pkg")"
        [ -n "$available" ] || continue

        result="$(
            apk version -t "$installed" "$available" 2>/dev/null || true
        )"

        if [ "$result" = "<" ]; then
            printf '  %-24s %s -> %s\n' \
                "$pkg" "$installed" "$available"

            found=1
        fi
    done

    [ "$found" = "1" ] || printf '  none\n'
}

simulation_is_safe() {
    sim_file="$1"
    max_actions="${2:-15}"

    count="$(
        grep -Ec '^\([[:space:]]*[0-9]+/[0-9]+\)' \
            "$sim_file" 2>/dev/null || true
    )"

    [ -n "$count" ] || count=0

    if [ "$count" -gt "$max_actions" ]; then
        warn "Simulation contains $count package actions. Maximum allowed here is $max_actions."
        return 1
    fi

    if grep -Eiq \
        '(Installing|Upgrading|Replacing|Downgrading|Removing|Purging) (busybox|apk-tools|libc|firewall4|dnsmasq|dropbear|hostapd|wpad-|kernel|kmod-|base-files)([[:space:]]|\()' \
        "$sim_file"
    then
        warn "Simulation touches critical OpenWrt system packages."
        return 1
    fi

    return 0
}

backup_state() {
    reason="${1:-manual}"

    detect_system

    mkdir -p "$BACKUP_DIR" || \
        die "Cannot create backup directory $BACKUP_DIR"

    installed="$(installed_version "$MAIN_PKG")"
    [ -n "$installed" ] || installed="not-installed"

    stamp="$(date +%Y%m%d-%H%M%S)"

    LAST_BACKUP="${BACKUP_DIR}/passwall2-${installed}-${stamp}"

    mkdir -p \
        "$LAST_BACKUP/etc/config" \
        "$LAST_BACKUP/etc/apk" \
        "$LAST_BACKUP/usr/share/passwall2" || \
        die "Cannot create backup structure."

    [ -f /etc/config/passwall2 ] && \
        cp -p /etc/config/passwall2 \
            "$LAST_BACKUP/etc/config/passwall2"

    [ -f /etc/config/passwall2_server ] && \
        cp -p /etc/config/passwall2_server \
            "$LAST_BACKUP/etc/config/passwall2_server"

    [ -f /usr/share/passwall2/direct_ip ] && \
        cp -p /usr/share/passwall2/direct_ip \
            "$LAST_BACKUP/usr/share/passwall2/direct_ip"

    [ -f /usr/share/passwall2/domains_excluded ] && \
        cp -p /usr/share/passwall2/domains_excluded \
            "$LAST_BACKUP/usr/share/passwall2/domains_excluded"

    [ -f /etc/apk/world ] && \
        cp -p /etc/apk/world \
            "$LAST_BACKUP/etc/apk/world"

    [ -f "$REPO_FILE" ] && \
        cp -p "$REPO_FILE" \
            "$LAST_BACKUP/passwall2-repository.list"

    apk list --installed --manifest 2>/dev/null \
        > "$LAST_BACKUP/packages.manifest" || true

    {
        printf 'reason=%s\n' "$reason"
        printf 'date=%s\n' "$(date)"
        printf 'openwrt=%s\n' "$RELEASE_FULL"
        printf 'arch=%s\n' "$ARCH"
        printf 'target=%s\n' "$TARGET"
        printf 'passwall2=%s\n' "$installed"
    } > "$LAST_BACKUP/metadata.txt"

    chmod 0700 "$LAST_BACKUP" 2>/dev/null || true
    chmod -R go-rwx "$LAST_BACKUP" 2>/dev/null || true

    info "Backup created: $LAST_BACKUP"
}

restart_passwall2() {
    /etc/init.d/rpcd restart 2>/dev/null || \
        warn "rpcd restart failed."

    if [ -x /etc/init.d/passwall2 ]; then
        /etc/init.d/passwall2 enable 2>/dev/null || true

        if ! /etc/init.d/passwall2 restart; then
            warn "PassWall2 restart failed. Trying start..."

            /etc/init.d/passwall2 start || \
                return 1
        fi
    else
        warn "/etc/init.d/passwall2 does not exist."
        return 1
    fi

    return 0
}

postcheck_passwall2() {
    sleep 3

    enabled="$(
        uci -q get passwall2.@global[0].enabled 2>/dev/null || echo 0
    )"

    [ "$enabled" = "1" ] || {
        info "PassWall2 main switch is disabled; runtime proxy check skipped."
        return 0
    }

    node="$(
        uci -q get passwall2.@global[0].node 2>/dev/null || true
    )"

    if [ -z "$node" ]; then
        warn "PassWall2 is enabled but no global node is configured."
        return 1
    fi

    if [ -f /tmp/log/passwall2.log ]; then
        if tail -n 120 /tmp/log/passwall2.log |
            grep -q 'Running in no proxy mode'
        then
            warn "PassWall2 entered NO PROXY MODE after package operation."
            warn "Backup: ${LAST_BACKUP:-not created}"
            return 1
        fi
    fi

    info "PassWall2 post-check: no 'no proxy mode' condition detected."

    return 0
}

cmd_status() {
    detect_system

    line
    printf 'PassWall2 APK manager %s\n' "$SCRIPT_VERSION"
    line

    printf 'OpenWrt:          %s\n' "$RELEASE_FULL"
    printf 'Feed branch:      %s\n' "$RELEASE_BRANCH"
    printf 'Architecture:     %s\n' "$ARCH"
    printf 'Target:           %s\n' "$TARGET"
    printf 'Rollback baseline:%s\n' " $BASELINE_TAG"
    printf 'Fallback proxy:   %s\n' "$PROXY"

    subline

    printf 'Signing key:      %s\n' "$KEY_FILE"

    if key_looks_valid; then
        printf 'Key status:       OK\n'
    else
        printf 'Key status:       missing/invalid\n'
    fi

    printf 'Repository:       %s\n' "$REPO_FILE"

    if [ -f "$REPO_FILE" ]; then
        sed 's/^/  /' "$REPO_FILE"
    else
        printf '  missing\n'
    fi

    subline

    printf 'Installed packages:\n'
    print_installed_versions

    subline

    printf 'Managed APK world constraints:\n'
    print_world_constraints

    subline

    printf 'Cached policy:\n'
    policy_output "$MAIN_PKG"

    line
}

cmd_check() {
    ensure_repo

    apk_update
    verify_repository

    main_installed="$(installed_version "$MAIN_PKG")"
    main_available="$(repository_best_version "$MAIN_PKG")"

    line
    printf 'PassWall2 status\n'
    line

    printf 'Installed version:  %s\n' \
        "${main_installed:-not installed}"

    printf 'Repository version: %s\n' \
        "${main_available:-not found}"

    constraint="$(world_constraint_for_pkg "$MAIN_PKG")"

    printf 'WORLD constraint:    %s\n' \
        "${constraint:-not present}"

    subline

    printf 'Repository policy:\n'
    policy_output "$MAIN_PKG"

    subline

    printf 'Available updates in the PassWall2 stack:\n'
    print_stack_updates

    subline

    if [ -z "$main_available" ]; then
        die "The repository is visible, but its version could not be parsed."
    fi

    release_tag="$(apk_version_to_tag "$main_available" 2>/dev/null || true)"

    if [ -n "$release_tag" ]; then
        print_release_safety "$release_tag"
    else
        warn "Could not map repository version $main_available to a GitHub release tag."
    fi

    legacy_hysteria="$(installed_version hysteria)"

    if [ -n "$legacy_hysteria" ]; then
        subline
        warn "Standalone hysteria $legacy_hysteria is still installed."
        warn "PassWall2 >= 26.8.27 no longer uses the standalone Hysteria core."
        warn "It is not removed automatically by this script."
    fi

    line
}

cmd_update() {
    override="${1:-}"

    case "$override" in
        ""|--breaking)
            ;;
        *)
            die "Usage: $0 update [--breaking]"
            ;;
    esac

    ensure_repo

    apk_update
    verify_repository

    installed="$(installed_version "$MAIN_PKG")"

    [ -n "$installed" ] || \
        die "$MAIN_PKG is not installed. Use: $0 install"

    normalize_main_world_constraint

    available="$(repository_best_version "$MAIN_PKG")"

    [ -n "$available" ] || {
        policy_output "$MAIN_PKG" >&2
        die "Cannot determine repository version of $MAIN_PKG."
    }

    info "Installed version:  $installed"
    info "Repository version: $available"

    result="$(
        apk version -t "$installed" "$available" 2>/dev/null || true
    )"

    case "$result" in
        "=")
            info "PassWall2 is already up to date."
            return 0
            ;;

        ">")
            warn "Installed PassWall2 is newer than the signed repository version."
            warn "No downgrade will be performed."
            return 0
            ;;

        "<")
            ;;

        *)
            die "Cannot compare installed and repository versions: '$installed' vs '$available'."
            ;;
    esac

    release_tag="$(apk_version_to_tag "$available" 2>/dev/null || true)"

    if [ -n "$release_tag" ]; then
        enforce_release_safety "$release_tag" "$override" || return 0
    else
        warn "Could not determine matching GitHub release tag."
        warn "Release-note safety check is unavailable."
    fi

    make_tmp

    sim="$TMP_ROOT/update-simulation.txt"

    info "Simulate targeted PassWall2 update WITHOUT --available ..."

    if ! apk upgrade --simulate "$MAIN_PKG" > "$sim" 2>&1; then
        cat "$sim"
        die "Targeted update simulation failed."
    fi

    cat "$sim"

    simulation_is_safe "$sim" 15 || \
        die "Update aborted by safety checks. Nothing was installed."

    confirm "Apply this targeted PassWall2 update?" || {
        info "Cancelled. Nothing was installed."
        return 0
    }

    backup_state "before-update-${installed}-to-${available}"

    apk_commit_with_fallback apk upgrade "$MAIN_PKG"

    restart_passwall2 || \
        die "PassWall2 package was updated, but the service could not be restarted. Backup: $LAST_BACKUP"

    postcheck_passwall2 || \
        die "PassWall2 post-check failed. Review configuration and backup: $LAST_BACKUP"

    after="$(installed_version "$MAIN_PKG")"

    info "PassWall2 after update: ${after:-unknown}"

    [ "$after" = "$available" ] || \
        warn "Installed version does not exactly match the repository candidate."
}

cmd_install() {
    override="${1:-}"

    case "$override" in
        ""|--breaking)
            ;;
        *)
            die "Usage: $0 install [--breaking]"
            ;;
    esac

    ensure_repo

    apk_update
    verify_repository

    available="$(repository_best_version "$MAIN_PKG")"

    [ -n "$available" ] || \
        die "Cannot determine repository version of $MAIN_PKG."

    release_tag="$(apk_version_to_tag "$available" 2>/dev/null || true)"

    if [ -n "$release_tag" ]; then
        enforce_release_safety "$release_tag" "$override" || return 0
    fi

    line
    printf 'Minimal installation request\n'
    line

    printf 'Explicit packages:\n'
    printf '  luci-app-passwall2\n'
    printf '  xray-core\n'

    printf '\n'
    printf 'Standalone hysteria is intentionally NOT installed.\n'
    printf 'Hysteria2 is provided through current supported cores.\n'
    printf '\n'

    printf 'Dependencies such as geoview, tcping, v2ray-geoip and v2ray-geosite are resolved by APK.\n'

    line

    make_tmp

    sim="$TMP_ROOT/install-simulation.txt"

    if ! apk add --simulate $MINIMAL_PKGS > "$sim" 2>&1; then
        cat "$sim"
        die "Minimal installation simulation failed."
    fi

    cat "$sim"

    simulation_is_safe "$sim" 30 || \
        die "Installation aborted by safety checks."

    confirm "Install this PassWall2 + Xray stack from the signed repository?" || {
        info "Cancelled. Nothing was changed."
        return 0
    }

    backup_state "before-install"

    apk_commit_with_fallback apk add $MINIMAL_PKGS

    restart_passwall2 || \
        die "Installation completed, but PassWall2 could not be started. Backup: $LAST_BACKUP"

    installed="$(installed_version "$MAIN_PKG")"

    [ -n "$installed" ] || \
        die "Installation finished, but $MAIN_PKG is not present in the package database."

    postcheck_passwall2 || \
        die "PassWall2 post-check failed. Backup: $LAST_BACKUP"

    info "PassWall2 installed: $installed"
}

find_and_download_luci_asset() {
    tag="$1"
    out="$2"

    apk_version="$(tag_to_apk_version "$tag")" || return 1

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

find_bundle_package() {
    pkgdir="$1"
    pkg="$2"

    find "$pkgdir" -type f -name "${pkg}-*.apk" 2>/dev/null |
        head -n 1
}

cmd_github() {
    tag="${1:-}"
    mode="${2:-luci}"

    [ -n "$tag" ] || \
        die "Usage: $0 rollback TAG [luci|stack]"

    case "$tag" in
        *[!A-Za-z0-9._-]*)
            die "Unsafe TAG value: $tag"
            ;;
    esac

    case "$mode" in
        minimal)
            warn "'minimal' is deprecated. Using the new adaptive 'stack' mode."
            mode="stack"
            ;;

        luci|stack)
            ;;

        *)
            die "Mode must be 'luci' or 'stack'."
            ;;
    esac

    detect_system
    ensure_supported_rollback_tag "$tag"
    require_local_apk_support
    make_tmp

    line
    printf 'Emergency GitHub rollback\n'
    line

    printf 'Target release:   %s\n' "$tag"
    printf 'Mode:             %s\n' "$mode"
    printf 'Architecture:     %s\n' "$ARCH"
    printf 'Minimum allowed:  %s\n' "$BASELINE_TAG"

    subline

    print_release_safety "$tag"

    if [ "$RELEASE_SAFETY" = "breaking" ]; then
        warn "Target release itself contains a configuration-breaking warning."
        warn "Because rollback never goes below $BASELINE_TAG, this is informational."
        warn "Do not assume configuration files are automatically backward-compatible."
    fi

    luci_apk="$TMP_ROOT/luci-app-passwall2.apk"

    info "GitHub mode uses official release assets and local APK installation."

    find_and_download_luci_asset "$tag" "$luci_apk" || \
        die "Cannot find a supported LuCI APK asset for release $tag."

    info "LuCI asset: $FOUND_URL"

    LOCAL_WORLD_PKGS="$MAIN_PKG"

    set -- "$luci_apk"

    if [ "$mode" = "stack" ]; then
        if ! command -v unzip >/dev/null 2>&1; then
            apk_update
            apk_commit_with_fallback apk add unzip
        fi

        bundle="$TMP_ROOT/passwall_packages_apk_${ARCH}.zip"

        bundle_url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/passwall_packages_apk_${ARCH}.zip"

        fetch_url "$bundle" "$bundle_url" || \
            die "Cannot download package bundle for architecture $ARCH."

        pkgdir="$TMP_ROOT/pkgs"

        mkdir -p "$pkgdir" || \
            die "Cannot create package extraction directory."

        unzip -oq "$bundle" -d "$pkgdir" || \
            die "Cannot unpack GitHub package bundle."

        subline
        printf 'Installed PassWall components selected for coherent rollback:\n'

        stack_count=0

        for pkg in $ROLLBACK_STACK_PKGS; do
            installed_pkg="$(installed_version "$pkg")"

            [ -n "$installed_pkg" ] || continue

            pkg_file="$(find_bundle_package "$pkgdir" "$pkg")"

            if [ -z "$pkg_file" ]; then
                die "Installed component '$pkg' is missing from target release bundle $tag. Stack rollback aborted."
            fi

            printf '  %-24s %s\n' "$pkg" "$installed_pkg"

            set -- "$@" "$pkg_file"

            LOCAL_WORLD_PKGS="$LOCAL_WORLD_PKGS $pkg"

            stack_count=$((stack_count + 1))
        done

        if [ "$stack_count" = "0" ]; then
            warn "No additional installed PassWall stack packages were selected."
            warn "Rollback will effectively be LuCI-only."
        fi
    fi

    make_tmp

    sim="$TMP_ROOT/github-simulation.txt"

    if ! apk add \
        --allow-untrusted \
        --force-non-repository \
        --simulate \
        "$@" > "$sim" 2>&1
    then
        cat "$sim"
        die "GitHub rollback simulation failed. Nothing was installed."
    fi

    cat "$sim"

    simulation_is_safe "$sim" 25 || \
        die "GitHub rollback aborted by safety checks. Nothing was installed."

    subline

    if [ "$mode" = "luci" ]; then
        confirm "Rollback only luci-app-passwall2 to GitHub release $tag?" || {
            info "Cancelled. Nothing was changed."
            return 0
        }
    else
        confirm "Rollback PassWall2 and the selected installed stack components to release $tag?" || {
            info "Cancelled. Nothing was changed."
            return 0
        }
    fi

    current="$(installed_version "$MAIN_PKG")"

    backup_state "before-rollback-${current:-unknown}-to-${tag}-${mode}"

    apk_commit_with_fallback \
        apk add \
        --allow-untrusted \
        --force-non-repository \
        "$@"

    for pkg in $LOCAL_WORLD_PKGS; do
        normalize_world_constraint_for_pkg "$pkg" 1
    done

    restart_passwall2 || \
        die "Rollback packages were installed, but PassWall2 could not be restarted. Backup: $LAST_BACKUP"

    postcheck_passwall2 || \
        die "Rollback completed, but PassWall2 post-check failed. Backup: $LAST_BACKUP"

    after="$(installed_version "$MAIN_PKG")"

    info "Installed PassWall2 after rollback: ${after:-unknown}"
    info "Backup from before rollback: $LAST_BACKUP"

    warn "Configuration compatibility is independent of package rollback."
    warn "If a future PassWall2 release changes the config format, use the backup created before that update."
}

cmd_repair_world() {
    detect_system

    line
    printf 'APK world identity-hash repair\n'
    line

    printf 'Before:\n'
    print_world_constraints

    subline

    need_repair=0

    for pkg in $MANAGED_WORLD_PKGS; do
        constraint="$(world_constraint_for_pkg "$pkg")"

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

    confirm "Replace managed identity-hash constraints with normal package constraints?" || {
        info "Cancelled. Nothing was changed."
        return 0
    }

    backup_state "before-world-repair"

    repair_identity_hash_constraints

    subline

    printf 'After:\n'
    print_world_constraints

    line
}

usage() {
    cat <<EOF_USAGE
PassWall2 APK manager $SCRIPT_VERSION

Usage:
  $0 status
  $0 setup
  $0 check
  $0 update [--breaking]
  $0 install [--breaking]
  $0 rollback TAG [luci|stack]
  $0 github TAG [luci|stack]
  $0 repair-world

Normal workflow:
  $0 check
  $0 update

After Attended Sysupgrade with configuration preservation:
  $0 install

Emergency rollback:
  $0 rollback 26.8.27-1

Rollback PassWall2 plus currently installed PassWall components:
  $0 rollback 26.8.27-1 stack

Breaking release:
  $0 update --breaking

Important:
  Rollback below $BASELINE_TAG is intentionally blocked.
  Standalone hysteria is no longer managed by this script.
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

        rollback|github)
            shift
            cmd_github "${1:-}" "${2:-luci}"
            ;;

        repair-world)
            cmd_repair_world
            ;;

        help|-h|--help)
            usage
            ;;

        *)
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
