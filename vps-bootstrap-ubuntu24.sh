#!/usr/bin/env bash
set -Eeuo pipefail

# Ubuntu 24.04 LTS VPS bootstrap.
# Does not reboot automatically.
# Does not add SSH keys: /root/.ssh/authorized_keys must already contain your public key.

SSH_PORT="${SSH_PORT:-ssh}"
IGNORE_IPS="${IGNORE_IPS:-127.0.0.1/8 ::1 84.22.133.232 95.182.112.211 185.230.190.12}"
UBUNTU_PRO_TOKEN="${UBUNTU_PRO_TOKEN:-}"
RUN_UPGRADE=1

WARNINGS=()
FAILED_CHECKS=()
PASSED_CHECKS=()

log() {
  printf '\n\033[1;32m==> %s\033[0m\n' "$*"
}

warn() {
  local msg="$*"
  WARNINGS+=("$msg")
  printf '\n\033[1;33mWARN: %s\033[0m\n' "$msg" >&2
}

fail_check() {
  FAILED_CHECKS+=("$1")
}

pass_check() {
  PASSED_CHECKS+=("$1")
}

die() {
  printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  sudo bash vps-bootstrap-ubuntu24.sh [options]

Options:
  --ssh-port PORT      SSH port for fail2ban jail. Default: ssh.
  --no-upgrade         Skip apt full-upgrade.
  -h, --help           Show help.

Environment overrides:
  SSH_PORT='22'
  IGNORE_IPS='127.0.0.1/8 ::1 x.x.x.x'
  UBUNTU_PRO_TOKEN='your-token'
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-port)
      SSH_PORT="${2:-}"
      shift 2
      ;;
    --no-upgrade)
      RUN_UPGRADE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"
}

check_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  . /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || die "This script is intended for Ubuntu 24.04 LTS; detected: ${PRETTY_NAME:-unknown}"
  [[ "${VERSION_ID:-}" == "24.04" ]] || die "This script is intended for Ubuntu 24.04 LTS; detected: ${PRETTY_NAME:-unknown}"

  pass_check "OS: ${PRETTY_NAME:-Ubuntu 24.04}"
}

backup_file() {
  local f="$1"
  if [[ -e "$f" || -L "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

check_root_authorized_keys() {
  log "Check root SSH public key before password login is disabled"

  if [[ ! -s /root/.ssh/authorized_keys ]]; then
    die "No /root/.ssh/authorized_keys found or file is empty. Add your public key first, then rerun the script."
  fi

  if ! grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256)[[:space:]]+' /root/.ssh/authorized_keys; then
    die "/root/.ssh/authorized_keys exists, but no valid-looking SSH public key was found."
  fi

  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys
  chown -R root:root /root/.ssh

  pass_check "Root SSH authorized_keys exists and permissions were normalized"
}

apt_upgrade_and_install() {
  log "APT update, optional full-upgrade, and base packages"

  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  apt-get -o DPkg::Lock::Timeout=600 update

  if [[ "$RUN_UPGRADE" -eq 1 ]]; then
    apt-get -o DPkg::Lock::Timeout=600 \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      -y full-upgrade
  else
    warn "APT full-upgrade was skipped by --no-upgrade"
  fi

  apt-get -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    -y install \
      ca-certificates \
      curl \
      fail2ban \
      nftables \
      systemd-resolved \
      unattended-upgrades \
      ubuntu-advantage-tools

  pass_check "APT packages installed"
}

configure_ssh() {
  log "Configure SSH hardening via sshd_config.d drop-in"

  backup_file /etc/ssh/sshd_config
  install -d -m 755 /etc/ssh/sshd_config.d

  # OpenSSH uses the first obtained value. Put Include at the very top so our drop-in wins.
  if ! head -n 20 /etc/ssh/sshd_config | grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf'; then
    local tmp
    tmp="$(mktemp)"
    {
      echo 'Include /etc/ssh/sshd_config.d/*.conf'
      cat /etc/ssh/sshd_config
    } > "$tmp"
    cat "$tmp" > /etc/ssh/sshd_config
    rm -f "$tmp"
  fi

  cat > /etc/ssh/sshd_config.d/00-proms-hardening.conf <<'EOF'
# Managed by vps-bootstrap-ubuntu24.sh
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
X11Forwarding no
EOF

  sshd -t || die "sshd config validation failed; SSH was not reloaded"

  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || die "Failed to reload SSH service"

  local effective
  effective="$(sshd -T 2>/dev/null || true)"

  grep -q '^pubkeyauthentication yes$' <<<"$effective" && \
  grep -q '^passwordauthentication no$' <<<"$effective" && \
  grep -q '^kbdinteractiveauthentication no$' <<<"$effective" && \
  grep -q '^permitrootlogin without-password$\|^permitrootlogin prohibit-password$' <<<"$effective" && \
    pass_check "SSH hardened: pubkey only, password disabled" || \
    fail_check "SSH effective config does not match expected hardening; check: sshd -T"
}

configure_resolved() {
  log "Configure systemd-resolved with global DNS-over-TLS"

  backup_file /etc/systemd/resolved.conf
  install -d -m 755 /etc/systemd/resolved.conf.d

  cat > /etc/systemd/resolved.conf.d/90-proms-dot.conf <<'EOF'
# Managed by vps-bootstrap-ubuntu24.sh
[Resolve]
DNS=
DNS=1.1.1.1#one.one.one.one 1.0.0.1#one.one.one.one 8.8.8.8#dns.google 8.8.4.4#dns.google
FallbackDNS=
Domains=
Domains=~.
DNSOverTLS=yes
DNSSEC=no
LLMNR=no
MulticastDNS=no
Cache=yes
DNSStubListener=yes
EOF

  if [[ ! -L /etc/resolv.conf ]] || [[ "$(readlink -f /etc/resolv.conf || true)" != "/run/systemd/resolve/stub-resolv.conf" ]]; then
    backup_file /etc/resolv.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  fi

  systemctl enable --now systemd-resolved
  systemctl restart systemd-resolved

  cat > /usr/local/sbin/disable-link-dns.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ARG="${1:-auto}"

detect_uplink_iface() {
  {
    ip -o -4 route show default 2>/dev/null || true
    ip -o -6 route show default 2>/dev/null || true
  } | awk '
    {
      for (i=1; i<=NF; i++) {
        if ($i == "dev") {
          dev = $(i+1)
          if (dev !~ /^(lo|wg|wg[0-9]+|tun|tun[0-9]+|tap|tap[0-9]+|docker|br-|veth|tailscale|zt|warp|mihomo|xray)/) {
            print dev
            exit
          }
        }
      }
    }'
}

IFACE="$ARG"

if [[ "$IFACE" == "auto" || -z "$IFACE" ]]; then
  IFACE="$(detect_uplink_iface || true)"
fi

if [[ -z "$IFACE" && -d /sys/class/net/eth0 ]]; then
  IFACE="eth0"
fi

if [[ -z "$IFACE" ]]; then
  echo "No suitable uplink interface detected; skipping per-link DNS disable"
  exit 0
fi

echo "Selected interface: $IFACE"

for _ in {1..30}; do
  if resolvectl status "$IFACE" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! resolvectl status "$IFACE" >/dev/null 2>&1; then
  echo "Interface $IFACE is not visible to systemd-resolved; skipping"
  exit 0
fi

resolvectl dns "$IFACE" "" || true
resolvectl domain "$IFACE" "" || true
resolvectl default-route "$IFACE" false || true
resolvectl flush-caches || true

echo "Per-link DNS disabled for $IFACE"
EOF

  chmod 755 /usr/local/sbin/disable-link-dns.sh

  cat > /etc/systemd/system/disable-link-dns.service <<'EOF'
[Unit]
Description=Disable provider per-link DNS so global systemd-resolved DNS is used
Requires=systemd-resolved.service
After=systemd-resolved.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/disable-link-dns.sh auto
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  if systemctl enable --now disable-link-dns.service; then
    pass_check "Provider per-link DNS disable service installed and started"
  else
    fail_check "disable-link-dns.service failed; check: systemctl status disable-link-dns.service"
  fi

  if resolvectl query ubuntu.com >/dev/null 2>&1; then
    pass_check "DNS test via systemd-resolved succeeded"
  else
    fail_check "DNS test failed; check DoT/TCP 853 reachability and resolvectl status"
  fi
}

configure_sysctl() {
  log "Configure UDP buffers and TCP Fast Open"

  cat > /etc/sysctl.d/99-proms-network.conf <<'EOF'
# Managed by vps-bootstrap-ubuntu24.sh
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_fastopen=3
EOF

  if sysctl -p /etc/sysctl.d/99-proms-network.conf; then
    pass_check "sysctl network tuning applied"
  else
    fail_check "sysctl network tuning failed"
  fi

  if command -v nginx >/dev/null 2>&1; then
    if nginx -t && systemctl reload nginx; then
      pass_check "Nginx config test and reload succeeded"
    else
      fail_check "Nginx exists but test/reload failed"
    fi
  else
    warn "Nginx is not installed yet; kernel TCP Fast Open is enabled, but nginx listen fastopen must be configured later if needed"
  fi
}

configure_unattended_upgrades() {
  log "Configure unattended upgrades without automatic reboot"

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  cat > /etc/apt/apt.conf.d/90-proms-unattended-upgrades <<'EOF'
// Managed by vps-bootstrap-ubuntu24.sh
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
EOF

  systemctl enable --now unattended-upgrades

  if systemctl is-active --quiet unattended-upgrades; then
    pass_check "unattended-upgrades enabled; automatic reboot disabled"
  else
    fail_check "unattended-upgrades is not active"
  fi
}

configure_ubuntu_pro() {
  log "Ubuntu Pro attach and Livepatch"

  local token="${UBUNTU_PRO_TOKEN:-}"

  if pro status 2>/dev/null | grep -qi "This machine is attached\|Subscription:"; then
    pass_check "Ubuntu Pro already attached"
    pro status || true
    return 0
  fi

  if [[ -z "$token" && -t 0 ]]; then
    read -rsp "Ubuntu Pro token (Enter to skip): " token
    echo
  fi

  if [[ -z "$token" ]]; then
    warn "Ubuntu Pro token was not provided; Ubuntu Pro/Livepatch skipped"
    return 0
  fi

  if pro attach "$token"; then
    pass_check "Ubuntu Pro attached"
  else
    fail_check "Ubuntu Pro attach failed"
    return 0
  fi

  if pro enable livepatch >/dev/null 2>&1 || pro status 2>/dev/null | grep -Eqi '^livepatch[[:space:]]+yes[[:space:]]+enabled'; then
    pass_check "Ubuntu Livepatch enabled or already enabled"
  else
    warn "Livepatch was not confirmed as enabled; check: pro status"
  fi

  pro status || true
}

configure_fail2ban() {
  log "Configure fail2ban for SSH"

  install -d -m 755 /etc/fail2ban/jail.d

  systemctl enable --now nftables >/dev/null 2>&1 || true

  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[DEFAULT]
ignoreip = $IGNORE_IPS
bantime = 4w
findtime = 120m
maxretry = 3
banaction = nftables[type=multiport]
banaction_allports = nftables[type=allports]
backend = systemd
usedns = no

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd[mode=aggressive]

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
backend = auto
banaction = %(banaction_allports)s
findtime = 90d
bantime = 26w
maxretry = 2
EOF

  if fail2ban-server -t; then
    pass_check "fail2ban config validation succeeded"
  else
    fail_check "fail2ban config validation failed"
    return 0
  fi

  systemctl enable --now fail2ban
  fail2ban-client reload || true

  if fail2ban-client status sshd >/dev/null 2>&1; then
    pass_check "fail2ban sshd jail is active"
  else
    fail_check "fail2ban sshd jail is not active"
  fi
}

final_report() {
  log "Final report"

  echo "Passed checks:"
  if [[ ${#PASSED_CHECKS[@]} -eq 0 ]]; then
    echo "  - none"
  else
    printf '  - %s\n' "${PASSED_CHECKS[@]}"
  fi

  echo
  echo "Warnings:"
  if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    echo "  - none"
  else
    printf '  - %s\n' "${WARNINGS[@]}"
  fi

  echo
  echo "Failed checks:"
  if [[ ${#FAILED_CHECKS[@]} -eq 0 ]]; then
    echo "  - none"
  else
    printf '  - %s\n' "${FAILED_CHECKS[@]}"
  fi

  echo
  echo "Useful status commands:"
  echo "  sshd -T | egrep 'pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin'"
  echo "  resolvectl status"
  echo "  resolvectl query ubuntu.com"
  echo "  systemctl status disable-link-dns.service --no-pager"
  echo "  fail2ban-client status sshd"
  echo "  pro status"

  echo
  if [[ -f /run/reboot-required ]]; then
    echo "Reboot required: YES. Run manually: sudo reboot"
  else
    echo "Reboot required: no marker found. Manual reboot is still OK after first full-upgrade if you want a clean start."
  fi

  echo
  echo "Important: do not close this SSH session until you verify a new SSH login with your key."

  if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
    return 1
  fi
}

main() {
  require_root
  check_os
  check_root_authorized_keys
  apt_upgrade_and_install
  configure_ssh
  configure_resolved
  configure_sysctl
  configure_unattended_upgrades
  configure_ubuntu_pro
  configure_fail2ban
  final_report
}

main "$@"
