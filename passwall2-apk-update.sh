#!/bin/sh
set -eu

# =========================================================
# PassWall2 APK updater for OpenWrt 25.12+ (APK)
#
# Supports:
# - fresh install if PassWall2 is absent
# - upgrade if GitHub/custom latest is newer
# - skip if same version is already installed
# - optional reinstall of same version
#
# Optional env overrides:
#   ARCH=aarch64_cortex-a53
#   REPO=Openwrt-Passwall/openwrt-passwall2
#   API_URL=https://api.github.com/repos/.../releases/latest
#   BASE_URL=https://github.com/.../releases/download
#   LATEST_URL=https://your.domain/passwall2/latest.txt
#   FORCE_REINSTALL=1   # force reinstall when versions match
# =========================================================

ARCH="${ARCH:-aarch64_cortex-a53}"
REPO="${REPO:-Openwrt-Passwall/openwrt-passwall2}"
API_URL="${API_URL:-https://api.github.com/repos/${REPO}/releases/latest}"
BASE_URL="${BASE_URL:-https://github.com/${REPO}/releases/download}"
LATEST_URL="${LATEST_URL:-}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"

WORKDIR="$(mktemp -d /tmp/passwall2-update.XXXXXX)"
TS="$(date +%F-%H%M%S)"

TARGET_PKGS="luci-app-passwall2 xray-core hysteria geoview tcping v2ray-geoip v2ray-geosite"

BEFORE_FILE="$WORKDIR/before.txt"
AFTER_FILE="$WORKDIR/after.txt"

ACTION="unknown"
ACTION_NOTE=""
SOURCE_DESC=""
TAG=""
APK_VER=""

BACKUP_PW="not present"
BACKUP_FW="not present"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

line() {
  printf '%s\n' "========================================================================"
}

subline() {
  printf '%s\n' "------------------------------------------------------------------------"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

installed_ver() {
  apk list --installed --manifest 2>/dev/null | awk -v p="$1" '$1==p{print $2; exit}'
}

snapshot_versions() {
  _out="$1"
  : > "$_out"
  for _pkg in $TARGET_PKGS; do
    _ver="$(installed_ver "$_pkg" || true)"
    [ -n "${_ver:-}" ] || _ver="-"
    printf '%s|%s\n' "$_pkg" "$_ver" >> "$_out"
  done
}

snap_ver() {
  _pkg="$1"
  _file="$2"
  awk -F'|' -v p="$_pkg" '$1==p{print $2; exit}' "$_file" 2>/dev/null
}

print_summary() {
  line
  printf ' PassWall2 APK updater summary\n'
  line
  printf 'Action           : %s\n' "$ACTION"
  printf 'Source           : %s\n' "$SOURCE_DESC"
  printf 'Release tag      : %s\n' "${TAG:-unknown}"
  printf 'Target APK ver   : %s\n' "${APK_VER:-unknown}"
  printf 'Architecture     : %s\n' "$ARCH"
  printf 'Base URL         : %s\n' "$BASE_URL"
  printf 'PassWall2 backup : %s\n' "$BACKUP_PW"
  printf 'Firewall backup  : %s\n' "$BACKUP_FW"
  subline
  printf '%-20s %-18s %-18s %-14s\n' "Package" "Before" "After" "Status"
  subline

  for _pkg in $TARGET_PKGS; do
    _before="$(snap_ver "$_pkg" "$BEFORE_FILE")"
    _after="$(snap_ver "$_pkg" "$AFTER_FILE")"
    [ -n "${_before:-}" ] || _before="-"
    [ -n "${_after:-}" ] || _after="-"

    if [ "$_before" = "-" ] && [ "$_after" != "-" ]; then
      _status="INSTALLED"
    elif [ "$_before" != "-" ] && [ "$_after" = "-" ]; then
      _status="MISSING"
    elif [ "$_before" = "$_after" ]; then
      case "$ACTION" in
        "REINSTALL SAME")
          _status="REINSTALLED"
          ;;
        "SKIP SAME")
          _status="SKIPPED"
          ;;
        *)
          _status="UNCHANGED"
          ;;
      esac
    else
      _status="UPDATED"
    fi

    printf '%-20s %-18s %-18s %-14s\n' "$_pkg" "$_before" "$_after" "$_status"
  done

  line
  printf 'Note             : %s\n' "$ACTION_NOTE"
  printf 'Services         : rpcd/firewall/passwall2 restart attempted\n'
  printf 'Logs             : /tmp/log/passwall2.log / /tmp/log/passwall2_server.log\n'
  line
}

echo "[1/10] Update APK indexes..."
apk update

echo "[2/10] Install required base tools from official repos..."
apk add ca-bundle ca-certificates wget-ssl unzip curl ip-full \
  coreutils coreutils-base64 coreutils-nohup resolveip

echo "[3/10] Backup configs if present..."
if [ -f /etc/config/passwall2 ]; then
  BACKUP_PW="/root/passwall2.backup.$TS"
  cp /etc/config/passwall2 "$BACKUP_PW"
fi

if [ -f /etc/config/firewall ]; then
  BACKUP_FW="/root/firewall.backup.$TS"
  cp /etc/config/firewall "$BACKUP_FW"
fi

echo "[4/10] Snapshot installed package versions..."
snapshot_versions "$BEFORE_FILE"

echo "[5/10] Detect latest PassWall2 release..."
if [ -n "$LATEST_URL" ]; then
  TAG="$(wget -qO- "$LATEST_URL" | tr -d '\r\n[:space:]')"
  SOURCE_DESC="Custom latest URL"
else
  JSON="$(wget -qO- "$API_URL" | tr -d '\n')"
  TAG="$(printf '%s' "$JSON" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  SOURCE_DESC="GitHub Releases API"
fi

[ -n "${TAG:-}" ] || die "Failed to detect latest PassWall2 tag"

APK_VER="${TAG%-*}-r${TAG##*-}"

echo "Latest tag : $TAG"
echo "APK ver    : $APK_VER"
echo "Arch       : $ARCH"

INSTALLED_MAIN="$(installed_ver luci-app-passwall2 || true)"

if [ -z "${INSTALLED_MAIN:-}" ] || [ "$INSTALLED_MAIN" = "-" ]; then
  ACTION="FRESH INSTALL"
  ACTION_NOTE="PassWall2 was not installed; fresh installation performed."
else
  CMP="$(apk version -t "$INSTALLED_MAIN" "$APK_VER" 2>/dev/null || true)"

  case "$CMP" in
    '<')
      ACTION="UPGRADE"
      ACTION_NOTE="Installed PassWall2 was older than target release."
      ;;
    '=')
      if [ "$FORCE_REINSTALL" = "1" ]; then
        ACTION="REINSTALL SAME"
        ACTION_NOTE="Versions matched, but reinstall was forced via FORCE_REINSTALL=1."
      else
        if [ -t 0 ]; then
          echo
          echo "Installed PassWall2 version : $INSTALLED_MAIN"
          echo "Latest available version    : $APK_VER"
          printf "Versions match. Reinstall same version anyway? [y/N]: "
          read -r ANSWER
          case "${ANSWER:-N}" in
            y|Y|yes|YES)
              ACTION="REINSTALL SAME"
              ACTION_NOTE="Versions matched; reinstall was confirmed by user."
              ;;
            *)
              ACTION="SKIP SAME"
              ACTION_NOTE="Latest version is already installed; installation step was skipped."
              cp "$BEFORE_FILE" "$AFTER_FILE"
              print_summary
              exit 0
              ;;
          esac
        else
          ACTION="SKIP SAME"
          ACTION_NOTE="Latest version is already installed; non-interactive run skipped reinstall."
          cp "$BEFORE_FILE" "$AFTER_FILE"
          print_summary
          exit 0
        fi
      fi
      ;;
    '>')
      ACTION="ABORT NEWER INSTALLED"
      ACTION_NOTE="Installed PassWall2 is newer than remote latest; script aborted to avoid downgrade."
      cp "$BEFORE_FILE" "$AFTER_FILE"
      print_summary
      exit 1
      ;;
    *)
      die "Unexpected version compare result: ${CMP:-empty}"
      ;;
  esac
fi

mkdir -p "$WORKDIR/pkgs"

echo "[6/10] Download LuCI APK..."
wget -O "$WORKDIR/luci-app-passwall2-${APK_VER}.apk" \
  "$BASE_URL/${TAG}/luci-app-passwall2-${APK_VER}.apk"

echo "[7/10] Download package bundle..."
wget -O "$WORKDIR/passwall_packages_apk_${ARCH}.zip" \
  "$BASE_URL/${TAG}/passwall_packages_apk_${ARCH}.zip"

echo "[8/10] Unpack package bundle..."
unzip -oq "$WORKDIR/passwall_packages_apk_${ARCH}.zip" -d "$WORKDIR/pkgs"

ls "$WORKDIR"/pkgs/xray-core-*.apk >/dev/null 2>&1 || die "xray-core package not found in bundle"
ls "$WORKDIR"/pkgs/hysteria-*.apk >/dev/null 2>&1 || die "hysteria package not found in bundle"
ls "$WORKDIR"/pkgs/geoview-*.apk >/dev/null 2>&1 || die "geoview package not found in bundle"
ls "$WORKDIR"/pkgs/tcping-*.apk >/dev/null 2>&1 || die "tcping package not found in bundle"
ls "$WORKDIR"/pkgs/v2ray-geoip-*.apk >/dev/null 2>&1 || die "v2ray-geoip package not found in bundle"
ls "$WORKDIR"/pkgs/v2ray-geosite-*.apk >/dev/null 2>&1 || die "v2ray-geosite package not found in bundle"

echo "[9/10] Install/update PassWall2 minimal stack..."
apk add --allow-untrusted \
  "$WORKDIR/luci-app-passwall2-${APK_VER}.apk" \
  "$WORKDIR"/pkgs/xray-core-*.apk \
  "$WORKDIR"/pkgs/hysteria-*.apk \
  "$WORKDIR"/pkgs/geoview-*.apk \
  "$WORKDIR"/pkgs/tcping-*.apk \
  "$WORKDIR"/pkgs/v2ray-geoip-*.apk \
  "$WORKDIR"/pkgs/v2ray-geosite-*.apk

echo "[10/10] Fix fw4 legacy flags and restart services..."
uci -q delete firewall.passwall2.reload || true
uci -q delete firewall.passwall2_server.reload || true
uci commit firewall

/etc/init.d/rpcd restart
/etc/init.d/firewall restart
/etc/init.d/passwall2 enable || true
/etc/init.d/passwall2 restart || /etc/init.d/passwall2 start || true

snapshot_versions "$AFTER_FILE"
print_summary
