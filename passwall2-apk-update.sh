#!/bin/sh
set -eu

ARCH="${ARCH:-aarch64_cortex-a53}"
REPO="${REPO:-Openwrt-Passwall/openwrt-passwall2}"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"
WORKDIR="$(mktemp -d /tmp/passwall2-update.XXXXXX)"
TS="$(date +%F-%H%M%S)"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

echo "[1/9] Update APK indexes..."
apk update

echo "[2/9] Install required base tools from official repos..."
apk add ca-bundle ca-certificates wget-ssl unzip curl ip-full \
  coreutils coreutils-base64 coreutils-nohup resolveip

echo "[3/9] Backup configs if present..."
[ -f /etc/config/passwall2 ] && cp /etc/config/passwall2 "/root/passwall2.backup.$TS"
[ -f /etc/config/firewall ]  && cp /etc/config/firewall  "/root/firewall.backup.$TS"

echo "[4/9] Detect latest PassWall2 release..."
JSON="$(wget -qO- "$API_URL" | tr -d '\n')"
TAG="$(printf '%s' "$JSON" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

if [ -z "${TAG:-}" ]; then
  echo "ERROR: Failed to detect latest PassWall2 tag from GitHub API"
  exit 1
fi

APK_VER="${TAG%-*}-r${TAG##*-}"

echo "Latest tag: $TAG"
echo "APK version: $APK_VER"
echo "Arch bundle: $ARCH"

mkdir -p "$WORKDIR/pkgs"

echo "[5/9] Download LuCI APK..."
wget -O "$WORKDIR/luci-app-passwall2-${APK_VER}.apk" \
  "https://github.com/${REPO}/releases/download/${TAG}/luci-app-passwall2-${APK_VER}.apk"

echo "[6/9] Download package bundle..."
wget -O "$WORKDIR/passwall_packages_apk_${ARCH}.zip" \
  "https://github.com/${REPO}/releases/download/${TAG}/passwall_packages_apk_${ARCH}.zip"

echo "[7/9] Unpack package bundle..."
unzip -oq "$WORKDIR/passwall_packages_apk_${ARCH}.zip" -d "$WORKDIR/pkgs"

echo "[8/9] Install or update PassWall2 minimal stack..."
apk add --allow-untrusted \
  "$WORKDIR/luci-app-passwall2-${APK_VER}.apk" \
  "$WORKDIR"/pkgs/xray-core-*.apk \
  "$WORKDIR"/pkgs/hysteria-*.apk \
  "$WORKDIR"/pkgs/geoview-*.apk \
  "$WORKDIR"/pkgs/tcping-*.apk \
  "$WORKDIR"/pkgs/v2ray-geoip-*.apk \
  "$WORKDIR"/pkgs/v2ray-geosite-*.apk

echo "[9/9] Fix fw4 legacy flags and restart services..."
uci -q delete firewall.passwall2.reload || true
uci -q delete firewall.passwall2_server.reload || true
uci commit firewall

/etc/init.d/rpcd restart
/etc/init.d/firewall restart
/etc/init.d/passwall2 enable || true
/etc/init.d/passwall2 restart || /etc/init.d/passwall2 start || true

echo
echo "Installed package set:"
apk info | grep -E 'luci-app-passwall2|xray-core|hysteria|geoview|tcping|v2ray-geoip|v2ray-geosite' || true

echo
echo "Done."
