#!/usr/bin/env bash
# ==============================================================================
#  node-bootstrap.sh — Remnawave node installer with rotating SNI
#  Supports: Debian 12+ / Ubuntu 22.04+  |  Requires: root
#
#  Usage (interactive):     bash node-bootstrap.sh
#  Usage (non-interactive): bash node-bootstrap.sh --domain ... --cf-token ... -y
#
#  Author:   catoo-hub
#  License:  MIT
#  Version:  1.0.0
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 · CONSTANTS & GLOBALS
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/node-bootstrap.log"
readonly STATE_DIR="/opt/web/state"
readonly CONFIG_FILE="${STATE_DIR}/config.env"
readonly VERSION_FILE="${STATE_DIR}/version"
readonly BACKUP_DIR="/var/backups/node-bootstrap"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

readonly WEB_DIR="/opt/web"
readonly NODE_DIR="${WEB_DIR}/node"
readonly NGINX_DIR="${WEB_DIR}/nginx"
readonly NGINX_SOCK="/dev/shm/nginx.sock"

readonly NSTP_BIN="/usr/local/bin/nstp"
readonly SNI_ROTATE_BIN="/usr/local/bin/web-sni-rotate"
readonly CERT_RENEW_BIN="/usr/local/bin/web-cert-renew"

# Container names — neutral
readonly NODE_CONTAINER="web-node"
readonly NGINX_CONTAINER="web-nginx"

# Image names — upstream-dictated (can't rename)
readonly NODE_IMAGE="ghcr.io/remnawave/node:latest"
readonly NGINX_IMAGE="nginx:1.27-alpine"

# ── Runtime flags ────────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
NON_INTERACTIVE=false
SKIP_UPDATE=false
UNINSTALL=false
WITH_MONITORING=false

# Required params
DOMAIN=""                  # example.com — wildcard base
NODE_NAME=""               # AUTOSNI:NODE_NAME tag value, default = hostname
CF_TOKEN=""                # Cloudflare API Token
PANEL_URL=""               # https://panel.example.com
PANEL_API_TOKEN=""         # API token from panel
NODE_SECRET_KEY=""         # SECRET_KEY from panel's "Create node" flow
NODE_PORT="2222"           # rw-node bind port (panel ↔ node)
ROTATION_DAYS=3
ACTIVE_SNIS=3
SNI_STYLE="cdn"            # cdn | words | hex
DEFAULT_FP="randomized"    # randomized | chrome | firefox | ...

# Optional
NODE_INBOUND_UUID=""       # config-profile inbound to manage (panel API will look up if blank)
CONFIG_PROFILE_UUID=""

# Auto-detected
NODE_PUBLIC_IP=""
HOSTNAME_SHORT=""
OS_ID=""
OS_VERSION_ID=""
ARCH=""
IS_CONTAINER=false
VIRT_TYPE=""
PKG_MGR="apt-get"

# Step status tracking
declare -A STEP_STATUS=()

# Auto-detect pipe mode
if [[ ! -t 0 ]]; then
    NON_INTERACTIVE=true
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 · COLOURS & LOGGING
# ─────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null && [[ "$(tput colors)" -ge 8 ]]; then
    RED=$'\e[0;31m';    LRED=$'\e[1;31m'
    GREEN=$'\e[0;32m';  LGREEN=$'\e[1;32m'
    YELLOW=$'\e[1;33m'; BLUE=$'\e[0;34m'
    CYAN=$'\e[0;36m';   MAGENTA=$'\e[0;35m'
    WHITE=$'\e[1;37m';  GRAY=$'\e[0;37m'
    BOLD=$'\e[1m';      RESET=$'\e[0m'
else
    RED=''; LRED=''; GREEN=''; LGREEN=''; YELLOW=''
    BLUE=''; CYAN=''; MAGENTA=''; WHITE=''; GRAY=''
    BOLD=''; RESET=''
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/node-bootstrap.log"

_log_raw() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
_log_session_header() {
    {
        printf '\n%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf '%s  [SESSION] node-bootstrap v%s | PID=%s | %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$SCRIPT_VERSION" "$$" "$(hostname)"
        printf '%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    } >> "$LOG_FILE"
}

log_info()  { echo -e "  ${GREEN}[INFO]${RESET}  $*"; _log_raw "[INFO]  $*"; }
log_ok()    { echo -e "  ${LGREEN}[ OK ]${RESET}  $*"; _log_raw "[ OK ]  $*"; }
log_warn()  { echo -e "  ${YELLOW}[WARN]${RESET}  $*"; _log_raw "[WARN]  $*"; }
log_error() { echo -e "  ${LRED}[ERR ]${RESET}  $*" >&2; _log_raw "[ERR ]  $*"; }
log_debug() { [[ "$VERBOSE" == true ]] && echo -e "  ${GRAY}[DBG ]${RESET}  $*"; _log_raw "[DBG ]  $*"; }
log_dry()   { echo -e "  ${MAGENTA}[DRY ]${RESET}  $*"; _log_raw "[DRY ]  $*"; }
log_step()  { echo ""; echo -e "${BOLD}══ $*${RESET}"; _log_raw "═══ $*"; }

print_separator() { echo -e "  ${GRAY}─────────────────────────────────────────────${RESET}"; }
print_header() {
    cat <<EOF

  ${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}
  ${BOLD}║          NODE BOOTSTRAP  ·  ${SCRIPT_VERSION}                           ║${RESET}
  ${BOLD}║          Remnawave node + rotating SNI + selfsteal      ║${RESET}
  ${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 · TRAP / FATAL HANDLER
# ─────────────────────────────────────────────────────────────────────────────

_fatal_exit() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "Abnormal exit (code ${rc}). Review ${LOG_FILE}"
    fi
    exit $rc
}
trap _fatal_exit EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 · PREFLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

_detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION_ID="${VERSION_ID:-unknown}"
        log_info "Detected OS : ${PRETTY_NAME:-${OS_ID} ${OS_VERSION_ID}}"
    else
        log_error "/etc/os-release missing — cannot detect OS"
        exit 1
    fi
}

_detect_arch() {
    ARCH="$(uname -m)"
    log_info "Architecture: ${ARCH}"
    case "$ARCH" in
        x86_64|aarch64) ;;
        *) log_warn "Untested architecture: ${ARCH} — proceeding anyway" ;;
    esac
}

_detect_virt() {
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo 'none')"
        if [[ "$VIRT_TYPE" =~ ^(openvz|lxc|lxc-libvirt|docker|podman)$ ]]; then
            IS_CONTAINER=true
            log_warn "Container virtualization detected: ${VIRT_TYPE} — Docker may have issues"
        else
            log_info "Virtualization: ${VIRT_TYPE}"
        fi
    fi
}

_check_internet() {
    log_debug "Checking internet connectivity..."
    if ! curl -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace -o /dev/null 2>/dev/null \
       && ! curl -fsS --max-time 10 https://8.8.8.8 -o /dev/null 2>/dev/null; then
        log_error "No internet connectivity"
        exit 1
    fi
    log_ok "Internet connectivity — OK"
}

_detect_public_ip() {
    NODE_PUBLIC_IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)"
    if [[ -z "$NODE_PUBLIC_IP" ]]; then
        NODE_PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '')"
    fi
    HOSTNAME_SHORT="$(hostname -s)"
}

preflight_checks() {
    log_step "Preflight checks"
    if [[ $EUID -ne 0 ]]; then
        log_error "Must run as root (use sudo)"
        exit 1
    fi
    log_debug "Running as root — OK"

    _detect_os
    _detect_arch
    _detect_virt
    _check_internet
    _detect_public_ip
    log_ok "Preflight checks passed"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 · SMALL UTILITIES
# ─────────────────────────────────────────────────────────────────────────────

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    local b="${BACKUP_DIR}/$(basename "$f").${TIMESTAMP}.bak"
    cp -a "$f" "$b"
    log_debug "Backed up: $f → $b"
}

apt_update() {
    [[ "$SKIP_UPDATE" == true ]] && { log_info "Skipping apt update (--skip-update)"; return 0; }
    log_step "Updating package lists"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would run: apt-get update"
        return 0
    fi
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    log_ok "Packages updated"
}

install_packages() {
    local pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install: ${pkgs[*]}"
        return 0
    fi
    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" &>/dev/null || missing+=("$p")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        log_debug "All requested packages already installed: ${pkgs[*]}"
        return 0
    fi
    log_info "Installing: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    log_ok "Installed: ${missing[*]}"
}

_validate_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

_validate_url() {
    [[ "$1" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$ ]]
}

_validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

state_save() {
    mkdir -p "$STATE_DIR"
    cat > "$CONFIG_FILE" <<EOF
# node-bootstrap install config — generated $(date -Iseconds)
DOMAIN="${DOMAIN}"
NODE_NAME="${NODE_NAME}"
NODE_PUBLIC_IP="${NODE_PUBLIC_IP}"
NODE_PORT="${NODE_PORT}"
PANEL_URL="${PANEL_URL}"
ROTATION_DAYS="${ROTATION_DAYS}"
ACTIVE_SNIS="${ACTIVE_SNIS}"
SNI_STYLE="${SNI_STYLE}"
DEFAULT_FP="${DEFAULT_FP}"
CONFIG_PROFILE_UUID="${CONFIG_PROFILE_UUID}"
NODE_INBOUND_UUID="${NODE_INBOUND_UUID}"
EOF
    chmod 600 "$CONFIG_FILE"

    # Secrets stored separately, 600
    cat > "${STATE_DIR}/secrets.env" <<EOF
CF_TOKEN="${CF_TOKEN}"
PANEL_API_TOKEN="${PANEL_API_TOKEN}"
NODE_SECRET_KEY="${NODE_SECRET_KEY}"
EOF
    chmod 600 "${STATE_DIR}/secrets.env"

    echo "$SCRIPT_VERSION" > "$VERSION_FILE"
}

state_load() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    if [[ -f "${STATE_DIR}/secrets.env" ]]; then
        # shellcheck disable=SC1091
        source "${STATE_DIR}/secrets.env"
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 · PARAM COLLECTION (interactive prompts + flag validation)
# ─────────────────────────────────────────────────────────────────────────────

collect_params() {
    log_step "Collecting installation parameters"

    # Default node name = hostname (sanitized for tag regex ^[A-Z0-9_:]+$)
    if [[ -z "$NODE_NAME" ]]; then
        NODE_NAME="$(echo "$HOSTNAME_SHORT" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_:' '_')"
        NODE_NAME="${NODE_NAME:-NODE01}"
    fi

    # DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        if [[ "$NON_INTERACTIVE" == true ]]; then
            log_error "--domain is required (e.g. example.com)"
            exit 1
        fi
        while true; do
            read -rp "  Base domain for wildcard cert (e.g. example.com → *.node.example.com): " DOMAIN
            _validate_domain "$DOMAIN" && break
            log_warn "Invalid domain: '${DOMAIN}'"
        done
    fi
    _validate_domain "$DOMAIN" || { log_error "Invalid --domain: ${DOMAIN}"; exit 1; }

    # CF_TOKEN
    if [[ -z "$CF_TOKEN" ]]; then
        if [[ "$NON_INTERACTIVE" == true ]]; then
            log_error "--cf-token is required"
            exit 1
        fi
        echo -e "  ${GRAY}Generate at Cloudflare → My Profile → API Tokens (scope: Zone:DNS:Edit for ${DOMAIN})${RESET}"
        while true; do
            read -rsp "  Cloudflare API Token (input hidden): " CF_TOKEN
            echo ""
            [[ -n "$CF_TOKEN" && ${#CF_TOKEN} -ge 30 ]] && break
            log_warn "Token looks too short — re-enter"
        done
    fi

    # PANEL_URL
    if [[ -z "$PANEL_URL" ]]; then
        if [[ "$NON_INTERACTIVE" == true ]]; then
            log_error "--panel-url is required"
            exit 1
        fi
        while true; do
            read -rp "  Panel URL (https://panel.example.com): " PANEL_URL
            _validate_url "$PANEL_URL" && break
            log_warn "Invalid URL: '${PANEL_URL}'"
        done
    fi
    PANEL_URL="${PANEL_URL%/}"
    _validate_url "$PANEL_URL" || { log_error "Invalid --panel-url"; exit 1; }

    # PANEL_API_TOKEN
    if [[ -z "$PANEL_API_TOKEN" ]]; then
        if [[ "$NON_INTERACTIVE" == true ]]; then
            log_error "--panel-token is required"
            exit 1
        fi
        echo -e "  ${GRAY}Generate in panel: Settings → API Tokens${RESET}"
        while true; do
            read -rsp "  Panel API token (input hidden): " PANEL_API_TOKEN
            echo ""
            [[ -n "$PANEL_API_TOKEN" && ${#PANEL_API_TOKEN} -ge 16 ]] && break
            log_warn "Token looks too short — re-enter"
        done
    fi

    # NODE_SECRET_KEY
    if [[ -z "$NODE_SECRET_KEY" ]]; then
        if [[ "$NON_INTERACTIVE" == true ]]; then
            log_error "--node-key is required (SECRET_KEY from panel's Create Node flow)"
            exit 1
        fi
        echo -e "  ${GRAY}In panel: Nodes → Create new node → copy SECRET_KEY${RESET}"
        while true; do
            read -rsp "  Node SECRET_KEY (input hidden): " NODE_SECRET_KEY
            echo ""
            [[ -n "$NODE_SECRET_KEY" && ${#NODE_SECRET_KEY} -ge 20 ]] && break
            log_warn "Key looks too short — re-enter"
        done
    fi

    # NODE_PORT
    if [[ "$NON_INTERACTIVE" == false ]]; then
        local _np
        read -rp "  Node port (panel ↔ node communication) [${NODE_PORT}]: " _np
        NODE_PORT="${_np:-$NODE_PORT}"
    fi
    _validate_port "$NODE_PORT" || { log_error "Invalid node port: ${NODE_PORT}"; exit 1; }

    log_info "DOMAIN  : ${DOMAIN}  (cert covers *.node.${DOMAIN})"
    log_info "NODE    : ${NODE_NAME} @ ${NODE_PUBLIC_IP}:${NODE_PORT}"
    log_info "PANEL   : ${PANEL_URL}"
    log_info "SNI POL : ${ACTIVE_SNIS}× active × rotate every ${ROTATION_DAYS}d (style: ${SNI_STYLE}, fp: ${DEFAULT_FP})"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 · BASE HARDENING (lifted from server-bootstrap.sh)
# ─────────────────────────────────────────────────────────────────────────────

setup_base_packages() {
    log_step "Installing base packages"
    install_packages curl wget git unzip tar jq vim nano htop net-tools dnsutils \
                     iproute2 ufw fail2ban socat tcpdump mtr-tiny ca-certificates \
                     lsb-release gnupg2 software-properties-common bc psmisc procps
    STEP_STATUS["base_packages"]="OK"
}

setup_sysctl() {
    log_step "Applying network sysctl (BBR, TCP buffers)"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would write /etc/sysctl.d/99-node-net.conf"
        STEP_STATUS["sysctl"]="DRY"
        return 0
    fi
    cat > /etc/sysctl.d/99-node-net.conf <<'EOF'
# node-bootstrap network tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 786432 1048576 1572864
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.icmp_echo_ignore_all = 1
EOF
    sysctl --system &>/dev/null || true
    log_ok "Sysctl applied (BBR enabled)"
    STEP_STATUS["sysctl"]="OK"
}

setup_swap() {
    log_step "Swap configuration"
    if swapon --show | grep -q '^'; then
        local sz
        sz="$(swapon --show=SIZE --noheadings | head -1)"
        log_info "Swap already active (${sz}). Skipping."
        STEP_STATUS["swap"]="SKIPPED"
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would create 2G swap file at /swapfile"
        STEP_STATUS["swap"]="DRY"
        return 0
    fi
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log_ok "Swap 2G created and enabled"
    STEP_STATUS["swap"]="OK"
}

_get_ssh_port() {
    local port
    port="$(awk '/^Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
    [[ -z "$port" ]] && port="$(ss -tnlp 2>/dev/null | awk '/sshd/ {split($4,a,":"); print a[length(a)]; exit}')"
    echo "${port:-22}"
}

setup_ssh() {
    log_step "SSH hardening"
    local sshd_config=/etc/ssh/sshd_config
    backup_file "$sshd_config"
    local ssh_port
    ssh_port="$(_get_ssh_port)"
    log_info "Detected SSH port: ${ssh_port}"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would set PermitRootLogin prohibit-password, PasswordAuthentication no (if key present)"
        STEP_STATUS["ssh"]="DRY"
        return 0
    fi
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_config"
    sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' "$sshd_config"
    sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 60/' "$sshd_config"
    if sshd -t -f "$sshd_config" 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        log_ok "SSH config applied"
        STEP_STATUS["ssh"]="OK"
    else
        log_error "sshd -t validation failed — reverting"
        local b="${BACKUP_DIR}/$(basename $sshd_config).${TIMESTAMP}.bak"
        [[ -f "$b" ]] && cp -a "$b" "$sshd_config"
        STEP_STATUS["ssh"]="FAILED"
    fi
}

setup_ufw() {
    log_step "Configuring UFW"
    install_packages ufw
    local ssh_port
    ssh_port="$(_get_ssh_port)"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would allow SSH(${ssh_port}), 80, 443, ${NODE_PORT}"
        STEP_STATUS["ufw"]="DRY"
        return 0
    fi
    if [[ "$IS_CONTAINER" == true ]]; then
        log_warn "Container — UFW may not work. Skipping."
        STEP_STATUS["ufw"]="SKIPPED(container)"
        return 0
    fi
    ufw --force reset &>/dev/null
    ufw default deny incoming  &>/dev/null
    ufw default allow outgoing &>/dev/null
    ufw allow "${ssh_port}/tcp" comment 'SSH' &>/dev/null
    ufw allow 80/tcp comment 'ACME HTTP-01 backup + http→https'  &>/dev/null
    ufw allow 443/tcp comment 'Xray Reality (TLS)' &>/dev/null
    ufw allow "${NODE_PORT}/tcp" comment 'panel → node' &>/dev/null
    if ! ufw show added 2>/dev/null | grep -qE "ufw allow ${ssh_port}"; then
        log_error "SAFETY ABORT: SSH not in UFW rules — refusing to enable"
        STEP_STATUS["ufw"]="FAILED"
        return 1
    fi
    ufw --force enable &>/dev/null
    log_ok "UFW enabled (ssh:${ssh_port}, 80, 443, node:${NODE_PORT})"
    STEP_STATUS["ufw"]="OK"
}

setup_fail2ban() {
    log_step "Configuring Fail2Ban"
    install_packages fail2ban
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would write /etc/fail2ban/jail.local with sshd"
        STEP_STATUS["fail2ban"]="DRY"
        return 0
    fi
    local jail=/etc/fail2ban/jail.local
    if [[ ! -s "$jail" ]]; then
        local ssh_port
        ssh_port="$(_get_ssh_port)"
        cat > "$jail" <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ${ssh_port}
EOF
        log_info "Created jail.local (sshd, port ${ssh_port})"
    fi
    systemctl enable fail2ban &>/dev/null
    systemctl restart fail2ban
    log_ok "Fail2Ban running"
    STEP_STATUS["fail2ban"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8 · DOCKER (with distro fallback if get.docker.com is blocked)
# ─────────────────────────────────────────────────────────────────────────────

install_docker() {
    log_step "Installing Docker & Compose v2"
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        log_ok "Docker + Compose v2 already installed: $(docker --version)"
        STEP_STATUS["docker"]="SKIPPED"
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install Docker (try get.docker.com, fall back to docker.io)"
        STEP_STATUS["docker"]="DRY"
        return 0
    fi

    # Clean up any stale apt source that returns 403
    if [[ -f /etc/apt/sources.list.d/docker.list ]] && \
       ! curl -fsS --max-time 5 -I https://download.docker.com/linux/ubuntu/dists/ >/dev/null 2>&1; then
        log_warn "Stale docker.list pointing at unreachable repo — removing"
        rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg 2>/dev/null || true
        apt-get update -qq 2>/dev/null || true
    fi

    local docker_ok=false
    log_info "Trying get.docker.com..."
    if curl -fsSL --max-time 30 https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null \
       && sh /tmp/get-docker.sh 2>&1 | tail -10 | sed 's/^/    [docker-installer] /' \
       && command -v docker &>/dev/null; then
        docker_ok=true
        log_ok "Docker installed via get.docker.com: $(docker --version)"
    fi
    rm -f /tmp/get-docker.sh 2>/dev/null

    if [[ "$docker_ok" != true ]]; then
        log_warn "get.docker.com unavailable — falling back to distro docker.io"
        rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null || true
        apt-get update -qq 2>/dev/null || true
        install_packages docker.io docker-compose-v2 || \
            install_packages docker.io docker-compose-plugin || \
            install_packages docker.io
        if command -v docker &>/dev/null; then
            docker_ok=true
            log_ok "Docker installed from distro: $(docker --version)"
        fi
    fi

    if [[ "$docker_ok" != true ]]; then
        log_error "All Docker install paths failed"
        STEP_STATUS["docker"]="FAILED"
        return 1
    fi

    systemctl enable docker &>/dev/null || true
    systemctl start docker &>/dev/null || true
    if ! docker compose version &>/dev/null; then
        install_packages docker-compose-plugin 2>/dev/null || \
        install_packages docker-compose-v2     2>/dev/null || \
        log_warn "docker compose plugin still missing"
    fi
    log_ok "Compose: $(docker compose version 2>/dev/null || echo unavailable)"
    STEP_STATUS["docker"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 9 · WILDCARD CERT via acme.sh + Cloudflare DNS-01
# ─────────────────────────────────────────────────────────────────────────────

setup_cert() {
    log_step "Issuing wildcard cert for *.node.${DOMAIN}"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install acme.sh and issue *.node.${DOMAIN} via Cloudflare DNS-01"
        STEP_STATUS["cert"]="DRY"
        return 0
    fi

    # 1. Install acme.sh if missing
    local acme_home="/root/.acme.sh"
    if [[ ! -x "${acme_home}/acme.sh" ]]; then
        log_info "Installing acme.sh..."
        curl -fsSL https://get.acme.sh -o /tmp/acme-install.sh
        sh /tmp/acme-install.sh --install-online >/dev/null 2>&1 || {
            log_error "acme.sh install failed"
            STEP_STATUS["cert"]="FAILED"
            return 1
        }
        rm -f /tmp/acme-install.sh
    fi

    # 2. Set Let's Encrypt as default CA
    "${acme_home}/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    # 3. Register account (idempotent)
    "${acme_home}/acme.sh" --register-account -m "admin@${DOMAIN}" >/dev/null 2>&1 || true

    # 4. Issue wildcard cert via Cloudflare DNS-01
    mkdir -p "${NGINX_DIR}/ssl"
    local fullchain="${NGINX_DIR}/ssl/fullchain.crt"
    local privkey="${NGINX_DIR}/ssl/private.key"

    # If cert already exists and not near expiry, skip
    if [[ -f "$fullchain" ]] && openssl x509 -in "$fullchain" -checkend $((60*86400)) -noout 2>/dev/null; then
        log_info "Cert exists and valid >60 days — skipping issuance"
        STEP_STATUS["cert"]="SKIPPED"
        return 0
    fi

    log_info "Requesting wildcard cert (this can take up to 2 min for DNS propagation)..."
    CF_Token="$CF_TOKEN" "${acme_home}/acme.sh" --issue \
        --dns dns_cf \
        -d "node.${DOMAIN}" \
        -d "*.node.${DOMAIN}" \
        --keylength ec-256 \
        --server letsencrypt \
        --force 2>&1 | sed 's/^/    [acme] /' || {
        log_error "acme.sh failed to issue cert — check Cloudflare token & domain"
        STEP_STATUS["cert"]="FAILED"
        return 1
    }

    # 5. Install cert to nginx path with proper hooks
    "${acme_home}/acme.sh" --install-cert \
        -d "node.${DOMAIN}" \
        --ecc \
        --fullchain-file "$fullchain" \
        --key-file "$privkey" \
        --reloadcmd "docker compose -f ${NGINX_DIR}/docker-compose.yml exec nginx nginx -s reload 2>/dev/null || true" \
        >/dev/null

    chmod 600 "$privkey"
    chmod 644 "$fullchain"

    log_ok "Wildcard cert installed at ${NGINX_DIR}/ssl/"

    # 6. Install renewal cron (acme.sh installs its own cron, but we also write a manual renew helper)
    cat > "$CERT_RENEW_BIN" <<EOF
#!/usr/bin/env bash
# Manual cert renewal — called by 'nstp cert renew'
set -e
CF_Token="\$(grep '^CF_TOKEN=' ${STATE_DIR}/secrets.env | cut -d'"' -f2)" \\
    ${acme_home}/acme.sh --renew -d node.${DOMAIN} --ecc --force
${acme_home}/acme.sh --install-cert -d node.${DOMAIN} --ecc \\
    --fullchain-file ${fullchain} \\
    --key-file ${privkey} \\
    --reloadcmd "docker compose -f ${NGINX_DIR}/docker-compose.yml exec nginx nginx -s reload 2>/dev/null || true"
EOF
    chmod +x "$CERT_RENEW_BIN"

    STEP_STATUS["cert"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 10 · NGINX SELFSTEAL (unix-socket + wildcard TLS + HTML stub)
# ─────────────────────────────────────────────────────────────────────────────

setup_nginx_selfsteal() {
    log_step "Setting up Nginx selfsteal (socket: ${NGINX_SOCK})"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would write ${NGINX_DIR}/{docker-compose.yml,nginx.conf,conf.d/site.conf,html/index.html}"
        STEP_STATUS["nginx"]="DRY"
        return 0
    fi

    mkdir -p "${NGINX_DIR}"/{conf.d,html,logs,ssl}

    # 1. Main nginx.conf
    cat > "${NGINX_DIR}/nginx.conf" <<'NGINX_CONF'
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens   off;

    # Real client IP comes via proxy_protocol header (xver: 1 from Xray)
    set_real_ip_from 127.0.0.1;
    set_real_ip_from unix:;
    real_ip_header proxy_protocol;

    log_format proxy_protocol '$proxy_protocol_addr - $remote_user [$time_local] '
                              '"$request" $status $body_bytes_sent '
                              '"$http_referer" "$http_user_agent"';

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;

    include /etc/nginx/conf.d/*.conf;
}
NGINX_CONF

    # 2. Site config — wildcard server_name + unix socket
    cat > "${NGINX_DIR}/conf.d/site.conf" <<EOF
# HTTPS via Unix socket with proxy_protocol (Xray Reality fallback target)
# Wildcard server_name → any rotated SNI works without nginx reload
server {
    listen unix:${NGINX_SOCK} ssl proxy_protocol http2;
    server_name *.node.${DOMAIN} node.${DOMAIN};

    ssl_certificate     /etc/nginx/ssl/fullchain.crt;
    ssl_certificate_key /etc/nginx/ssl/private.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;

    access_log /var/log/nginx/access.log proxy_protocol;
    error_log  /var/log/nginx/error.log warn;

    root /usr/share/nginx/html;
    index index.html;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

    # 3. HTML stub
    cat > "${NGINX_DIR}/html/index.html" <<'HTML_STUB'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Service</title>
<style>
  body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#0d1117;color:#c9d1d9;margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;text-align:center}
  .card{max-width:520px;padding:48px 32px}
  h1{font-size:1.6rem;margin:0 0 12px;font-weight:600}
  p{color:#8b949e;line-height:1.6;margin:0}
  .dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#3fb950;margin-right:8px;vertical-align:middle}
</style>
</head>
<body>
  <main class="card">
    <h1><span class="dot"></span>Service is running</h1>
    <p>This endpoint is operational. If you reached this page by accident, no action is required.</p>
  </main>
</body>
</html>
HTML_STUB

    # 4. docker-compose.yml
    cat > "${NGINX_DIR}/docker-compose.yml" <<EOF
services:
  nginx:
    image: ${NGINX_IMAGE}
    container_name: ${NGINX_CONTAINER}
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./html:/usr/share/nginx/html:ro
      - ./ssl:/etc/nginx/ssl:ro
      - ./logs:/var/log/nginx
      - /dev/shm:/dev/shm
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    # 5. Bring up
    log_info "Starting nginx container..."
    ( cd "$NGINX_DIR" && docker compose up -d 2>&1 | sed 's/^/    [nginx] /' ) || {
        log_error "Nginx failed to start"
        STEP_STATUS["nginx"]="FAILED"
        return 1
    }

    sleep 2
    if docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER"; then
        log_ok "Nginx selfsteal running on ${NGINX_SOCK}"
        STEP_STATUS["nginx"]="OK"
    else
        log_error "Nginx container not found after start"
        STEP_STATUS["nginx"]="FAILED"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11 · RW-NODE CONTAINER
# ─────────────────────────────────────────────────────────────────────────────

setup_node() {
    log_step "Deploying node container '${NODE_CONTAINER}'"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would deploy ${NODE_IMAGE} as '${NODE_CONTAINER}' (host network, /dev/shm mounted)"
        STEP_STATUS["node"]="DRY"
        return 0
    fi

    mkdir -p "$NODE_DIR"

    # .env — minimal upstream-required vars
    backup_file "${NODE_DIR}/.env"
    cat > "${NODE_DIR}/.env" <<EOF
### NODE — generated $(date -Iseconds) ###
APP_PORT=${NODE_PORT}
SSL_CERT=${NODE_SECRET_KEY}
EOF
    chmod 600 "${NODE_DIR}/.env"

    # docker-compose.yml — mirrors DigneZzZ remnanode.sh layout
    backup_file "${NODE_DIR}/docker-compose.yml"
    cat > "${NODE_DIR}/docker-compose.yml" <<EOF
services:
  ${NODE_CONTAINER}:
    image: ${NODE_IMAGE}
    container_name: ${NODE_CONTAINER}
    hostname: ${NODE_CONTAINER}
    env_file:
      - .env
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - /dev/shm:/dev/shm
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
EOF

    log_info "Pulling ${NODE_IMAGE}..."
    docker pull "$NODE_IMAGE" 2>&1 | tail -3 | sed 's/^/    [pull] /' || {
        log_error "Failed to pull node image"
        STEP_STATUS["node"]="FAILED"
        return 1
    }

    log_info "Starting node container..."
    ( cd "$NODE_DIR" && docker compose up -d 2>&1 | sed 's/^/    [node] /' ) || {
        log_error "Node failed to start"
        STEP_STATUS["node"]="FAILED"
        return 1
    }

    sleep 3
    if docker ps --format '{{.Names}}' | grep -qx "$NODE_CONTAINER"; then
        log_ok "Node container running"
        STEP_STATUS["node"]="OK"
    else
        log_error "Node container exited — check 'docker logs ${NODE_CONTAINER}'"
        STEP_STATUS["node"]="FAILED"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 12 · NSTP CLI INSTALL
# ─────────────────────────────────────────────────────────────────────────────

install_nstp_cli() {
    log_step "Installing 'nstp' management CLI"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would install ${NSTP_BIN}"
        STEP_STATUS["nstp_cli"]="DRY"
        return 0
    fi

    cat > "$NSTP_BIN" <<'NSTP_SCRIPT'
#!/usr/bin/env bash
# nstp — node management CLI (installed by node-bootstrap.sh)
set -euo pipefail
STATE_DIR="/opt/web/state"
WEB_DIR="/opt/web"
NODE_DIR="${WEB_DIR}/node"
NGINX_DIR="${WEB_DIR}/nginx"

if [[ ! -f "${STATE_DIR}/config.env" ]]; then
    echo "node-bootstrap state not found at ${STATE_DIR}. Run node-bootstrap.sh first." >&2
    exit 1
fi
# shellcheck disable=SC1091
source "${STATE_DIR}/config.env"
[[ -f "${STATE_DIR}/secrets.env" ]] && source "${STATE_DIR}/secrets.env"

CYAN=$'\e[0;36m'; GREEN=$'\e[1;32m'; YELLOW=$'\e[1;33m'; RED=$'\e[1;31m'; RESET=$'\e[0m'; BOLD=$'\e[1m'

cmd_status() {
    echo -e "${BOLD}Containers:${RESET}"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | grep -E "web-|NAMES" || true
    echo ""
    echo -e "${BOLD}Cert:${RESET}"
    local cert="${NGINX_DIR}/ssl/fullchain.crt"
    if [[ -f "$cert" ]]; then
        local exp
        exp="$(openssl x509 -in "$cert" -enddate -noout | cut -d= -f2)"
        echo "  Expires: $exp"
    else
        echo "  (no cert at $cert)"
    fi
    echo ""
    echo -e "${BOLD}SNI rotation:${RESET}"
    if [[ -f "${STATE_DIR}/sni.json" ]]; then
        cat "${STATE_DIR}/sni.json" 2>/dev/null | sed 's/^/  /'
    else
        echo "  (no rotation state yet — run 'nstp sni rotate' to initialize)"
    fi
}

cmd_logs() {
    local svc="${1:-all}"
    case "$svc" in
        node)  docker compose -f "${NODE_DIR}/docker-compose.yml" logs -f ;;
        nginx) docker compose -f "${NGINX_DIR}/docker-compose.yml" logs -f ;;
        all|*) docker compose -f "${NODE_DIR}/docker-compose.yml" logs -f &
               docker compose -f "${NGINX_DIR}/docker-compose.yml" logs -f
               wait ;;
    esac
}

cmd_cert() {
    case "${1:-status}" in
        status)
            local cert="${NGINX_DIR}/ssl/fullchain.crt"
            [[ -f "$cert" ]] || { echo "No cert at $cert"; return 1; }
            openssl x509 -in "$cert" -text -noout | grep -E "Subject:|DNS:|Not After"
            ;;
        renew)
            [[ -x /usr/local/bin/web-cert-renew ]] || { echo "Renewer not installed"; exit 1; }
            /usr/local/bin/web-cert-renew
            ;;
        *) echo "Usage: nstp cert {status|renew}"; exit 2 ;;
    esac
}

cmd_sni() {
    [[ -x /usr/local/bin/web-sni-rotate ]] || { echo "SNI rotator not installed yet (planned for v1.1)"; return 1; }
    case "${1:-list}" in
        list)   /usr/local/bin/web-sni-rotate list ;;
        rotate) /usr/local/bin/web-sni-rotate rotate ;;
        *)      echo "Usage: nstp sni {list|rotate}"; exit 2 ;;
    esac
}

cmd_fp() {
    case "${1:-show}" in
        show)
            echo "Current default fingerprint: ${DEFAULT_FP:-randomized}"
            ;;
        set)
            local new_fp="${2:-}"
            [[ -z "$new_fp" ]] && { echo "Usage: nstp fp set <chrome|firefox|safari|ios|android|edge|randomized>"; exit 2; }
            echo "Updating default fingerprint to: $new_fp"
            sed -i "s|^DEFAULT_FP=.*|DEFAULT_FP=\"${new_fp}\"|" "${STATE_DIR}/config.env"
            echo "(planned v1.1: PATCH all AUTOSNI hosts in panel via API)"
            ;;
        *) echo "Usage: nstp fp {show|set <fp>}"; exit 2 ;;
    esac
}

cmd_update() {
    echo "Pulling latest images..."
    docker compose -f "${NODE_DIR}/docker-compose.yml"  pull
    docker compose -f "${NGINX_DIR}/docker-compose.yml" pull
    docker compose -f "${NODE_DIR}/docker-compose.yml"  up -d
    docker compose -f "${NGINX_DIR}/docker-compose.yml" up -d
}

cmd_uninstall() {
    read -rp "Remove EVERYTHING (containers, /opt/web, certs, CLI)? Type 'yes' to confirm: " ans
    [[ "$ans" == "yes" ]] || { echo "Aborted"; exit 0; }
    docker compose -f "${NODE_DIR}/docker-compose.yml"  down --volumes 2>/dev/null || true
    docker compose -f "${NGINX_DIR}/docker-compose.yml" down --volumes 2>/dev/null || true
    rm -rf /opt/web
    rm -f /usr/local/bin/nstp /usr/local/bin/web-sni-rotate /usr/local/bin/web-cert-renew
    rm -f /etc/cron.d/web-sni-rotate
    echo "Removed."
}

cmd_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}nstp — node management${RESET}"
        echo "  ${CYAN}1)${RESET} status       — containers + cert + sni"
        echo "  ${CYAN}2)${RESET} logs         — tail all logs"
        echo "  ${CYAN}3)${RESET} cert status  — show cert expiry"
        echo "  ${CYAN}4)${RESET} cert renew   — force renewal"
        echo "  ${CYAN}5)${RESET} sni list     — show active SNIs"
        echo "  ${CYAN}6)${RESET} sni rotate   — rotate now"
        echo "  ${CYAN}7)${RESET} update       — pull + restart containers"
        echo "  ${RED}u)${RESET} uninstall    — remove everything"
        echo "  ${YELLOW}q)${RESET} quit"
        read -rp "  > " c
        case "$c" in
            1) cmd_status ;;
            2) cmd_logs all ;;
            3) cmd_cert status ;;
            4) cmd_cert renew ;;
            5) cmd_sni list ;;
            6) cmd_sni rotate ;;
            7) cmd_update ;;
            u|U) cmd_uninstall; break ;;
            q|Q|"") break ;;
        esac
    done
}

case "${1:-menu}" in
    status)    cmd_status ;;
    logs)      shift; cmd_logs "$@" ;;
    cert)      shift; cmd_cert "$@" ;;
    sni)       shift; cmd_sni "$@" ;;
    fp)        shift; cmd_fp "$@" ;;
    update)    cmd_update ;;
    uninstall) cmd_uninstall ;;
    menu|"")   cmd_menu ;;
    -h|--help)
        cat <<HELP
nstp — Node management CLI

Usage:
  nstp                     interactive menu
  nstp status              show containers + cert + SNI state
  nstp logs [node|nginx|all]
  nstp cert {status|renew}
  nstp sni  {list|rotate}
  nstp fp   {show|set <fp>}
  nstp update              pull + restart
  nstp uninstall           remove everything (asks confirmation)
HELP
        ;;
    *) echo "Unknown command: $1. Try 'nstp --help'"; exit 2 ;;
esac
NSTP_SCRIPT

    chmod +x "$NSTP_BIN"
    log_ok "Installed ${NSTP_BIN}"
    STEP_STATUS["nstp_cli"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 13 · SUMMARY / UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
    echo ""
    log_step "Installation summary"
    for k in "${!STEP_STATUS[@]}"; do
        local v="${STEP_STATUS[$k]}"
        local color="$GREEN"
        [[ "$v" =~ FAILED ]] && color="$RED"
        [[ "$v" =~ SKIPPED|DRY ]] && color="$YELLOW"
        printf "  %-20s ${color}%s${RESET}\n" "$k" "$v"
    done | sort
    echo ""
    echo -e "  ${BOLD}Next steps:${RESET}"
    echo "    1. In Remnawave panel: confirm node '${NODE_NAME}' is online"
    echo "    2. Run: ${BOLD}nstp sni rotate${RESET} to initialise SNI rotation (creates first AUTOSNI host)"
    echo "    3. Subscribe a test user → verify connection works"
    echo "    4. ${BOLD}nstp status${RESET} any time to check health"
    echo ""
}

run_uninstall() {
    log_step "UNINSTALL"
    read -rp "  Remove everything (containers, /opt/web, /usr/local/bin/nstp, cron)? [yes/N]: " ans
    [[ "$ans" != "yes" ]] && { log_info "Aborted"; return 0; }

    [[ -f "${NODE_DIR}/docker-compose.yml"  ]] && ( cd "$NODE_DIR"  && docker compose down --volumes 2>/dev/null || true )
    [[ -f "${NGINX_DIR}/docker-compose.yml" ]] && ( cd "$NGINX_DIR" && docker compose down --volumes 2>/dev/null || true )
    rm -rf /opt/web
    rm -f "$NSTP_BIN" "$SNI_ROTATE_BIN" "$CERT_RENEW_BIN"
    rm -f /etc/cron.d/web-sni-rotate
    rm -f /etc/sysctl.d/99-node-net.conf
    log_ok "Removed. Backups remain in ${BACKUP_DIR}/"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 14 · CLI ARG PARSER
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF

${BOLD}node-bootstrap.sh ${SCRIPT_VERSION}${RESET}

${BOLD}Usage:${RESET}
  bash ${SCRIPT_NAME} [OPTIONS]

${BOLD}Required (or asked interactively):${RESET}
  --domain <d>            base domain (cert covers *.node.<d>)
  --cf-token <t>          Cloudflare API token (Zone:DNS:Edit)
  --panel-url <u>         Remnawave panel URL
  --panel-token <t>       Panel API token
  --node-key <k>          Node SECRET_KEY from panel

${BOLD}Optional:${RESET}
  --node-name <n>         node tag value (default: hostname uppercased)
  --node-port <p>         node bind port (default: ${NODE_PORT})
  --rotation-days <n>     SNI rotation cadence (default: ${ROTATION_DAYS})
  --active-snis <n>       how many SNIs to keep active (default: ${ACTIVE_SNIS})
  --sni-style <s>         words | cdn | hex (default: ${SNI_STYLE})
  --fp <fp>               default fingerprint (default: ${DEFAULT_FP})
  --with-monitoring       install Node Exporter + Grafana dashboard
  --dry-run               simulate
  --verbose, -v           debug output
  --skip-update           skip apt update
  --non-interactive, -y   no prompts (all required flags must be set)
  --status                show current state and exit
  --uninstall             remove everything
  --help, -h              this help

${BOLD}Examples:${RESET}
  # Interactive
  bash ${SCRIPT_NAME}

  # Non-interactive
  bash ${SCRIPT_NAME} \\
    --domain example.com \\
    --cf-token cf_xxx \\
    --panel-url https://panel.example.com \\
    --panel-token rw_xxx \\
    --node-key nk_xxx \\
    -y

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)               DOMAIN="$2";              shift 2 ;;
            --node-name)            NODE_NAME="$2";           shift 2 ;;
            --node-port)            NODE_PORT="$2";           shift 2 ;;
            --cf-token)             CF_TOKEN="$2";            shift 2 ;;
            --panel-url)            PANEL_URL="$2";           shift 2 ;;
            --panel-token)          PANEL_API_TOKEN="$2";     shift 2 ;;
            --node-key)             NODE_SECRET_KEY="$2";     shift 2 ;;
            --rotation-days)        ROTATION_DAYS="$2";       shift 2 ;;
            --active-snis)          ACTIVE_SNIS="$2";         shift 2 ;;
            --sni-style)            SNI_STYLE="$2";           shift 2 ;;
            --fp)                   DEFAULT_FP="$2";          shift 2 ;;
            --with-monitoring)      WITH_MONITORING=true;     shift ;;
            --dry-run)              DRY_RUN=true;             shift ;;
            --verbose|-v)           VERBOSE=true;             shift ;;
            --skip-update)          SKIP_UPDATE=true;         shift ;;
            --non-interactive|-y)   NON_INTERACTIVE=true;     shift ;;
            --status)               preflight_checks; state_load && print_summary; exit 0 ;;
            --uninstall)            UNINSTALL=true;           shift ;;
            --version)              echo "node-bootstrap ${SCRIPT_VERSION}"; exit 0 ;;
            --help|-h)              usage; exit 0 ;;
            *) log_error "Unknown argument: $1"; usage; exit 2 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 15 · MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    print_header
    _log_session_header

    preflight_checks

    if [[ "$UNINSTALL" == true ]]; then
        run_uninstall
        exit 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_warn "DRY-RUN — no changes will be made"
    fi

    collect_params

    if [[ "$NON_INTERACTIVE" == false ]]; then
        echo ""
        read -rp "  Proceed with installation? [Y/n]: " ans
        [[ "${ans,,}" == "n" ]] && { log_info "Aborted by user"; exit 0; }
    fi

    apt_update
    setup_base_packages
    setup_sysctl
    setup_swap
    setup_ssh
    setup_ufw
    setup_fail2ban
    install_docker
    setup_cert
    setup_nginx_selfsteal
    setup_node
    install_nstp_cli

    state_save
    print_summary
}

main "$@"
