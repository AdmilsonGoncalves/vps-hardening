#!/usr/bin/env bash
# ==============================================================================
# Script Name  : 05_optional_zsh_setup.sh
# Description  : Stage 5 (Optional) - Developer Shell & Productivity Enhancement
#                Installs Zsh, Oh My Zsh (OMZ), Spaceship/P10k themes, syntax
#                highlighting, auto-suggestions, NVM, Zoxide, and custom aliases.
# Target OS    : Ubuntu 24.04 LTS / Debian / General Linux VPS
# ==============================================================================
# Purpose:
#   While a baseline hardened server focuses strictly on security, administrative
#   efficiency requires a modern, responsive, and ergonomic terminal environment.
#   This optional script safely installs and configures Zsh, Oh My Zsh, essential
#   plugins (`zsh-autosuggestions`, `zsh-syntax-highlighting`, `nvm`), and
#   productivity tools (`zoxide`, `htop`, `ncdu`, `jq`) for the unprivileged
#   administrative user WITHOUT violating security or running untrusted root scripts.
#
# Usage:
#   sudo ./05_optional_zsh_setup.sh [username]
#
# Arguments:
#   $1 - username (optional, overrides ADMIN_USER from vps.env or defaults to 'vpsadmin')
#
# Key Features & Security Safeguards:
#   1. System Package Installation: Safely installs `zsh`, `git`, `curl`, `zoxide`,
#      `htop`, `ncdu`, `jq`, and `unzip` via official system repositories (`apt-get`).
#   2. Unprivileged Execution: Clones Oh My Zsh, plugins, and themes strictly under
#      the target user's context (`sudo -u <user>`) with exact ownership boundaries.
#   3. Theme & Plugin Suite: Installs both `spaceship-prompt` and `powerlevel10k`
#      themes along with `zsh-autosuggestions` and `zsh-syntax-highlighting`.
#   4. Node Version Manager (NVM): Prepares NVM inside the user's home directory.
#   5. Custom `.zshrc` Baseline: Generates an optimized configuration including
#      instant prompt checks, clean alias definitions (`clear_swap`, `sys-upgrade`, `sys-purge`),
#      and `zoxide` integration.
#   6. Default Shell Transition: Safely changes the administrative user's login
#      shell to `/bin/zsh`.
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

ADMIN_USER="${1:-${ADMIN_USER:-vpsadmin}}"

# Verify target user exists
if ! id "${ADMIN_USER}" >/dev/null 2>&1; then
    log_error "User '${ADMIN_USER}' does not exist! Run Stage 1 (01_provision_user.sh) first."
    exit 1
fi

USER_HOME=$(eval echo "~${ADMIN_USER}")
log_info "Starting Stage 5 (Optional): Shell Enhancement for user '${ADMIN_USER}' (${USER_HOME})..."

# --- Step 3: Install Essential System Packages & Productivity Tools ---
log_info "Installing Zsh, Zoxide, Git, Curl, locales, and productivity utilities via apt..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq zsh git curl wget unzip htop ncdu jq zoxide locales >/dev/null
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
log_success "System packages, locales (en_US.UTF-8), and Zoxide installed."

# --- Step 4: Install Oh My Zsh (Non-Interactive, under target user context) ---
OMZ_DIR="${USER_HOME}/.oh-my-zsh"
if [[ -d "${OMZ_DIR}" ]]; then
    log_info "Oh My Zsh directory already exists at '${OMZ_DIR}'. Skipping fresh install..."
else
    log_info "Cloning Oh My Zsh for '${ADMIN_USER}'..."
    sudo -u "${ADMIN_USER}" git clone -q --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "${OMZ_DIR}"
    log_success "Oh My Zsh installed successfully."
fi

# --- Step 5: Install Themes (`spaceship-prompt` and `powerlevel10k`) ---
ZSH_CUSTOM="${OMZ_DIR}/custom"

# 5.1 Spaceship Theme
SPACESHIP_DIR="${ZSH_CUSTOM}/themes/spaceship-prompt"
if [[ ! -d "${SPACESHIP_DIR}" ]]; then
    log_info "Installing Spaceship Zsh theme..."
    sudo -u "${ADMIN_USER}" git clone -q --depth=1 https://github.com/spaceship-prompt/spaceship-prompt.git "${SPACESHIP_DIR}"
    sudo -u "${ADMIN_USER}" ln -sf "${SPACESHIP_DIR}/spaceship.zsh-theme" "${ZSH_CUSTOM}/themes/spaceship.zsh-theme"
    log_success "Spaceship theme installed."
fi

# 5.2 Powerlevel10k Theme
P10K_DIR="${ZSH_CUSTOM}/themes/powerlevel10k"
if [[ ! -d "${P10K_DIR}" ]]; then
    log_info "Installing Powerlevel10k Zsh theme..."
    sudo -u "${ADMIN_USER}" git clone -q --depth=1 https://github.com/romkatv/powerlevel10k.git "${P10K_DIR}"
    log_success "Powerlevel10k theme installed."
fi

# --- Step 6: Install OMZ Plugins ---
# 6.1 zsh-autosuggestions
SUGGEST_DIR="${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
if [[ ! -d "${SUGGEST_DIR}" ]]; then
    log_info "Installing zsh-autosuggestions plugin..."
    sudo -u "${ADMIN_USER}" git clone -q --depth=1 https://github.com/zsh-users/zsh-autosuggestions "${SUGGEST_DIR}"
fi

# 6.2 zsh-syntax-highlighting
SYNTAX_DIR="${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"
if [[ ! -d "${SYNTAX_DIR}" ]]; then
    log_info "Installing zsh-syntax-highlighting plugin..."
    sudo -u "${ADMIN_USER}" git clone -q --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "${SYNTAX_DIR}"
fi
log_success "OMZ plugins (autosuggestions & syntax-highlighting) installed."

# --- Step 7: Install Node Version Manager (NVM) ---
NVM_DIR="${USER_HOME}/.nvm"
if [[ ! -d "${NVM_DIR}" ]]; then
    log_info "Installing NVM (Node Version Manager) for user '${ADMIN_USER}'..."
    sudo -u "${ADMIN_USER}" mkdir -p "${NVM_DIR}"
    sudo -u "${ADMIN_USER}" bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | NVM_DIR='${NVM_DIR}' bash >/dev/null 2>&1" || true
    log_success "NVM installed at '${NVM_DIR}'."
fi

# --- Step 8: Generate Optimized `.zshrc` Configuration ---
ZSHRC_FILE="${USER_HOME}/.zshrc"
BACKUP_ZSHRC="${ZSHRC_FILE}.bak.$(date +%F_%T)"
if [[ -f "${ZSHRC_FILE}" ]]; then
    cp "${ZSHRC_FILE}" "${BACKUP_ZSHRC}"
    log_info "Backed up existing .zshrc to ${BACKUP_ZSHRC}"
fi

log_info "Generating customized .zshrc baseline..."
cat <<'EOF' > "${ZSHRC_FILE}"
# ==============================================================================
# ~/.zshrc — Hardened & Optimized Zsh Configuration
# ==============================================================================

# --- Locale & Environment Setup ---
# Enforce en_US.UTF-8 locale to prevent Perl/locale warnings when connecting via SSH from clients with local locales
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Path to Oh My Zsh installation
export ZSH="$HOME/.oh-my-zsh"

# Set Zsh theme.
# Default active theme is 'spaceship' (or switch to 'powerlevel10k/powerlevel10k')
ZSH_THEME="spaceship"

# Uncomment line below if using Powerlevel10k instead:
# ZSH_THEME="powerlevel10k/powerlevel10k"

# Standard Oh My Zsh settings
HYPHEN_INSENSITIVE="true"
ENABLE_CORRECTION="true"
COMPLETION_WAITING_DOTS="true"
HIST_STAMPS="yyyy-mm-dd"

# Loaded Plugins (git + autosuggestions + syntax highlighting + nvm)
plugins=(git zsh-autosuggestions zsh-syntax-highlighting nvm)

# Load Oh My Zsh core
source "$ZSH/oh-my-zsh.sh"

# --- User Environment & NVM Setup ---
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# --- Custom System & Maintenance Aliases ---
# Memory & Swap Reclamation (Requires sudo)
alias clean-swap='sudo swapoff -a && sudo swapon -a && sync && echo 3 | sudo tee /proc/sys/vm/drop_caches'

# System Routine Upgrade (Safe upgrade without removing packages)
alias sys-upgrade='sudo apt update && sudo apt upgrade -y && (sudo snap refresh 2>/dev/null || true)'

# System Package Purge/Cleanup (Interactive confirmation for safety)
alias sys-purge='sudo apt autoremove --purge && sudo apt autoclean'

# Quick directory/file shortcuts
alias l='ls -lh --color=auto'
alias ll='ls -la --color=auto'

# --- Zoxide (Ultra-fast smart navigation: replace cd/z) ---
if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh)"
fi

# --- Load Powerlevel10k Custom Configuration (If available) ---
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
EOF

# Enforce secure ownership and permissions
chown "${ADMIN_USER}:${ADMIN_USER}" "${ZSHRC_FILE}"
chmod 600 "${ZSHRC_FILE}"
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${OMZ_DIR}"
log_success "Created customized .zshrc with clean permissions (600)."

# --- Step 9: Set Zsh as Default Shell ---
ZSH_BIN=$(command -v zsh)
CURRENT_SHELL=$(getent passwd "${ADMIN_USER}" | cut -d: -f7)

if [[ "${CURRENT_SHELL}" != "${ZSH_BIN}" ]]; then
    log_info "Changing default login shell for '${ADMIN_USER}' to ${ZSH_BIN}..."
    usermod -s "${ZSH_BIN}" "${ADMIN_USER}"
    log_success "Login shell changed to ${ZSH_BIN}."
else
    log_info "User '${ADMIN_USER}' already uses ${ZSH_BIN} as login shell."
fi

# --- Step 10: Completion Summary ---
echo ""
echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}             STAGE 5 (OPTIONAL) SHELL SETUP COMPLETED!                        ${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo -e "Summary of Installed Components for '${ADMIN_USER}':"
echo -e "  * Shell        : ${YELLOW}Zsh (${ZSH_BIN})${NC}"
echo -e "  * Framework    : ${GREEN}Oh My Zsh (${OMZ_DIR})${NC}"
echo -e "  * Themes       : ${GREEN}Spaceship & Powerlevel10k${NC} (Active: Spaceship)"
echo -e "  * Plugins      : ${GREEN}git, zsh-autosuggestions, zsh-syntax-highlighting, nvm${NC}"
echo -e "  * Utilities    : ${GREEN}Zoxide (z command), NVM, htop, ncdu, jq, locales (en_US.UTF-8)${NC}"
echo -e "  * Custom Aliases: ${BLUE}clean-swap, sys-upgrade, sys-purge, zoxide init${NC}"
echo -e ""
echo -e "Next Step: Log in as '${ADMIN_USER}' via SSH. Your Zsh environment will load instantly!"
echo -e "${GREEN}==============================================================================${NC}"
