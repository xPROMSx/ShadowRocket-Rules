#!/bin/sh
# PassWall2 APK manager, reviewed against OpenWrt 25.12 / PW2 26.9.12-1.
# SPDX-License-Identifier: GPL-3.0-only
# check [install] | update [--allow-prerelease] | install [--allow-prerelease] | status | help
# BusyBox ash is the target shell; local is intentionally used.
# shellcheck disable=SC3043
# No global apk upgrade; no unsigned APKs; no automatic rollback claims.
set -eu
umask 077
export LC_ALL=C
SCRIPT_VERSION="4.0.1"
PROXY="${PROXY:-http://192.168.1.11:1088}"
MAIN_PKG=luci-app-passwall2
KEY_SHA256=52802b143489214e13b78f96599a147a638205cc22d9dd6d71229504e38ddc00
KEY_URL=https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub
KEY_FILE=/etc/apk/keys/openwrt-passwall-build.pem
REPO_FILE=/etc/apk/repositories.d/passwall2.list
BACKUP_DIR=/root/passwall2-backups
TMP_ROOT='' LAST_BACKUP='' LOCKED=0 MAINTENANCE=0 COMMIT_STARTED=0 KEEP_TMP=0
ALLOW_PRERELEASE=0 RELEASE_PRERELEASE=0 IS_CHECK=0
MODE=update SWAP_DNS=0 OLD_DNS='' ORIGINAL_ENABLED=0 SERVER_ENABLED=0

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
sha() { sha256sum "$1" | awk '{print $1}'; }
valid_version() { printf '%s\n' "$1" | grep -Eq '^[0-9]+([.][0-9]+)*(-r[0-9]+)?$'; }
compare() {
    local result
    result=$(apk version -t "$1" "$2") || die 'APK version comparison failed.'
    case "$result" in '<'|'='|'>') printf '%s\n' "$result";; *) die 'Invalid APK comparison result.';; esac
}

direct_run() (
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    "$@"
)
proxy_run() (
    export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
    unset all_proxy ALL_PROXY
    export no_proxy=localhost,127.0.0.1,::1,192.168.1.11 NO_PROXY=localhost,127.0.0.1,::1,192.168.1.11
    "$@"
)
# Only read/download operations may be retried. NEVER retry a package commit.
network_run() {
    if direct_run "$@"; then return 0; fi
    warn "Direct access failed; retrying via $PROXY"
    proxy_run "$@"
}
wget_once() {
    # GNU wget otherwise retries up to 20 times before reaching the fallback.
    if wget --help 2>&1 | grep -q -- '--tries'; then
        wget -t 1 -T 30 -O "$1" "$2"
    else
        wget -T 30 -O "$1" "$2"
    fi
}
fetch() {
    local dest="$1" url="$2"
    rm -f "$dest"
    if direct_run wget_once "$dest" "$url" && [ -s "$dest" ]; then return 0; fi
    rm -f "$dest"
    warn "Retry download via Synology: $url"
    if proxy_run wget_once "$dest" "$url" && [ -s "$dest" ]; then return 0; fi
    rm -f "$dest"
    return 1
}

installed_version() {
    # Read the installed DB, not a candidate from a remote index.
    apk list --installed --manifest 2>/dev/null | awk -v p="$1" '$1==p {print $2; exit}'
}
configured_path() {
    local key="$1" fallback="$2" value
    value=$(uci -q get "passwall2.@global_app[0].${key}_file" 2>/dev/null || true)
    if [ -n "$value" ] && [ -x "$value" ]; then printf '%s\n' "$value"; else printf '%s\n' "$fallback"; fi
}
runtime_version() {
    local pkg="$1" path="$2" result
    [ -x "$path" ] || return 0
    case "$pkg" in
        xray-core) result=$("$path" version 2>/dev/null | awk '$1=="Xray" {print $2; exit}');;
        sing-box) result=$("$path" version 2>/dev/null | awk '$1=="sing-box" && $2=="version" {print $3; exit}');;
        *) return 1;;
    esac
    printf '%s\n' "$result"
}

require_system() {
    [ "$(id -u)" = 0 ] || die 'Run as root.'
    local c
    for c in apk uci jsonfilter wget sha256sum awk sed grep mktemp readlink cmp tar; do
        command -v "$c" >/dev/null 2>&1 || die "Required command is missing: $c"
    done
    [ -r /etc/openwrt_release ] || die 'Only OpenWrt is supported.'
    # shellcheck disable=SC1091
    . /etc/openwrt_release
    RELEASE_FULL=${DISTRIB_RELEASE:-}
    ARCH=${DISTRIB_ARCH:-}
    printf '%s\n' "$RELEASE_FULL" | grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$' || die 'Only stable OpenWrt releases are supported, not SNAPSHOT/RC.'
    [ -n "$ARCH" ] || die 'OpenWrt package architecture is missing.'
    BRANCH=${RELEASE_FULL%.*}
    [ "$(compare "$BRANCH" 25.12)" != '<' ] || die 'OpenWrt 25.12 or newer with APK is required.'
    [ -x /sbin/fw4 ] || die 'This script installs the firewall4/nftables stack.'
    BASE_URL="https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${BRANCH}/${ARCH}"
    case "$PROXY" in http://*) ;; *) die 'PROXY must be an HTTP proxy URL.';; esac
}

apk_run() {
    apk --repositories-file "$TMP_ROOT/repositories" --keys-dir "$TMP_ROOT/keys" \
        --cache-dir "$TMP_ROOT/cache" --timeout 30 "$@"
}

prepare() {
    TMP_ROOT=$(mktemp -d /tmp/passwall2-apk.XXXXXX) || die 'Cannot create work directory.'
    mkdir -p "$TMP_ROOT/keys" "$TMP_ROOT/cache"
    local file name
    for file in /etc/apk/keys/*; do
        [ -f "$file" ] || continue
        cp -p "$file" "$TMP_ROOT/keys/"
    done
    if [ -f "$KEY_FILE" ] && [ "$(sha "$KEY_FILE")" = "$KEY_SHA256" ]; then
        cp "$KEY_FILE" "$TMP_ROOT/keys/openwrt-passwall-build.pem"
    else
        fetch "$TMP_ROOT/keys/openwrt-passwall-build.pem" "$KEY_URL" || die 'Cannot download the repository key.'
    fi
    [ "$(sha "$TMP_ROOT/keys/openwrt-passwall-build.pem")" = "$KEY_SHA256" ] || die 'Repository key fingerprint mismatch. Key rotation needs review.'
    : > "$TMP_ROOT/repositories"
    # Match APK file precedence. Keep other repositories; replace only the PW feed.
    for file in /etc/apk/repositories /etc/apk/repositories.d/*.list /lib/apk/repositories.d/*.list; do
        [ -f "$file" ] || continue
        name=${file##*/}
        case "$file" in /lib/apk/repositories.d/*) [ ! -f "/etc/apk/repositories.d/$name" ] || continue;; esac
        awk '!/openwrt-passwall-build/' "$file" >> "$TMP_ROOT/repositories"
        printf '\n' >> "$TMP_ROOT/repositories"
    done
    : > "$TMP_ROOT/pw-repositories"
    for name in passwall_packages passwall_luci passwall2; do
        printf '%s/%s/packages.adb\n' "$BASE_URL" "$name" >> "$TMP_ROOT/pw-repositories"
    done
    cat "$TMP_ROOT/pw-repositories" >> "$TMP_ROOT/repositories"
    network_run apk_run update || die 'Cannot refresh all signed APK indexes.'
    apk list --installed --manifest > "$TMP_ROOT/installed-before"
    [ -f /etc/apk/world ] && cp /etc/apk/world "$TMP_ROOT/world-before"
}

repository_versions() {
    apk_run policy "$1" | awk -v base="$BASE_URL/" '
        /^  [^ ]/ && /:$/ {v=$0; sub(/^  /,"",v); sub(/:$/,"",v)}
        index($0,base) && v!="" {print v}
    ' | sort -u
}
repository_best() {
    local pkg="$1" upstream="${2:-}" best='' v
    for v in $(repository_versions "$pkg"); do
        valid_version "$v" || continue
        [ -z "$upstream" ] || [ "${v%-r*}" = "$upstream" ] || continue
        if [ -z "$best" ] || [ "$(compare "$v" "$best")" = '>' ]; then best=$v; fi
    done
    printf '%s\n' "$best"
}
release_component() {
    awk -F '|' -v p="$1" 'index($1,p) {v=$2; gsub(/[*[:space:]`]/,"",v); print v}' "$TMP_ROOT/release-body"
}

select_targets() {
    local installed available tag actual metadata_tag component pkg path expect target old cfg pw_version latest
    installed=$(installed_version "$MAIN_PKG")
    if [ "$MODE" = update ]; then
        [ -n "$installed" ] || die 'PassWall2 is missing. Use: check install / install.'
    fi
    if [ -s /etc/config/passwall2 ]; then
        cfg=$(uci -q get 'passwall2.@global[0].node' || true)
        [ -n "$cfg" ] || die 'Saved PassWall2 config has no global node field. Review its schema before restoring packages.'
    fi
    if [ -n "$installed" ] && [ "$(compare "$installed" 26.8.27-r1)" = '<' ]; then
        die 'Migration from PassWall2 older than 26.8.27 needs separate configuration review.'
    fi
    available=$(repository_best "$MAIN_PKG")
    [ -n "$available" ] || die 'No PassWall2 package in the signed repository for this OpenWrt release/architecture.'
    [ -z "$installed" ] || [ "$(compare "$installed" "$available")" != '>' ] || die 'Installed PassWall2 is newer than the repository. Downgrade blocked.'
    pw_version=$available
    tag=$(printf '%s\n' "$available" | sed 's/-r/-/')
    fetch "$TMP_ROOT/release.json" "https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall2/releases/tags/$tag" || die 'Cannot verify the exact PassWall2 release.'
    metadata_tag=$(jsonfilter -i "$TMP_ROOT/release.json" -e '@.tag_name')
    [ "$metadata_tag" = "$tag" ] || die 'Release metadata/tag mismatch.'
    [ "$(jsonfilter -i "$TMP_ROOT/release.json" -e '@.draft')" = false ] || die 'Draft or invalid release.'
    case "$(jsonfilter -i "$TMP_ROOT/release.json" -e '@.prerelease')" in
        false) RELEASE_PRERELEASE=0;;
        true)
            RELEASE_PRERELEASE=1
            warn "PassWall2 $tag is marked prerelease. This flag alone does not establish compatibility."
            if fetch "$TMP_ROOT/latest.json" 'https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall2/releases/latest'; then
                latest=$(jsonfilter -i "$TMP_ROOT/latest.json" -e '@.tag_name' || true)
                info "Signed feed candidate: $tag; GitHub latest stable: ${latest:-unknown}"
            fi
            ;;
        *) die 'Missing or invalid prerelease status in release metadata.';;
    esac
    jsonfilter -i "$TMP_ROOT/release.json" -e '@.body' > "$TMP_ROOT/release-body"
    # Warnings are conservative filters, never proof that a release is safe.
    if grep -Eiq 'breaking change|restore.*default config|incompatible config|configuration structure|migration logic' "$TMP_ROOT/release-body"; then
        die 'Release notes require manual migration review.'
    fi
    info "OpenWrt $RELEASE_FULL / $ARCH; script $SCRIPT_VERSION"
    info "PassWall2 APK: ${installed:-absent} -> $available"
    info "Release: https://github.com/Openwrt-Passwall/openwrt-passwall2/releases/tag/$tag"
    printf '%s=%s\n' "$MAIN_PKG" "$available" > "$TMP_ROOT/targets"
    printf '%s\n' "$MAIN_PKG" > "$TMP_ROOT/managed"
    : > "$TMP_ROOT/cores"
    : > "$TMP_ROOT/reinstall"
    for pkg in xray-core sing-box; do
        case "$pkg" in
            xray-core) component=xray-core; path=$(configured_path xray /usr/bin/xray); expect=/usr/bin/xray;;
            sing-box)
                # Restore an optional core if it was installed or appears in saved nodes.
                cfg=$(uci -q show passwall2 2>/dev/null || true)
                if [ -z "$(installed_version sing-box)" ] && [ ! -x "$(configured_path sing_box /usr/bin/sing-box)" ]; then
                    [ "$MODE" = install ] || continue
                    printf '%s\n' "$cfg" | grep -Eiq "[.]type='sing-box'" || continue
                fi
                component=sing-box; path=$(configured_path sing_box /usr/bin/sing-box); expect=/usr/bin/sing-box;;
        esac
        # A custom active binary must not silently override the updated APK binary.
        if [ "$path" != "$expect" ]; then
            [ "$(readlink -f "$path")" = "$expect" ] || die "Custom runtime $path is active; move it to $expect via App Update settings before using APK management."
        fi
        target=$(release_component "$component")
        valid_version "$target" || die "Missing/ambiguous $component bundle version in release metadata."
        if [ "$pkg" = xray-core ] && [ "$(compare "$pw_version" 26.9.9-r1)" != '<' ]; then
            [ "$(compare "$target" 26.9.9)" != '<' ] || die 'September PW2 releases require the reviewed Xray 26.9.9-or-newer bundle.'
        fi
        actual=$(runtime_version "$pkg" "$path")
        if [ -x "$path" ]; then
            valid_version "$actual" || die "Cannot identify the actual $pkg runtime at $path."
            [ "$(compare "$actual" "$target")" != '>' ] || die "$pkg runtime $actual is newer than release bundle $target; automatic downgrade blocked."
        fi
        old=$(installed_version "$pkg")
        available=$(repository_best "$pkg" "$target")
        [ -n "$available" ] || die "Signed feed has no $pkg $target. Wait for the feed; the working installation is unchanged."
        [ -z "$old" ] || [ "$(compare "$old" "$available")" != '>' ] || die "$pkg APK downgrade blocked."
        info "$pkg runtime: ${actual:-absent} -> $target; APK: ${old:-absent} -> $available"
        printf '%s=%s\n' "$pkg" "$available" >> "$TMP_ROOT/targets"
        printf '%s\n' "$pkg" >> "$TMP_ROOT/managed"
        printf '%s|%s|%s\n' "$pkg" "$expect" "$target" >> "$TMP_ROOT/cores"
        if [ "$old" = "$available" ] && [ "$actual" != "$target" ]; then
            printf '%s\n' "$pkg" >> "$TMP_ROOT/reinstall"
            info "$pkg needs reinstallation: APK metadata alone would otherwise leave the old/missing binary."
        fi
    done
    if [ "$MODE" = install ]; then
        printf '%s\n' chinadns-ng dnsmasq-full kmod-nft-socket kmod-nft-tproxy kmod-nft-nat >> "$TMP_ROOT/targets"
        if [ -z "$(installed_version dnsmasq-full)" ]; then
            for pkg in dnsmasq dnsmasq-dhcpv6; do
                old=$(installed_version "$pkg")
                if [ -n "$old" ]; then
                    [ "$SWAP_DNS" = 0 ] || die 'Multiple dnsmasq variants are installed; manual review required.'
                    SWAP_DNS=1; OLD_DNS="$pkg=$old"
                    info "Atomic DNS variant replacement: $pkg -> dnsmasq-full; the original will also be cached."
                fi
            done
        fi
    fi
    info 'Geodata and existing Geoview are preserved. Existing non-target package changes are blocked.'
    info 'Bundle versions are an upstream packaging baseline, not a universal compatibility guarantee.'
}

# Parse the APK 3 action stream strictly. Unknown formats fail closed.
parse_plan() {
    awk '
    /^\([[:space:]]*[0-9]+\/[0-9]+\)/ {
        hdr=$0; sub(/\).*/,"",hdr); gsub(/[()[:space:]]/,"",hdr); split(hdr,h,"/")
        if (h[1] != count+1 || (total && total != h[2])) {bad=1; exit 34}
        count++; total=h[2]
        s=$0; sub(/^\([[:space:]]*[0-9]+\/[0-9]+\)[[:space:]]*/,"",s)
        if (s ~ /^Updating pinning /) {a="Pinning"; sub(/^Updating pinning /,"",s)}
        else {a=s; sub(/ .*/,"",a); sub(/^[^ ]+ +/,"",s)}
        if (a !~ /^(Installing|Upgrading|Downgrading|Replacing|Reinstalling|Removing|Purging|Pinning)$/) {bad=1; exit 31}
        p=s; sub(/ .*/,"",p); sub(/@.*/,"",p)
        if (p !~ /^[a-zA-Z0-9][a-zA-Z0-9+_.-]*$/) {bad=1; exit 32}
        v=s; sub(/^[^(]*\(/,"",v); sub(/\).*/,"",v); sub(/^.* -> /,"",v)
        if (v !~ /^[a-zA-Z0-9][a-zA-Z0-9+_.:~-]*$/) {bad=1; exit 33}
        print a "|" p "|" v
    }
    END {if (bad || count != total) exit 35}
    ' "$1"
}
check_plan() {
    local input="$1" output="$2" action pkg version count=0 dns_install=0
    parse_plan "$input" > "$output" || die 'Unrecognized APK action format; refusing to continue.'
    # APK simulation must finish successfully and emit a summary.
    grep -Eq '^OK:' "$input" || die 'Missing successful APK simulation summary.'
    grep -q '^Installing|dnsmasq-full|' "$output" && dns_install=1
    while IFS='|' read -r action pkg version; do
        count=$((count + 1))
        case "$action" in
            Removing|Purging)
                if [ "$MODE" = install ] && [ "$SWAP_DNS" = 1 ] && [ "$pkg" = "${OLD_DNS%=*}" ] &&
                   [ "$dns_install" = 1 ]; then continue; fi
                die "Destructive action blocked: $action $pkg";;
            Downgrading) die "Downgrade blocked: $pkg";;
        esac
        if grep -Fxq "$pkg" "$TMP_ROOT/managed"; then continue; fi
        case "$pkg" in busybox|apk-tools*|libc|musl*|firewall4|dropbear|hostapd*|wpad*|kernel|base-files|netifd|procd|ubus|uci)
            die "System package change blocked: $action $pkg";;
        esac
        [ "$action" = Installing ] || die "Unrelated installed package change blocked: $action $pkg"
        case "$pkg" in
            kmod-*|dnsmasq*) [ "$MODE" = install ] || die "Use install to restore missing nftables/DNS components: $pkg";;
            luci-i18n-passwall2-*) die 'An unexpected language package was selected.';;
            sing-box) die 'An unrequested sing-box installation was selected.';;
        esac
    done < "$output"
    [ "$count" -le 80 ] || die 'Unexpectedly large package operation.'
}


simulate() {
    local arg pkg version
    set --
    while IFS= read -r arg; do set -- "$@" "$arg"; done < "$TMP_ROOT/targets"
    apk_run --no-network add --simulate "$@" > "$TMP_ROOT/plan" 2>&1 || { cat "$TMP_ROOT/plan"; die 'APK dependency simulation failed. Nothing installed.'; }
    cat "$TMP_ROOT/plan"
    check_plan "$TMP_ROOT/plan" "$TMP_ROOT/actions"
    while IFS= read -r arg; do
        case "$arg" in *=*) pkg=${arg%%=*}; version=${arg#*=};; *) continue;; esac
        if [ "$(installed_version "$pkg")" != "$version" ]; then
            awk -F '|' -v p="$pkg" -v v="$version" '$2==p && $3==v {ok=1} END {exit !ok}' "$TMP_ROOT/actions" || die "APK did not plan the selected version of $pkg."
        fi
    done < "$TMP_ROOT/targets"
    while IFS= read -r arg; do
        apk_run --no-network fix --simulate --reinstall "$arg" > "$TMP_ROOT/fix-$arg-plan" 2>&1 || die "Cannot simulate binary repair for $arg."
        check_plan "$TMP_ROOT/fix-$arg-plan" "$TMP_ROOT/fix-$arg-actions"
        cat "$TMP_ROOT/fix-$arg-plan"
    done < "$TMP_ROOT/reinstall"
}

space_check() {
    local ram disk
    ram=$(df -Pk /tmp | awk 'END {print $4}')
    disk=$(df -Pk /overlay | awk 'END {print $4}')
    info "Free space: /tmp ${ram} KiB; /overlay ${disk} KiB"
    [ "$ram" -ge 131072 ] || die 'At least 128 MiB free in /tmp is required for package staging.'
    [ "$disk" -ge 196608 ] || die 'At least 192 MiB free in /overlay is required for backup and installation.'
}

check_idle() {
    local p changes
    for p in /var/lock/passwall2.lock /var/lock/passwall2_rule_update.lock /var/lock/passwall2_subscribe.lock; do
        [ ! -e "$p" ] || die "PassWall2 operation/lock exists: $p. Finish it first."
    done
    changes=$(uci -q changes 2>/dev/null || true)
    [ -z "$changes" ] || die 'There are uncommitted UCI changes. Save/apply them in LuCI first.'
}

snapshot_files() {
    local file asset
    : > "$TMP_ROOT/config-files"
    for file in /etc/config/passwall2 /etc/config/passwall2_server /usr/share/passwall2/direct_ip /usr/share/passwall2/domains_excluded; do
        [ ! -f "$file" ] || printf '%s\n' "$file" >> "$TMP_ROOT/config-files"
    done
    asset=$(uci -q get 'passwall2.@global_rules[0].v2ray_location_asset' || true)
    asset=${asset:-/usr/share/v2ray}
    for file in "$asset/geoip.dat" "$asset/geosite.dat"; do
        [ ! -f "$file" ] || printf '%s\n' "$file" >> "$TMP_ROOT/config-files"
    done
    : > "$TMP_ROOT/config-hashes"
    while IFS= read -r file; do sha256sum "$file" >> "$TMP_ROOT/config-hashes"; done < "$TMP_ROOT/config-files"
}
assert_unchanged() {
    apk list --installed --manifest > "$TMP_ROOT/installed-now"
    cmp -s "$TMP_ROOT/installed-before" "$TMP_ROOT/installed-now" || die 'Installed packages changed during preparation. Run check again.'
    cmp -s "$TMP_ROOT/world-before" /etc/apk/world || die 'APK world changed during preparation.'
    if [ -s "$TMP_ROOT/config-hashes" ]; then
        sha256sum -c "$TMP_ROOT/config-hashes" >/dev/null || die 'PassWall2 settings changed during preparation.'
    fi
    check_idle
}

prefetch() {
    local arg action pkg version
    set --
    while IFS='|' read -r action pkg version; do
        case "$action" in Purging|Removing) continue;; esac
        set -- "$@" "$pkg=$version"
    done < "$TMP_ROOT/actions"
    while IFS= read -r arg; do set -- "$@" "$arg"; done < "$TMP_ROOT/targets"
    network_run apk_run cache download "$@" || die 'Package predownload failed; no packages were changed.'
    if [ "$SWAP_DNS" = 1 ]; then
        network_run apk_run cache download "$OLD_DNS" || die 'Cannot cache original dnsmasq for recovery.'
    fi
    # Offline solver must produce exactly the reviewed plan.
    set --
    while IFS= read -r arg; do set -- "$@" "$arg"; done < "$TMP_ROOT/targets"
    apk_run --no-network add --simulate "$@" > "$TMP_ROOT/offline-plan" 2>&1 || die 'Offline simulation failed.'
    parse_plan "$TMP_ROOT/offline-plan" > "$TMP_ROOT/offline-actions" || die 'Offline action parser failed.'
    cmp -s "$TMP_ROOT/actions" "$TMP_ROOT/offline-actions" || die 'The package plan changed during download.'
}

backup() {
    local file
    mkdir -p "$BACKUP_DIR"
    LAST_BACKUP=$(mktemp -d "$BACKUP_DIR/pw2-$(date +%Y%m%d-%H%M%S).XXXXXX")
    mkdir -p "$LAST_BACKUP/files" "$LAST_BACKUP/runtime"
    while IFS= read -r file; do
        mkdir -p "$LAST_BACKUP/files${file%/*}"
        cp -p "$file" "$LAST_BACKUP/files$file"
    done < "$TMP_ROOT/config-files"
    cp "$TMP_ROOT/config-files" "$LAST_BACKUP/config-files"
    for file in /etc/config/dhcp /etc/config/firewall /etc/config/uhttpd /etc/apk/world; do
        [ -f "$file" ] || continue
        mkdir -p "$LAST_BACKUP/files${file%/*}"
        cp -p "$file" "$LAST_BACKUP/files$file"
    done
    for file in /usr/bin/xray /usr/bin/sing-box; do
        [ ! -f "$file" ] || cp -pL "$file" "$LAST_BACKUP/runtime/"
    done
    cp "$TMP_ROOT/installed-before" "$TMP_ROOT/plan" "$TMP_ROOT/cores" "$LAST_BACKUP/"
    printf 'OpenWrt=%s\nArchitecture=%s\nScript=%s\n' "$RELEASE_FULL" "$ARCH" "$SCRIPT_VERSION" > "$LAST_BACKUP/metadata"
    info "Configuration/runtime backup: $LAST_BACKUP (not a complete APK rollback)."
}
restore_configs() {
    local file
    [ -n "$LAST_BACKUP" ] || return 0
    while IFS= read -r file; do
        mkdir -p "${file%/*}" || return 1
        cp -p "$LAST_BACKUP/files$file" "$file" || return 1
    done < "$LAST_BACKUP/config-files"
}

persist_repo() {
    local file tmp
    mkdir -p /etc/apk/keys /etc/apk/repositories.d
    for file in /etc/apk/repositories /etc/apk/repositories.d/*.list; do
        [ -f "$file" ] || continue
        grep -q openwrt-passwall-build "$file" || continue
        mkdir -p "$LAST_BACKUP/files${file%/*}"
        cp -p "$file" "$LAST_BACKUP/files$file"
        tmp="${file}.pw2-$$"
        awk '!/openwrt-passwall-build/' "$file" > "$tmp"
        chmod 0644 "$tmp"
        mv "$tmp" "$file"
    done
    # Other entries previously stored in passwall2.list must also survive.
    [ ! -f "$REPO_FILE" ] || cat "$REPO_FILE" > "$TMP_ROOT/repo-final"
    [ -f "$TMP_ROOT/repo-final" ] || : > "$TMP_ROOT/repo-final"
    cat "$TMP_ROOT/pw-repositories" >> "$TMP_ROOT/repo-final"
    cp "$TMP_ROOT/repo-final" "$REPO_FILE.tmp"
    chmod 0644 "$REPO_FILE.tmp"
    mv "$REPO_FILE.tmp" "$REPO_FILE"
    cp "$TMP_ROOT/keys/openwrt-passwall-build.pem" "$KEY_FILE.tmp"
    chmod 0644 "$KEY_FILE.tmp"
    mv "$KEY_FILE.tmp" "$KEY_FILE"
}

stop_services() {
    local svc
    for svc in passwall2 passwall2_server; do
        [ ! -x "/etc/init.d/$svc" ] || timeout 40 "/etc/init.d/$svc" stop || return 1
    done
}
maintenance() {
    /etc/init.d/passwall2 enabled >/dev/null 2>&1 && ORIGINAL_ENABLED=1 || ORIGINAL_ENABLED=0
    /etc/init.d/passwall2_server enabled >/dev/null 2>&1 && SERVER_ENABLED=1 || SERVER_ENABLED=0
    MAINTENANCE=1
    stop_services || die 'Could not stop PassWall2 before installation.'
    # OpenWrt postinst automatically starts services. Temporarily give both
    # services disabled configs, then restore the exact saved files before restart.
    cat > /etc/config/passwall2 <<'EOF'
config global
 option enabled '0'
 option socks_enabled '0'
 option acl_enable '0'
config global_haproxy
 option balancing_enable '0'
config global_delay
 option start_daemon '0'
EOF
    if [ -f /etc/config/passwall2_server ]; then
        printf "config global\n option enabled '0'\n" > /etc/config/passwall2_server
    fi
}

apply_packages() {
    local arg
    COMMIT_STARTED=1
    set --
    while IFS= read -r arg; do set -- "$@" "$arg"; done < "$TMP_ROOT/targets"
    if ! apk_run --no-network add "$@" > "$LAST_BACKUP/install.log" 2>&1; then
        cat "$LAST_BACKUP/install.log" >&2
        if [ "$SWAP_DNS" = 1 ] && [ -z "$(installed_version dnsmasq-full)" ]; then
            warn 'Restoring cached original dnsmasq.'
            apk_run --no-network add "$OLD_DNS" > "$LAST_BACKUP/dns-recovery.log" 2>&1 || warn "DNS recovery failed; inspect $LAST_BACKUP/dns-recovery.log"
        fi
        die 'APK installation failed. It was NOT retried. Keep the diagnostic files.'
    fi
    cat "$LAST_BACKUP/install.log"
    while IFS= read -r arg; do
        apk_run --no-network fix --reinstall "$arg" > "$LAST_BACKUP/fix-$arg.log" 2>&1 || die "Reinstallation of $arg failed."
    done < "$TMP_ROOT/reinstall"
    stop_services || die 'Cannot stop post-install service instances.'
    restore_configs || die 'Could not restore saved PassWall2 configuration.'
    if [ ! -s "$LAST_BACKUP/files/etc/config/passwall2" ]; then
        # A genuinely new install must receive the vendor default, not the temporary disabled config.
        cp /usr/share/passwall2/0_default_config /etc/config/passwall2
    fi
    if [ -s "$TMP_ROOT/config-hashes" ]; then
        sha256sum -c "$TMP_ROOT/config-hashes" >/dev/null || die 'Configuration preservation check failed.'
    fi
    MAINTENANCE=0
}

verify_versions() {
    local arg pkg version path actual
    while IFS= read -r arg; do
        case "$arg" in *=*) pkg=${arg%%=*}; version=${arg#*=};; *) continue;; esac
        [ "$(installed_version "$pkg")" = "$version" ] || die "Installed $pkg differs from the selected version."
    done < "$TMP_ROOT/targets"
    while IFS='|' read -r pkg path version; do
        actual=$(runtime_version "$pkg" "$path")
        [ "$actual" = "$version" ] || die "$pkg runtime is ${actual:-missing}, expected $version."
    done < "$TMP_ROOT/cores"
}

proxy_processes() {
    local entry exe
    for entry in /proc/[0-9]*/cmdline; do
        [ -r "$entry" ] || continue
        tr '\000' '\n' < "$entry" 2>/dev/null | grep -q '^/tmp/etc/passwall2/' || continue
        exe=$(readlink "${entry%/cmdline}/exe" 2>/dev/null || true)
        case "$exe" in /usr/bin/xray|/usr/bin/sing-box) printf '%s\n' "${entry%/cmdline}";; esac
    done
}
postcheck() {
    local enabled socks acl n=0 list proc exe config asset
    enabled=$(uci -q get 'passwall2.@global[0].enabled' || true)
    socks=$(uci -q get 'passwall2.@global[0].socks_enabled' || true)
    acl=$(uci -q get 'passwall2.@global[0].acl_enable' || true)
    if [ "$enabled" != 1 ] && [ "$socks" != 1 ] && [ "$acl" != 1 ]; then
        info 'Proxy is disabled in saved settings. Package/runtime verification passed; network test skipped.'
        return 0
    fi
    while [ "$n" -lt 15 ]; do
        list=$(proxy_processes)
        [ -z "$list" ] || break
        n=$((n + 1)); sleep 1
    done
    [ -n "$list" ] || die 'No running PassWall2 Xray/Sing-Box process after start.'
    sleep 3
    asset=$(uci -q get 'passwall2.@global_rules[0].v2ray_location_asset' || true)
    asset=${asset:-/usr/share/v2ray}
    for proc in $list; do
        [ -r "$proc/cmdline" ] || die 'A proxy process exited during the startup check.'
        exe=$(readlink "$proc/exe")
        config=$(tr '\000' '\n' < "$proc/cmdline" | awk 'p {print; exit} $0=="-c" || $0=="-config" {p=1}')
        [ -n "$config" ] && [ -f "$config" ] || die 'Cannot find the running proxy configuration.'
        case "$exe" in
            /usr/bin/xray)
                XRAY_LOCATION_ASSET="$asset" V2RAY_LOCATION_ASSET="$asset" timeout 30 "$exe" run -test -c "$config" >> "$LAST_BACKUP/config-test.log" 2>&1 || die 'Xray rejected its generated configuration.';;
            /usr/bin/sing-box)
                ENABLE_DEPRECATED_GEOSITE=true ENABLE_DEPRECATED_GEOIP=true timeout 30 "$exe" check -c "$config" >> "$LAST_BACKUP/config-test.log" 2>&1 || die 'Sing-Box rejected its generated configuration.';;
        esac
    done
    if [ -f /tmp/log/passwall2.log ] && grep -Eiq 'Running in no proxy mode|failed to (start|load)|invalid config|feature.*removed|exit code[^0-9]*[1-9]' /tmp/log/passwall2.log; then
        cp /tmp/log/passwall2.log "$LAST_BACKUP/passwall2.log"
        die 'PassWall2 log reports a startup/configuration failure.'
    fi
    info 'Local checks passed: expected binary versions, persistent proxy processes and valid generated configurations.'
    info 'Check Internet/DNS and your selected nodes from a LAN client. Local checks cannot prove remote server reachability.'
}

print_commands() {
    cat <<'EOF'

============================================================
Памятка команд (check ничего не устанавливает):
  sh /root/passwall2-apk-repo.sh check
  sh /root/passwall2-apk-repo.sh update
  sh /root/passwall2-apk-repo.sh update --allow-prerelease

После прошивки / для восстановления пакетов:
  sh /root/passwall2-apk-repo.sh check install
  sh /root/passwall2-apk-repo.sh install
  sh /root/passwall2-apk-repo.sh install --allow-prerelease

Текущие версии и справка:
  sh /root/passwall2-apk-repo.sh status
  sh /root/passwall2-apk-repo.sh help

--allow-prerelease разрешает только предварительный релиз.
Остальные проверки сохраняются. Пакеты берутся из репозитория.
Ошибка check требует разбора; этот список не означает,
что проверка прошла успешно или обновление разрешено.
============================================================
EOF
}

enforce_prerelease() {
    [ "$RELEASE_PRERELEASE" = 1 ] || return 0
    [ "$ALLOW_PRERELEASE" = 1 ] || die "Prerelease installation blocked. To explicitly allow it, run: sh /root/passwall2-apk-repo.sh $MODE --allow-prerelease"
    warn 'Prerelease explicitly allowed for this run. All other safety checks remain enabled.'
}

cleanup() {
    local rc="$?"
    trap - EXIT HUP INT TERM
    if [ "$MAINTENANCE" = 1 ]; then
        stop_services >/dev/null 2>&1 || true
        restore_configs || warn "Restore failed. Original configuration: $LAST_BACKUP/files/etc/config/passwall2"
    fi
    if [ "$rc" -ne 0 ] && [ "$COMMIT_STARTED" = 1 ]; then
        KEEP_TMP=1
        warn "Update incomplete. Backup/logs: $LAST_BACKUP; signed package cache: $TMP_ROOT/cache"
        warn 'No automatic APK rollback was claimed or performed. Do not restore only the old Xray against a new PassWall2.'
    fi
    if [ -n "$TMP_ROOT" ] && [ "$KEEP_TMP" = 0 ]; then rm -rf "$TMP_ROOT"; fi
    [ "$LOCKED" = 0 ] || rmdir /tmp/passwall2-apk-manager.lock 2>/dev/null || true
    if [ "$IS_CHECK" = 1 ]; then print_commands; fi
    exit "$rc"
}

status() {
    printf 'PassWall2 APK manager %s\n' "$SCRIPT_VERSION"
    local p path
    for p in luci-app-passwall2 xray-core sing-box geoview v2ray-geoip v2ray-geosite dnsmasq-full; do
        printf '%-24s %s\n' "$p" "$(installed_version "$p")"
    done
    path=$(configured_path xray /usr/bin/xray)
    printf 'Actual Xray: %s %s\n' "$path" "$(runtime_version xray-core "$path")"
}

main() {
    local command="${1:-check}" answer
    [ "$#" -eq 0 ] || shift
    ALLOW_PRERELEASE=0
    IS_CHECK=0
    case "$command" in
        help|--help|-h) [ "$#" -eq 0 ] || die 'Unexpected help arguments.'; print_commands; return;;
        status) [ "$#" -eq 0 ] || die 'Usage: status'; require_system; status; return;;
        check)
            IS_CHECK=1
            MODE="${1:-update}"
            [ "$#" -le 1 ] || die 'Usage: check [install]'
            case "$MODE" in update|install) ;; *) die 'Usage: check [install]';; esac
            ;;
        update|install)
            MODE="$command"
            case "$#" in
                0) ;;
                1) [ "$1" = --allow-prerelease ] || die 'Only --allow-prerelease is supported.'; ALLOW_PRERELEASE=1;;
                *) die 'Usage: update|install [--allow-prerelease]';;
            esac
            ;;
        *) die 'Usage: passwall2-apk-repo.sh {check [install]|update [--allow-prerelease]|install [--allow-prerelease]|status|help}';;
    esac
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    require_system
    mkdir /tmp/passwall2-apk-manager.lock 2>/dev/null || die 'Another manager is running (or its lock remains after an interrupted run).'
    LOCKED=1
    prepare
    check_idle
    snapshot_files
    select_targets
    simulate
    space_check
    info 'Safety gates passed for the package plan. This is not a guarantee against firmware/network regressions.'
    if [ "$command" = check ]; then
        if [ "$RELEASE_PRERELEASE" = 1 ]; then
            warn "Plan checked; installation requires explicit $MODE --allow-prerelease."
        fi
        return 0
    fi
    if [ ! -s "$TMP_ROOT/actions" ] && [ ! -s "$TMP_ROOT/reinstall" ] && [ "$SWAP_DNS" = 0 ]; then
        info 'Selected packages and actual core versions are already current.'
        return 0
    fi
    enforce_prerelease
    printf 'Download and apply this %s? [y/N]: ' "$MODE"
    read -r answer || return 0
    case "$answer" in y|Y|yes|YES) ;; *) info 'Cancelled.'; return 0;; esac
    prefetch
    assert_unchanged
    backup
    persist_repo
    maintenance
    apply_packages
    verify_versions
    if [ "$ORIGINAL_ENABLED" = 1 ] || [ "$MODE" = install ]; then
        /etc/init.d/passwall2 enable
    else
        /etc/init.d/passwall2 disable
    fi
    timeout 40 /etc/init.d/passwall2 start || die 'PassWall2 start failed.'
    if [ -x /etc/init.d/passwall2_server ]; then
        if [ "$SERVER_ENABLED" = 1 ] || [ "$MODE" = install ]; then
            /etc/init.d/passwall2_server enable
        else
            /etc/init.d/passwall2_server disable
        fi
        timeout 40 /etc/init.d/passwall2_server start || die 'PassWall2 server start failed.'
    fi
    postcheck
    info "Completed. Settings preserved. Backup/logs: $LAST_BACKUP"
}

# Source-only mode is for deterministic offline regression tests.
if [ "${PW2_SOURCE_ONLY:-0}" != 1 ]; then main "$@"; fi

