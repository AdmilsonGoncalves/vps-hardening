#!/usr/bin/env bash
# ==============================================================================
# Script Name  : 06_optional_docker_maintenance.sh
# Description  : Stage 6 (Optional) - Automated Docker Maintenance & Build Cache Cleanup
#                Deploys a conservative, multi-stage pruning routine to prevent
#                disk exhaustion (No space left on device) while safeguarding
#                active containers and recent rollback images.
# Target OS    : Ubuntu 24.04 LTS / Debian / General Linux VPS
# ==============================================================================
# Purpose:
#   While Stage 2 (03_harden_server.sh) configures daemon-level log rotation,
#   containerized environments frequently suffer from storage exhaustion caused
#   by unmanaged Docker build cache (buildx layers), dangling images (<none>:<none>),
#   and abandoned stopped containers.
#
#   Running `docker system prune -a -f` indiscriminately inside a blind cron job
#   is dangerous: it deletes all tagged images not running at that exact second,
#   destroying base images and instant rollback capability.
#
#   This script deploys a conservative 3-stage maintenance pipeline scheduled
#   every Sunday at 04:00 AM with dedicated disk logging (/var/log/docker-maintenance.log)
#   and automated log rotation (`/etc/logrotate.d/docker-maintenance`).
#
# Usage:
#   sudo ./06_optional_docker_maintenance.sh
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

# --- Step 2: Load Configuration Defaults ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/vps.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/vps.env"
    log_info "Loaded configuration parameters from vps.env."
fi

# --- Step 3: Check Docker Status ---
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log_info "Docker is installed and active on this server."
else
    log_warn "Docker is not currently active or installed."
    log_info "Installing the conservative maintenance routine anyway so that any future Docker installation will be automatically protected against disk exhaustion."
fi

# --- Step 4: Deploy Conservative Maintenance Script (/usr/local/bin/docker-maintenance.sh) ---
MAINTENANCE_SCRIPT="/usr/local/bin/docker-maintenance.sh"
log_info "Creating conservative Docker maintenance script at ${MAINTENANCE_SCRIPT}..."

cat <<'EOF' > "${MAINTENANCE_SCRIPT}"
#!/usr/bin/env bash
# ==============================================================================
# Automated Docker Maintenance Routine (Conservative Multi-Stage Pruning)
# Deploys safe cleanup policies without destroying rollback images.
# Managed by Stage 6 of vps-hardening suite.
# ==============================================================================

LOG_FILE="/var/log/docker-maintenance.log"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

# Verify Docker is installed and running before attempting cleanup
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "[${TIMESTAMP}] [SKIP] Docker command not found or daemon not active. Skipping maintenance routine." >> "${LOG_FILE}"
    exit 0
fi

{
    echo "========================================================================"
    echo "[${TIMESTAMP}] [START] Starting Automated Docker Maintenance Routine"
    echo "------------------------------------------------------------------------"
    echo "[INFO] Docker disk usage BEFORE cleanup:"
    docker system df || true
    echo "------------------------------------------------------------------------"

    ERRORS=0

    # Stage 1: Prune stopped containers, unused networks, and dangling images (<none>:<none>)
    # NOTE: Targeted pruning is used to avoid wiping build cache in Stage 1. All tagged images are preserved safely.
    echo "[EXEC] Running: docker container prune -f, network prune -f, image prune -f"
    if ! (docker container prune -f && docker network prune -f && docker image prune -f); then
        echo "[ERROR] Stage 1 container/network/dangling pruning encountered errors."
        ERRORS=$((ERRORS + 1))
    fi

    # Stage 2: Prune build cache (buildx/layers) older than 7 days (168h)
    # Build layers are the primary cause of silent storage exhaustion in production VPS instances.
    echo "[EXEC] Running: docker builder prune --all --filter \"until=168h\" -f (Build cache older than 7 days)"
    if ! docker builder prune --all --filter "until=168h" -f; then
        echo "[ERROR] Stage 2 build cache pruning encountered errors."
        ERRORS=$((ERRORS + 1))
    fi

    # Stage 3: Conservative cleanup of unused tagged images older than 14 days (336h)
    # Provides a 2-week safety buffer for instant rollbacks while preventing abandoned images from residing on disk forever.
    echo "[EXEC] Running: docker image prune -a --filter \"until=336h\" -f (Unused tagged images older than 14 days)"
    if ! docker image prune -a --filter "until=336h" -f; then
        echo "[ERROR] Stage 3 unused image pruning encountered errors."
        ERRORS=$((ERRORS + 1))
    fi

    echo "------------------------------------------------------------------------"
    echo "[INFO] Docker disk usage AFTER cleanup:"
    docker system df || true

    if [ "${ERRORS}" -ne 0 ]; then
        echo "[FAILED] Docker Maintenance Completed with ${ERRORS} error(s)."
        echo "========================================================================"
        echo ""
        exit 1
    else
        echo "[DONE] Docker Maintenance Completed Successfully."
        echo "========================================================================"
        echo ""
        exit 0
    fi
} >> "${LOG_FILE}" 2>&1
EOF

chmod 700 "${MAINTENANCE_SCRIPT}"
chown root:root "${MAINTENANCE_SCRIPT}"
log_success "Conservative maintenance routine installed (${MAINTENANCE_SCRIPT}). permissions: 700."

# --- Step 5: Configure Log Rotation (/etc/logrotate.d/docker-maintenance) ---
LOGROTATE_CONF="/etc/logrotate.d/docker-maintenance"
log_info "Configuring log rotation rules at ${LOGROTATE_CONF}..."

cat <<EOF > "${LOGROTATE_CONF}"
/var/log/docker-maintenance.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF

chmod 644 "${LOGROTATE_CONF}"
chown root:root "${LOGROTATE_CONF}"
log_success "Log rotation configured (rotates weekly, retains 4 weeks compressed)."

# --- Step 6: Schedule Weekly Cron Job (/etc/cron.d/docker-maintenance) ---
CRON_FILE="/etc/cron.d/docker-maintenance"
log_info "Scheduling weekly maintenance cron job at ${CRON_FILE} (Sunday at 04:00 AM)..."

cat <<EOF > "${CRON_FILE}"
# Automated Conservative Docker Maintenance (Stage 6) — Runs every Sunday at 04:00 AM
0 4 * * 0 root /usr/bin/env bash ${MAINTENANCE_SCRIPT} > /dev/null 2>&1
EOF

chmod 644 "${CRON_FILE}"
chown root:root "${CRON_FILE}"
log_success "Cron schedule created: every Sunday at 04:00 AM (${CRON_FILE})."

# --- Step 7: Completion Summary ---
echo ""
echo -e "${GREEN}==============================================================================${NC}"
echo -e "${GREEN}        STAGE 6 (OPTIONAL) DOCKER MAINTENANCE SETUP COMPLETED!                ${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo -e "Summary of Active Maintenance Components:"
# shellcheck disable=SC2016
echo -e "  * Execution Script : ${YELLOW}${MAINTENANCE_SCRIPT}${NC} (Permissions: 700)"
# shellcheck disable=SC2016
echo -e "  * Cron Schedule    : ${GREEN}Sunday at 04:00 AM${NC} (${CRON_FILE})"
# shellcheck disable=SC2016
echo -e "  * Dedicated Log    : ${BLUE}/var/log/docker-maintenance.log${NC}"
# shellcheck disable=SC2016
echo -e "  * Log Rotation     : ${GREEN}${LOGROTATE_CONF}${NC} (4 weeks retention)"
echo -e ""
echo -e "Pruning Policy Summary:"
echo -e "  1. ${GREEN}container/network/image prune -f${NC} : Targeted cleanup of stopped containers, networks, and dangling images."
echo -e "  2. ${GREEN}builder prune --until=168h${NC}: Cleans build cache older than 7 days."
echo -e "  3. ${GREEN}image prune -a --until=336h${NC} : Cleans unused tagged images older than 14 days."
echo -e ""
echo -e "Note: To run an immediate proof-of-concept test right now, execute:"
echo -e "      ${YELLOW}sudo ${MAINTENANCE_SCRIPT} && cat /var/log/docker-maintenance.log${NC}"
echo -e "${GREEN}==============================================================================${NC}"
