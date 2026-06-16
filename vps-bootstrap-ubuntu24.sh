#!/usr/bin/env bash
set -Eeuo pipefail

# Ubuntu 24.04 LTS VPS bootstrap.
# Target: safe SSH hardening, DNS-over-TLS, Ubuntu Pro/Livepatch, unattended upgrades with 04:38 reboot,
# fail2ban, basic network tuning for proxy workloads.
# Requirements: run as root; /root/.ssh/authorized_keys must already contain your public key.

TIMEZONE="${TIMEZONE:-Europe/Moscow}"
SSH_PORT="${SSH_PORT:-ssh}"
IGNORE_IPS="${IGNORE_IPS:-127.0.0.1/8 ::1 84.22.133.232 95.182.112.211 185.230.190.12}"
UBUNTU_PRO_TOKEN="${UBUNTU_PRO_TOKEN:-}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:38}"
RUN_UPGRADE=1

WARNINGS=()
FAILED_CHECKS=()
PASSED_CHECKS=()

trap 'echo; echo "ERROR at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

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
  --ssh-port PORT        SSH port for fail2ban jail. Default: ssh.
  --no-upgrade           Skip initial full upgrade and cleanup.
  -h, --help             Show help.

Environment overrides:
  TIMEZONE='Europe/Moscow'
  AUTO_REBOOT_TIME='04:38'
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

backup_file() {
  local f="$1"
  if [[ -e "$f" || -L "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

check_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  . /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || die "This script is intended for Ubuntu 24.04 LTS; detected: ${PRETTY_NAME:-unknown}"
  [[ "${VERSION_ID:-}" == "24.04" ]] || die "This script is intended for Ubuntu 24.04 LTS; detected: ${PRETTY_NAME:-unknown}"

  pass_check "OS: ${PRETTY_NAME:-Ubuntu 24.04}"
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

apt_update() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt-get -o DPkg::Lock::Timeout=600 update
}

apt_install_base_packages() {
  log "APT update and install base packages"

  apt_update

  apt-get -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    -y install \
      ca-certificates \
      curl \
      tzdata \
      openssh-server \
      systemd-resolved \
      unattended-upgrades \
      ubuntu-pro-client \
      fail2ban \
      nftables

  pass_check "Base packages installed"
}

set_timezone() {
  log "Set server timezone to ${TIMEZONE}"

  if [[ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    die "Timezone ${TIMEZONE} does not exist under /usr/share/zoneinfo"
  fi

  timedatectl set-timezone "$TIMEZONE"
  timedatectl set-ntp true || true

  # Keep /etc/timezone in sync for tools that still read it directly.
  echo "$TIMEZONE" > /etc/timezone
  dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

  if timedatectl status | grep -q "Time zone: ${TIMEZONE}"; then
    pass_check "Timezone set to ${TIMEZONE}"
  else
    fail_check "Timezone was not confirmed as ${TIMEZONE}; check: timedatectl status"
  fi
}

configure_ubuntu_pro() {
  log "Ubuntu Pro attach and Livepatch"

  local token="${UBUNTU_PRO_TOKEN:-}"

  if command -v pro >/dev/null 2>&1 && pro status 2>/dev/null | grep -Eqi 'Subscription:|This machine is attached|Account:'; then
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

  if pro enable livepatch >/dev/null 2>&1 || pro status 2>/dev/null | grep -Eiq '^livepatch[[:space:]]+yes[[:space:]]+enabled'; then
    pass_check "Ubuntu Livepatch enabled or already enabled"
  else
    warn "Livepatch was not confirmed as enabled; check: pro status"
  fi

  pro status || true
}

protect_manual_packages() {
  log "Mark critical packages as manually installed before autoremove"

  local pkgs=(
    openssh-server
    systemd
    systemd-sysv
    systemd-resolved
    ubuntu-minimal
    ubuntu-server
    cloud-init
    netplan.io
    sudo
    ca-certificates
    curl
    tzdata
    ubuntu-pro-client
    unattended-upgrades
    fail2ban
    nftables
  )

  local pkg
  for pkg in "${pkgs[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      apt-mark manual "$pkg" >/dev/null 2>&1 || true
    fi
  done

  pass_check "Critical installed packages marked manual where present"
}

full_upgrade_and_cleanup() {
  log "Full upgrade and cleanup"

  if [[ "$RUN_UPGRADE" -ne 1 ]]; then
    warn "Initial full-upgrade and cleanup were skipped by --no-upgrade"
    return 0
  fi

  apt_update

  apt-get -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    -y dist-upgrade

  protect_manual_packages

  apt-get -o DPkg::Lock::Timeout=600 -y autoremove --purge
  apt-get -o DPkg::Lock::Timeout=600 -y autoclean

  pass_check "Full upgrade completed; autoremove --purge and autoclean completed"
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

  if grep -q '^pubkeyauthentication yes$' <<<"$effective" && \
     grep -q '^passwordauthentication no$' <<<"$effective" && \
     grep -q '^kbdinteractiveauthentication no$' <<<"$effective" && \
     grep -Eq '^permitrootlogin (without-password|prohibit-password)$' <<<"$effective"; then
    pass_check "SSH hardened: public key auth only; password login disabled"
  else
    fail_check "SSH effective config does not match expected hardening; check: sshd -T"
  fi
}

configure_resolved() {
  log "Configure systemd-resolved with strict global DNS-over-TLS"

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

  resolvectl flush-caches || true

  if resolvectl query ubuntu.com >/dev/null 2>&1 && resolvectl query cloudflare.com >/dev/null 2>&1; then
    pass_check "DNS tests via systemd-resolved succeeded"
  else
    fail_check "DNS test failed; strict DoT may be blocked or unreachable; check: resolvectl status"
  fi
}

configure_sysctl() {
  log "Configure UDP buffers, TCP Fast Open, and BBR if available"

  cat > /etc/sysctl.d/99-proms-network.conf <<'EOF'
# Managed by vps-bootstrap-ubuntu24.sh

# UDP buffers for QUIC/Hysteria-like transports.
net.core.rmem_max=16777216
net.core.wmem_max=16777216

# 3 = client-side + server-side TCP Fast Open support at kernel level.
net.ipv4.tcp_fastopen=3
EOF

  modprobe tcp_bbr 2>/dev/null || true

  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    cat >> /etc/sysctl.d/99-proms-network.conf <<'EOF'

# TCP BBR for proxy workloads when supported by the kernel.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    pass_check "BBR is available and configured"
  else
    warn "BBR is not available in this kernel; BBR tuning skipped"
  fi

  if sysctl -p /etc/sysctl.d/99-proms-network.conf; then
    pass_check "sysctl network tuning applied"
  else
    fail_check "sysctl network tuning failed"
  fi
}

configure_unattended_upgrades() {
  log "Configure unattended upgrades with automatic reboot at ${AUTO_REBOOT_TIME} ${TIMEZONE}"

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  cat > /etc/apt/apt.conf.d/90-proms-unattended-upgrades <<EOF
// Managed by vps-bootstrap-ubuntu24.sh
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "${AUTO_REBOOT_TIME}";
EOF

  systemctl enable --now unattended-upgrades

  if systemctl is-active --quiet unattended-upgrades; then
    pass_check "unattended-upgrades enabled; automatic reboot set to ${AUTO_REBOOT_TIME} ${TIMEZONE}"
  else
    fail_check "unattended-upgrades is not active"
  fi
}

configure_fail2ban() {
  log "Configure fail2ban for SSH"

  install -d -m 755 /etc/fail2ban/jail.d

  cat > /etc/fail2ban/fail2ban.local <<'EOF'
[Definition]
logtarget = /var/log/fail2ban.log
dbpurgeage = 180d
EOF

  touch /var/log/fail2ban.log
  chmod 640 /var/log/fail2ban.log || true

  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[DEFAULT]
ignoreip = ${IGNORE_IPS}
bantime = 4w
findtime = 120m
maxretry = 3
banaction = nftables[type=multiport]
banaction_allports = nftables[type=allports]
backend = systemd
usedns = no

[sshd]
enabled = true
port = ${SSH_PORT}
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

  echo "System:"
  echo "  Hostname: $(hostname -f 2>/dev/null || hostname)"
  echo "  Kernel: $(uname -r)"
  echo "  Time: $(date '+%Y-%m-%d %H:%M:%S %Z %z')"
  timedatectl status --no-pager 2>/dev/null | sed 's/^/  /' || true

  echo
  echo "SSH effective settings:"
  sshd -T 2>/dev/null | awk '/^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|x11forwarding) / {print "  " $0}' || true

  echo
  echo "DNS summary:"
  resolvectl dns 2>/dev/null | sed 's/^/  /' || true
  resolvectl domain 2>/dev/null | sed 's/^/  /' || true

  echo
  echo "Network sysctl:"
  sysctl net.core.rmem_max net.core.wmem_max net.ipv4.tcp_fastopen net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null | sed 's/^/  /' || true

  echo
  echo "Update services:"
  systemctl is-enabled unattended-upgrades 2>/dev/null | sed 's/^/  unattended-upgrades enabled: /' || true
  systemctl is-active unattended-upgrades 2>/dev/null | sed 's/^/  unattended-upgrades active: /' || true
  echo "  automatic reboot time: ${AUTO_REBOOT_TIME} (${TIMEZONE})"

  echo
  echo "Ubuntu Pro status:"
  pro status 2>/dev/null | sed 's/^/  /' || true

  echo
  echo "fail2ban status:"
  fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || true

  echo
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
  echo "Useful commands:"
  echo "  sshd -T | egrep 'pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin'"
  echo "  resolvectl status"
  echo "  resolvectl query ubuntu.com"
  echo "  systemctl status disable-link-dns.service --no-pager"
  echo "  fail2ban-client status sshd"
  echo "  pro status"
  echo "  systemctl list-timers 'apt*' --all"

  echo
  if [[ -f /run/reboot-required ]]; then
    echo "Reboot required: YES. Run manually now if convenient: sudo reboot"
  else
    echo "Reboot required: no marker found. Manual reboot is still recommended after first bootstrap on old VPS images."
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
  apt_install_base_packages
  set_timezone
  configure_ubuntu_pro
  full_upgrade_and_cleanup
  configure_ssh
  configure_resolved
  configure_sysctl
  configure_unattended_upgrades
  configure_fail2ban
  final_report
}

main "$@"
