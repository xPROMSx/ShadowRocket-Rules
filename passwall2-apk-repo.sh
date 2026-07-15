#!/bin/sh

set -u

SCRIPT_VERSION="1.0.0"
APP_PKG="luci-app-passwall2"
MINIMAL_RUNTIME_PKGS="xray-core hysteria geoview tcping v2ray-geoip v2ray-geosite"
PROXY_URL="${PW2_PROXY_URL:-http://192.168.1.11:1088}"

KEY_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub"
KEY_FILE="/etc/apk/keys/openwrt-passwall-build.pem"
REPO_FILE="/etc/apk/repositories.d/passwall2.list"
SF_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build"
GH_REPO="Openwrt-Passwall/openwrt-passwall2"
GH_BASE="https://github.com/${GH_REPO}/releases/download"

log()  { printf '%s\n' "[INFO] $*"; }
warn() { printf '%s\n' "[WARN] $*" >&2; }
die()  { printf '%s\n' "[ERROR] $*" >&2; exit 1; }

usage() {
cat <<'USAGE'
PassWall2 APK manager

Usage:
  sh passwall2-apk-repo.sh status
      Local diagnostics. Does not access the network and changes nothing.

  sh passwall2-apk-repo.sh setup
      Add or repair the signed PassWall2 APK repository and signing key.

  sh passwall2-apk-repo.sh check
      Refresh indexes and show installed/available versions and updates.

  sh passwall2-apk-repo.sh update
      Safely update only luci-app-passwall2 from the signed repository.
      Runtime cores are not explicitly requested for upgrade; APK may adjust
      a dependency only if the new PassWall2 package requires it.

  sh passwall2-apk-repo.sh install
      Fresh/recovery install of the minimal stack:
      luci-app-passwall2, xray-core, hysteria, geoview, tcping,
      v2ray-geoip and v2ray-geosite.
      Use this after Attended Sysupgrade when PassWall2 was excluded
      from the firmware image but configuration was kept.

  sh passwall2-apk-repo.sh github TAG [luci|minimal]
      Emergency install/rollback to a specific official GitHub release.
      Example:
        sh passwall2-apk-repo.sh github 26.6.3-1 luci
        sh passwall2-apk-repo.sh github 26.6.3-1 minimal
      This mode installs local upstream APK files with --allow-untrusted.
      Prefer the signed repository for normal installation and updates.

Environment variables:
  PW2_PROXY_URL=http://192.168.1.11:1088
      Fallback proxy. Direct access is always attempted first.

  ASSUME_YES=1
      Skip interactive confirmations.
USAGE
}

need_root() {
    [ "$(id -u)" = "0" ] || die "Run the script as root."
}

load_system() {
    [ -r /etc/openwrt_release ] || die "/etc/openwrt_release was not found."
    # shellcheck disable=SC1091
    . /etc/openwrt_release

    RELEASE_FULL="${DISTRIB_RELEASE:-}"
    ARCH="${DISTRIB_ARCH:-}"
    TARGET="${DISTRIB_TARGET:-unknown}"

    [ -n "$RELEASE_FULL" ] || die "Cannot detect the OpenWrt version."
    [ -n "$ARCH" ] || die "Cannot detect the APK architecture."
    command -v apk >/dev/null 2>&1 || die "apk was not found. This script is for OpenWrt 25.12+ APK builds."

    case "$RELEASE_FULL" in
        SNAPSHOT|*SNAPSHOT*)
            die "SNAPSHOT is not supported by this stable-release script."
            ;;
    esac

    RELEASE_BRANCH="${RELEASE_FULL%.*}"
}

repo_url() {
    feed="$1"
    printf '%s\n' "${SF_BASE}/releases/packages-${RELEASE_BRANCH}/${ARCH}/${feed}/packages.adb"
}

expected_repo_text() {
    repo_url passwall_packages
    repo_url passwall_luci
    repo_url passwall2
}

run_direct() {
    (
        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
        "$@"
    )
}

run_proxy() {
    (
        export http_proxy="$PROXY_URL"
        export https_proxy="$PROXY_URL"
        export HTTP_PROXY="$PROXY_URL"
        export HTTPS_PROXY="$PROXY_URL"
        export all_proxy="$PROXY_URL"
        export ALL_PROXY="$PROXY_URL"
        "$@"
    )
}

net_run() {
    description="$1"
    shift

    log "$description: trying direct connection..."
    if run_direct "$@"; then
        return 0
    fi

    warn "Direct connection failed. Retrying through $PROXY_URL"
    run_proxy "$@"
}

fetch_file() {
    output="$1"
    url="$2"
    command -v wget >/dev/null 2>&1 || die "wget is not installed."
    rm -f "$output"
    net_run "Download $(basename "$output")" wget -T 30 -O "$output" "$url" \
        || { rm -f "$output"; return 1; }
    [ -s "$output" ] || { rm -f "$output"; return 1; }
}

is_installed() {
    apk info --exists "$1" >/dev/null 2>&1
}

installed_version() {
    apk info -v "$1" 2>/dev/null | sed -n '1p'
}

show_pkg() {
    pkg="$1"
    if is_installed "$pkg"; then
        printf '  %-24s %s\n' "$pkg" "$(installed_version "$pkg")"
    else
        printf '  %-24s %s\n' "$pkg" "not installed"
    fi
}

repo_file_is_current() {
    [ -s "$KEY_FILE" ] || return 1
    [ -s "$REPO_FILE" ] || return 1
    actual="$(cat "$REPO_FILE" 2>/dev/null)"
    expected="$(expected_repo_text)"
    [ "$actual" = "$expected" ]
}

remove_duplicate_repo_lines() {
    for file in /etc/apk/repositories /etc/apk/repositories.d/*; do
        [ -f "$file" ] || continue
        [ "$file" = "$REPO_FILE" ] && continue
        if grep -q 'openwrt-passwall-build' "$file" 2>/dev/null; then
            log "Removing duplicate openwrt-passwall-build lines from $file"
            sed -i '\|openwrt-passwall-build|d' "$file" \
                || die "Cannot clean duplicate repository lines in $file"
        fi
    done
}

write_repo_file() {
    mkdir -p /etc/apk/repositories.d || die "Cannot create /etc/apk/repositories.d"
    tmp="/tmp/passwall2.list.$$"
    expected_repo_text > "$tmp" || die "Cannot build repository list."
    chmod 644 "$tmp" 2>/dev/null || true
    mv "$tmp" "$REPO_FILE" || die "Cannot install $REPO_FILE"
}

install_signing_key() {
    mkdir -p /etc/apk/keys || die "Cannot create /etc/apk/keys"
    tmp="/tmp/openwrt-passwall-build.pem.$$"

    fetch_file "$tmp" "$KEY_URL" \
        || die "Cannot download the repository signing key directly or through the proxy."

    grep -q 'BEGIN PUBLIC KEY' "$tmp" \
        || { rm -f "$tmp"; die "Downloaded key is not a valid PEM public key."; }
    grep -q 'END PUBLIC KEY' "$tmp" \
        || { rm -f "$tmp"; die "Downloaded key is not a valid PEM public key."; }

    chmod 644 "$tmp" 2>/dev/null || true
    mv "$tmp" "$KEY_FILE" || die "Cannot install the signing key."
}

refresh_indexes() {
    net_run "Refresh APK indexes" apk update \
        || die "apk update failed both directly and through the proxy."
}

verify_feed() {
    if ! apk search -x "$APP_PKG" 2>/dev/null | grep -q "^${APP_PKG}-"; then
        die "$APP_PKG is not available after apk update. Check the repository, OpenWrt branch and architecture."
    fi
}

setup_repo() {
    load_system
    log "OpenWrt $RELEASE_FULL; branch $RELEASE_BRANCH; arch $ARCH; target $TARGET"

    remove_duplicate_repo_lines
    install_signing_key
    write_repo_file
    refresh_indexes
    verify_feed

    log "Signed PassWall2 repository is configured."
    log "Repository file: $REPO_FILE"
    log "Signing key:    $KEY_FILE"
    apk policy "$APP_PKG" 2>/dev/null || true
}

ensure_repo() {
    load_system
    if repo_file_is_current; then
        return 0
    fi
    warn "Repository/key is missing or does not match this OpenWrt branch/architecture. Running setup."
    setup_repo
}

confirm() {
    question="$1"
    if [ "${ASSUME_YES:-0}" = "1" ]; then
        return 0
    fi

    printf '%s [y/N]: ' "$question"
    read -r answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

world_is_plain() {
    [ -r /etc/apk/world ] && grep -qx "$APP_PKG" /etc/apk/world 2>/dev/null
}

installed_app_version_only() {
    full="$(installed_version "$APP_PKG")"
    printf '%s\n' "${full#${APP_PKG}-}"
}

repo_app_version_only() {
    full="$(apk search -x "$APP_PKG" 2>/dev/null | sed -n '1p')"
    [ -n "$full" ] || return 1
    printf '%s\n' "${full#${APP_PKG}-}"
}

restart_passwall2() {
    /etc/init.d/rpcd restart 2>/dev/null || true
    if [ -x /etc/init.d/passwall2 ]; then
        /etc/init.d/passwall2 enable 2>/dev/null || true
        /etc/init.d/passwall2 restart 2>/dev/null \
            || /etc/init.d/passwall2 start 2>/dev/null \
            || warn "PassWall2 could not be restarted automatically."
    fi
}

status_cmd() {
    load_system

    printf '%s\n' "PassWall2 APK manager $SCRIPT_VERSION"
    printf '%s\n' "============================================================"
    printf 'OpenWrt:       %s\n' "$RELEASE_FULL"
    printf 'Feed branch:   %s\n' "$RELEASE_BRANCH"
    printf 'Architecture:  %s\n' "$ARCH"
    printf 'Target:        %s\n' "$TARGET"
    printf 'Fallback proxy:%s\n' " $PROXY_URL"
    printf '%s\n' "------------------------------------------------------------"

    if [ -s "$KEY_FILE" ]; then
        printf 'Signing key:   %s\n' "$KEY_FILE"
    else
        printf '%s\n' "Signing key:   missing"
    fi

    if [ -s "$REPO_FILE" ]; then
        printf 'Repository:    %s\n' "$REPO_FILE"
        sed 's/^/  /' "$REPO_FILE"
    else
        printf '%s\n' "Repository:    not configured in the script-managed file"
    fi

    printf '%s\n' "Other matching repository entries:"
    found=0
    for file in /etc/apk/repositories /etc/apk/repositories.d/*; do
        [ -f "$file" ] || continue
        [ "$file" = "$REPO_FILE" ] && continue
        if grep -n 'openwrt-passwall-build' "$file" 2>/dev/null; then
            printf '  file: %s\n' "$file"
            found=1
        fi
    done
    [ "$found" -eq 1 ] || printf '%s\n' "  none"

    printf '%s\n' "------------------------------------------------------------"
    show_pkg "$APP_PKG"
    for pkg in $MINIMAL_RUNTIME_PKGS; do
        show_pkg "$pkg"
    done

    printf '%s\n' "------------------------------------------------------------"
    printf '%s\n' "/etc/apk/world PassWall2 constraint:"
    if [ -r /etc/apk/world ] && grep "^${APP_PKG}" /etc/apk/world 2>/dev/null; then
        :
    else
        printf '%s\n' "  no explicit PassWall2 constraint"
    fi

    printf '%s\n' "------------------------------------------------------------"
    printf '%s\n' "Cached repository policy:"
    apk policy "$APP_PKG" 2>/dev/null || true

    printf '%s\n' "------------------------------------------------------------"
    if [ -x /etc/init.d/passwall2 ]; then
        printf '%s' "Service:       "
        /etc/init.d/passwall2 status 2>&1 || true
    else
        printf '%s\n' "Service:       not installed"
    fi
}

check_cmd() {
    ensure_repo
    refresh_indexes
    verify_feed

    printf '%s\n' "Installed:"
    show_pkg "$APP_PKG"
    for pkg in $MINIMAL_RUNTIME_PKGS; do
        show_pkg "$pkg"
    done

    printf '%s\n' "------------------------------------------------------------"
    printf '%s\n' "PassWall2 repository policy:"
    apk policy "$APP_PKG" 2>/dev/null || true

    printf '%s\n' "------------------------------------------------------------"
    printf '%s\n' "Available updates in the PassWall2 minimal stack:"
    if ! apk list --upgradable 2>/dev/null \
        | grep -E '^(luci-app-passwall2|xray-core|hysteria|geoview|tcping|v2ray-geoip|v2ray-geosite)-'; then
        printf '%s\n' "  none"
    fi
}

update_cmd() {
    ensure_repo
    refresh_indexes
    verify_feed

    is_installed "$APP_PKG" \
        || die "$APP_PKG is not installed. Use the install command."

    installed_ver="$(installed_app_version_only)"
    repo_ver="$(repo_app_version_only)" \
        || die "Cannot determine the repository version of $APP_PKG."
    comparison="$(apk version -t "$installed_ver" "$repo_ver" 2>/dev/null)" \
        || die "Cannot compare installed and repository versions."

    log "Installed version: $installed_ver"
    log "Repository version: $repo_ver"
    apk policy "$APP_PKG" 2>/dev/null || true

    case "$comparison" in
        '>')
            warn "The installed PassWall2 version is newer than the signed repository version."
            warn "Nothing was changed. Wait until the repository catches up, or use a deliberate GitHub rollback."
            return 0
            ;;
        '=')
            if world_is_plain; then
                log "The latest repository version is already installed. Nothing was changed."
                return 0
            fi

            warn "The same version is installed, but /etc/apk/world contains a local/pinned package constraint:"
            grep "^${APP_PKG}" /etc/apk/world 2>/dev/null || true
            log "Simulation: adopt the same version into normal repository management."
            apk add --simulate "$APP_PKG" \
                || die "Repository adoption simulation failed. Nothing was changed."
            confirm "Replace the local/pinned constraint with normal repository management?" \
                || { warn "Cancelled."; return 0; }
            net_run "Adopt $APP_PKG from repository" apk add "$APP_PKG" \
                || die "Repository adoption failed."
            restart_passwall2
            log "PassWall2 is now managed by the signed repository."
            return 0
            ;;
        '<')
            if world_is_plain; then
                log "Simulation: apk upgrade $APP_PKG"
                apk upgrade --simulate "$APP_PKG" \
                    || die "Upgrade simulation failed. Nothing was changed."
                confirm "Update only $APP_PKG from the signed repository?" \
                    || { warn "Cancelled."; return 0; }
                net_run "Update $APP_PKG" apk upgrade "$APP_PKG" \
                    || die "PassWall2 update failed."
            else
                warn "A local/pinned PassWall2 constraint was found in /etc/apk/world:"
                grep "^${APP_PKG}" /etc/apk/world 2>/dev/null || true
                log "The repository version is newer; apk add will adopt and update PassWall2 in one transaction."
                apk add --simulate "$APP_PKG" \
                    || die "Adoption/update simulation failed. Nothing was changed."
                confirm "Adopt and update $APP_PKG from the signed repository?" \
                    || { warn "Cancelled."; return 0; }
                net_run "Adopt and update $APP_PKG" apk add "$APP_PKG" \
                    || die "PassWall2 adoption/update failed."
            fi

            restart_passwall2
            log "Done: $(installed_version "$APP_PKG")"
            log "Runtime cores were not explicitly requested for upgrade."
            ;;
        *)
            die "Unexpected version comparison result: $comparison"
            ;;
    esac
}

install_cmd() {
    ensure_repo
    refresh_indexes
    verify_feed

    set -- "$APP_PKG"
    for pkg in $MINIMAL_RUNTIME_PKGS; do
        set -- "$@" "$pkg"
    done

    log "Minimal stack: $*"
    log "Simulation: apk add minimal PassWall2 stack"
    apk add --simulate "$@" \
        || die "Installation simulation failed. Nothing was changed."

    confirm "Install/update the minimal PassWall2 stack from the signed repository?" \
        || { warn "Cancelled."; return 0; }

    net_run "Install/update minimal PassWall2 stack" apk add "$@" \
        || die "Minimal PassWall2 installation failed."

    restart_passwall2
    log "PassWall2 minimal stack is installed."
    log "PassWall2: $(installed_version "$APP_PKG")"
}

check_download_size() {
    file="$1"
    minimum="$2"
    label="$3"
    [ -s "$file" ] || die "$label download is empty."
    size="$(wc -c < "$file" | tr -d ' ')"
    [ "${size:-0}" -ge "$minimum" ] \
        || die "$label download is suspiciously small: ${size:-0} bytes."
}

github_cmd() {
    tag="${1:-}"
    mode="${2:-luci}"

    [ -n "$tag" ] || die "Specify a release tag, for example: 26.6.3-1"
    case "$tag" in
        *[!0-9.-]*|.*|-*|*.) die "Invalid release tag: $tag" ;;
    esac
    case "$mode" in
        luci|minimal) : ;;
        *) die "Mode must be 'luci' or 'minimal'." ;;
    esac

    load_system
    workdir="$(mktemp -d /tmp/passwall2-github.XXXXXX)" \
        || die "Cannot create a temporary directory."
    trap 'rm -rf "$workdir"' EXIT INT TERM

    apk_ver="${tag%-*}-r${tag##*-}"
    luci_apk="$workdir/luci-app-passwall2-${apk_ver}.apk"
    luci_url="${GH_BASE}/${tag}/luci-app-passwall2-${apk_ver}.apk"

    log "Official GitHub release: $tag"
    log "APK version:             $apk_ver"
    log "Architecture:            $ARCH"
    log "Mode:                    $mode"

    fetch_file "$luci_apk" "$luci_url" \
        || die "Cannot download $luci_url"
    check_download_size "$luci_apk" 100000 "PassWall2 LuCI APK"

    set -- "$luci_apk"

    if [ "$mode" = "minimal" ]; then
        ensure_repo
        refresh_indexes
        if ! command -v unzip >/dev/null 2>&1; then
            net_run "Install unzip" apk add unzip \
                || die "Cannot install unzip, which is required for the GitHub bundle."
        fi

        bundle="$workdir/passwall_packages_apk_${ARCH}.zip"
        bundle_url="${GH_BASE}/${tag}/passwall_packages_apk_${ARCH}.zip"
        fetch_file "$bundle" "$bundle_url" \
            || die "Cannot download $bundle_url"
        check_download_size "$bundle" 1000000 "PassWall2 package bundle"

        mkdir -p "$workdir/pkgs" || die "Cannot create package extraction directory."
        unzip -oq "$bundle" -d "$workdir/pkgs" \
            || die "Cannot unpack the PassWall2 package bundle."

        set -- \
            "$luci_apk" \
            "$workdir"/pkgs/xray-core-*.apk \
            "$workdir"/pkgs/hysteria-*.apk \
            "$workdir"/pkgs/geoview-*.apk \
            "$workdir"/pkgs/tcping-*.apk \
            "$workdir"/pkgs/v2ray-geoip-*.apk \
            "$workdir"/pkgs/v2ray-geosite-*.apk

        for file in "$@"; do
            [ -f "$file" ] || die "A required package is missing from the GitHub bundle: $file"
        done
    fi

    warn "This emergency mode installs local upstream APK files with --allow-untrusted."
    warn "Use it only for a deliberate rollback/specific release. Normal updates should use the signed repository."

    net_run "Simulate GitHub release installation" apk add --allow-untrusted --simulate "$@" \
        || die "GitHub release installation simulation failed. Nothing was changed."

    confirm "Install official GitHub release $tag in '$mode' mode?" \
        || { warn "Cancelled."; return 0; }

    net_run "Install GitHub release $tag" apk add --allow-untrusted "$@" \
        || die "GitHub release installation failed."

    restart_passwall2
    log "Installed GitHub release: $(installed_version "$APP_PKG")"
    warn "A local-package constraint may now exist in /etc/apk/world."
    warn "The next normal 'update' command will offer to adopt the package back into the signed repository."
}

main() {
    need_root
    command="${1:-help}"
    shift 2>/dev/null || true

    case "$command" in
        status)  status_cmd ;;
        setup)   setup_repo ;;
        check)   check_cmd ;;
        update)  update_cmd ;;
        install|minimal) install_cmd ;;
        github)  github_cmd "${1:-}" "${2:-luci}" ;;
        help|-h|--help) usage ;;
        *) usage; die "Unknown command: $command" ;;
    esac
}

main "$@"
