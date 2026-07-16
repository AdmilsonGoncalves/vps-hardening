#!/usr/bin/env bash
# ==============================================================================
# Script Name  : 02_verify_access.sh
# Description  : Verification Script - Pre-Hardening Access & Permissions Check
#                Validates administrative user existence, sudo privileges, and
#                SSH authorized_keys file integrity/permissions before hardening.
# Target OS    : Ubuntu 24.04 LTS / Debian / General Linux VPS
# ==============================================================================
# Purpose:
#   Before applying strict SSH configurations (such as disabling PermitRootLogin,
#   disabling PasswordAuthentication, and changing the SSH listening port), it is
#   mandatory to verify that the newly provisioned administrative user has complete
#   sudo privileges and valid SSH keys configured. If any check fails, running
#   the subsequent hardening script (`03_harden_server.sh`) would result in a
#   permanent lockout from the VPS.
#
# Usage:
#   sudo ./02_verify_access.sh [username]
#
# Arguments:
#   $1 - username to verify (optional, overrides ADMIN_USER from vps.env or defaults to 'vpsadmin')
#
# Verification Checks Performed:
#   1. User Existence Check: Confirms the target user account exists.
#   2. Group Membership Check: Confirms the user belongs to the `sudo` group.
#   3. Sudo Privilege Check: Verifies the user can execute commands via `sudo` (-l check).
#   4. SSH Directory Integrity Check: Verifies `/home/<user>/.ssh` exists and has permissions <= 700.
#   5. Authorized Keys Check: Verifies `authorized_keys` exists, is non-empty, and has permissions <= 600.
#   6. Active SSH Port Check: Confirms sshd is currently listening on port 22 (baseline).
# ==============================================================================

set -euo pipefail

# --- Color Definitions for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_pass()    { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail()    { echo -e "${RED}[FAIL]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/vps.env" ]]; then
    source "${SCRIPT_DIR}/vps.env"
fi

ADMIN_USER="${1:-${ADMIN_USER:-vpsadmin}}"
ERRORS=0

echo -e "${BLUE}==============================================================================${NC}"
echo -e "${BLUE}         PRE-HARDENING ACCESS & CONFIGURATION AUDIT (${ADMIN_USER})         ${NC}"
echo -e "${BLUE}==============================================================================${NC}"

# --- Check 1: User Existence ---
if id "${ADMIN_USER}" >/dev/null 2>&1; then
    log_pass "User account '${ADMIN_USER}' exists."
else
    log_fail "User account '${ADMIN_USER}' does NOT exist."
    ((ERRORS++))
fi

# --- Check 2: Group Membership ---
if id -nG "${ADMIN_USER}" 2>/dev/null | grep -qw sudo; then
    log_pass "User '${ADMIN_USER}' is a member of the 'sudo' group."
else
    log_fail "User '${ADMIN_USER}' is NOT in the 'sudo' group."
    ((ERRORS++))
fi

# --- Check 3: Sudo Privileges ---
if sudo -l -U "${ADMIN_USER}" >/dev/null 2>&1; then
    log_pass "User '${ADMIN_USER}' has valid sudo command execution privileges."
else
    log_fail "User '${ADMIN_USER}' failed sudo privilege check (`sudo -l -U ${ADMIN_USER}`)."
    ((ERRORS++))
fi

# --- Check 4 & 5: SSH Directory & Authorized Keys ---
USER_HOME=$(eval echo "~${ADMIN_USER}" 2>/dev/null || echo "")
if [[ -n "${USER_HOME}" && -d "${USER_HOME}/.ssh" ]]; then
    DIR_PERMS=$(stat -c "%a" "${USER_HOME}/.ssh")
    if [[ "${DIR_PERMS}" == "700" || "${DIR_PERMS}" == "500" ]]; then
        log_pass "SSH directory '${USER_HOME}/.ssh' exists with secure permissions (${DIR_PERMS})."
    else
        log_fail "SSH directory '${USER_HOME}/.ssh' has insecure permissions (${DIR_PERMS}). Expected: 700."
        ((ERRORS++))
    fi

    AUTH_FILE="${USER_HOME}/.ssh/authorized_keys"
    if [[ -f "${AUTH_FILE}" && -s "${AUTH_FILE}" ]]; then
        FILE_PERMS=$(stat -c "%a" "${AUTH_FILE}")
        if [[ "${FILE_PERMS}" == "600" || "${FILE_PERMS}" == "400" ]]; then
            log_pass "authorized_keys exists, is non-empty, and has secure permissions (${FILE_PERMS})."
        else
            log_fail "authorized_keys has insecure permissions (${FILE_PERMS}). Expected: 600."
            ((ERRORS++))
        fi
    else
        log_fail "authorized_keys file '${AUTH_FILE}' is missing or empty!"
        ((ERRORS++))
    fi
else
    log_fail "SSH directory '${USER_HOME}/.ssh' is missing!"
    ((ERRORS++))
fi

# --- Check 6: Current SSH Daemon Status ---
if ss -tulpn 2>/dev/null | grep -q ":22 "; then
    log_pass "OpenSSH daemon is currently active and listening on standard port 22."
else
    log_warn "OpenSSH daemon is not currently listening on port 22 (it may already be customized)."
fi

echo -e "${BLUE}==============================================================================${NC}"
if [[ ${ERRORS} -eq 0 ]]; then
    echo -e "${GREEN}All pre-hardening checks PASSED!${NC}"
    echo -e "You can now safely proceed to run: ${BLUE}sudo ./03_harden_server.sh [ssh_port]${NC}"
    exit 0
else
    echo -e "${RED}Found ${ERRORS} issue(s) during access verification!${NC}"
    echo -e "${RED}DO NOT proceed with hardening until these issues are resolved to prevent lockout.${NC}"
    exit 1
fi
