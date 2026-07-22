#!/usr/bin/env bash
# ==============================================================================
# Script Name  : 03_harden_server.sh
# Description  : Stage 2 - Comprehensive Server Hardening & Baseline Configuration
#                Orchestrates SSH hardening, UFW firewall rules, Fail2Ban IDS,
#                automated patching (`unattended-upgrades`), and Docker log rotation.
# Target OS    : Ubuntu 24.04 LTS / Debian / General Linux VPS
# ==============================================================================
# Purpose:
#   Implements the core security baseline protocol outlined in README.md.
#   This script closes primary attack vectors by disabling root login over SSH,
#   enforcing key-based authentication (disabling both passwords and PAM keyboard-interactive),
#   obfuscating the SSH port, enforcing default-deny firewall rules (and cleaning legacy
#   port 22 rules), installing an intrusion detection/prevention system (Fail2Ban),
#   enabling unattended security patching, and bounding container log growth safely.
#
# Usage:
#   sudo ./03_harden_server.sh [ssh_port] [--force]
#
# Arguments:
#   $1 - ssh_port (optional, overrides SSH_PORT from vps.env)
#   $2 - --force (optional, bypasses pre-flight administrative user check if needed)
#
# Execution & Safety Guarantees:
#   1. Slices environment configuration from `vps.env` if present in the script directory.
#   2. Pre-flight Safety Check: Verifies that at least one non-root user with `sudo`
#      access and a non-empty `authorized_keys` file exists. If missing, aborts to
#      prevent permanent server lockout (unless `--force` is provided).
#   3. OpenSSH & Socket Hardening:
#      - Backs up existing `/etc/ssh/sshd_config`.
#      - Uses clean drop-in overrides (`/etc/ssh/sshd_config.d/99-vps-hardening.conf`)
#        for modern Ubuntu compatibility (`Port`, `PermitRootLogin no`,
#        `PasswordAuthentication no`, `KbdInteractiveAuthentication no`).
#      - Checks configuration syntax (`sshd -t`) before applying changes.
#      - Automatically configures systemd socket activation (`ssh.socket`) override
#        (`ListenStream=<port>`) on Ubuntu 24.04 systems.
#      - On socket-activated systems, restarts `ssh.socket` directly without starting
#        `ssh.service` explicitly, avoiding binding conflicts.
#   4. Perimeter Defense (UFW):
#      - Deletes legacy rules allowing standard port 22 or OpenSSH if switching ports.
#      - Establishes a `default deny incoming` and `default allow outgoing` policy.
#      - Whitelists `<ssh_port>/tcp`, `80/tcp` (HTTP), and `443/tcp` (HTTPS).
#      - Non-interactively enables UFW.
#   5. Fail2Ban Orchestration:
#      - Installs and configures Fail2Ban for the customized SSH port.
#      - Uses `backend = systemd` by default for robustness across Ubuntu 24.04+ where
#        `/var/log/auth.log` may not exist without rsyslog.
#   6. Patch Management:
#      - Upgrades system packages (`apt-get upgrade -y`).
#      - Configures `unattended-upgrades` non-interactively (`20auto-upgrades` and
#        `51unattended-upgrades-custom`) with automatic maintenance reboots at `${REBOOT_TIME:-04:30}`
#        in `${TIMEZONE:-system default}` when required (`/var/run/reboot-required`).
#   7. Docker Log Rotation:
#      - Safely merges log limits (`max-size: 10m`, `max-file: 3`) into existing
#        `/etc/docker/daemon.json` using `jq` to prevent overwriting existing keys.
# ==============================================================================

set -euo pipefail

# --- Color Definitions for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Step 1: Root Privilege Check ---
if [[ "${EUID}" -ne 0 ]]; then
    log_error "This script must be executed as root (or via sudo)."
    exit 1
fi

# --- Step 2: Load Configuration Defaults & Parse Arguments ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/vps.env" ]]; then
    source "${SCRIPT_DIR}/vps.env"
fi

SSH_PORT="${1:-${SSH_PORT:-}}"
FORCE_FLAG="${2:-}"
EXTRA_PORTS="${UFW_ALLOWED_PORTS-80/tcp 443/tcp}"

if [[ -z "${SSH_PORT}" || "${SSH_PORT}" =~ ^your-prefer?red-ssh-port$ || ! "${SSH_PORT}" =~ ^[0-9]+$ || "${SSH_PORT}" -lt 1024 || "${SSH_PORT}" -gt 65535 ]]; then
    log_error "CRITICAL CONFIGURATION ERROR: Target SSH_PORT ('${SSH_PORT:-<empty>}') is invalid or not configured."
    log_error "You MUST specify a valid non-standard SSH port (1024 - 65535) inside 'vps.env' (SSH_PORT=\"your-preferred-ssh-port\") or pass it as the first argument: $0 <ssh_port>"
    log_error "Please adjust 'vps.env' before running this script again."
    exit 1
fi

log_info "Starting Stage 2: Server Hardening & Baseline Configuration..."
log_info "Target SSH Listening Port: ${SSH_PORT}"

# --- Step 3: Pre-flight Lockout Protection Check ---
log_info "Verifying pre-flight lockout protection requirements..."
SAFE_USER_FOUND=false

for user_home in /home/*; do
    if [[ -d "${user_home}" ]]; then
        uname=$(basename "${user_home}")
        if id -nG "${uname}" 2>/dev/null | grep -qw sudo; then
            if [[ -s "${user_home}/.ssh/authorized_keys" ]]; then
                SAFE_USER_FOUND=true
                log_success "Verified administrative user '${uname}' with active SSH keys and sudo rights."
                break
            fi
        fi
    fi
done

if [[ "${SAFE_USER_FOUND}" == "false" && "${FORCE_FLAG}" != "--force" ]]; then
    log_error "CRITICAL SAFETY ABORT: No non-root user found with both 'sudo' group membership and non-empty 'authorized_keys'!"
    log_error "If we disable root login right now, you WILL be locked out of this VPS."
    log_error "Run 'sudo ./01_provision_user.sh' and 'sudo ./02_verify_access.sh' first, or pass '--force' to bypass."
    exit 1
fi

# --- Step 4: SSH Service Hardening ---
log_info "Configuring OpenSSH daemon and socket overrides..."

# 4.1 Backup existing sshd_config
BACKUP_PATH="/etc/ssh/sshd_config.bak.$(date +%F_%T)"
cp /etc/ssh/sshd_config "${BACKUP_PATH}"
log_info "Backed up /etc/ssh/sshd_config to ${BACKUP_PATH}"

# 4.2 Create drop-in hardening configuration
mkdir -p /etc/ssh/sshd_config.d
rm -f /etc/ssh/sshd_config.d/99-vps-hardening.conf 2>/dev/null || true
cat <<EOF > /etc/ssh/sshd_config.d/00-vps-hardening.conf
# Automated VPS Hardening Override (`date +%F`)
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
MaxAuthTries 3
EOF
chmod 644 /etc/ssh/sshd_config.d/00-vps-hardening.conf

# Ensure main config includes drop-in directory
if ! grep -Eq "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

# 4.3 Validate sshd configuration syntax
mkdir -p /run/sshd && chmod 0755 /run/sshd 2>/dev/null || true
if ! sshd -t; then
    log_error "OpenSSH configuration syntax check failed! Rolling back changes..."
    rm -f /etc/ssh/sshd_config.d/00-vps-hardening.conf
    cp "${BACKUP_PATH}" /etc/ssh/sshd_config
    exit 1
fi
log_success "OpenSSH syntax check passed ('sshd -t')."

# 4.4 Systemd Socket Activation (Ubuntu 24.04 handling)
SOCKET_ACTIVATED=false
if systemctl list-unit-files 2>/dev/null | grep -qw "ssh.socket"; then
    log_info "Detected systemd socket activation (ssh.socket). Disabling in favor of standalone ssh.service for dual-stack IPv4/IPv6 binding and Fail2Ban compatibility..."
    if ! systemctl disable --now ssh.socket >/dev/null 2>&1; then
        log_error "Failed to disable ssh.socket! Aborting before SSH is disrupted..."
        exit 1
    fi
    rm -f /etc/systemd/system/ssh.socket.d/override.conf 2>/dev/null || true
    SOCKET_ACTIVATED=true
    log_success "Disabled systemd socket activation and switched to dedicated ssh.service daemon."
fi

# --- Step 5: Perimeter Defense (Firewall Baseline) ---
log_info "Configuring Uncomplicated Firewall (UFW) baseline rules..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq ufw jq >/dev/null

# Clean up legacy SSH/Port 22 rules before applying custom port
if [[ "${SSH_PORT}" != "22" ]]; then
    log_info "Removing any legacy UFW rules for standard port 22/OpenSSH to prevent exposure..."
    while read -r rule_num; do
        if [[ -n "${rule_num}" && "${rule_num}" =~ ^[0-9]+$ ]]; then
            echo "y" | ufw delete "${rule_num}" >/dev/null 2>&1 || true
        fi
    done < <(ufw status numbered 2>/dev/null | grep -iE '\[[ 0-9]+\][[:space:]]+(22(/tcp)?|OpenSSH|ssh)([[:space:]]|$)' | awk -F'[' '{print $2}' | awk -F']' '{print $1}' | tr -d ' ' | sort -rn)
    
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
    ufw delete allow OpenSSH >/dev/null 2>&1 || true
    ufw delete allow ssh >/dev/null 2>&1 || true
fi

# Set secure default policies
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# Allow essential ports
log_info "Whitelisting target SSH port: ${SSH_PORT}/tcp..."
ufw allow "${SSH_PORT}/tcp" comment 'Obfuscated SSH Port' >/dev/null

if [[ -n "${EXTRA_PORTS}" ]]; then
    log_info "Whitelisting additional firewall rules (${EXTRA_PORTS})..."
    for port_rule in ${EXTRA_PORTS}; do
        port_clean=$(echo "${port_rule}" | tr -d ' ')
        if [[ -n "${port_clean}" ]]; then
            ufw allow "${port_clean}" comment 'User Whitelisted Port' >/dev/null
        fi
    done
fi

# Enable firewall non-interactively
ufw --force enable >/dev/null
log_success "UFW enabled and active."

# --- Step 6: Service Reinitialization ---
log_info "Reloading systemd daemon and restarting SSH services..."
systemctl daemon-reload

SSH_SERVICE_UNIT="ssh.service"
if ! systemctl list-unit-files 2>/dev/null | grep -qw "ssh.service"; then
    SSH_SERVICE_UNIT="sshd.service"
fi

if ! systemctl enable --now "${SSH_SERVICE_UNIT}" 2>/dev/null; then
    log_error "Failed to enable and start ${SSH_SERVICE_UNIT}! Attempting rollback..."
    if [[ "${SOCKET_ACTIVATED}" == "true" ]]; then
        systemctl enable --now ssh.socket 2>/dev/null || true
    fi
    rm -f /etc/ssh/sshd_config.d/00-vps-hardening.conf
    cp "${BACKUP_PATH}" /etc/ssh/sshd_config
    systemctl daemon-reload && systemctl restart "${SSH_SERVICE_UNIT}" 2>/dev/null || true
    exit 1
fi

if ! systemctl restart "${SSH_SERVICE_UNIT}"; then
    log_error "Failed to restart ${SSH_SERVICE_UNIT}! Rolling back SSH configuration..."
    if [[ "${SOCKET_ACTIVATED}" == "true" ]]; then
        systemctl enable --now ssh.socket 2>/dev/null || true
    fi
    rm -f /etc/ssh/sshd_config.d/00-vps-hardening.conf
    cp "${BACKUP_PATH}" /etc/ssh/sshd_config
    systemctl daemon-reload && systemctl restart "${SSH_SERVICE_UNIT}" 2>/dev/null || true
    exit 1
fi

if ! systemctl is-active --quiet "${SSH_SERVICE_UNIT}"; then
    log_error "Service ${SSH_SERVICE_UNIT} is not active after restart! Rolling back..."
    if [[ "${SOCKET_ACTIVATED}" == "true" ]]; then
        systemctl enable --now ssh.socket 2>/dev/null || true
    fi
    rm -f /etc/ssh/sshd_config.d/00-vps-hardening.conf
    cp "${BACKUP_PATH}" /etc/ssh/sshd_config
    systemctl daemon-reload && systemctl restart "${SSH_SERVICE_UNIT}" 2>/dev/null || true
    exit 1
fi

log_success "SSH service (${SSH_SERVICE_UNIT}) successfully reinitialized and verified active on port ${SSH_PORT}."

# --- Step 7: Fail2Ban Orchestration ---
log_info "Installing and configuring Fail2Ban intrusion detection..."
apt-get install -y -qq fail2ban >/dev/null

FAIL2BAN_BACKEND="systemd"
FAIL2BAN_LOGPATH=""
if [[ -f "/var/log/auth.log" ]]; then
    FAIL2BAN_BACKEND="auto"
    FAIL2BAN_LOGPATH="logpath = /var/log/auth.log"
fi

cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = ${FAIL2BAN_BACKEND}
${FAIL2BAN_LOGPATH}
maxretry = 3
bantime = 1h
EOF

systemctl restart fail2ban
log_success "Fail2Ban restarted and monitoring port ${SSH_PORT} (backend: ${FAIL2BAN_BACKEND})."

# --- Step 8: Patch & Lifecycle Management ---
log_info "Synchronizing package indexes and upgrading system packages..."
apt-get upgrade -y -qq >/dev/null

# Configure system timezone if specified
if [[ -n "${TIMEZONE:-}" ]]; then
    log_info "Configuring system timezone to '${TIMEZONE}'..."
    if command -v timedatectl >/dev/null 2>&1 && timedatectl list-timezones 2>/dev/null | grep -Fxq "${TIMEZONE}" && timedatectl set-timezone "${TIMEZONE}" 2>/dev/null; then
        log_success "System timezone configured to ${TIMEZONE} via timedatectl."
    elif [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
        ln -fs "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
        echo "${TIMEZONE}" > /etc/timezone
        export DEBIAN_FRONTEND=noninteractive
        dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
        log_success "System timezone configured to ${TIMEZONE} via /etc/localtime."
    else
        log_warn "Timezone '${TIMEZONE}' invalid or unavailable; retaining current system timezone."
    fi
fi

log_info "Installing and configuring unattended-upgrades..."
apt-get install -y -qq unattended-upgrades >/dev/null

# Non-interactive activation
cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Automated reboot policy for updates requiring reboot (/var/run/reboot-required)
REBOOT_TIME_CFG="${REBOOT_TIME:-04:30}"
if ! [[ "${REBOOT_TIME_CFG}" =~ ^(now|\+[0-9]+|([01][0-9]|2[0-3]):[0-5][0-9])$ ]]; then
    log_warn "Invalid REBOOT_TIME '${REBOOT_TIME_CFG}' (must be HH:MM, now, or +m). Falling back to safe default '04:30'."
    REBOOT_TIME_CFG="04:30"
fi
cat <<EOF > /etc/apt/apt.conf.d/51unattended-upgrades-custom
// Custom overrides for unattended security and system updates
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME_CFG}";
EOF
log_success "Unattended upgrades and ${REBOOT_TIME_CFG} (${TIMEZONE:-local time}) reboot policy active."

# --- Step 9: Docker Resource Hardening ---
log_info "Checking and configuring Docker daemon log rotation rules..."
mkdir -p /etc/docker
DAEMON_JSON="/etc/docker/daemon.json"

# Safely merge JSON settings without overwriting existing daemon configurations
if [[ -f "${DAEMON_JSON}" && -s "${DAEMON_JSON}" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
        apt-get install -y -qq jq >/dev/null 2>&1 || true
    fi
    if command -v jq >/dev/null 2>&1; then
        log_info "Merging log rotation limits into existing ${DAEMON_JSON}..."
        jq '. * {"log-driver": "json-file", "log-opts": ((.["log-opts"] // {}) + {"max-size": "10m", "max-file": "3"})}' "${DAEMON_JSON}" > "${DAEMON_JSON}.tmp" && mv "${DAEMON_JSON}.tmp" "${DAEMON_JSON}"
    else
        log_warn "jq could not be installed; skipping Docker config overwrite to preserve existing keys."
    fi
else
    cat <<EOF > "${DAEMON_JSON}"
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
fi
chmod 644 "${DAEMON_JSON}"

if command -v docker >/dev/null 2>&1 && systemctl is-active docker >/dev/null 2>&1; then
    log_info "Docker service active. Restarting Docker daemon to apply log limits..."
    systemctl restart docker
    log_success "Docker log limits applied ('max-size: 10m', 'max-file: 3')."
    log_info "Note: New log rotation limits apply to newly created containers."
else
    log_info "Docker is not currently active on this VPS. ${DAEMON_JSON} configured for future container execution."
fi

# --- Step 10: Completion Summary ---
echo ""
echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}                     STAGE 2 HARDENING SUCCESSFULLY APPLIED!                  ${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo -e "Summary of Active Protections:"
echo -e "  * OpenSSH Port : ${YELLOW}${SSH_PORT}${NC}"
echo -e "  * Root Login   : ${RED}DISABLED${NC}"
echo -e "  * Pass & KBD   : ${RED}DISABLED${NC} (Password & PAM Keyboard-Interactive)"
echo -e "  * UFW Firewall : ${GREEN}ACTIVE${NC} (${SSH_PORT}/tcp ${EXTRA_PORTS:-} whitelisted, 22 cleaned)"
echo -e "  * Fail2Ban     : ${GREEN}ACTIVE${NC} (Max 3 retries, 1 hour ban)"
echo -e "  * Auto Patch   : ${GREEN}ACTIVE${NC} (Unattended upgrades + ${REBOOT_TIME:-04:30} [${TIMEZONE:-local}] reboot)"
echo -e ""
echo -e "Next Step: Run the post-audit check to verify all services and listening states:"
echo -e "   ${BLUE}sudo ./04_post_audit.sh ${SSH_PORT}${NC}"
echo -e "${GREEN}==============================================================================${NC}"
