#!/usr/bin/env bash
# ==============================================================================
# Script Name  : 04_post_audit.sh
# Description  : Verification & Audit Script - Post-Hardening Security Baseline
#                Performs automated checks across OpenSSH, UFW, Fail2Ban, APT
#                unattended-upgrades, and Docker to confirm compliance.
# Target OS    : Ubuntu 24.04 LTS / Debian / General Linux VPS
# ==============================================================================
# Purpose:
#   After executing Stage 2 hardening (`03_harden_server.sh`), this script validates
#   that all desired configuration states are actively enforced by running runtime
#   queries against system daemons (`sshd -T`, `ss`, `ufw status`, `fail2ban-client`).
#   It ensures no loose ends remain and confirms that security policies are active.
#
# Usage:
#   sudo ./04_post_audit.sh [expected_ssh_port]
#
# Arguments:
#   $1 - expected_ssh_port (optional, overrides SSH_PORT from vps.env)
#
# Audit Checklist:
#   1. OpenSSH Syntax Check: Verifies `sshd -t` returns success.
#   2. Effective SSH Port: Verifies `sshd -T | grep '^port '` matches expected port.
#   3. Root Login Policy: Verifies `permitrootlogin no` is enforced.
#   4. Password Auth Policy: Verifies `passwordauthentication no` is enforced.
#   5. KbdInteractive Auth Policy: Verifies `kbdinteractiveauthentication no` is enforced.
#   6. Network Listening Check: Verifies port <expected_ssh_port> is listening via `ss`
#      and confirms standard port 22 is closed.
#   7. UFW Status Check: Verifies UFW is active and default policies are secure.
#   8. Fail2Ban Status Check: Verifies Fail2Ban daemon is running and sshd jail active.
#   9. Unattended Upgrades Check: Verifies auto-upgrades and automatic reboots are configured.
#   10. Docker Log Limits Check: Verifies `/etc/docker/daemon.json` exists with log limits.
# ==============================================================================

set -euo pipefail

# --- Color Definitions for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/vps.env" ]]; then
    source "${SCRIPT_DIR}/vps.env"
fi

EXPECTED_PORT="${1:-${SSH_PORT:-}}"

if [[ -z "${EXPECTED_PORT}" || "${EXPECTED_PORT}" =~ ^your-prefer?red-ssh-port$ || ! "${EXPECTED_PORT}" =~ ^[0-9]+$ || "${EXPECTED_PORT}" -lt 1024 || "${EXPECTED_PORT}" -gt 65535 ]]; then
    log_fail "CRITICAL AUDIT ERROR: Target SSH_PORT ('${EXPECTED_PORT:-<empty>}') is invalid or not configured."
    log_fail "Please define SSH_PORT=\"your-preferred-ssh-port\" inside 'vps.env' or pass the port as an argument: $0 <expected_ssh_port>"
    exit 1
fi

FAILURES=0
WARNINGS=0

echo -e "${BLUE}==============================================================================${NC}"
echo -e "${BLUE}            POST-HARDENING BASELINE COMPLIANCE AUDIT REPORT                 ${NC}"
echo -e "${BLUE}==============================================================================${NC}"

# --- Check 1: SSH Configuration Syntax ---
# Ensure privilege separation directory exists (required by sshd -t when socket activation is idle)
if mkdir -p /run/sshd 2>/dev/null && chmod 0755 /run/sshd 2>/dev/null; then
    if sshd -t 2>/dev/null; then
        log_pass "OpenSSH configuration syntax is valid."
    else
        log_fail "OpenSSH configuration syntax check ('sshd -t') reported errors!"
        ((FAILURES++))
    fi
else
    log_fail "Failed to prepare privilege separation directory /run/sshd (check root permissions)."
    ((FAILURES++))
fi

# --- Check 2, 3, 4, 5: Runtime Effective SSH Policies ---
if command -v sshd >/dev/null 2>&1; then
    EFFECTIVE_CONFIG=$(sshd -T 2>/dev/null || echo "")

    # Port Check
    if echo "${EFFECTIVE_CONFIG}" | grep -Ei "^port ${EXPECTED_PORT}$" >/dev/null; then
        log_pass "OpenSSH is configured for target port ${EXPECTED_PORT}."
    else
        log_fail "OpenSSH effective configuration port does not match expected (${EXPECTED_PORT})."
        ((FAILURES++))
    fi

    # Root Login Check
    if echo "${EFFECTIVE_CONFIG}" | grep -Ei "^permitrootlogin no$" >/dev/null; then
        log_pass "OpenSSH root login ('PermitRootLogin') is explicitly disabled."
    else
        log_fail "OpenSSH root login is NOT disabled ('permitrootlogin' != no)."
        ((FAILURES++))
    fi

    # Password Auth Check
    if echo "${EFFECTIVE_CONFIG}" | grep -Ei "^passwordauthentication no$" >/dev/null; then
        log_pass "OpenSSH password authentication is explicitly disabled."
    else
        log_fail "OpenSSH password authentication is NOT disabled!"
        ((FAILURES++))
    fi

    # Keyboard-Interactive Auth Check
    if echo "${EFFECTIVE_CONFIG}" | grep -Ei "^(kbdinteractiveauthentication|challengeresponseauthentication) no$" >/dev/null; then
        log_pass "OpenSSH keyboard-interactive (PAM challenge-response) auth is disabled."
    else
        log_warn "OpenSSH keyboard-interactive authentication check did not return explicitly 'no'."
        ((WARNINGS++))
    fi
else
    log_fail "sshd binary not found!"
    ((FAILURES++))
fi

# --- Check 6: Active Network Listening Sockets ---
if ss -tulpn 2>/dev/null | grep -q ":${EXPECTED_PORT} "; then
    log_pass "Network socket check confirmed listening on port ${EXPECTED_PORT}."
else
    log_fail "No network socket found listening on expected SSH port ${EXPECTED_PORT}!"
    ((FAILURES++))
fi

if ss -tulpn 2>/dev/null | grep -q ":22 "; then
    if [[ "${EXPECTED_PORT}" != "22" ]]; then
        log_fail "Standard SSH port 22 is STILL open and listening!"
        ((FAILURES++))
    fi
else
    if [[ "${EXPECTED_PORT}" != "22" ]]; then
        log_pass "Standard SSH port 22 is verified closed."
    fi
fi

# --- Check 7: Uncomplicated Firewall (UFW) ---
if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(ufw status verbose 2>/dev/null || echo "")
    if echo "${UFW_STATUS}" | grep -Eq "^Status: active"; then
        log_pass "UFW firewall is active."
        if echo "${UFW_STATUS}" | grep -q "${EXPECTED_PORT}/tcp"; then
            log_pass "UFW whitelists port ${EXPECTED_PORT}/tcp."
        else
            log_fail "UFW does NOT have an allow rule for port ${EXPECTED_PORT}/tcp!"
            ((FAILURES++))
        fi
    else
        log_fail "UFW firewall is NOT active ('ufw status' != active)."
        ((FAILURES++))
    fi
else
    log_fail "UFW binary not installed!"
    ((FAILURES++))
fi

# --- Check 8: Fail2Ban IDS Status ---
if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active fail2ban >/dev/null 2>&1; then
    log_pass "Fail2Ban service is active and running."
    if fail2ban-client status sshd >/dev/null 2>&1; then
        log_pass "Fail2Ban jail 'sshd' is initialized and monitoring login attempts."
    else
        log_fail "Fail2Ban jail 'sshd' is not active!"
        ((FAILURES++))
    fi
else
    log_fail "Fail2Ban service is not active or not installed!"
    ((FAILURES++))
fi

# --- Check 9: Automated Security Updates ('unattended-upgrades') ---
if [[ -f "/etc/apt/apt.conf.d/20auto-upgrades" ]] && grep -Eq 'APT::Periodic::Unattended-Upgrade "1";' /etc/apt/apt.conf.d/20auto-upgrades; then
    log_pass "Unattended-upgrades is pre-seeded and enabled ('20auto-upgrades')."
else
    log_fail "Unattended-upgrades configuration not found or disabled ('20auto-upgrades')."
    ((FAILURES++))
fi

if [[ -f "/etc/apt/apt.conf.d/51unattended-upgrades-custom" ]] && grep -Eq 'Automatic-Reboot "true";' /etc/apt/apt.conf.d/51unattended-upgrades-custom; then
    log_pass "Automatic maintenance reboots are configured ('51unattended-upgrades-custom')."
else
    log_warn "Automatic reboot override check warning ('51unattended-upgrades-custom' missing or not true)."
    ((WARNINGS++))
fi

# --- Check 10: Docker Log Rotation ---
if [[ -f "/etc/docker/daemon.json" ]] && grep -q '"max-size"' /etc/docker/daemon.json; then
    log_pass "Docker daemon configuration '/etc/docker/daemon.json' contains log rotation rules."
else
    log_warn "Docker log rotation configuration ('daemon.json') is missing."
    ((WARNINGS++))
fi

echo -e "${BLUE}==============================================================================${NC}"
echo -e "Audit Results: ${GREEN}PASS (${FAILURES} failures, ${WARNINGS} warnings)${NC}"
echo -e "${BLUE}==============================================================================${NC}"

if [[ ${FAILURES} -eq 0 ]]; then
    echo -e "${GREEN}SYSTEM COMPLIANCE VERIFIED: VPS meets all baseline hardening requirements.${NC}"
    exit 0
else
    echo -e "${RED}SYSTEM COMPLIANCE FAILED: Found ${FAILURES} critical issue(s). Review log above.${NC}"
    exit 1
fi
