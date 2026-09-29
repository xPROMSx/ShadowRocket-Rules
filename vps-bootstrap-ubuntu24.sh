#!/usr/bin/env bash
set -Eeuo pipefail
# Never trace the subscription token, even when invoked with bash -x.
set +x
umask 022
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Ubuntu 24.04 LTS VPS bootstrap.
# Target: safe SSH hardening, DNS-over-TLS, Ubuntu Pro/Livepatch, unattended upgrades with 04:38 reboot,
# fail2ban, basic network tuning for proxy workloads.
# Requirements: run as root; /root/.ssh/authorized_keys must already contain your public key.

TIMEZONE="${TIMEZONE:-Europe/Moscow}"
SSH_PORT="${SSH_PORT:-auto}"
IGNORE_IPS="${IGNORE_IPS:-127.0.0.1/8 ::1 84.22.133.232 95.182.112.211 185.230.190.12}"
UBUNTU_PRO_TOKEN="${UBUNTU_PRO_TOKEN:-}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:38}"
RUN_UPGRADE=1
RUN_AUTOREMOVE=0
CONFIGURE_DNS=1
STATE_DIR=""
TX_SERVICE=""
TX_FILES=()

WARNINGS=()
FAILED_CHECKS=()
PASSED_CHECKS=()
VALID_KEY_TYPES=()

trap 'printf "ERROR at line %s (command omitted to protect secrets)\n" "$LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'finish' EXIT

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
  --ssh-port PORT        SSH port(s) for fail2ban only, comma-separated. Default: auto.
  --no-upgrade           Skip initial full upgrade and cleanup.
  --autoremove           Opt in to removing unused packages after upgrade.
  --skip-dns             Preserve current DNS configuration.
  -h, --help             Show help.

Environment overrides:
  TIMEZONE='Europe/Moscow'
  AUTO_REBOOT_TIME='04:38'
  SSH_PORT='22'
  IGNORE_IPS='127.0.0.1/8 ::1 x.x.x.x'
  UBUNTU_PRO_TOKEN='your-token'
USAGE
}

parse_args() {
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-port)
      [[ $# -ge 2 && -n "$2" ]] || die "--ssh-port requires a value"
      SSH_PORT="$2"
      shift 2
      ;;
    --autoremove)
      RUN_AUTOREMOVE=1
      shift
      ;;
    --skip-dns)
      CONFIGURE_DNS=0
      shift
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

}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"
}

backup_file() {
  local f="$1"
  # Config writes below are in-place; backing up only a symlink would not
  # preserve its target. resolv.conf is replaced as a link, never written through.
  [[ ! -L "$f" || "$f" == /etc/resolv.conf ]] || die "Refusing to overwrite symlinked config: $f"
  if [[ -e "$f" || -L "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S).$$"
  fi
}

# Save exact originals, including symlinks, until validation and activation succeed.
begin_transaction() {
  local service="$1"
  shift
  local -a files=("$@")
  local i
  for i in "${!files[@]}"; do
    [[ ! -d "${files[$i]}" ]] || die "Expected a file, got a directory: ${files[$i]}"
    if [[ -e "${files[$i]}" || -L "${files[$i]}" ]]; then
      backup_file "${files[$i]}"
      cp -a -- "${files[$i]}" "$STATE_DIR/tx-$i"
    fi
  done
  TX_FILES=("${files[@]}")
  TX_SERVICE="$service"
}

commit_transaction() {
  TX_SERVICE=""
  TX_FILES=()
  rm -f -- "$STATE_DIR"/tx-*
}

rollback_transaction() {
  local i service="$TX_SERVICE"
  for i in "${!TX_FILES[@]}"; do
    rm -f -- "${TX_FILES[$i]}" || return 1
    if [[ -e "$STATE_DIR/tx-$i" || -L "$STATE_DIR/tx-$i" ]]; then
      cp -a -- "$STATE_DIR/tx-$i" "${TX_FILES[$i]}" || return 1
    fi
  done
  commit_transaction
  case "$service" in
    ssh) systemctl reload ssh || warn "Could not reload restored SSH configuration" ;;
    systemd-resolved) systemctl restart systemd-resolved || warn "Could not restart restored DNS" ;;
    fail2ban) systemctl restart fail2ban || warn "Could not restart restored fail2ban" ;;
  esac
}

finish() {
  local rc=$?
  trap - EXIT
  if [[ -n "$TX_SERVICE" ]]; then
    if ! rollback_transaction; then
      printf 'Rollback incomplete. Recovery files retained in %s\n' "$STATE_DIR" >&2
      exit 1
    fi
  fi
  if [[ -n "$STATE_DIR" ]]; then
    rm -rf -- "$STATE_DIR"
  fi
  exit "$rc"
}

validate_inputs() {
  [[ "$AUTO_REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "AUTO_REBOOT_TIME must be HH:MM"
  [[ "$TIMEZONE" != /* && "$TIMEZONE" != *..* && -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Invalid TIMEZONE"
  [[ "$IGNORE_IPS" != *$'\n'* && "$IGNORE_IPS" != *$'\r'* ]] || die "IGNORE_IPS must be one line"
  if [[ "$SSH_PORT" != auto && "$SSH_PORT" != ssh ]]; then
    [[ "$SSH_PORT" =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || die "Invalid SSH port list"
    local port
    local -a ports
    IFS=, read -ra ports <<< "$SSH_PORT"
    for port in "${ports[@]}"; do
      (( 10#$port >= 1 && 10#$port <= 65535 )) || die "SSH port out of range"
    done
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
  log "Validate existing root SSH keys without changing managed sections"
  local keys=/root/.ssh/authorized_keys line type rest valid=0
  [[ ! -L /root/.ssh && ! -L "$keys" && -f "$keys" && -s "$keys" ]] ||
    die "Expected a nonempty regular /root/.ssh/authorized_keys; run your key installer first"
  command -v ssh-keygen >/dev/null || die "Install openssh-client first"
  # Same lock as update-sshid-proms; release it immediately after this check.
  exec 8>/root/.ssh/.update-sshid-proms.lock
  flock -x 8
  VALID_KEY_TYPES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    read -r type rest <<< "$line"
    case "$type" in
      ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
        printf '%s\n' "$line" > "$STATE_DIR/key.pub"
        if ssh-keygen -lf "$STATE_DIR/key.pub" >/dev/null 2>&1; then
          valid=$((valid + 1))
          VALID_KEY_TYPES+=("$type")
        else
          die "Malformed public key found in authorized_keys"
        fi
        ;;
      # Preserve comments and option-prefixed keys. Restricted keys alone do
      # not prove that an interactive root login is possible.
    esac
  done < "$keys"
  (( valid > 0 )) || die "No unrestricted OpenSSH-validated key found; check your key installer"
  chmod 700 /root/.ssh
  chmod 600 "$keys"
  chown root:root /root/.ssh "$keys"
  flock -u 8
  exec 8>&-
  pass_check "Validated $valid unrestricted SSH keys; managed sections preserved"
}

apt_update() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt-get -o DPkg::Lock::Timeout=600 -o APT::Update::Error-Mode=any update
}

apt_install_base_packages() {
  log "APT update and install base packages"

  apt_update

  apt-get -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    -y install \
      python3 \
      python3-apt \
      python3-systemd \
      update-notifier-common \
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

pro_field() {
  python3 -c '
import json,sys
d=json.load(sys.stdin)
if sys.argv[1] == "attached":
    assert type(d["attached"]) is bool
    print(str(d["attached"]).lower())
else:
    services=d["services"]
    s=next((s for s in services if s["name"] == sys.argv[1]), {})
    print(s.get("status", "missing"))
' "$1"
}

configure_ubuntu_pro() {
  log "Check Ubuntu Pro attachment, ESM Infra, ESM Apps and Livepatch"
  local token="${UBUNTU_PRO_TOKEN:-}" status attached service state
  unset UBUNTU_PRO_TOKEN
  if ! status="$(pro status --all --format json)" ||
     ! attached="$(pro_field attached <<< "$status")"; then
    fail_check "Cannot read Ubuntu Pro status; no attachment changes made"
    return 0
  fi
  if [[ "$attached" != true ]]; then
    if [[ -z "$token" && -t 0 ]]; then
      read -rsp "Ubuntu Pro token (Enter to skip): " token || token=""
      echo
    fi
    if [[ -z "$token" ]]; then
      warn "No Ubuntu Pro token provided; Pro services skipped"
      return 0
    fi
    # JSON is valid YAML; keep the token out of command arguments and logs.
    printf '%s' "$token" | python3 -c 'import json,sys; json.dump({"token":sys.stdin.read()},sys.stdout)' > "$STATE_DIR/pro-attach.yaml"
    if ! pro attach --no-auto-enable --attach-config "$STATE_DIR/pro-attach.yaml"; then
      rm -f "$STATE_DIR/pro-attach.yaml"
      unset token
      fail_check "Ubuntu Pro attachment failed; inspect pro status"
      return 0
    fi
    rm -f "$STATE_DIR/pro-attach.yaml"
  fi
  unset token
  if ! status="$(pro status --all --format json)" ||
     [[ "$(pro_field attached <<< "$status")" != true ]]; then
    fail_check "Ubuntu Pro attachment could not be confirmed"
    return 0
  fi
  pass_check "Ubuntu Pro attached"
  for service in esm-infra esm-apps livepatch; do
    state="$(pro_field "$service" <<< "$status")"
    if [[ "$state" == disabled ]]; then
      if ! pro enable --assume-yes "$service"; then
        fail_check "Failed to enable $service"
        continue
      fi
      if ! status="$(pro status --all --format json)"; then
        fail_check "Cannot verify $service after enable"
        return 0
      fi
      state="$(pro_field "$service" <<< "$status")"
    fi
    case "$state" in
      enabled) pass_check "Ubuntu Pro $service enabled" ;;
      n/a|unavailable|inapplicable|-)
        warn "Ubuntu Pro $service unavailable for this machine/subscription ($state); inspect pro status --all" ;;
      *) fail_check "Ubuntu Pro $service is not enabled ($state)" ;;
    esac
  done
  if [[ "$(pro_field livepatch <<< "$status")" == enabled ]]; then
    if [[ -x /snap/bin/canonical-livepatch ]]; then
      if ! /snap/bin/canonical-livepatch status --verbose; then
        fail_check "Livepatch client health check failed"
      fi
    else
      warn "Pro reports Livepatch enabled but its client was not found"
    fi
  fi
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
    --no-remove -y dist-upgrade

  protect_manual_packages

  if [[ "$RUN_AUTOREMOVE" -eq 1 ]]; then
    apt-get -o DPkg::Lock::Timeout=600 -y autoremove --purge
  else
    warn "Automatic package removal skipped; use --autoremove only after reviewing apt-get -s autoremove"
  fi
  apt-get -o DPkg::Lock::Timeout=600 -y autoclean

  pass_check "Full upgrade and autoclean completed"
}

ssh_policy_ok() {
  local effective="$1" algorithms type
  algorithms=",$(awk '$1 == "pubkeyacceptedalgorithms" {print $2}' <<< "$effective"),"
  for type in "${VALID_KEY_TYPES[@]}"; do
    if [[ "$type" == ssh-rsa ]]; then
      # RSA keys can use modern SHA-2 signatures; never re-enable SHA-1 ssh-rsa.
      [[ "$algorithms" == *,rsa-sha2-256,* || "$algorithms" == *,rsa-sha2-512,* ]] || return 1
    else
      [[ "$algorithms" == *",$type,"* ]] || return 1
    fi
  done
  grep -qx 'pubkeyauthentication yes' <<< "$effective" &&
  grep -qx 'passwordauthentication no' <<< "$effective" &&
  grep -qx 'kbdinteractiveauthentication no' <<< "$effective" &&
  grep -Eq '^permitrootlogin (without-password|prohibit-password)$' <<< "$effective" &&
  grep -Eq '^authenticationmethods (any|publickey)$' <<< "$effective" &&
  grep -Eq '^authorizedkeysfile .*' <<< "$effective" &&
  awk '$1 == "authorizedkeysfile" {for(i=2;i<=NF;i++) if($i == ".ssh/authorized_keys" || $i == "/root/.ssh/authorized_keys" || $i == "%h/.ssh/authorized_keys") found=1} END {exit !found}' <<< "$effective"
}

configure_ssh() {
  log "Validate and apply key-only SSH authentication"
  local config=/etc/ssh/sshd_config dropin=/etc/ssh/sshd_config.d/00-proms-hardening.conf effective
  local remote _rport localaddr localport
  sshd -t || die "Existing SSH configuration is invalid"
  # Recheck after package operations, which can take a long time.
  check_root_authorized_keys
  install -d -m 755 /etc/ssh/sshd_config.d
  begin_transaction ssh "$config" "$dropin"
  # Explicit first include avoids earlier cloud-init/drop-in scalar values.
  # Remove only our exact include; the distribution wildcard remains intact.
  {
    echo "Include $dropin"
    sed '\|^[[:space:]]*Include[[:space:]]\+/etc/ssh/sshd_config.d/00-proms-hardening.conf[[:space:]]*$|d' "$STATE_DIR/tx-0"
  } > "$config"
  cat > "$dropin" <<'EOF'
# Managed by vps-bootstrap-ubuntu24.sh
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
X11Forwarding no
EOF
  chmod 644 "$dropin"
  sshd -t || die "New SSH config invalid; restoring original files"
  effective="$(sshd -T -C user=root,host=localhost,addr=127.0.0.1)"
  ssh_policy_ok "$effective" || die "Root SSH policy conflicts with key-only login; restoring original files"
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r remote _rport localaddr localport <<< "$SSH_CONNECTION"
    effective="$(sshd -T -C "user=root,host=$remote,addr=$remote,laddr=$localaddr,lport=$localport")"
    ssh_policy_ok "$effective" || die "SSH Match rules conflict for current client; restoring original files"
  fi
  if grep -Eq '^(allowusers|denyusers|allowgroups|denygroups) ' <<< "$effective"; then
    warn "SSH access lists are present; they are preserved and still apply"
  fi
  systemctl reload ssh || die "SSH reload failed; restoring original files"
  commit_transaction
  pass_check "SSH syntax and effective root key-only policy validated before reload"
  warn "A local key check cannot prove remote login. Test a second session with both SSH ID and YubiKey before closing this one; other Match contexts may differ"
}

configure_resolved() {
  [[ "$CONFIGURE_DNS" -eq 1 ]] || { warn "DNS changes skipped"; return 0; }
  log "Configure global DNS-over-TLS with rollback on resolution failure"
  # The old one-shot erased link domains and was undone by DHCP renewal.
  # Do not erase VPN/private DNS routes or restart the network manager.
  if [[ -f /etc/systemd/system/disable-link-dns.service ]] &&
     grep -q 'ExecStart=/usr/local/sbin/disable-link-dns.sh auto' /etc/systemd/system/disable-link-dns.service; then
    systemctl disable --now disable-link-dns.service
    warn "Legacy one-shot DNS eraser disabled. Previously erased link DNS returns on lease renewal or reboot"
  fi
  install -d -m 755 /etc/systemd/resolved.conf.d
  begin_transaction systemd-resolved /etc/systemd/resolved.conf.d/90-proms-dot.conf /etc/resolv.conf
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
  ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  systemctl enable --now systemd-resolved
  systemctl restart systemd-resolved
  resolvectl flush-caches
  if timeout 30 resolvectl query --cache=no ubuntu.com >/dev/null 2>&1 &&
     timeout 30 resolvectl query --cache=no cloudflare.com >/dev/null 2>&1 &&
     timeout 30 getent ahosts ubuntu.com >/dev/null; then
    commit_transaction
    pass_check "Uncached resolver and system DNS tests succeeded"
    warn "Global DoT does not override more-specific link/VPN DNS routes; inspect resolvectl status. A link with ~. can also handle public queries"
  else
    rollback_transaction
    fail_check "DNS tests failed; previous resolver files restored (DoT may be blocked)"
  fi
}

configure_sysctl() {
  log "Configure UDP buffers, TCP Fast Open, and BBR if available"

  backup_file /etc/sysctl.d/99-proms-network.conf
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
    log "BBR is available; applying configuration"
  else
    warn "BBR is not available in this kernel; BBR tuning skipped"
  fi

  if sysctl -p /etc/sysctl.d/99-proms-network.conf; then
    if grep -q 'tcp_congestion_control=bbr' /etc/sysctl.d/99-proms-network.conf &&
       [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" != bbr ]]; then
      fail_check "BBR was configured but is not active"
    else
      pass_check "sysctl network tuning applied"
    fi
  else
    fail_check "sysctl network tuning failed"
  fi
}

configure_unattended_upgrades() {
  log "Configure unattended upgrades with automatic reboot at ${AUTO_REBOOT_TIME} ${TIMEZONE}"

  begin_transaction apt /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/90-proms-unattended-upgrades
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  cat > /etc/apt/apt.conf.d/90-proms-unattended-upgrades <<EOF
// Managed by vps-bootstrap-ubuntu24.sh
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "${AUTO_REBOOT_TIME}";
EOF

  # Add required security origins without deleting administrator-defined origins.
  cat >> /etc/apt/apt.conf.d/90-proms-unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
  "${distro_id}ESMApps:${distro_codename}-apps-security";
  "${distro_id}ESM:${distro_codename}-infra-security";
};
EOF
  if ! python3 - "$AUTO_REBOOT_TIME" <<'PY'
import apt_pkg, sys
apt_pkg.init()
c = apt_pkg.config
expected = {
    "APT::Periodic::Enable": "1",
    "APT::Periodic::Update-Package-Lists": "1",
    "APT::Periodic::Unattended-Upgrade": "1",
    "Unattended-Upgrade::Automatic-Reboot": "true",
    "Unattended-Upgrade::Automatic-Reboot-WithUsers": "true",
    "Unattended-Upgrade::Automatic-Reboot-Time": sys.argv[1],
}
bad = [k for k, v in expected.items() if c.find(k).lower() != v]
required = {
    "${distro_id}:${distro_codename}-security",
    "${distro_id}ESMApps:${distro_codename}-apps-security",
    "${distro_id}ESM:${distro_codename}-infra-security",
}
if not required.issubset(set(c.value_list("Unattended-Upgrade::Allowed-Origins"))):
    bad.append("Unattended-Upgrade::Allowed-Origins")
if bad:
    print("Conflicting effective APT options: " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
  then
    rollback_transaction
    fail_check "Effective unattended-upgrades settings were overridden; inspect apt-config dump"
    return 0
  fi
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
  systemctl enable --now unattended-upgrades

  if systemctl is-active --quiet unattended-upgrades &&
     systemctl is-active --quiet apt-daily.timer &&
     systemctl is-active --quiet apt-daily-upgrade.timer; then
    commit_transaction
    pass_check "unattended-upgrades enabled; automatic reboot set to ${AUTO_REBOOT_TIME} ${TIMEZONE}"
  else
    rollback_transaction
    fail_check "unattended-upgrades or its APT timers are not active"
  fi
}

configure_fail2ban() {
  log "Configure fail2ban for SSH"

  if [[ "$SSH_PORT" == auto ]]; then
    SSH_PORT="$(sshd -T | awk '$1 == "port" {print $2}' | paste -sd, -)"
    # Ubuntu 24.04 may use ssh.socket; include its actual listener ports too.
    if systemctl is-active --quiet ssh.socket; then
      local socket_ports
      socket_ports="$(systemctl show ssh.socket -p Listen --value | grep -oE '[0-9]+ \(Stream\)' | awk '{print $1}' | paste -sd, - || true)"
      [[ -z "$socket_ports" ]] || SSH_PORT="$SSH_PORT,$socket_ports"
    fi
    [[ -n "$SSH_PORT" ]] || die "Cannot detect SSH listening ports; use --ssh-port"
  fi
  validate_inputs
  install -d -m 755 /etc/fail2ban/jail.d
  begin_transaction fail2ban /etc/fail2ban/fail2ban.local /etc/fail2ban/jail.d/sshd.local

  cat > /etc/fail2ban/fail2ban.local <<'EOF'
[Definition]
logtarget = /var/log/fail2ban.log
dbpurgeage = 200d
EOF

  touch /var/log/fail2ban.log
  chmod 640 /var/log/fail2ban.log || true

  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd[mode=normal]
ignoreip = ${IGNORE_IPS}
bantime = 4w
findtime = 120m
maxretry = 3
banaction = nftables[type=multiport]
backend = systemd
usedns = no


[recidive]
enabled = true
ignoreip = ${IGNORE_IPS}
logpath = /var/log/fail2ban.log
backend = auto
banaction = nftables[type=allports]
findtime = 90d
bantime = 26w
maxretry = 2
EOF

  if fail2ban-server -t; then
    pass_check "fail2ban config validation succeeded"
  else
    rollback_transaction
    fail_check "fail2ban config validation failed; previous files restored"
    return 0
  fi

  systemctl enable --now fail2ban
  if ! fail2ban-client reload; then
    rollback_transaction
    fail_check "fail2ban reload failed; previous files restored"
    return 0
  fi

  if fail2ban-client status sshd >/dev/null 2>&1 && fail2ban-client status recidive >/dev/null 2>&1; then
    commit_transaction
    pass_check "fail2ban sshd and recidive jails are active"
  else
    rollback_transaction
    fail_check "fail2ban jail not active; previous files restored"
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
  echo "  systemctl status systemd-resolved --no-pager"
  echo "  fail2ban-client status sshd"
  echo "  pro status"
  echo "  systemctl list-timers 'apt*' --all"

  echo
  if [[ -f /run/reboot-required ]]; then
    echo "Reboot required: YES. Run manually now if convenient: sudo reboot"
  else
    echo "Reboot required: no marker found. No reboot is requested by the package system."
  fi

  echo
  echo "Important: do not close this SSH session until you verify a new SSH login with your key."

  if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
    return 1
  fi
}

main() {
  parse_args "$@"
  require_root
  validate_inputs
  check_os
  exec 9>/run/lock/vps-bootstrap-proms.lock
  flock -n 9 || die "Another bootstrap instance is running"
  STATE_DIR="$(mktemp -d /run/vps-bootstrap-proms.XXXXXX)"
  chmod 700 "$STATE_DIR"
  check_root_authorized_keys
  apt_install_base_packages
  set_timezone
  configure_ubuntu_pro
  # Refresh indexes for newly enabled ESM repositories even with --no-upgrade.
  apt_update
  full_upgrade_and_cleanup
  configure_ssh
  configure_resolved
  configure_sysctl
  configure_unattended_upgrades
  configure_fail2ban
  final_report
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
