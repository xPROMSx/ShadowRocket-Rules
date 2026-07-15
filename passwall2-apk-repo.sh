#!/bin/sh
set -u

# PassWall2 APK manager for OpenWrt 25.12+
# Modes:
#   status                 local diagnostics; no network changes
#   setup                  add/repair signed PassWall2 APK repository
#   check                  refresh indexes and show available updates
#   update                 update ONLY luci-app-passwall2 from signed repository
#   install                install minimal stack: PassWall2 + Xray + Hysteria
#   github TAG [luci|minimal]
#                          emergency manual install/rollback from GitHub release
#
# Examples:
#   sh /root/passwall2-apk-repo.sh check
#   sh /root/passwall2-apk-repo.sh update
#   sh /root/passwall2-apk-repo.sh install
#   sh /root/passwall2-apk-repo.sh github 26.6.3-1 luci
#
# Optional override:
#   PROXY="http://192.168.1.11:1088" sh /root/passwall2-apk-repo.sh check

SCRIPT_VERSION="2.0.0"
MAIN_PKG="luci-app-passwall2"
MINIMAL_PKGS="luci-app-passwall2 xray-core hysteria"
DISPLAY_PKGS="luci-app-passwall2 xray-core hysteria geoview tcping v2ray-geoip v2ray-geosite"
PROXY="${PROXY:-http://192.168.1.11:1088}"
REPO_FILE="/etc/apk/repositories.d/passwall2.list"
KEY_FILE="/etc/apk/keys/openwrt-passwall-build.pem"
KEY_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub"
GITHUB_REPO="Openwrt-Passwall/openwrt-passwall2"
TMP_ROOT=""

line() { printf '%s\n' '============================================================'; }
subline() { printf '%s\n' '------------------------------------------------------------'; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() {
    [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"
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

require_root() {
    [ "$(id -u 2>/dev/null || echo 1)" = "0" ] \
        || die "Run this script as root."
}

require_apk() {
    command -v apk >/dev/null 2>&1 \
        || die "apk was not found. This script is only for OpenWrt APK builds."
}

detect_system() {
    [ -r /etc/openwrt_release ] \
        || die "/etc/openwrt_release was not found."

    . /etc/openwrt_release

    RELEASE_FULL="${DISTRIB_RELEASE:-}"
    ARCH="${DISTRIB_ARCH:-}"
    TARGET="${DISTRIB_TARGET:-unknown}"

    [ -n "$RELEASE_FULL" ] \
        || die "Cannot detect OpenWrt release."

    [ -n "$ARCH" ] \
        || die "Cannot detect package architecture."

    RELEASE_BRANCH="${RELEASE_FULL%.*}"

    REPO_BASE="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${RELEASE_BRANCH}/${ARCH}"

    REPO_PASSWALL_PACKAGES="${REPO_BASE}/passwall_packages/packages.adb"
    REPO_PASSWALL_LUCI="${REPO_BASE}/passwall_luci/packages.adb"
    REPO_PASSWALL2="${REPO_BASE}/passwall2/packages.adb"
}

make_tmp() {
    [ -n "${TMP_ROOT:-}" ] && return 0

    TMP_ROOT="$(mktemp -d /tmp/passwall2-apk.XXXXXX)" \
        || die "Cannot create temporary directory."
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

    proxy_env_run apk update \
        || die "apk update failed both directly and through the proxy."
}

apk_commit_with_fallback() {
    info "Trying direct package download..."

    if "$@"; then
        return 0
    fi

    warn "Direct package operation failed. Retrying through $PROXY ..."

    proxy_env_run "$@" \
        || die "Package operation failed both directly and through the proxy."
}

fetch_file() {
    out="$1"
    url="$2"

    rm -f "$out"

    info "Download directly: $url"

    if wget -T 30 -O "$out" "$url"; then
        [ -s "$out" ] \
            || die "Downloaded file is empty: $url"

        return 0
    fi

    warn "Direct download failed. Retrying through $PROXY ..."

    rm -f "$out"

    if proxy_env_run wget -T 30 -O "$out" "$url"; then
        [ -s "$out" ] \
            || die "Downloaded file is empty: $url"

        return 0
    fi

    rm -f "$out"

    return 1
}

repo_file_is_current() {
    [ -s "$REPO_FILE" ] || return 1

    grep -Fxq "$REPO_PASSWALL_PACKAGES" "$REPO_FILE" \
        || return 1

    grep -Fxq "$REPO_PASSWALL_LUCI" "$REPO_FILE" \
        || return 1

    grep -Fxq "$REPO_PASSWALL2" "$REPO_FILE" \
        || return 1

    count="$(
        grep -c \
        '^https://.*openwrt-passwall-build.*packages\.adb$' \
        "$REPO_FILE" \
        2>/dev/null \
        || true
    )"

    [ "$count" = "3" ] || return 1

    return 0
}

key_looks_valid() {
    [ -s "$KEY_FILE" ] || return 1

    grep -q \
        '^-----BEGIN PUBLIC KEY-----' \
        "$KEY_FILE" \
        || return 1

    grep -q \
        '^-----END PUBLIC KEY-----' \
        "$KEY_FILE" \
        || return 1

    return 0
}

remove_duplicate_repo_lines() {
    for file in \
        /etc/apk/repositories \
        /etc/apk/repositories.d/*
    do
        [ -f "$file" ] || continue

        [ "$file" = "$REPO_FILE" ] \
            && continue

        if grep -q \
            'openwrt-passwall-build' \
            "$file" \
            2>/dev/null
        then
            tmp="${file}.pw2tmp.$$"

            grep -v \
                'openwrt-passwall-build' \
                "$file" \
                > "$tmp" \
                || true

            mv "$tmp" "$file" \
                || die "Cannot clean duplicate repository entries in $file"

            info "Removed old PassWall repository entries from $file"
        fi
    done
}

write_repo_file() {
    mkdir -p /etc/apk/repositories.d \
        || die "Cannot create /etc/apk/repositories.d"

    tmp="${REPO_FILE}.tmp.$$"

    cat > "$tmp" <<EOF_REPOS
$REPO_PASSWALL_PACKAGES
$REPO_PASSWALL_LUCI
$REPO_PASSWALL2
EOF_REPOS

    mv "$tmp" "$REPO_FILE" \
        || die "Cannot install $REPO_FILE"
}

install_signing_key() {
    make_tmp

    mkdir -p /etc/apk/keys \
        || die "Cannot create /etc/apk/keys"

    tmp_key="$TMP_ROOT/openwrt-passwall-build.pem"

    fetch_file "$tmp_key" "$KEY_URL" \
        || die "Cannot download repository signing key."

    grep -q \
        '^-----BEGIN PUBLIC KEY-----' \
        "$tmp_key" \
        || die "Downloaded signing key has an unexpected format."

    grep -q \
        '^-----END PUBLIC KEY-----' \
        "$tmp_key" \
        || die "Downloaded signing key is incomplete."

    chmod 0644 "$tmp_key"

    mv "$tmp_key" "$KEY_FILE" \
        || die "Cannot install signing key."
}

verify_repository() {
    policy="$(
        apk policy "$MAIN_PKG" \
        2>/dev/null \
        || true
    )"

    printf '%s\n' "$policy" \
        | grep -q 'openwrt-passwall-build' \
        || die \
        "The signed repository is configured, but $MAIN_PKG is not visible in apk policy."
}

setup_repo() {
    detect_system

    info \
    "Configure signed PassWall2 repository for OpenWrt $RELEASE_BRANCH / $ARCH"

    remove_duplicate_repo_lines

    write_repo_file

    install_signing_key

    apk_update

    verify_repository

    info "Signed PassWall2 repository is ready."
}

ensure_repo() {
    detect_system

    if repo_file_is_current \
        && key_looks_valid
    then
        return 0
    fi

    warn \
    "PassWall2 repository configuration is missing or does not match this OpenWrt build."

    setup_repo
}

installed_version() {
    pkg="$1"

    apk list \
        --installed \
        --manifest \
        2>/dev/null \
    | awk \
        -v p="$pkg" \
        '$1 == p { print $2; exit }'
}

world_constraint() {
    awk \
        -v p="$MAIN_PKG" \
        '
        index($0, p) == 1 {
            c = substr(
                $0,
                length(p) + 1,
                1
            )

            if (
                c == "" ||
                c == "@" ||
                c == "<" ||
                c == ">" ||
                c == "=" ||
                c == "~" ||
                c == "!"
            ) {
                print
                exit
            }
        }
        ' \
        /etc/apk/world \
        2>/dev/null
}

repository_versions() {
    apk policy "$1" \
        2>/dev/null \
    | awk '
        /^  [^ ]/ {
            ver = $1

            sub(
                /:$/,
                "",
                ver
            )

            next
        }

        /^    https?:\/\// &&
        /openwrt-passwall-build/ {
            if (ver != "") {
                print ver
            }
        }
        '
}

repository_best_version() {
    pkg="$1"

    best=""

    for ver in $(repository_versions "$pkg")
    do
        if [ -z "$best" ]; then
            best="$ver"
            continue
        fi

        cmp="$(
            apk version \
                -t \
                "$best" \
                "$ver" \
                2>/dev/null \
                || true
        )"

        [ "$cmp" = "<" ] \
            && best="$ver"
    done

    printf '%s\n' "$best"
}

print_installed_versions() {
    for pkg in $DISPLAY_PKGS
    do
        ver="$(installed_version "$pkg")"

        [ -n "$ver" ] \
            || ver="not installed"

        printf \
            '  %-24s %s\n' \
            "$pkg" \
            "$ver"
    done
}

normalize_main_world_constraint() {
    current="$(world_constraint)"

    [ -n "$current" ] \
        || return 0

    [ "$current" = "$MAIN_PKG" ] \
        && return 0

    warn \
    "Non-standard APK world constraint detected:"

    printf \
        '  %s\n' \
        "$current"

    info \
    "This usually remains after installation from a local GitHub APK."

    info \
    "Normalizing it to: $MAIN_PKG"

    apk_commit_with_fallback \
        apk add \
        "$MAIN_PKG"

    current="$(world_constraint)"

    [ "$current" = "$MAIN_PKG" ] \
        || die \
        "Cannot normalize /etc/apk/world. Current value: ${current:-missing}"

    info \
    "WORLD constraint normalized successfully."
}

simulation_is_safe_for_targeted_update() {
    sim_file="$1"

    count="$(
        awk \
        '
        /^\([[:space:]]*[0-9]+\/[0-9]+\)/ {
            n++
        }

        END {
            print n + 0
        }
        ' \
        "$sim_file"
    )"

    if [ "$count" -gt 15 ]; then
        warn \
        "Simulation contains $count package actions. This is too large for a targeted PassWall2 update."

        return 1
    fi

    if grep \
        -Eiq \
        ' (Upgrading|Replacing|Downgrading) (busybox|apk-tools|libc|firewall4|dnsmasq|dropbear|hostapd|wpad-|kernel|kmod-|base-files)([[:space:]]|\()' \
        "$sim_file"
    then
        warn \
        "Simulation touches critical OpenWrt system packages."

        return 1
    fi

    return 0
}

restart_passwall2() {
    /etc/init.d/rpcd restart \
        2>/dev/null \
        || warn \
        "rpcd restart failed."

    if [ -x /etc/init.d/passwall2 ]; then
        /etc/init.d/passwall2 enable \
            2>/dev/null \
            || true

        /etc/init.d/passwall2 restart \
            2>/dev/null \
        || /etc/init.d/passwall2 start \
            2>/dev/null \
        || warn \
            "PassWall2 restart/start failed."
    fi
}

cmd_status() {
    detect_system

    line

    printf \
        'PassWall2 APK manager %s\n' \
        "$SCRIPT_VERSION"

    line

    printf \
        'OpenWrt:       %s\n' \
        "$RELEASE_FULL"

    printf \
        'Feed branch:   %s\n' \
        "$RELEASE_BRANCH"

    printf \
        'Architecture:  %s\n' \
        "$ARCH"

    printf \
        'Target:        %s\n' \
        "$TARGET"

    printf \
        'Fallback proxy:%s\n' \
        " $PROXY"

    subline

    printf \
        'Signing key:   %s\n' \
        "$KEY_FILE"

    if key_looks_valid; then
        printf \
            'Key status:    OK\n'
    else
        printf \
            'Key status:    missing/invalid\n'
    fi

    printf \
        'Repository:    %s\n' \
        "$REPO_FILE"

    if [ -f "$REPO_FILE" ]; then
        sed \
            's/^/  /' \
            "$REPO_FILE"
    else
        printf \
            '  missing\n'
    fi

    subline

    printf \
        'Installed packages:\n'

    print_installed_versions

    subline

    printf \
        '/etc/apk/world PassWall2 constraint:\n'

    wc_line="$(world_constraint)"

    printf \
        '  %s\n' \
        "${wc_line:-not present}"

    subline

    printf \
        'Cached policy:\n'

    apk policy \
        "$MAIN_PKG" \
        2>/dev/null \
        || true

    line
}

cmd_check() {
    ensure_repo

    apk_update

    verify_repository

    installed="$(
        installed_version \
        "$MAIN_PKG"
    )"

    available="$(
        repository_best_version \
        "$MAIN_PKG"
    )"

    line

    printf \
        'PassWall2 status\n'

    line

    printf \
        'Installed version:  %s\n' \
        "${installed:-not installed}"

    printf \
        'Repository version: %s\n' \
        "${available:-not found}"

    printf \
        'WORLD constraint:    %s\n' \
        "$(world_constraint)"

    subline

    printf \
        'Repository policy:\n'

    apk policy \
        "$MAIN_PKG" \
        2>/dev/null \
        || true

    subline

    printf \
        'Available updates in the PassWall2 stack:\n'

    updates="$(
        apk list \
            --upgradeable \
            2>/dev/null \
        | grep \
            -E \
            '^(luci-app-passwall2|xray-core|hysteria|geoview|tcping|v2ray-geoip|v2ray-geosite)-' \
        || true
    )"

    if [ -n "$updates" ]; then
        printf \
            '%s\n' \
            "$updates"
    else
        printf \
            '  none\n'
    fi

    line
}

cmd_update() {
    ensure_repo

    apk_update

    verify_repository

    installed="$(
        installed_version \
        "$MAIN_PKG"
    )"

    [ -n "$installed" ] \
        || die \
        "$MAIN_PKG is not installed. Use: $0 install"

    normalize_main_world_constraint

    installed="$(
        installed_version \
        "$MAIN_PKG"
    )"

    available="$(
        repository_best_version \
        "$MAIN_PKG"
    )"

    [ -n "$available" ] \
        || die \
        "Cannot determine repository version of $MAIN_PKG."

    info \
    "Installed version:  $installed"

    info \
    "Repository version: $available"

    cmp="$(
        apk version \
            -t \
            "$installed" \
            "$available" \
            2>/dev/null \
            || true
    )"

    case "$cmp" in
        '=')
            info \
            "PassWall2 is already up to date."

            return 0
            ;;

        '>')
            warn \
            "Installed PassWall2 is newer than the signed repository version. No downgrade will be performed."

            return 0
            ;;

        '<')
            ;;

        *)
            die \
            "Cannot compare installed and repository versions: '$installed' vs '$available'."
            ;;
    esac

    make_tmp

    sim="$TMP_ROOT/update-simulation.txt"

    info \
    "Simulate targeted update WITHOUT --available ..."

    if ! apk upgrade \
        --simulate \
        "$MAIN_PKG" \
        > "$sim" \
        2>&1
    then
        cat "$sim"

        die \
        "Targeted update simulation failed."
    fi

    cat "$sim"

    simulation_is_safe_for_targeted_update \
        "$sim" \
        || die \
        "Update aborted by safety checks. Nothing was changed."

    confirm \
    "Apply this targeted PassWall2 update?" \
    || {
        info \
        "Cancelled. Nothing was changed."

        return 0
    }

    apk_commit_with_fallback \
        apk upgrade \
        "$MAIN_PKG"

    restart_passwall2

    after="$(
        installed_version \
        "$MAIN_PKG"
    )"

    info \
    "PassWall2 after update: ${after:-unknown}"

    [ "$after" = "$available" ] \
        || warn \
        "Installed version does not exactly match the repository candidate. Check: apk policy $MAIN_PKG"
}

cmd_install() {
    ensure_repo

    apk_update

    verify_repository

    line

    printf \
        'Minimal installation request\n'

    line

    printf \
        'Explicit packages:\n'

    printf \
        '  luci-app-passwall2\n'

    printf \
        '  xray-core\n'

    printf \
        '  hysteria\n'

    printf \
        '\nPassWall2 dependencies such as geoview, tcping, v2ray-geoip and\n'

    printf \
        'v2ray-geosite will be resolved automatically by APK.\n'

    line

    make_tmp

    sim="$TMP_ROOT/install-simulation.txt"

    if ! apk add \
        --simulate \
        $MINIMAL_PKGS \
        > "$sim" \
        2>&1
    then
        cat "$sim"

        die \
        "Minimal installation simulation failed."
    fi

    cat "$sim"

    confirm \
    "Install this minimal PassWall2 stack from the signed repository?" \
    || {
        info \
        "Cancelled. Nothing was changed."

        return 0
    }

    apk_commit_with_fallback \
        apk add \
        $MINIMAL_PKGS

    restart_passwall2

    installed="$(
        installed_version \
        "$MAIN_PKG"
    )"

    [ -n "$installed" ] \
        || die \
        "Installation finished, but $MAIN_PKG is not present in the installed package database."

    info \
    "PassWall2 installed: $installed"
}

find_and_download_luci_asset() {
    tag="$1"

    apk_ver="${tag%-*}-r${tag##*-}"

    base="https://github.com/${GITHUB_REPO}/releases/download/${tag}"

    out="$2"

    FOUND_URL=""

    url="${base}/luci-app-passwall2-${apk_ver}.apk"

    if fetch_file \
        "$out" \
        "$url"
    then
        FOUND_URL="$url"

        return 0
    fi

    url="${base}/luci-app-passwall2_${tag}_all.apk"

    if fetch_file \
        "$out" \
        "$url"
    then
        FOUND_URL="$url"

        return 0
    fi

    url="${base}/luci-app-passwall2_${apk_ver}_all.apk"

    if fetch_file \
        "$out" \
        "$url"
    then
        FOUND_URL="$url"

        return 0
    fi

    return 1
}

cmd_github() {
    tag="${1:-}"

    mode="${2:-luci}"

    [ -n "$tag" ] \
        || die \
        "Usage: $0 github TAG [luci|minimal]"

    case "$tag" in
        *[!A-Za-z0-9._-]*)
            die \
            "Unsafe TAG value: $tag"
            ;;
    esac

    case "$mode" in
        luci|minimal)
            ;;

        *)
            die \
            "Mode must be 'luci' or 'minimal'."
            ;;
    esac

    detect_system

    make_tmp

    luci_apk="$TMP_ROOT/luci-app-passwall2.apk"

    info \
    "Emergency GitHub mode. Packages are downloaded manually and require --allow-untrusted."

    find_and_download_luci_asset \
        "$tag" \
        "$luci_apk" \
        || die \
        "Cannot find a supported LuCI APK asset for release $tag."

    info \
    "LuCI asset: $FOUND_URL"

    if [ "$mode" = "luci" ]; then
        info \
        "Simulate manual LuCI package installation..."

        apk add \
            --allow-untrusted \
            --simulate \
            "$luci_apk" \
            || die \
            "Manual LuCI installation simulation failed."

        confirm \
        "Install/rollback only luci-app-passwall2 from GitHub release $tag?" \
        || {
            info \
            "Cancelled. Nothing was changed."

            return 0
        }

        apk add \
            --allow-untrusted \
            "$luci_apk" \
            || die \
            "Manual LuCI installation failed."
    else
        command -v unzip \
            >/dev/null \
            2>&1 \
        || {
            apk_update

            apk_commit_with_fallback \
                apk add \
                unzip
        }

        bundle="$TMP_ROOT/passwall_packages_apk_${ARCH}.zip"

        bundle_url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/passwall_packages_apk_${ARCH}.zip"

        fetch_file \
            "$bundle" \
            "$bundle_url" \
            || die \
            "Cannot download package bundle for architecture $ARCH."

        pkgdir="$TMP_ROOT/pkgs"

        mkdir -p "$pkgdir"

        unzip \
            -oq \
            "$bundle" \
            -d "$pkgdir" \
            || die \
            "Cannot unpack GitHub package bundle."

        for pkg in \
            xray-core \
            hysteria \
            geoview \
            tcping \
            v2ray-geoip \
            v2ray-geosite
        do
            ls \
                "$pkgdir"/"$pkg"-*.apk \
                >/dev/null \
                2>&1 \
                || die \
                "Package '$pkg' was not found in the GitHub bundle."
        done

        info \
        "Simulate manual minimal-stack installation..."

        apk add \
            --allow-untrusted \
            --simulate \
            "$luci_apk" \
            "$pkgdir"/xray-core-*.apk \
            "$pkgdir"/hysteria-*.apk \
            "$pkgdir"/geoview-*.apk \
            "$pkgdir"/tcping-*.apk \
            "$pkgdir"/v2ray-geoip-*.apk \
            "$pkgdir"/v2ray-geosite-*.apk \
            || die \
            "Manual minimal-stack simulation failed."

        confirm \
        "Install/rollback the minimal stack from GitHub release $tag?" \
        || {
            info \
            "Cancelled. Nothing was changed."

            return 0
        }

        apk add \
            --allow-untrusted \
            "$luci_apk" \
            "$pkgdir"/xray-core-*.apk \
            "$pkgdir"/hysteria-*.apk \
            "$pkgdir"/geoview-*.apk \
            "$pkgdir"/tcping-*.apk \
            "$pkgdir"/v2ray-geoip-*.apk \
            "$pkgdir"/v2ray-geosite-*.apk \
            || die \
            "Manual minimal-stack installation failed."
    fi

    restart_passwall2

    warn \
    "GitHub manual mode may create an identity-hash constraint in /etc/apk/world."

    warn \
    "A later signed-repository update will normalize that constraint automatically."

    info \
    "Installed PassWall2: $(installed_version "$MAIN_PKG")"
}

usage() {
    cat <<EOF_USAGE
PassWall2 APK manager $SCRIPT_VERSION

Usage:
  $0 status
  $0 setup
  $0 check
  $0 update
  $0 install
  $0 github TAG [luci|minimal]

Normal workflow:
  $0 check
  $0 update

After Attended Sysupgrade with configuration preservation:
  $0 install

Emergency rollback example:
  $0 github 26.6.3-1 luci
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
            cmd_update
            ;;

        install)
            cmd_install
            ;;

        github)
            shift

            cmd_github \
                "${1:-}" \
                "${2:-luci}"
            ;;

        help|-h|--help)
            usage
            ;;

        *)
            usage

            die \
            "Unknown command: $command"
            ;;
    esac
}

main "$@"
