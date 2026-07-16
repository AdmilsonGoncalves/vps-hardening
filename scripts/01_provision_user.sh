#!/usr/bin/env bash
# ==============================================================================
# Script Name  : 01_provision_user.sh
# Description  : Stage 1 - Identity & Access Management (IAM) Provisioning
#                Creates an administrative user with sudo privileges and sets up
#                key-based SSH authentication securely without interactive prompts.
# Target OS    : Ubuntu 24.04 LTS / Debian / General Linux VPS
# ======================================
# Purpose:
#   Direct superuser (root) login via SSH is a major security vulnerability.
#   Before disabling root SSH login and changing SSH configuration ports, an
#   unprivileged administrative user with `sudo` access and SSH key authentication
#   must be created and verified.
#
# Usage:
#   sudo ./01_provision_user.sh [username] [path_to_ssh_public_key]
#
# Arguments:
#   $1 - username (optional, overrides ADMIN_USER from vps.env or defaults to 'vpsadmin')
#   $2 - path_to_ssh_public_key (optional, overrides PUBKEY_SOURCE from vps.env or defaults to '/root/.ssh/authorized_keys')
#
# Behavior & Safeguards:
#   1. Slices environment configuration from `vps.env` if present in the script directory.
#   2. Verifies root/sudo execution privileges.
#   3. Non-interactively creates the target user if they do not already exist (`useradd -m -s /bin/bash`).
#   4. Adds the user to the `sudo` group for administrative escalation.
#   5. Safely creates `/home/<username>/.ssh` with exact `700` directory permissions.
#   6. Populates `authorized_keys` from either the provided public key file or `/root/.ssh/authorized_keys`,
#      setting exact `600` file permissions and correct ownership (`chown -R <user>:<user>`).
#   7. Enforces a strict verification boundary before proceeding to Stage 2 (Hardening).
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
    # Load defaults from vps.env
    source "${SCRIPT_DIR}/vps.env"
fi

ADMIN_USER="${1:-${ADMIN_USER:-vpsadmin}}"
PUBKEY_SOURCE="${2:-${PUBKEY_SOURCE:-/root/.ssh/authorized_keys}}"
ADMIN_USER_PUBKEY="${ADMIN_USER_PUBKEY:-}"

log_info "Starting Stage 1: Provisioning administrative user '${ADMIN_USER}'..."

# --- Step 3: User Creation & Privilege Escalation ---
if id "${ADMIN_USER}" >/dev/null 2>&1; then
    log_info "User '${ADMIN_USER}' already exists. Updating group memberships..."
else
    log_info "Creating user '${ADMIN_USER}' with home directory and /bin/bash shell..."
    useradd -m -s /bin/bash "${ADMIN_USER}"
    log_success "User '${ADMIN_USER}' created."
fi

# Ensure user is added to the sudo group
log_info "Adding '${ADMIN_USER}' to the 'sudo' group..."
usermod -aG sudo "${ADMIN_USER}"
log_success "User '${ADMIN_USER}' granted sudo group privileges."

# --- Step 4: SSH Key-Based Authentication Setup ---
USER_HOME=$(eval echo "~${ADMIN_USER}")
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS_FILE="${SSH_DIR}/authorized_keys"

log_info "Configuring SSH key directory at '${SSH_DIR}'..."
mkdir -p "${SSH_DIR}"

if [[ -n "${ADMIN_USER_PUBKEY}" ]]; then
    log_info "Injecting authorized key from ADMIN_USER_PUBKEY defined in vps.env..."
    echo "${ADMIN_USER_PUBKEY}" > "${AUTH_KEYS_FILE}"
elif [[ -f "${PUBKEY_SOURCE}" && -s "${PUBKEY_SOURCE}" ]]; then
    log_info "Injecting authorized keys from '${PUBKEY_SOURCE}'..."
    cp "${PUBKEY_SOURCE}" "${AUTH_KEYS_FILE}"
elif [[ -f "${AUTH_KEYS_FILE}" && -s "${AUTH_KEYS_FILE}" ]]; then
    log_info "Existing authorized_keys found for '${ADMIN_USER}', preserving entries."
else
    log_warn "No valid authorized_keys found at '${PUBKEY_SOURCE}' and ADMIN_USER_PUBKEY is empty."
    log_warn "You MUST populate your public SSH key before running 02_verify_access.sh!"
    log_warn "  -> Method A (From local workstation): ssh-copy-id ${ADMIN_USER}@$(hostname -I | awk '{print $1}' 2>/dev/null || echo '<server-ip>')"
    log_warn "  -> Method B (Declarative via vps.env): Set ADMIN_USER_PUBKEY=\"ssh-ed25519 AAA...\" in vps.env and re-run ./01_provision_user.sh"
    touch "${AUTH_KEYS_FILE}"
fi

# Enforce strict OpenSSH permissions
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chmod 600 "${AUTH_KEYS_FILE}"
log_success "SSH directory and authorized_keys permissions enforced (700/600)."

# --- Step 5: Critical Verification Instruction ---
echo ""
echo -e "${YELLOW}==============================================================================${NC}"
echo -e "${YELLOW}                           CRITICAL NEXT STEPS                                ${NC}"
echo -e "${YELLOW}==============================================================================${NC}"
echo -e "Stage 1 complete! Before proceeding to Stage 2 (Service & Firewall Hardening),"
echo -e "you MUST verify that you can successfully log in as '${ADMIN_USER}' and execute sudo."
echo -e ""
echo -e "1. Open a ${GREEN}NEW TERMINAL WINDOW${NC} on your local workstation."
echo -e "2. Test SSH login using port 22 (current port):"
echo -e "   ${BLUE}ssh -p 22 ${ADMIN_USER}@$(hostname -I | awk '{print $1}' 2>/dev/null || echo '<server-ip>')${NC}"
echo -e "3. Verify sudo access inside the new session:"
echo -e "   ${BLUE}sudo -v${NC}"
echo -e ""
echo -e "Alternatively, run the verification check script right now:"
echo -e "   ${BLUE}./02_verify_access.sh ${ADMIN_USER}${NC}"
echo -e ""
echo -e "${RED}DO NOT run 03_harden_server.sh until you have confirmed working access!${NC}"
echo -e "${YELLOW}==============================================================================${NC}"
