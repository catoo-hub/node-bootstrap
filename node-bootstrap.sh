#!/usr/bin/env bash
# ==============================================================================
#  node-bootstrap.sh — Remnawave node installer (full API-driven setup)
#  Supports: Debian 12+ / Ubuntu 22.04+  |  Requires: root
#
#  v1.1.0 — node creation + config-profile creation + hosts creation all via API
#
#  Usage (interactive):     bash node-bootstrap.sh
#  Usage (non-interactive): bash node-bootstrap.sh --country NL --hosting 1CENT ... -y
#
#  Author:   catoo-hub
#  License:  MIT
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 · CONSTANTS & GLOBALS
# ─────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="1.1.0"
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
readonly XHTTP_SOCK="/dev/shm/xrxh.socket"

readonly NSTP_BIN="/usr/local/bin/nstp"
readonly SNI_ROTATE_BIN="/usr/local/bin/web-sni-rotate"
readonly CERT_RENEW_BIN="/usr/local/bin/web-cert-renew"

readonly RAW_BASE="https://raw.githubusercontent.com/catoo-hub/node-bootstrap/main"

# Container names — neutral
readonly NODE_CONTAINER="web-node"
readonly NGINX_CONTAINER="web-nginx"

# Image names — upstream-dictated
readonly NODE_IMAGE="ghcr.io/remnawave/node:latest"
readonly NGINX_IMAGE="nginx:1.27-alpine"

# ── Runtime flags ────────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
NON_INTERACTIVE=false
SKIP_UPDATE=false
UNINSTALL=false
WITH_MONITORING=false
MONITOR_FROM_IP=""         # IP of the panel/Prometheus server allowed to scrape :9100

# Required params
DOMAIN=""                  # example.com — wildcard base
CF_TOKEN=""                # Cloudflare API Token
PANEL_URL=""               # https://panel.example.com
PANEL_API_TOKEN=""         # API token from panel
COUNTRY_CODE=""            # ISO-2: NL, FI, DE, ...
HOSTING=""                 # optional suffix: 1CENT, HETZNER, ...

# Naming (auto-derived if blank)
NODE_NAME=""               # NL-02 or NL-02-1CENT
NODE_SEQUENCE=""           # 02 — auto-detected from existing nodes
TAG_PREFIX=""              # AUTOSNI:NL02

# Existing-resource overrides (for re-runs / hybrid setups)
USE_EXISTING_NODE=false
EXISTING_NODE_UUID=""
NODE_SECRET_KEY=""         # if --existing-node + --node-key: skip POST /api/nodes
CONFIG_PROFILE_UUID=""
NODE_INBOUND_REALITY_UUID=""
NODE_INBOUND_GRPC_UUID=""
NODE_INBOUND_XHTTP_UUID=""
NODE_INBOUND_HYS_UUID=""

# Rotation
ROTATION_DAYS=3
ACTIVE_SNIS=3
SNI_STYLE="cdn"            # cdn | words | hex
DEFAULT_FP="firefox"       # firefox (default) | chrome | edge | safari | ios | android | qq | randomized
# Reasoning (June 2026 research):
#   - JA4+ defeats randomized-mode by sorting TLS extensions before hashing.
#     uTLS randomized produces statistical anomalies real users never show.
#   - chrome is universally targeted on RU mobile carriers (operator reports).
#   - firefox: non-Chromium TLS profile, smaller target population, currently
#     the best signal/noise tradeoff for RU traffic.
#   - edge is a reasonable alternative; switch via `nstp fp set edge`.

# Node container
# Default to a high "looks like ephemeral / app port" range. 2222 (SSH alt) and
# 3000 (web dev) stand out in scanner logs. 61000 is taken by XTLS_API_PORT
# inside the container, so use 60000.
NODE_PORT="60000"          # rw-node ↔ panel control port

# Reality keys — generated per inbound (TCP + gRPC use SEPARATE keypairs)
REALITY_PRIV_TCP=""
REALITY_PUB_TCP=""
REALITY_PRIV_GRPC=""
REALITY_PUB_GRPC=""

# Reality short IDs — one per inbound, generated locally via openssl rand -hex 8.
# Goes into realitySettings.shortIds of the corresponding inbound; panel picks
# them up when building client subscription URLs.
SHORT_ID_TCP=""
SHORT_ID_GRPC=""

# Hysteria2
HYS_OBFS_PASSWORD=""
HYS_PASSWORD=""

# XHTTP path — chosen at install time from XHTTP_PATH_POOL
XHTTP_PATH=""

# Selfsteal stub site — picked randomly from templates/stubs/ at install time
STUB_NAME=""

# Misc
NODE_UUID=""               # filled after POST /api/nodes
NODE_PUBLIC_IP=""
HOSTNAME_SHORT=""
OS_ID=""
OS_VERSION_ID=""
ARCH=""
IS_CONTAINER=false
VIRT_TYPE=""

declare -A STEP_STATUS=()

# Auto-detect pipe mode
if [[ ! -t 0 ]]; then
    NON_INTERACTIVE=true
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1b · COUNTRY CODE TABLE (ISO 3166-1 alpha-2 → English name)
#   Used to build remark strings; emoji flag generated mathematically from code.
# ─────────────────────────────────────────────────────────────────────────────

declare -A COUNTRY_NAME=(
    [AD]="Andorra"           [AE]="UAE"              [AF]="Afghanistan"      [AG]="Antigua"
    [AL]="Albania"           [AM]="Armenia"          [AO]="Angola"           [AR]="Argentina"
    [AT]="Austria"           [AU]="Australia"        [AZ]="Azerbaijan"
    [BA]="Bosnia"            [BB]="Barbados"         [BD]="Bangladesh"       [BE]="Belgium"
    [BF]="Burkina Faso"      [BG]="Bulgaria"         [BH]="Bahrain"          [BI]="Burundi"
    [BJ]="Benin"             [BN]="Brunei"           [BO]="Bolivia"          [BR]="Brazil"
    [BS]="Bahamas"           [BT]="Bhutan"           [BW]="Botswana"         [BY]="Belarus"
    [BZ]="Belize"
    [CA]="Canada"            [CD]="DR Congo"         [CF]="CAR"              [CG]="Congo"
    [CH]="Switzerland"       [CI]="Côte d'Ivoire"    [CL]="Chile"            [CM]="Cameroon"
    [CN]="China"             [CO]="Colombia"         [CR]="Costa Rica"       [CU]="Cuba"
    [CV]="Cape Verde"        [CY]="Cyprus"           [CZ]="Czechia"
    [DE]="Germany"           [DJ]="Djibouti"         [DK]="Denmark"          [DM]="Dominica"
    [DO]="Dominican Rep"     [DZ]="Algeria"
    [EC]="Ecuador"           [EE]="Estonia"          [EG]="Egypt"            [ER]="Eritrea"
    [ES]="Spain"             [ET]="Ethiopia"
    [FI]="Finland"           [FJ]="Fiji"             [FM]="Micronesia"       [FR]="France"
    [GA]="Gabon"             [GB]="United Kingdom"   [GD]="Grenada"          [GE]="Georgia"
    [GH]="Ghana"             [GM]="Gambia"           [GN]="Guinea"           [GQ]="Eq. Guinea"
    [GR]="Greece"            [GT]="Guatemala"        [GW]="Guinea-Bissau"    [GY]="Guyana"
    [HK]="Hong Kong"         [HN]="Honduras"         [HR]="Croatia"          [HT]="Haiti"
    [HU]="Hungary"
    [ID]="Indonesia"         [IE]="Ireland"          [IL]="Israel"           [IN]="India"
    [IQ]="Iraq"              [IR]="Iran"             [IS]="Iceland"          [IT]="Italy"
    [JM]="Jamaica"           [JO]="Jordan"           [JP]="Japan"
    [KE]="Kenya"             [KG]="Kyrgyzstan"       [KH]="Cambodia"         [KI]="Kiribati"
    [KM]="Comoros"           [KN]="Saint Kitts"      [KP]="North Korea"      [KR]="South Korea"
    [KW]="Kuwait"            [KZ]="Kazakhstan"
    [LA]="Laos"              [LB]="Lebanon"          [LC]="Saint Lucia"      [LI]="Liechtenstein"
    [LK]="Sri Lanka"         [LR]="Liberia"          [LS]="Lesotho"          [LT]="Lithuania"
    [LU]="Luxembourg"        [LV]="Latvia"           [LY]="Libya"
    [MA]="Morocco"           [MC]="Monaco"           [MD]="Moldova"          [ME]="Montenegro"
    [MG]="Madagascar"        [MH]="Marshall Is."     [MK]="N. Macedonia"     [ML]="Mali"
    [MM]="Myanmar"           [MN]="Mongolia"         [MR]="Mauritania"       [MT]="Malta"
    [MU]="Mauritius"         [MV]="Maldives"         [MW]="Malawi"           [MX]="Mexico"
    [MY]="Malaysia"          [MZ]="Mozambique"
    [NA]="Namibia"           [NE]="Niger"            [NG]="Nigeria"          [NI]="Nicaragua"
    [NL]="Netherlands"       [NO]="Norway"           [NP]="Nepal"            [NR]="Nauru"
    [NZ]="New Zealand"
    [OM]="Oman"
    [PA]="Panama"            [PE]="Peru"             [PG]="PNG"              [PH]="Philippines"
    [PK]="Pakistan"          [PL]="Poland"           [PT]="Portugal"         [PW]="Palau"
    [PY]="Paraguay"
    [QA]="Qatar"
    [RO]="Romania"           [RS]="Serbia"           [RU]="Russia"           [RW]="Rwanda"
    [SA]="Saudi Arabia"      [SB]="Solomon Is."      [SC]="Seychelles"       [SD]="Sudan"
    [SE]="Sweden"            [SG]="Singapore"        [SI]="Slovenia"         [SK]="Slovakia"
    [SL]="Sierra Leone"      [SM]="San Marino"       [SN]="Senegal"          [SO]="Somalia"
    [SR]="Suriname"          [SS]="South Sudan"      [SV]="El Salvador"      [SY]="Syria"
    [SZ]="Eswatini"
    [TD]="Chad"              [TG]="Togo"             [TH]="Thailand"         [TJ]="Tajikistan"
    [TL]="Timor-Leste"       [TM]="Turkmenistan"     [TN]="Tunisia"          [TO]="Tonga"
    [TR]="Türkiye"           [TT]="Trinidad"         [TV]="Tuvalu"           [TW]="Taiwan"
    [TZ]="Tanzania"
    [UA]="Ukraine"           [UG]="Uganda"           [US]="United States"    [UY]="Uruguay"
    [UZ]="Uzbekistan"
    [VA]="Vatican"           [VC]="Saint Vincent"    [VE]="Venezuela"        [VN]="Vietnam"
    [VU]="Vanuatu"
    [WS]="Samoa"
    [YE]="Yemen"
    [ZA]="South Africa"      [ZM]="Zambia"           [ZW]="Zimbabwe"
)

# Plausible XHTTP paths (look like real API/metrics endpoints)
XHTTP_PATH_POOL=(
    "/api/v3/stats/"
    "/api/v1/metrics/"
    "/api/v2/events/"
    "/internal/health/"
    "/api/v1/telemetry/"
    "/grpc.health.v1.Health/Check/"
    "/api/v4/observability/"
    "/api/v1/spans/"
)

# Generate emoji flag from ISO-2 country code (e.g. NL → 🇳🇱)
country_flag() {
    local cc="${1^^}"
    [[ ${#cc} -ne 2 ]] && { echo ""; return; }
    local A B
    A=$(printf '\\U%08x' $((0x1F1E6 + $(printf '%d' "'${cc:0:1}") - 65)))
    B=$(printf '\\U%08x' $((0x1F1E6 + $(printf '%d' "'${cc:1:1}") - 65)))
    printf "$A$B"
}

country_name() {
    local cc="${1^^}"
    echo "${COUNTRY_NAME[$cc]:-${cc}}"
}

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

print_header() {
    cat <<EOF

  ${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}
  ${BOLD}║          NODE BOOTSTRAP  ·  ${SCRIPT_VERSION}                           ║${RESET}
  ${BOLD}║          Remnawave node + rotating SNI + selfsteal      ║${RESET}
  ${BOLD}║          Full API-driven setup                          ║${RESET}
  ${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 · TRAP
# ─────────────────────────────────────────────────────────────────────────────

_fatal_exit() {
    local rc=$?
    [[ $rc -ne 0 ]] && log_error "Abnormal exit (code ${rc}). Review ${LOG_FILE}"
    exit $rc
}
trap _fatal_exit EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 · PREFLIGHT
# ─────────────────────────────────────────────────────────────────────────────

_detect_os() {
    [[ -f /etc/os-release ]] || { log_error "/etc/os-release missing"; exit 1; }
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    log_info "Detected OS : ${PRETTY_NAME:-${OS_ID} ${OS_VERSION_ID}}"
}

_detect_arch() {
    ARCH="$(uname -m)"
    log_info "Architecture: ${ARCH}"
}

_detect_virt() {
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo 'none')"
        if [[ "$VIRT_TYPE" =~ ^(openvz|lxc|lxc-libvirt|docker|podman)$ ]]; then
            IS_CONTAINER=true
            log_warn "Container virtualization: ${VIRT_TYPE} — Docker may have issues"
        else
            log_info "Virtualization: ${VIRT_TYPE}"
        fi
    fi
}

_check_internet() {
    log_debug "Checking internet..."
    if ! curl -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace -o /dev/null 2>/dev/null \
       && ! curl -fsS --max-time 10 https://8.8.8.8 -o /dev/null 2>/dev/null; then
        log_error "No internet connectivity"
        exit 1
    fi
    log_ok "Internet connectivity — OK"
}

_detect_public_ip() {
    NODE_PUBLIC_IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)"
    [[ -z "$NODE_PUBLIC_IP" ]] && NODE_PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '')"
    HOSTNAME_SHORT="$(hostname -s)"
}

preflight_checks() {
    log_step "Preflight checks"
    [[ $EUID -ne 0 ]] && { log_error "Must run as root"; exit 1; }
    log_debug "Running as root — OK"
    _detect_os
    _detect_arch
    _detect_virt
    _check_internet
    _detect_public_ip
    log_ok "Preflight checks passed"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 · UTILITIES
# ─────────────────────────────────────────────────────────────────────────────

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$f" "${BACKUP_DIR}/$(basename "$f").${TIMESTAMP}.bak"
}

apt_update() {
    [[ "$SKIP_UPDATE" == true ]] && { log_info "Skipping apt update"; return 0; }
    log_step "Updating package lists"
    [[ "$DRY_RUN" == true ]] && { log_dry "apt-get update"; return 0; }
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    log_ok "Packages updated"
}

install_packages() {
    local pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0
    [[ "$DRY_RUN" == true ]] && { log_dry "Install: ${pkgs[*]}"; return 0; }
    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" &>/dev/null || missing+=("$p")
    done
    [[ ${#missing[@]} -eq 0 ]] && { log_debug "All present: ${pkgs[*]}"; return 0; }
    log_info "Installing: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    log_ok "Installed: ${missing[*]}"
}

_validate_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}
_validate_url()    { [[ "$1" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$ ]]; }
_validate_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
_validate_cc()     { [[ "$1" =~ ^[A-Z]{2}$ ]]; }

# Random string generators
gen_password() { openssl rand -hex 12; }
gen_short_id() { openssl rand -hex 8; }

# Generate Reality x25519 keypair via the node image (most reliable, same lib as runtime)
reality_keygen() {
    local out
    out="$(docker run --rm --entrypoint xray "$NODE_IMAGE" x25519 2>/dev/null)" || {
        log_error "Failed to generate Reality keys (xray x25519)"
        return 1
    }
    # Output format:
    #   Private key: xxxxx
    #   Public key:  yyyyy
    local priv pub
    priv="$(echo "$out" | grep -i 'private' | awk '{print $NF}')"
    pub="$(echo "$out" | grep -i 'public'  | awk '{print $NF}')"
    [[ -z "$priv" || -z "$pub" ]] && { log_error "Could not parse xray x25519 output"; return 1; }
    echo "${priv}|${pub}"
}

# state_load — if a previous install left ${CONFIG_FILE} on disk, source it
# so re-runs reuse the SAME XHTTP_PATH, SHORT_IDs, Reality keys, Hysteria
# passwords, STUB_NAME, NODE_NAME, sequence, etc. Without this, every
# re-install picks new random values for those fields and they desync from
# the host records already created in the panel (this is what caused the
# XHTTP 405 — nginx had path A, host record had path B, both random,
# different runs).
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

state_save() {
    mkdir -p "$STATE_DIR"
    cat > "$CONFIG_FILE" <<EOF
# node-bootstrap install config — generated $(date -Iseconds)
DOMAIN="${DOMAIN}"
NODE_NAME="${NODE_NAME}"
NODE_SEQUENCE="${NODE_SEQUENCE}"
COUNTRY_CODE="${COUNTRY_CODE}"
HOSTING="${HOSTING}"
TAG_PREFIX="${TAG_PREFIX}"
NODE_PUBLIC_IP="${NODE_PUBLIC_IP}"
NODE_PORT="${NODE_PORT}"
PANEL_URL="${PANEL_URL}"
ROTATION_DAYS="${ROTATION_DAYS}"
ACTIVE_SNIS="${ACTIVE_SNIS}"
SNI_STYLE="${SNI_STYLE}"
DEFAULT_FP="${DEFAULT_FP}"
XHTTP_PATH="${XHTTP_PATH}"

NODE_UUID="${NODE_UUID}"
CONFIG_PROFILE_UUID="${CONFIG_PROFILE_UUID}"
NODE_INBOUND_REALITY_UUID="${NODE_INBOUND_REALITY_UUID}"
NODE_INBOUND_GRPC_UUID="${NODE_INBOUND_GRPC_UUID}"
NODE_INBOUND_XHTTP_UUID="${NODE_INBOUND_XHTTP_UUID}"
NODE_INBOUND_HYS_UUID="${NODE_INBOUND_HYS_UUID}"

REALITY_PRIV_TCP="${REALITY_PRIV_TCP}"
REALITY_PUB_TCP="${REALITY_PUB_TCP}"
REALITY_PRIV_GRPC="${REALITY_PRIV_GRPC}"
REALITY_PUB_GRPC="${REALITY_PUB_GRPC}"
SHORT_ID_TCP="${SHORT_ID_TCP}"
SHORT_ID_GRPC="${SHORT_ID_GRPC}"

HYS_PASSWORD="${HYS_PASSWORD}"
HYS_OBFS_PASSWORD="${HYS_OBFS_PASSWORD}"
STUB_NAME="${STUB_NAME}"
EOF
    chmod 600 "$CONFIG_FILE"

    cat > "${STATE_DIR}/secrets.env" <<EOF
CF_TOKEN="${CF_TOKEN}"
PANEL_API_TOKEN="${PANEL_API_TOKEN}"
NODE_SECRET_KEY="${NODE_SECRET_KEY}"
EOF
    chmod 600 "${STATE_DIR}/secrets.env"

    echo "$SCRIPT_VERSION" > "$VERSION_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5b · PANEL API CLIENT
# ─────────────────────────────────────────────────────────────────────────────

# panel_req <METHOD> <PATH> [BODY_JSON] — echoes response body only, sets RC
panel_req() {
    local method="$1" path="$2" body="${3:-}"
    local url="${PANEL_URL}${path}"
    local code
    local resp
    if [[ -n "$body" ]]; then
        resp="$(curl -sS -X "$method" "$url" \
            -H "Authorization: Bearer ${PANEL_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$body" \
            -w '\n___HTTP_CODE___%{http_code}' 2>>"$LOG_FILE")"
    else
        resp="$(curl -sS -X "$method" "$url" \
            -H "Authorization: Bearer ${PANEL_API_TOKEN}" \
            -w '\n___HTTP_CODE___%{http_code}' 2>>"$LOG_FILE")"
    fi
    code="${resp##*___HTTP_CODE___}"
    local body_out="${resp%___HTTP_CODE___*}"
    body_out="${body_out%$'\n'}"   # strip trailing newline
    if [[ ! "$code" =~ ^2 ]]; then
        log_error "Panel API ${method} ${path} returned ${code}"
        log_debug "Response: ${body_out}"
        echo "$body_out"
        return 1
    fi
    echo "$body_out"
    return 0
}

panel_get_keygen() {
    local r; r="$(panel_req GET /api/keygen)" || return 1
    echo "$r" | jq -r '.response.pubKey'
}

panel_list_nodes() {
    panel_req GET /api/nodes
}

# Detect next sequence number for a country: scans existing nodes' names matching <CC>-NN
panel_detect_next_sequence() {
    local cc="${1^^}"
    local nodes; nodes="$(panel_list_nodes)" || { echo "01"; return; }
    local highest
    highest="$(echo "$nodes" | jq -r --arg cc "$cc" \
        '[.response[] | .name | capture("^" + $cc + "-(?<n>[0-9]+)") | .n | tonumber] | max // 0')"
    printf '%02d' $((highest + 1))
}

panel_create_config_profile() {
    local profile_name="$1" config_json="$2"
    local body
    body="$(jq -n --arg n "$profile_name" --argjson c "$config_json" '{name: $n, config: $c}')"
    local r; r="$(panel_req POST /api/config-profiles "$body")" || return 1
    echo "$r"
}

panel_create_node() {
    local body="$1"
    local r; r="$(panel_req POST /api/nodes "$body")" || return 1
    echo "$r"
}

panel_create_host() {
    panel_req POST /api/hosts "$1"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 · PARAM COLLECTION
# ─────────────────────────────────────────────────────────────────────────────

collect_params() {
    log_step "Collecting installation parameters"

    # 0. Resume previous values from state if present. CLI flags override these;
    #    only fields the operator didn't pass get the persisted value. Critical
    #    for re-runs — keeps XHTTP_PATH / SHORT_ID_* / Reality keys / passwords
    #    stable so panel-side host records keep matching the on-server config.
    if state_load 2>/dev/null; then
        log_info "Loaded previous install state from ${CONFIG_FILE}"
    fi

    # 1. DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        [[ "$NON_INTERACTIVE" == true ]] && { log_error "--domain is required"; exit 1; }
        while true; do
            read -rp "  Base domain (cert will cover *.<domain>, e.g. node.example.com): " DOMAIN
            _validate_domain "$DOMAIN" && break
            log_warn "Invalid: ${DOMAIN}"
        done
    fi
    _validate_domain "$DOMAIN" || { log_error "Invalid --domain"; exit 1; }

    # 2. CF_TOKEN
    if [[ -z "$CF_TOKEN" ]]; then
        [[ "$NON_INTERACTIVE" == true ]] && { log_error "--cf-token is required"; exit 1; }
        echo -e "  ${GRAY}Cloudflare → My Profile → API Tokens → Custom (Zone:DNS:Edit for ${DOMAIN})${RESET}"
        while true; do
            read -rsp "  Cloudflare API Token: "; CF_TOKEN="$REPLY"; echo ""
            [[ ${#CF_TOKEN} -ge 30 ]] && break
            log_warn "Looks short — re-enter"
        done
    fi

    # 3. PANEL_URL + token
    if [[ -z "$PANEL_URL" ]]; then
        [[ "$NON_INTERACTIVE" == true ]] && { log_error "--panel-url is required"; exit 1; }
        while true; do
            read -rp "  Panel URL (https://panel.example.com): " PANEL_URL
            _validate_url "$PANEL_URL" && break
            log_warn "Invalid: ${PANEL_URL}"
        done
    fi
    PANEL_URL="${PANEL_URL%/}"

    if [[ -z "$PANEL_API_TOKEN" ]]; then
        [[ "$NON_INTERACTIVE" == true ]] && { log_error "--panel-token is required"; exit 1; }
        while true; do
            read -rsp "  Panel API token: "; PANEL_API_TOKEN="$REPLY"; echo ""
            [[ ${#PANEL_API_TOKEN} -ge 16 ]] && break
            log_warn "Looks short — re-enter"
        done
    fi

    # 4. COUNTRY_CODE
    if [[ "$USE_EXISTING_NODE" == false ]]; then
        if [[ -z "$COUNTRY_CODE" ]]; then
            [[ "$NON_INTERACTIVE" == true ]] && { log_error "--country is required (ISO-2: NL, FI, DE)"; exit 1; }
            while true; do
                read -rp "  Country (ISO-2, e.g. NL, FI, DE, US): " COUNTRY_CODE
                COUNTRY_CODE="${COUNTRY_CODE^^}"
                _validate_cc "$COUNTRY_CODE" && break
                log_warn "Two letters required"
            done
        fi
        COUNTRY_CODE="${COUNTRY_CODE^^}"
        _validate_cc "$COUNTRY_CODE" || { log_error "--country must be ISO-2 (2 letters)"; exit 1; }

        # 5. HOSTING (optional suffix)
        if [[ -z "$HOSTING" && "$NON_INTERACTIVE" == false ]]; then
            read -rp "  Hosting suffix (optional, e.g. 1CENT, HETZNER): " HOSTING
        fi
        HOSTING="${HOSTING^^}"
        HOSTING="$(echo "$HOSTING" | tr -c 'A-Z0-9' '_' | sed 's/_*$//')"

        # 6. NODE_SEQUENCE — auto-detect from panel
        if [[ -z "$NODE_SEQUENCE" ]]; then
            log_info "Auto-detecting next sequence number for ${COUNTRY_CODE}..."
            NODE_SEQUENCE="$(panel_detect_next_sequence "$COUNTRY_CODE")"
            log_info "Next sequence: ${NODE_SEQUENCE}"
        fi

        # 7. NODE_NAME
        if [[ -z "$NODE_NAME" ]]; then
            NODE_NAME="${COUNTRY_CODE}-${NODE_SEQUENCE}"
            [[ -n "$HOSTING" ]] && NODE_NAME="${NODE_NAME}-${HOSTING}"
        fi

        # 8. TAG_PREFIX
        TAG_PREFIX="AUTOSNI:${COUNTRY_CODE}${NODE_SEQUENCE}"
    else
        # Existing node: ensure we have UUID + KEY
        if [[ -z "$EXISTING_NODE_UUID" ]]; then
            [[ "$NON_INTERACTIVE" == true ]] && { log_error "--existing-node-uuid is required when --existing-node is set"; exit 1; }
            read -rp "  Existing node UUID: " EXISTING_NODE_UUID
        fi
        NODE_UUID="$EXISTING_NODE_UUID"

        if [[ -z "$NODE_SECRET_KEY" ]]; then
            [[ "$NON_INTERACTIVE" == true ]] && { log_error "--node-key is required when --existing-node is set"; exit 1; }
            read -rsp "  Node SECRET_KEY: "; NODE_SECRET_KEY="$REPLY"; echo ""
        fi

        # Will discover NODE_NAME/COUNTRY_CODE from panel later
        NODE_NAME="${NODE_NAME:-$(hostname -s | tr '[:lower:]' '[:upper:]')}"
        TAG_PREFIX="AUTOSNI:$(echo "$NODE_NAME" | tr -c 'A-Z0-9_:' '_')"
    fi

    # 9. XHTTP path
    # Pick XHTTP path only on first install — re-runs must reuse the existing
    # one so nginx config and panel host record stay in sync (see state_load).
    if [[ -z "${XHTTP_PATH:-}" ]]; then
        XHTTP_PATH="${XHTTP_PATH_POOL[$RANDOM % ${#XHTTP_PATH_POOL[@]}]}"
    fi

    log_info "DOMAIN  : ${DOMAIN}"
    log_info "NODE    : ${NODE_NAME}  $(country_flag "$COUNTRY_CODE") $(country_name "$COUNTRY_CODE")"
    log_info "TAG     : ${TAG_PREFIX}"
    log_info "PANEL   : ${PANEL_URL}"
    log_info "SNI POL : ${ACTIVE_SNIS}× active × every ${ROTATION_DAYS}d (style: ${SNI_STYLE}, fp: ${DEFAULT_FP})"
    log_info "XHTTP   : ${XHTTP_PATH}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 · BASE HARDENING
# ─────────────────────────────────────────────────────────────────────────────

setup_base_packages() {
    log_step "Installing base packages"
    install_packages curl wget git unzip tar jq vim nano htop net-tools dnsutils \
                     iproute2 ufw fail2ban socat tcpdump mtr-tiny ca-certificates \
                     lsb-release gnupg2 software-properties-common bc psmisc procps openssl
    STEP_STATUS["base_packages"]="OK"
}

setup_sysctl() {
    log_step "Applying network sysctl (BBR + TCP tuning)"
    [[ "$DRY_RUN" == true ]] && { log_dry "Would write sysctl"; STEP_STATUS["sysctl"]="DRY"; return 0; }
    cat > /etc/sysctl.d/99-node-net.conf <<'EOF'
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
    log_ok "Sysctl applied (BBR)"
    STEP_STATUS["sysctl"]="OK"
}

setup_swap() {
    log_step "Swap configuration"
    if swapon --show | grep -q '^'; then
        log_info "Swap already active: $(swapon --show=SIZE --noheadings | head -1). Skipping."
        STEP_STATUS["swap"]="SKIPPED"
        return 0
    fi
    [[ "$DRY_RUN" == true ]] && { log_dry "Create 2G swap"; STEP_STATUS["swap"]="DRY"; return 0; }
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log_ok "Swap 2G enabled"
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
    backup_file /etc/ssh/sshd_config
    local sp; sp="$(_get_ssh_port)"
    log_info "SSH port: ${sp}"
    [[ "$DRY_RUN" == true ]] && { log_dry "Would harden SSH"; STEP_STATUS["ssh"]="DRY"; return 0; }

    # Only flip PermitRootLogin to prohibit-password (= key-only) if root has
    # at least one authorized SSH key on disk. Otherwise we'd lock the operator
    # out the moment ssh reloads — exactly what happened to the first test
    # install on this project.
    if [[ -s /root/.ssh/authorized_keys ]]; then
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
        log_info "PermitRootLogin → prohibit-password (root key present)"
    else
        log_warn "No /root/.ssh/authorized_keys — leaving PermitRootLogin as-is to avoid lockout"
        log_warn "To harden later: add a key, then:"
        log_warn "  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && systemctl reload ssh"
    fi

    sed -i 's/^#*X11Forwarding.*/X11Forwarding no/'                       /etc/ssh/sshd_config
    sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 60/'           /etc/ssh/sshd_config
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        log_ok "SSH config applied"
        STEP_STATUS["ssh"]="OK"
    else
        log_error "sshd -t failed — reverting"
        cp -a "${BACKUP_DIR}/sshd_config.${TIMESTAMP}.bak" /etc/ssh/sshd_config
        STEP_STATUS["ssh"]="FAILED"
    fi
}

setup_ufw() {
    log_step "Configuring UFW"
    install_packages ufw
    local sp; sp="$(_get_ssh_port)"
    [[ "$DRY_RUN" == true ]] && { log_dry "UFW: SSH(${sp}), 80, 443, 8443, 9443, ${NODE_PORT}"; STEP_STATUS["ufw"]="DRY"; return 0; }
    [[ "$IS_CONTAINER" == true ]] && { log_warn "Container — skipping UFW"; STEP_STATUS["ufw"]="SKIPPED(container)"; return 0; }
    ufw --force reset           &>/dev/null
    ufw default deny incoming   &>/dev/null
    ufw default allow outgoing  &>/dev/null
    ufw allow "${sp}/tcp"       comment 'SSH'                 &>/dev/null
    ufw allow 80/tcp            comment 'ACME HTTP-01'         &>/dev/null
    ufw allow 443/tcp           comment 'Xray Reality TCP'     &>/dev/null
    ufw allow 8443/tcp          comment 'Xray Reality gRPC'    &>/dev/null
    ufw allow 9443/udp          comment 'Hysteria2'            &>/dev/null
    ufw allow "${NODE_PORT}/tcp" comment 'panel → node ctrl'   &>/dev/null
    ufw show added 2>/dev/null | grep -q "ufw allow ${sp}" || {
        log_error "SAFETY ABORT: SSH not in UFW rules"
        STEP_STATUS["ufw"]="FAILED"
        return 1
    }
    ufw --force enable &>/dev/null
    log_ok "UFW enabled (ssh:${sp}, 80, 443, 8443, 9443/udp, ${NODE_PORT})"
    STEP_STATUS["ufw"]="OK"
}

setup_fail2ban() {
    log_step "Configuring Fail2Ban (sshd + web-nginx scanners)"
    install_packages fail2ban
    [[ "$DRY_RUN" == true ]] && { log_dry "fail2ban jails"; STEP_STATUS["fail2ban"]="DRY"; return 0; }

    local sp; sp="$(_get_ssh_port)"

    # Filter that matches nginx 405 (try_files POST on unknown XHTTP paths) and
    # 444 (ssl_reject_handshake on unknown SNI). Both signal scanners probing
    # for proxy endpoints — legitimate clients never hit either status.
    cat > /etc/fail2ban/filter.d/web-nginx.conf <<'F2B'
[Definition]
# Log format from our site.conf:
#   $proxy_protocol_addr - $remote_user [$time_local] "$request" $status $size
failregex = ^<HOST>\s.*"(?:POST|GET|HEAD|PUT|DELETE)[^"]*"\s(?:405|444)\s
ignoreregex =
F2B

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = 127.0.0.1/8 ::1 ${NODE_PUBLIC_IP}

[sshd]
enabled = true
port    = ${sp}

[web-nginx]
enabled  = true
filter   = web-nginx
port     = 80,443
logpath  = /opt/web/nginx/logs/access.log
maxretry = 20
findtime = 1h
bantime  = 6h
EOF
    log_info "Created jail.local (sshd:${sp} + web-nginx 20/h → 6h ban)"
    systemctl enable fail2ban &>/dev/null
    systemctl restart fail2ban
    log_ok "Fail2Ban running with 2 jails"
    STEP_STATUS["fail2ban"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7b · LOG ROTATION
# ─────────────────────────────────────────────────────────────────────────────

setup_logrotate() {
    log_step "Setting up logrotate for nginx + xray"
    [[ "$DRY_RUN" == true ]] && { log_dry "logrotate configs"; STEP_STATUS["logrotate"]="DRY"; return 0; }
    install_packages logrotate

    # Nginx access/error logs — written to host bind mount, easy to rotate.
    # Send a nginx -s reopen signal after rotation so new file handles are taken.
    cat > /etc/logrotate.d/web-nginx <<EOF
${NGINX_DIR}/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        docker compose -f ${NGINX_DIR}/docker-compose.yml exec -T ${NGINX_CONTAINER} nginx -s reopen 2>/dev/null || true
    endscript
}
EOF

    # Xray supervisor logs — mounted from container to host (see setup_node).
    # No signal needed — supervisord rotates files internally per restart.
    cat > /etc/logrotate.d/web-node <<EOF
${NODE_DIR}/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    copytruncate
}
EOF

    log_ok "logrotate configured (14 days retention, daily, gzip)"
    STEP_STATUS["logrotate"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7c · NODE EXPORTER (Prometheus)
# Only enabled if --monitor-from <ip> is passed; opens 9100 from that IP only.
# Operator runs Grafana on their own panel server and imports the dashboard
# JSON from templates/grafana/node-dashboard.json in this repo.
# ─────────────────────────────────────────────────────────────────────────────

setup_node_exporter() {
    [[ -z "${MONITOR_FROM_IP:-}" ]] && return 0
    log_step "Installing node_exporter (allow scrape from ${MONITOR_FROM_IP})"
    [[ "$DRY_RUN" == true ]] && { log_dry "Deploy node_exporter on :9100"; STEP_STATUS["node_exporter"]="DRY"; return 0; }

    mkdir -p /opt/web/monitoring
    cat > /opt/web/monitoring/docker-compose.yml <<'YAML'
services:
  node-exporter:
    image: prom/node-exporter:v1.8.2
    container_name: web-node-exporter
    restart: unless-stopped
    network_mode: host
    pid: host
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc|var/lib/docker)($$|/)'
      - '--web.listen-address=:9100'
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
YAML

    # UFW: allow scrape only from panel server IP
    if [[ "$IS_CONTAINER" != true ]]; then
        ufw allow from "${MONITOR_FROM_IP}" to any port 9100 proto tcp \
            comment "node_exporter scrape from panel" &>/dev/null || true
    fi

    ( cd /opt/web/monitoring && docker compose up -d 2>&1 | sed 's/^/    [exporter] /' ) || {
        log_error "node_exporter failed to start"
        STEP_STATUS["node_exporter"]="FAILED"
        return 1
    }
    log_ok "node_exporter on :9100 (UFW: only from ${MONITOR_FROM_IP})"
    echo ""
    log_info "Grafana dashboard template:"
    log_info "  ${RAW_BASE}/templates/grafana/node-dashboard.json"
    log_info "Import in your Grafana → set Prometheus target to: ${NODE_PUBLIC_IP}:9100"
    STEP_STATUS["node_exporter"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8 · DOCKER
# ─────────────────────────────────────────────────────────────────────────────

install_docker() {
    log_step "Installing Docker & Compose v2"
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        log_ok "Docker present: $(docker --version)"
        STEP_STATUS["docker"]="SKIPPED"
        return 0
    fi
    [[ "$DRY_RUN" == true ]] && { log_dry "Install Docker"; STEP_STATUS["docker"]="DRY"; return 0; }

    if [[ -f /etc/apt/sources.list.d/docker.list ]] && \
       ! curl -fsS --max-time 5 -I https://download.docker.com/linux/ubuntu/dists/ >/dev/null 2>&1; then
        log_warn "Stale docker.list — removing"
        rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg 2>/dev/null || true
        apt-get update -qq 2>/dev/null || true
    fi

    local docker_ok=false
    log_info "Trying get.docker.com..."
    if curl -fsSL --max-time 30 https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null \
       && sh /tmp/get-docker.sh 2>&1 | tail -10 | sed 's/^/    [docker-installer] /' \
       && command -v docker &>/dev/null; then
        docker_ok=true
        log_ok "Installed via get.docker.com: $(docker --version)"
    fi
    rm -f /tmp/get-docker.sh 2>/dev/null

    if [[ "$docker_ok" != true ]]; then
        log_warn "get.docker.com unavailable — falling back to distro docker.io"
        rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null || true
        apt-get update -qq 2>/dev/null || true
        install_packages docker.io docker-compose-v2 || \
            install_packages docker.io docker-compose-plugin || \
            install_packages docker.io
        command -v docker &>/dev/null && {
            docker_ok=true
            log_ok "Installed from distro: $(docker --version)"
        }
    fi

    [[ "$docker_ok" != true ]] && { log_error "Docker install failed"; STEP_STATUS["docker"]="FAILED"; return 1; }

    systemctl enable docker &>/dev/null || true
    systemctl start docker &>/dev/null || true
    docker compose version &>/dev/null || {
        install_packages docker-compose-plugin 2>/dev/null || \
        install_packages docker-compose-v2     2>/dev/null || true
    }
    log_ok "Compose: $(docker compose version 2>/dev/null || echo unavailable)"
    STEP_STATUS["docker"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 9 · CERT — wildcard via acme.sh + Cloudflare DNS-01
# ─────────────────────────────────────────────────────────────────────────────

setup_cert() {
    log_step "Issuing wildcard cert for *.${DOMAIN}"
    [[ "$DRY_RUN" == true ]] && { log_dry "acme.sh + CF DNS-01 for *.${DOMAIN}"; STEP_STATUS["cert"]="DRY"; return 0; }

    local acme_home="/root/.acme.sh"
    if [[ ! -x "${acme_home}/acme.sh" ]]; then
        log_info "Installing acme.sh..."
        # Clean any half-broken previous install
        rm -rf "$acme_home" 2>/dev/null || true

        if ! curl -fsSL https://get.acme.sh -o /tmp/acme-install.sh; then
            log_error "Failed to download acme.sh installer from get.acme.sh"
            STEP_STATUS["cert"]="FAILED"
            return 1
        fi

        # The official acme.sh installer expects `email=...` as an argument
        # (NOT --install-online — that flag doesn't exist).
        # Run it verbosely so any error is visible; then verify the binary landed.
        local acme_out
        acme_out="$(sh /tmp/acme-install.sh email="admin@${DOMAIN}" 2>&1)"
        rm -f /tmp/acme-install.sh

        if [[ ! -x "${acme_home}/acme.sh" ]]; then
            log_error "acme.sh installer ran but ${acme_home}/acme.sh was not created."
            log_error "Installer output (last 20 lines):"
            echo "$acme_out" | tail -20 | sed 's/^/    [acme-installer] /' >&2
            STEP_STATUS["cert"]="FAILED"
            return 1
        fi
        log_ok "acme.sh installed at ${acme_home}"
    fi

    "${acme_home}/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    "${acme_home}/acme.sh" --register-account -m "admin@${DOMAIN}" >/dev/null 2>&1 || true

    mkdir -p "${NGINX_DIR}/ssl"
    local fullchain="${NGINX_DIR}/ssl/fullchain.pem"
    local privkey="${NGINX_DIR}/ssl/privkey.pem"

    if [[ -f "$fullchain" ]] && openssl x509 -in "$fullchain" -checkend $((60*86400)) -noout 2>/dev/null; then
        log_info "Cert valid >60d — skipping issuance"
    else
        log_info "Requesting cert (DNS propagation can take ~2min)..."
        local acme_log; acme_log="$(mktemp)"
        # Run with set +e so we can check the real exit code from acme.sh below.
        # We pipe through tee for live progress + log capture; pipefail/sed combo
        # would mask acme.sh's true exit code, so save it explicitly via PIPESTATUS.
        set +e
        CF_Token="$CF_TOKEN" "${acme_home}/acme.sh" --issue \
            --dns dns_cf \
            -d "${DOMAIN}" \
            -d "*.${DOMAIN}" \
            --keylength ec-256 \
            --server letsencrypt \
            --force 2>&1 | tee "$acme_log" | sed 's/^/    [acme] /'
        local rc=${PIPESTATUS[0]}
        set -e

        # Success signal: acme.sh prints "Cert success." once the cert is downloaded.
        # The intermediate "Pending. The CA is processing your order, please wait." line
        # is NOT an error — it's a normal status during validation. Don't grep for it.
        if (( rc != 0 )) || ! grep -q "Cert success\." "$acme_log"; then
            log_error "Cert issuance failed (exit code: ${rc}). Last 25 lines of acme.sh output:"
            tail -25 "$acme_log" | sed 's/^/    [acme] /' >&2
            log_error "Common causes:"
            log_error "  • CF token lacks 'Zone:DNS:Edit' for the zone covering '${DOMAIN}'"
            log_error "  • DOMAIN is not a subdomain of any zone in your Cloudflare account"
            log_error "  • Let's Encrypt rate limit hit (5 duplicate certs/week per registered domain)"
            rm -f "$acme_log"
            STEP_STATUS["cert"]="FAILED"
            return 1
        fi
        rm -f "$acme_log"
        log_ok "Cert issued by Let's Encrypt"
        "${acme_home}/acme.sh" --install-cert \
            -d "${DOMAIN}" --ecc \
            --fullchain-file "$fullchain" \
            --key-file "$privkey" \
            --reloadcmd "docker compose -f ${NGINX_DIR}/docker-compose.yml exec ${NGINX_CONTAINER} nginx -s reload 2>/dev/null || true" \
            >/dev/null
        chmod 600 "$privkey"
        chmod 644 "$fullchain"
        log_ok "Wildcard cert installed"
    fi

    # (no host-side symlink needed: the node container gets the cert via
    # ${NGINX_DIR}/ssl → /etc/xray/cert mount declared in setup_node)

    # Manual renew helper
    cat > "$CERT_RENEW_BIN" <<EOF
#!/usr/bin/env bash
set -e
source ${STATE_DIR}/secrets.env
CF_Token="\$CF_TOKEN" ${acme_home}/acme.sh --renew -d ${DOMAIN} --ecc --force
${acme_home}/acme.sh --install-cert -d ${DOMAIN} --ecc \\
    --fullchain-file ${fullchain} \\
    --key-file ${privkey} \\
    --reloadcmd "docker compose -f ${NGINX_DIR}/docker-compose.yml exec ${NGINX_CONTAINER} nginx -s reload 2>/dev/null || true"
EOF
    chmod +x "$CERT_RENEW_BIN"
    STEP_STATUS["cert"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 9b · WILDCARD DNS A RECORD via Cloudflare API
# Creates `*.${DOMAIN} → ${NODE_PUBLIC_IP}` so any rotated SNI subdomain
# resolves to this node. Required for browser-based selfsteal tests and for
# Xray clients that do DNS validation on SNI. Reality proxy traffic itself
# connects by IP so doesn't strictly need DNS, but having a real A record
# makes the SNI subdomain look "real" to DPI as well.
# ─────────────────────────────────────────────────────────────────────────────

# Find the Cloudflare zone that covers the given DOMAIN.
# Walks up the labels (target.kitsura.fun → kitsura.fun → fun) and stops at
# the first one the CF_TOKEN can see in /zones?name=...
_cf_find_zone_id() {
    local d="$DOMAIN"
    while [[ "$d" == *.* ]]; do
        local resp; resp="$(curl -fsS --max-time 10 \
            -H "Authorization: Bearer ${CF_TOKEN}" \
            "https://api.cloudflare.com/client/v4/zones?name=${d}" 2>/dev/null)" || resp=""
        local zid; zid="$(echo "$resp" | jq -r '.result[0].id // empty' 2>/dev/null)"
        if [[ -n "$zid" ]]; then
            echo "${zid}|${d}"
            return 0
        fi
        d="${d#*.}"  # strip leftmost label
    done
    return 1
}

setup_wildcard_dns() {
    log_step "Creating wildcard DNS A record *.${DOMAIN} → ${NODE_PUBLIC_IP}"
    [[ "$DRY_RUN" == true ]] && { log_dry "Cloudflare API: upsert *.${DOMAIN} A → ${NODE_PUBLIC_IP}"; STEP_STATUS["wildcard_dns"]="DRY"; return 0; }

    local zone_info; zone_info="$(_cf_find_zone_id)" || {
        log_error "Could not find Cloudflare zone for '${DOMAIN}' — is the CF token scoped to a parent zone?"
        STEP_STATUS["wildcard_dns"]="FAILED"
        return 1
    }
    local zone_id="${zone_info%|*}"
    local zone_name="${zone_info##*|}"
    log_info "Cloudflare zone: ${zone_name} (id: ${zone_id})"

    # Check if record already exists
    local record_name="*.${DOMAIN}"
    local existing; existing="$(curl -fsS --max-time 10 \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${record_name}")"
    local rec_id; rec_id="$(echo "$existing" | jq -r '.result[0].id // empty')"

    # `proxied: false` is CRITICAL — Reality needs a direct TCP connection to
    # the node. With CF proxy ON, all traffic goes through Cloudflare's edge
    # which strips Reality's TLS handshake characteristics.
    local body
    body="$(jq -n --arg name "$record_name" --arg ip "$NODE_PUBLIC_IP" \
        '{type: "A", name: $name, content: $ip, proxied: false, ttl: 1}')"

    local resp
    if [[ -n "$rec_id" ]]; then
        log_info "Wildcard record exists — updating to point at ${NODE_PUBLIC_IP}"
        resp="$(curl -fsS --max-time 10 -X PUT \
            -H "Authorization: Bearer ${CF_TOKEN}" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${rec_id}" \
            -d "$body")"
    else
        log_info "Creating new wildcard record"
        resp="$(curl -fsS --max-time 10 -X POST \
            -H "Authorization: Bearer ${CF_TOKEN}" \
            -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
            -d "$body")"
    fi

    if [[ "$(echo "$resp" | jq -r '.success // false')" != "true" ]]; then
        log_error "Cloudflare API rejected the DNS write:"
        echo "$resp" | jq '.errors // .' 2>/dev/null | sed 's/^/    [cf-api] /' >&2
        STEP_STATUS["wildcard_dns"]="FAILED"
        return 1
    fi

    log_ok "Wildcard DNS record live: *.${DOMAIN} → ${NODE_PUBLIC_IP} (proxied=false)"
    STEP_STATUS["wildcard_dns"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 10 · NGINX SELFSTEAL — unix socket + XHTTP gRPC + reject default
# ─────────────────────────────────────────────────────────────────────────────

setup_nginx_selfsteal() {
    log_step "Setting up Nginx selfsteal (${NGINX_SOCK} + XHTTP via ${XHTTP_SOCK})"
    [[ "$DRY_RUN" == true ]] && { log_dry "Write nginx config + start container"; STEP_STATUS["nginx"]="DRY"; return 0; }

    mkdir -p "${NGINX_DIR}"/{conf.d,html,logs,ssl}

    # Main nginx.conf — minimal, lets conf.d/site.conf do the work
    cat > "${NGINX_DIR}/nginx.conf" <<'NGX_MAIN'
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
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    server_tokens off;

    set_real_ip_from 127.0.0.1;
    set_real_ip_from unix:;
    real_ip_header proxy_protocol;

    log_format pp '$proxy_protocol_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent';

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ""      close;
    }

    include /etc/nginx/conf.d/*.conf;
}
NGX_MAIN

    # site.conf — wildcard server_name + XHTTP gRPC pass + reject default
    cat > "${NGINX_DIR}/conf.d/site.conf" <<EOF
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
# Cipher order matches Cloudflare's TLS 1.2/1.3 server preference (canonical
# "modern" recipe). Real CDNs use this exact order — DPI fingerprinting that
# scores cipher-suite ordering as a signal should see "looks like Cloudflare".
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
# Session cache name is what's burned into the shared memory zone — rename
# off MozSSL to avoid trivial fingerprinting via cache zone size + name.
ssl_session_cache shared:SSL:50m;
# Session tickets ON: IPLogs research (2026) flagged "session ticket length
# differs from real site" as a Reality-vs-real signal in active probing.
# Without tickets we'd send no ticket — real sites usually do send one.
ssl_session_tickets on;

# HTTP → HTTPS redirect on port 80 (no proxy_protocol — direct TCP).
# Nginx in host network mode can bind 0.0.0.0:80 directly.
# Xray Reality only owns 443, so 80 is free for nginx.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # ACME HTTP-01 fallback (we use DNS-01 by default but keep this just in case)
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen unix:${NGINX_SOCK} ssl proxy_protocol;
    http2 on;
    server_name *.${DOMAIN} ${DOMAIN};

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_trusted_certificate /etc/nginx/ssl/fullchain.pem;

    root /usr/share/nginx/html;
    index index.html;

    access_log /var/log/nginx/access.log pp;
    error_log  /var/log/nginx/error.log warn;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    # Cloudflare-style response headers — DPI grep-detection that triggers
    # on "Server: nginx + no CF-RAY" gets confused. The Alt-Svc tells the
    # client HTTP/3 is available on :443 — same as every real CDN site.
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
    set \$cf_ray \$request_id\$msec;
    add_header CF-Cache-Status DYNAMIC always;
    add_header CF-RAY "\$cf_ray" always;

    # Fake static assets that the stub HTML references. Real sites serve
    # CSS/JS bundles from CDN; if the stub returns 404 for /static/*.js
    # an active probe sees "site references resources that don't exist" —
    # selfsteal tell. Return tiny realistic-looking responses so the page
    # appears whole.
    location ~ ^/static/[^/]+\.js$ {
        default_type application/javascript;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        return 200 "/* (c) 2026 */\n!function(){var e={env:\"production\"};window.__APP=e;}();\n";
    }
    location ~ ^/static/[^/]+\.css$ {
        default_type text/css;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        return 200 "/* */\n:root{--bg:#0d1117}body{margin:0}\n";
    }

    location ${XHTTP_PATH} {
        client_max_body_size 0;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        client_body_timeout 5m;
        grpc_read_timeout 315;
        grpc_send_timeout 5m;
        grpc_pass unix:${XHTTP_SOCK};
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}

# Default server — reject unknown SNI
server {
    listen unix:${NGINX_SOCK} ssl proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}
EOF

    # HTML stub — pick one of the templates at random.
    # Templates live in templates/stubs/<name>.html in the repo.
    # If running from a local clone, copy directly. Otherwise download from RAW_BASE.
    local stub_templates=(realestate sushi analytics apidocs blog portfolio)
    # Sticky: re-runs keep the same stub so the visible site doesn't change.
    if [[ -z "${STUB_NAME:-}" ]]; then
        STUB_NAME="${stub_templates[$RANDOM % ${#stub_templates[@]}]}"
    fi
    log_info "Selfsteal stub: ${STUB_NAME}"

    local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""
    local html_dest="${NGINX_DIR}/html/index.html"
    if [[ -f "${script_dir}/templates/stubs/${STUB_NAME}.html" ]]; then
        cp "${script_dir}/templates/stubs/${STUB_NAME}.html" "$html_dest"
    elif curl -fsSL "${RAW_BASE}/templates/stubs/${STUB_NAME}.html" -o "$html_dest"; then
        log_info "Fetched stub from ${RAW_BASE}/templates/stubs/${STUB_NAME}.html"
    else
        log_warn "Could not fetch stub template — falling back to a minimal placeholder"
        cat > "$html_dest" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>Service</title></head>
<body style="font-family:system-ui;text-align:center;padding:80px">
<h1>Service</h1><p>The site is running.</p></body></html>
HTML
        STUB_NAME="minimal"
    fi

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

    log_info "Starting nginx container..."
    ( cd "$NGINX_DIR" && docker compose up -d 2>&1 | sed 's/^/    [nginx] /' ) || {
        log_error "Nginx failed to start"
        STEP_STATUS["nginx"]="FAILED"
        return 1
    }
    sleep 2
    docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER" && {
        log_ok "Nginx selfsteal running"
        STEP_STATUS["nginx"]="OK"
    } || {
        log_error "Nginx container not visible after start"
        STEP_STATUS["nginx"]="FAILED"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11 · GENERATE REALITY KEYS + HYS PASSWORDS
# ─────────────────────────────────────────────────────────────────────────────

generate_secrets() {
    log_step "Generating Reality keypairs + Hysteria passwords"
    [[ "$DRY_RUN" == true ]] && { log_dry "x25519 + openssl rand"; STEP_STATUS["secrets"]="DRY"; return 0; }

    # Sticky-secret guard: if state_load brought existing values back from
    # a previous install, skip regenerating them. Re-runs MUST reuse the same
    # Reality keypairs, shortIds, and Hysteria passwords — otherwise the host
    # records already in the panel point at stale crypto and stop working.
    local need_keys=false
    [[ -z "${REALITY_PRIV_TCP:-}" || -z "${REALITY_PUB_TCP:-}" ]] && need_keys=true
    [[ -z "${REALITY_PRIV_GRPC:-}" || -z "${REALITY_PUB_GRPC:-}" ]] && need_keys=true
    if [[ "$need_keys" != true \
       && -n "${SHORT_ID_TCP:-}" && -n "${SHORT_ID_GRPC:-}" \
       && -n "${HYS_PASSWORD:-}" && -n "${HYS_OBFS_PASSWORD:-}" ]]; then
        log_info "Reusing existing keys/secrets from state"
        STEP_STATUS["secrets"]="SKIPPED(state)"
        return 0
    fi

    log_info "Pulling node image (needed for xray x25519 keygen)..."
    docker pull "$NODE_IMAGE" 2>&1 | tail -2 | sed 's/^/    [pull] /' || {
        log_error "Failed to pull node image"
        STEP_STATUS["secrets"]="FAILED"
        return 1
    }

    if [[ -z "${REALITY_PRIV_TCP:-}" || -z "${REALITY_PUB_TCP:-}" ]]; then
        log_info "Generating Reality keypair (TCP inbound)..."
        local kp; kp="$(reality_keygen)" || return 1
        REALITY_PRIV_TCP="${kp%%|*}"
        REALITY_PUB_TCP="${kp##*|}"
    fi
    if [[ -z "${REALITY_PRIV_GRPC:-}" || -z "${REALITY_PUB_GRPC:-}" ]]; then
        log_info "Generating Reality keypair (gRPC inbound)..."
        local kp; kp="$(reality_keygen)" || return 1
        REALITY_PRIV_GRPC="${kp%%|*}"
        REALITY_PUB_GRPC="${kp##*|}"
    fi

    [[ -z "${HYS_PASSWORD:-}" ]]      && HYS_PASSWORD="$(gen_password)"
    [[ -z "${HYS_OBFS_PASSWORD:-}" ]] && HYS_OBFS_PASSWORD="$(gen_password)"
    [[ -z "${SHORT_ID_TCP:-}" ]]      && SHORT_ID_TCP="$(openssl rand -hex 8)"
    [[ -z "${SHORT_ID_GRPC:-}" ]]     && SHORT_ID_GRPC="$(openssl rand -hex 8)"

    log_ok "Secrets generated"
    STEP_STATUS["secrets"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 12 · BUILD XRAY CONFIG JSON (template based on user-provided example)
# ─────────────────────────────────────────────────────────────────────────────

# Args: $1 — initial SNI string
build_xray_config() {
    local sni="$1"
    local tag_main="${COUNTRY_CODE}-${NODE_SEQUENCE}"
    local tag_grpc="${tag_main}-GRPC"
    local tag_xhttp="${tag_main}-XHTTP"
    local tag_hys="${tag_main}-HYS"
    # Hysteria2 cert paths AS SEEN FROM INSIDE the node container.
    # node-bootstrap mounts /opt/web/nginx/ssl → /etc/xray/cert (read-only)
    # so Xray can read the same wildcard cert that nginx serves.
    local hys_cert="/etc/xray/cert/fullchain.pem"
    local hys_key="/etc/xray/cert/privkey.pem"

    jq -n \
        --arg t1 "$tag_main" --arg t2 "$tag_grpc" --arg t3 "$tag_xhttp" --arg t4 "$tag_hys" \
        --arg sock "$NGINX_SOCK" --arg xhttp_sock "$XHTTP_SOCK" --arg xhttp_path "$XHTTP_PATH" \
        --arg sni "$sni" \
        --arg priv1 "$REALITY_PRIV_TCP"  --arg pub1 "$REALITY_PUB_TCP"  --arg sid1 "$SHORT_ID_TCP" \
        --arg priv2 "$REALITY_PRIV_GRPC" --arg pub2 "$REALITY_PUB_GRPC" --arg sid2 "$SHORT_ID_GRPC" \
        --arg hys_pwd "$HYS_PASSWORD" --arg hys_obfs "$HYS_OBFS_PASSWORD" \
        --arg hys_cert "$hys_cert" --arg hys_key "$hys_key" \
'{
  log: {loglevel: "warning"},
  dns: {
    servers: ["https://dns.quad9.net/dns-query", "https://dns.google/dns-query", "localhost"],
    queryStrategy: "UseIPv4"
  },
  inbounds: [
    {
      tag: $t1,
      port: 443,
      protocol: "vless",
      settings: {clients: [], decryption: "none"},
      sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]},
      streamSettings: {
        network: "raw",
        security: "reality",
        realitySettings: {
          dest: $sock,
          show: false,
          xver: 1,
          spiderX: "",
          shortIds: [$sid1],
          publicKey: $pub1,
          privateKey: $priv1,
          serverNames: [$sni]
        }
      }
    },
    {
      tag: $t2,
      port: 8443,
      protocol: "vless",
      settings: {clients: [], decryption: "none"},
      sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]},
      streamSettings: {
        network: "grpc",
        security: "reality",
        grpcSettings: {serviceName: "grpc-proxy"},
        realitySettings: {
          dest: $sock,
          show: false,
          xver: 1,
          spiderX: "",
          shortIds: [$sid2],
          publicKey: $pub2,
          privateKey: $priv2,
          serverNames: [$sni]
        }
      }
    },
    {
      tag: $t3,
      listen: ($xhttp_sock + ",0666"),
      protocol: "vless",
      settings: {clients: [], fallbacks: [], decryption: "none"},
      sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]},
      streamSettings: {
        network: "xhttp",
        xhttpSettings: {
          mode: "packet-up",
          path: $xhttp_path,
          extra: {noSSEHeader: true, xPaddingBytes: "100-1000", scMaxBufferedPosts: 30, scMaxEachPostBytes: 786432}
        }
      }
    },
    {
      tag: $t4,
      port: 9443,
      protocol: "hysteria",
      settings: {
        obfs: {type: "salamander", password: $hys_obfs},
        clients: [],
        version: 2,
        password: $hys_pwd
      },
      streamSettings: {
        network: "hysteria",
        security: "tls",
        sniffing: {enabled: false},
        tlsSettings: {
          alpn: ["h3"],
          certificates: [{keyFile: $hys_key, certificateFile: $hys_cert}]
        },
        hysteriaSettings: {version: 2}
      }
    }
  ],
  outbounds: [
    {tag: "DIRECT", protocol: "freedom"},
    {tag: "BLOCK",  protocol: "blackhole"},
    {tag: "TORRENT",protocol: "blackhole"}
  ],
  routing: {
    rules: [
      {protocol: ["bittorrent"], outboundTag: "TORRENT"},
      {protocol: ["quic"],       outboundTag: "BLOCK"},
      {domain:   ["geosite:private"], outboundTag: "BLOCK"},
      {ip:       ["geoip:private"],   outboundTag: "BLOCK"}
    ],
    domainStrategy: "IPIfNonMatch"
  }
}'
}

# Pick initial SNI value at install time
generate_initial_sni() {
    case "${SNI_STYLE}" in
        cdn)
            local prefixes=(api cdn docs static web edge assets media swagger supabase)
            local regions=(fra ams lhr sgp nrt iad lax ord)
            echo "${prefixes[$RANDOM % ${#prefixes[@]}]}-$((RANDOM % 99 + 1))-${regions[$RANDOM % ${#regions[@]}]}.${DOMAIN}"
            ;;
        words)
            echo "blue-river-$((RANDOM % 99 + 1)).${DOMAIN}"
            ;;
        hex)
            echo "$(openssl rand -hex 3).${DOMAIN}"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 13 · PANEL — create config-profile + node + hosts
# ─────────────────────────────────────────────────────────────────────────────

setup_panel_resources() {
    log_step "Creating resources in panel via API"
    [[ "$DRY_RUN" == true ]] && {
        log_dry "Would: GET /api/keygen, POST /api/config-profiles, POST /api/nodes, POST /api/hosts ×4"
        STEP_STATUS["panel"]="DRY"
        return 0
    }

    # 1. Get panel pub key (used as SSL_CERT in node .env)
    log_info "Fetching panel pubKey..."
    NODE_SECRET_KEY="$(panel_get_keygen)" || {
        log_error "Failed to GET /api/keygen — token has wrong scope?"
        STEP_STATUS["panel"]="FAILED"
        return 1
    }
    [[ "$NODE_SECRET_KEY" == "null" || -z "$NODE_SECRET_KEY" ]] && {
        log_error "/api/keygen returned empty pubKey"
        STEP_STATUS["panel"]="FAILED"
        return 1
    }
    log_ok "Got panel pubKey ($(echo -n "$NODE_SECRET_KEY" | wc -c) chars)"

    # 2. Build Xray config + create config-profile
    local initial_sni; initial_sni="$(generate_initial_sni)"
    log_info "Initial SNI: ${initial_sni}"
    local xray_cfg; xray_cfg="$(build_xray_config "$initial_sni")"

    local profile_name="${NODE_NAME}"
    log_info "Creating config-profile '${profile_name}'..."
    local cp_resp; cp_resp="$(panel_create_config_profile "$profile_name" "$xray_cfg")" || {
        log_error "Failed to create config-profile"
        STEP_STATUS["panel"]="FAILED"
        return 1
    }
    CONFIG_PROFILE_UUID="$(echo "$cp_resp" | jq -r '.response.uuid')"
    log_ok "config-profile UUID: ${CONFIG_PROFILE_UUID}"

    # 3. Extract inbound UUIDs from the profile (panel assigns its own UUIDs).
    # The create-profile response sometimes returns inbounds in `.response.inbounds`
    # (top-level), but on some panel versions they only live nested under
    # `.response.config.inbounds`. Re-fetch the profile via GET to be sure we
    # have the authoritative set with panel-assigned UUIDs.
    log_info "Re-fetching config-profile to read panel-assigned inbound UUIDs..."
    local cp_full; cp_full="$(panel_req GET "/api/config-profiles/${CONFIG_PROFILE_UUID}")"
    local inbounds; inbounds="$(echo "$cp_full" | jq -c '.response.inbounds // .response.config.inbounds // []')"
    local inbounds_count; inbounds_count="$(echo "$inbounds" | jq 'length')"
    log_info "Profile has ${inbounds_count} inbounds"

    if [[ "$inbounds_count" -lt 4 ]]; then
        log_error "Expected 4 inbounds, got ${inbounds_count}. Dumping response structure for debugging:"
        echo "$cp_full" | jq '. | {response_keys: (.response | keys), inbounds_at_response: (.response.inbounds // null | length), inbounds_at_config: (.response.config.inbounds // null | length), first_inbound_sample: (.response.inbounds[0] // .response.config.inbounds[0] // null)}' | sed 's/^/    [debug] /' >&2
        STEP_STATUS["panel"]="FAILED"
        return 1
    fi

    local tag_main="${COUNTRY_CODE}-${NODE_SEQUENCE}"
    NODE_INBOUND_REALITY_UUID="$(echo "$inbounds" | jq -r --arg t "$tag_main"       '.[] | select(.tag == $t) | .uuid' | head -1)"
    NODE_INBOUND_GRPC_UUID="$(echo "$inbounds"    | jq -r --arg t "${tag_main}-GRPC"  '.[] | select(.tag == $t) | .uuid' | head -1)"
    NODE_INBOUND_XHTTP_UUID="$(echo "$inbounds"   | jq -r --arg t "${tag_main}-XHTTP" '.[] | select(.tag == $t) | .uuid' | head -1)"
    NODE_INBOUND_HYS_UUID="$(echo "$inbounds"     | jq -r --arg t "${tag_main}-HYS"   '.[] | select(.tag == $t) | .uuid' | head -1)"

    if [[ -z "$NODE_INBOUND_REALITY_UUID" ]]; then
        log_warn "Could not match inbounds by tag — first inbound has tag='$(echo "$inbounds" | jq -r '.[0].tag')'. Falling back to index order."
        NODE_INBOUND_REALITY_UUID="$(echo "$inbounds" | jq -r '.[0].uuid')"
        NODE_INBOUND_GRPC_UUID="$(echo "$inbounds"    | jq -r '.[1].uuid')"
        NODE_INBOUND_XHTTP_UUID="$(echo "$inbounds"   | jq -r '.[2].uuid')"
        NODE_INBOUND_HYS_UUID="$(echo "$inbounds"     | jq -r '.[3].uuid')"
    fi

    # Final sanity check — make sure every slot ended up with a real UUID
    for slot in REALITY GRPC XHTTP HYS; do
        local var="NODE_INBOUND_${slot}_UUID"
        local val="${!var}"
        if [[ -z "$val" || "$val" == "null" ]]; then
            log_error "Could not resolve inbound UUID for slot ${slot}"
            log_error "Inbound list panel returned:"
            echo "$inbounds" | jq '.[] | {tag, uuid, type, network, security}' | sed 's/^/    [inbound] /' >&2
            STEP_STATUS["panel"]="FAILED"
            return 1
        fi
    done

    log_info "Inbound UUIDs: REALITY=${NODE_INBOUND_REALITY_UUID} GRPC=${NODE_INBOUND_GRPC_UUID} XHTTP=${NODE_INBOUND_XHTTP_UUID} HYS=${NODE_INBOUND_HYS_UUID}"

    # 4. Create node in panel
    log_info "Registering node '${NODE_NAME}' in panel..."
    local node_body
    node_body="$(jq -n \
        --arg name "$NODE_NAME" \
        --arg addr "$NODE_PUBLIC_IP" \
        --arg cc "$COUNTRY_CODE" \
        --argjson port "$NODE_PORT" \
        --arg cp "$CONFIG_PROFILE_UUID" \
        --argjson inbounds "$(jq -n --arg a "$NODE_INBOUND_REALITY_UUID" --arg b "$NODE_INBOUND_GRPC_UUID" --arg c "$NODE_INBOUND_XHTTP_UUID" --arg d "$NODE_INBOUND_HYS_UUID" '[$a,$b,$c,$d]')" \
        --arg tag "$(echo "${TAG_PREFIX}" | tr -c 'A-Z0-9_:' '_' | head -c 36)" \
        '{
            name: $name,
            address: $addr,
            port: $port,
            countryCode: $cc,
            configProfile: {activeConfigProfileUuid: $cp, activeInbounds: $inbounds},
            tags: [$tag]
        }')"

    local node_resp; node_resp="$(panel_create_node "$node_body")" || {
        log_error "Failed to create node"
        STEP_STATUS["panel"]="FAILED"
        return 1
    }
    NODE_UUID="$(echo "$node_resp" | jq -r '.response.uuid')"
    log_ok "Node UUID: ${NODE_UUID}"

    # Verify the node actually got the 4 activeInbounds we sent. The panel will
    # sometimes silently accept a malformed POST and create the node with an
    # empty activeInbounds array — which then ships an empty Xray config to
    # the container, and Xray binds nothing. This catches that early.
    local node_check; node_check="$(panel_req GET "/api/nodes/${NODE_UUID}" 2>/dev/null || echo '')"
    local active_count; active_count="$(echo "$node_check" | jq '[.response.configProfile.activeInbounds[]?] | length' 2>/dev/null || echo 0)"
    if [[ "$active_count" -lt 4 ]]; then
        log_error "Node was created but configProfile.activeInbounds has only ${active_count} entries (expected 4)."
        log_error "This means Xray will start with no listeners. The node is unusable."
        log_error "Node body sent to panel was:"
        echo "$node_body" | jq '.configProfile' | sed 's/^/    [sent] /' >&2
        log_error "Panel response for node ${NODE_UUID}:"
        echo "$node_check" | jq '.response.configProfile' | sed 's/^/    [got] /' >&2
        STEP_STATUS["panel"]="FAILED"
        return 1
    fi
    log_ok "Node has ${active_count} active inbounds linked"

    # Persist Initial SNI as our first AUTOSNI record (state file initialized)
    mkdir -p "$STATE_DIR"
    local now; now="$(date -Iseconds)"
    jq -n --arg n "$NODE_UUID" --arg p "$CONFIG_PROFILE_UUID" \
          --arg rt "$NODE_INBOUND_REALITY_UUID" --arg rg "$NODE_INBOUND_GRPC_UUID" \
          --arg sni "$initial_sni" --arg now "$now" \
        '{
            node_uuid: $n,
            config_profile_uuid: $p,
            inbound_reality_uuid: $rt,
            inbound_grpc_uuid: $rg,
            active_snis: [{sni: $sni, host_reality_uuid: "", host_grpc_uuid: "", created_at: $now}],
            last_rotation: $now
        }' > "${STATE_DIR}/sni.json"
    chmod 600 "${STATE_DIR}/sni.json"

    STEP_STATUS["panel"]="OK"
}

# Create 4 hosts (Reality TCP, Reality gRPC, XHTTP, Hysteria) at first install
# Returns Xray xHTTP extra-params JSON for the XHTTP host config.
# Tuned per the user-provided reference (xmux + padding + body-size ranges).
_xhttp_extra_json() {
    cat <<'JSON'
{
  "xmux": {
    "cMaxReuseTimes": "200-300",
    "maxConnections": 1,
    "hKeepAlivePeriod": 60,
    "hMaxRequestTimes": "200-300",
    "hMaxReusableSecs": "600-900"
  },
  "noGRPCHeader": false,
  "xPaddingBytes": "100-1000",
  "scMaxEachPostBytes": "393216-786432",
  "xPaddingKey": "v",
  "xPaddingPlacement": "query"
}
JSON
}

# Returns sockopt params JSON for TCP-based hosts (Reality TCP, gRPC, XHTTP).
# Skip for Hysteria — it's UDP, tcp* tunables don't apply.
_sockopt_params_json() {
    cat <<'JSON'
{
  "tcpcongestion": "bbr",
  "domainStrategy": "AsIs",
  "tcpUserTimeout": 10000,
  "tcpKeepAliveIdle": 300,
  "tcpKeepAliveInterval": 60
}
JSON
}

setup_initial_hosts() {
    log_step "Creating initial hosts in panel"
    [[ "$DRY_RUN" == true ]] && { log_dry "POST /api/hosts × 4"; STEP_STATUS["hosts"]="DRY"; return 0; }

    local sni; sni="$(jq -r '.active_snis[0].sni' "${STATE_DIR}/sni.json")"
    local flag; flag="$(country_flag "$COUNTRY_CODE")"
    local cname; cname="$(country_name "$COUNTRY_CODE")"
    local tag_base="${TAG_PREFIX}"

    # Pre-build JSON-fragment params so jq can include them as nested objects.
    local xhttp_extra sockopt_params
    xhttp_extra="$(_xhttp_extra_json)"
    sockopt_params="$(_sockopt_params_json)"

    # Helper to build remark within the panel's 40-char limit.
    #
    # The panel counts string length using JavaScript String.length (UTF-16
    # code units), where a regional-indicator flag emoji like 🇺🇸 is 4 units.
    # Bash ${#s} in a UTF-8 locale counts it as 2 code points instead. So a
    # remark that bash sees as 40 chars can end up as 42 in the panel's
    # validation — exactly what failed on US-01-AKILE with the full
    # "United States" country name.
    #
    # Resolution: use the 2-letter country code instead of the full name.
    # Bash conservatively budgets 32 chars to leave ~8 unit safety margin
    # for emoji UTF-16 expansion + any future panel change.
    _remark() {
        local prefix="$1" suffix="$2"
        local s="[${NODE_NAME}] ${flag} ${COUNTRY_CODE} · ${suffix}"
        if (( ${#s} > 32 )); then s="[${NODE_NAME}] ${flag} · ${suffix}"; fi
        if (( ${#s} > 32 )); then s="[${NODE_NAME}] · ${suffix}"; fi
        if (( ${#s} > 32 )); then s="${NODE_NAME} · ${suffix}"; fi
        echo "${s:0:32}"
    }

    # ─── Reality TCP — securityLayer=DEFAULT (panel reads Reality from inbound)
    local body
    body="$(jq -n \
        --arg cp "$CONFIG_PROFILE_UUID" --arg ib "$NODE_INBOUND_REALITY_UUID" \
        --arg remark "$(_remark "" "REALITY")" --arg addr "$NODE_PUBLIC_IP" \
        --arg sni "$sni" --arg tag "${tag_base}" --arg fp "$DEFAULT_FP" --arg node "$NODE_UUID" \
        --argjson sockopt "$sockopt_params" \
        '{inbound:{configProfileUuid:$cp,configProfileInboundUuid:$ib},
          remark:$remark, address:$addr, port:443, sni:$sni,
          fingerprint:$fp, tag:$tag, securityLayer:"DEFAULT",
          sockoptParams:$sockopt, nodes:[$node]}')"
    local resp; resp="$(panel_create_host "$body")" || { log_error "Failed to create Reality TCP host"; STEP_STATUS["hosts"]="FAILED"; return 1; }
    local h_reality; h_reality="$(echo "$resp" | jq -r '.response.uuid')"

    # ─── Reality gRPC — securityLayer=DEFAULT, serviceName via path
    body="$(jq -n \
        --arg cp "$CONFIG_PROFILE_UUID" --arg ib "$NODE_INBOUND_GRPC_UUID" \
        --arg remark "$(_remark "" "GRPC")" --arg addr "$NODE_PUBLIC_IP" \
        --arg sni "$sni" --arg tag "${tag_base}:GRPC" --arg fp "$DEFAULT_FP" --arg node "$NODE_UUID" \
        --arg path "grpc-proxy" \
        --argjson sockopt "$sockopt_params" \
        '{inbound:{configProfileUuid:$cp,configProfileInboundUuid:$ib},
          remark:$remark, address:$addr, port:8443, sni:$sni, path:$path,
          fingerprint:$fp, tag:$tag, securityLayer:"DEFAULT",
          sockoptParams:$sockopt, nodes:[$node]}')"
    resp="$(panel_create_host "$body")" || { log_error "Failed to create Reality gRPC host"; STEP_STATUS["hosts"]="FAILED"; return 1; }
    local h_grpc; h_grpc="$(echo "$resp" | jq -r '.response.uuid')"

    # ─── XHTTP — securityLayer=TLS (Xray inbound is socket-only; nginx terminates
    # TLS in front, so the client MUST do TLS itself to reach nginx).
    # SNI = base ${DOMAIN}: XHTTP/Hysteria are intentionally NOT rotated so that
    # a Reality-SNI bust doesn't collateral-kill them. ALPN h3,h2,http/1.1 for
    # client to advertise QUIC fallback chain.
    body="$(jq -n \
        --arg cp "$CONFIG_PROFILE_UUID" --arg ib "$NODE_INBOUND_XHTTP_UUID" \
        --arg remark "$(_remark "" "XHTTP")" --arg addr "$NODE_PUBLIC_IP" \
        --arg sni "${DOMAIN}" --arg host "${DOMAIN}" \
        --arg tag "${tag_base}:XHTTP" --arg fp "$DEFAULT_FP" --arg node "$NODE_UUID" \
        --arg path "$XHTTP_PATH" \
        --argjson xhttp_extra "$xhttp_extra" \
        --argjson sockopt "$sockopt_params" \
        '{inbound:{configProfileUuid:$cp,configProfileInboundUuid:$ib},
          remark:$remark, address:$addr, port:443,
          sni:$sni, host:$host, path:$path,
          alpn:"h3,h2,http/1.1",
          fingerprint:$fp, tag:$tag,
          securityLayer:"TLS",
          xHttpExtraParams:$xhttp_extra,
          sockoptParams:$sockopt,
          nodes:[$node]}')"
    resp="$(panel_create_host "$body")" || { log_error "Failed to create XHTTP host"; STEP_STATUS["hosts"]="FAILED"; return 1; }
    local h_xhttp; h_xhttp="$(echo "$resp" | jq -r '.response.uuid')"

    # ─── Hysteria — UDP/QUIC with its own TLS (cert from wildcard mount).
    # ALPN h3 (QUIC). securityLayer=TLS explicit. fingerprint set for the
    # underlying uTLS handshake. No sockoptParams — Hysteria is UDP.
    body="$(jq -n \
        --arg cp "$CONFIG_PROFILE_UUID" --arg ib "$NODE_INBOUND_HYS_UUID" \
        --arg remark "$(_remark "" "HYS")" --arg addr "$NODE_PUBLIC_IP" \
        --arg sni "${DOMAIN}" --arg host "${DOMAIN}" \
        --arg tag "${tag_base}:HYS" --arg fp "$DEFAULT_FP" --arg node "$NODE_UUID" \
        '{inbound:{configProfileUuid:$cp,configProfileInboundUuid:$ib},
          remark:$remark, address:$addr, port:9443,
          sni:$sni, host:$host,
          alpn:"h3",
          fingerprint:$fp, tag:$tag,
          securityLayer:"TLS",
          nodes:[$node]}')"
    resp="$(panel_create_host "$body")" || { log_error "Failed to create Hysteria host"; STEP_STATUS["hosts"]="FAILED"; return 1; }
    local h_hys; h_hys="$(echo "$resp" | jq -r '.response.uuid')"

    # Persist host UUIDs into sni.json
    jq --arg r "$h_reality" --arg g "$h_grpc" --arg x "$h_xhttp" --arg y "$h_hys" \
       '.active_snis[0].host_reality_uuid = $r |
        .active_snis[0].host_grpc_uuid    = $g |
        .static_hosts                     = {xhttp: $x, hysteria: $y}' \
       "${STATE_DIR}/sni.json" > "${STATE_DIR}/sni.json.tmp"
    mv "${STATE_DIR}/sni.json.tmp" "${STATE_DIR}/sni.json"
    chmod 600 "${STATE_DIR}/sni.json"

    log_ok "Created 4 hosts: REALITY=$h_reality GRPC=$h_grpc XHTTP=$h_xhttp HYS=$h_hys"
    STEP_STATUS["hosts"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 14 · NODE CONTAINER (uses NODE_SECRET_KEY obtained above)
# ─────────────────────────────────────────────────────────────────────────────

setup_node() {
    log_step "Deploying node container '${NODE_CONTAINER}'"
    [[ "$DRY_RUN" == true ]] && { log_dry "Deploy ${NODE_IMAGE} as ${NODE_CONTAINER}"; STEP_STATUS["node"]="DRY"; return 0; }
    [[ -z "$NODE_SECRET_KEY" ]] && { log_error "NODE_SECRET_KEY is empty — setup_panel_resources must run first"; STEP_STATUS["node"]="FAILED"; return 1; }

    mkdir -p "$NODE_DIR" "$NODE_DIR/logs"
    backup_file "${NODE_DIR}/.env"

    # The panel pubKey arrives as a multi-line PEM after jq -r decodes the JSON.
    # docker-compose env_file expects single-line values, so collapse any real
    # newlines back into literal '\n' sequences. The node app re-expands them.
    local secret_for_env
    secret_for_env="$(printf '%s' "$NODE_SECRET_KEY" | awk 'BEGIN{ORS=""}NR>1{printf "\\n"}{printf "%s", $0}')"

    cat > "${NODE_DIR}/.env" <<EOF
### NODE — generated $(date -Iseconds) ###
# Variable names below are dictated by the upstream node image and CANNOT be renamed.
NODE_PORT=${NODE_PORT}
SECRET_KEY=${secret_for_env}
EOF
    chmod 600 "${NODE_DIR}/.env"

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
      # Mount the wildcard cert so Xray (running inside this container) can
      # read it for the Hysteria2 inbound's tlsSettings. Nginx serves the same
      # files from its own /etc/nginx/ssl mount.
      - ${NGINX_DIR}/ssl:/etc/xray/cert:ro
      # Mount supervisor's log dir to host so logrotate can rotate xray.out.log
      - ${NODE_DIR}/logs:/var/log/supervisor
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
EOF

    log_info "Starting node container..."
    ( cd "$NODE_DIR" && docker compose up -d 2>&1 | sed 's/^/    [node] /' ) || {
        log_error "Node failed to start"
        STEP_STATUS["node"]="FAILED"
        return 1
    }

    # Give the app a few seconds to either come up or crash-loop on env validation
    sleep 6

    # Check container is up AND has been running for at least a few seconds (i.e.
    # not stuck in a fast restart loop due to bad env vars).
    if ! docker ps --format '{{.Names}}' | grep -qx "$NODE_CONTAINER"; then
        log_error "Node container is not visible in 'docker ps'"
        STEP_STATUS["node"]="FAILED"
        return 1
    fi

    local restart_count uptime_sec
    restart_count="$(docker inspect --format '{{.RestartCount}}' "$NODE_CONTAINER" 2>/dev/null || echo 0)"
    if (( restart_count > 1 )); then
        log_error "Node container is in a restart loop (RestartCount=${restart_count})."
        log_error "Last 20 log lines from the container:"
        docker logs --tail 20 "$NODE_CONTAINER" 2>&1 | sed 's/^/    [node] /' >&2
        log_error "Fix: check ${NODE_DIR}/.env, ensure NODE_PORT and SECRET_KEY are set correctly."
        STEP_STATUS["node"]="FAILED"
        return 1
    fi

    log_ok "Node container running (RestartCount=${restart_count})"
    STEP_STATUS["node"]="OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 15 · NSTP CLI + SNI ROTATOR INSTALL
# ─────────────────────────────────────────────────────────────────────────────

install_sni_rotator() {
    log_step "Installing SNI rotator"
    [[ "$DRY_RUN" == true ]] && { log_dry "Install ${SNI_ROTATE_BIN} + cron"; STEP_STATUS["sni_rotator"]="DRY"; return 0; }

    local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""
    if [[ -f "${script_dir}/web-sni-rotate" ]]; then
        cp "${script_dir}/web-sni-rotate" "$SNI_ROTATE_BIN"
        log_info "Installed rotator from local copy"
    else
        log_info "Fetching rotator from ${RAW_BASE}/web-sni-rotate"
        curl -fsSL "${RAW_BASE}/web-sni-rotate" -o "$SNI_ROTATE_BIN" || {
            log_error "Failed to download web-sni-rotate"
            STEP_STATUS["sni_rotator"]="FAILED"
            return 1
        }
    fi
    chmod +x "$SNI_ROTATE_BIN"

    local rand_min=$((RANDOM % 60))
    cat > /etc/cron.d/web-sni-rotate <<EOF
${rand_min} 4 * * * root ${SNI_ROTATE_BIN} rotate >> /var/log/web-sni-rotate.log 2>&1
EOF
    chmod 644 /etc/cron.d/web-sni-rotate
    log_ok "Rotator + cron installed (04:${rand_min} daily)"
    STEP_STATUS["sni_rotator"]="OK"
}

install_nstp_cli() {
    log_step "Installing 'nstp' management CLI"
    [[ "$DRY_RUN" == true ]] && { log_dry "Install ${NSTP_BIN}"; STEP_STATUS["nstp_cli"]="DRY"; return 0; }

    # Source nstp from a local clone if available; otherwise fetch from RAW_BASE.
    local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""
    if [[ -f "${script_dir}/nstp" ]]; then
        cp "${script_dir}/nstp" "$NSTP_BIN"
        log_info "Installed nstp from local copy"
    elif curl -fsSL "${RAW_BASE}/nstp" -o "$NSTP_BIN"; then
        log_info "Fetched nstp from ${RAW_BASE}/nstp"
    else
        log_error "Could not install nstp CLI"
        STEP_STATUS["nstp_cli"]="FAILED"
        return 1
    fi
    chmod +x "$NSTP_BIN"
    log_ok "Installed ${NSTP_BIN}"
    STEP_STATUS["nstp_cli"]="OK"
    return 0
}

# Stale heredoc — kept commented for reference until next refactor pass.

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 16 · SUMMARY
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
    echo -e "  ${BOLD}Node:${RESET}      ${NODE_NAME} $(country_flag "$COUNTRY_CODE") $(country_name "$COUNTRY_CODE")"
    echo -e "  ${BOLD}Panel UUID:${RESET} ${NODE_UUID}"
    echo -e "  ${BOLD}Profile:${RESET}    ${CONFIG_PROFILE_UUID}"
    echo ""
    echo -e "  ${BOLD}Next:${RESET}"
    echo "    • ${BOLD}nstp status${RESET}      — verify everything green"
    echo "    • ${BOLD}nstp sni list${RESET}    — current SNI + next rotation time"
    echo "    • In panel: attach hosts to your squad(s) so users see them"
    echo "    • SNI rotates every ${ROTATION_DAYS}d via cron (writes new SNI into Reality serverNames + creates fresh hosts)"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 17 · UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────

run_uninstall() {
    log_step "UNINSTALL"
    read -rp "  Remove everything? [yes/N]: " ans
    [[ "$ans" != "yes" ]] && { log_info "Aborted"; return 0; }
    [[ -f "${NODE_DIR}/docker-compose.yml"  ]] && ( cd "$NODE_DIR"  && docker compose down --volumes 2>/dev/null || true )
    [[ -f "${NGINX_DIR}/docker-compose.yml" ]] && ( cd "$NGINX_DIR" && docker compose down --volumes 2>/dev/null || true )
    rm -rf /opt/web /etc/nginx/ssl/node.*
    rm -f "$NSTP_BIN" "$SNI_ROTATE_BIN" "$CERT_RENEW_BIN"
    rm -f /etc/cron.d/web-sni-rotate
    rm -f /etc/sysctl.d/99-node-net.conf
    log_ok "Removed. Backups remain in ${BACKUP_DIR}/"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 18 · CLI PARSER
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF

${BOLD}node-bootstrap.sh ${SCRIPT_VERSION}${RESET}

${BOLD}Usage:${RESET}
  bash ${SCRIPT_NAME} [OPTIONS]

${BOLD}Required:${RESET}
  --domain <d>            base domain (cert covers *.<d>, e.g. node.example.com)
  --cf-token <t>          Cloudflare API token (Zone:DNS:Edit)
  --panel-url <u>         Remnawave panel URL
  --panel-token <t>       Panel API token
  --country <CC>          ISO-2 country code (e.g. NL, FI, DE)

${BOLD}Optional:${RESET}
  --hosting <name>        hosting suffix (e.g. 1CENT, HETZNER) — appended to node name
  --seq <NN>              force sequence number (otherwise auto-detected from panel)
  --node-port <p>         control port for panel ↔ node (default: ${NODE_PORT})
  --rotation-days <n>     SNI rotation cadence (default: ${ROTATION_DAYS})
  --active-snis <n>       active SNIs in rotation pool (default: ${ACTIVE_SNIS})
  --sni-style <s>         cdn | words | hex (default: ${SNI_STYLE})
  --fp <fp>               default fingerprint (default: ${DEFAULT_FP})
  --dry-run               simulate
  --verbose, -v           debug output
  --skip-update           skip apt update
  --non-interactive, -y   no prompts
  --status                show current state and exit
  --uninstall             remove everything
  --help, -h              this help

${BOLD}Existing-node fallback (if node was already created in panel UI):${RESET}
  --existing-node             enable fallback mode
  --existing-node-uuid <uuid> existing node UUID in panel
  --node-key <key>            existing node SECRET_KEY

${BOLD}Examples:${RESET}
  # Full automatic — creates everything in panel via API:
  bash ${SCRIPT_NAME} --domain example.com --cf-token cf_xxx \\
      --panel-url https://panel.example.com --panel-token rw_xxx \\
      --country NL --hosting 1CENT -y

  # Fallback — attach to existing node:
  bash ${SCRIPT_NAME} --domain example.com --cf-token cf_xxx \\
      --panel-url https://panel.example.com --panel-token rw_xxx \\
      --existing-node --existing-node-uuid <uuid> --node-key <KEY> -y
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)               DOMAIN="$2";              shift 2 ;;
            --cf-token)             CF_TOKEN="$2";            shift 2 ;;
            --panel-url)            PANEL_URL="$2";           shift 2 ;;
            --panel-token)          PANEL_API_TOKEN="$2";     shift 2 ;;
            --country)              COUNTRY_CODE="${2^^}";    shift 2 ;;
            --hosting)              HOSTING="${2^^}";         shift 2 ;;
            --seq)                  NODE_SEQUENCE="$2";       shift 2 ;;
            --node-port)            NODE_PORT="$2";           shift 2 ;;
            --rotation-days)        ROTATION_DAYS="$2";       shift 2 ;;
            --active-snis)          ACTIVE_SNIS="$2";         shift 2 ;;
            --sni-style)            SNI_STYLE="$2";           shift 2 ;;
            --fp)                   DEFAULT_FP="$2";          shift 2 ;;
            --monitor-from)         MONITOR_FROM_IP="$2";     shift 2 ;;
            --existing-node)        USE_EXISTING_NODE=true;   shift ;;
            --existing-node-uuid)   EXISTING_NODE_UUID="$2";  shift 2 ;;
            --node-key)             NODE_SECRET_KEY="$2";     shift 2 ;;
            --dry-run)              DRY_RUN=true;             shift ;;
            --verbose|-v)           VERBOSE=true;             shift ;;
            --skip-update)          SKIP_UPDATE=true;         shift ;;
            --non-interactive|-y)   NON_INTERACTIVE=true;     shift ;;
            --status)               preflight_checks; [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"; print_summary; exit 0 ;;
            --uninstall)            UNINSTALL=true;           shift ;;
            --version)              echo "node-bootstrap ${SCRIPT_VERSION}"; exit 0 ;;
            --help|-h)              usage; exit 0 ;;
            *)                      log_error "Unknown argument: $1"; usage; exit 2 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 19 · MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    print_header
    _log_session_header

    preflight_checks
    [[ "$UNINSTALL" == true ]] && { run_uninstall; exit 0; }
    [[ "$DRY_RUN" == true ]] && log_warn "DRY-RUN — no changes will be made"

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
    setup_wildcard_dns
    setup_nginx_selfsteal

    if [[ "$USE_EXISTING_NODE" == false ]]; then
        generate_secrets
        setup_panel_resources       # creates config-profile + node + initializes sni.json
        setup_node
        setup_initial_hosts         # creates 4 user-facing hosts
    else
        # Existing node — skip panel-side creation
        log_info "Using existing node UUID=${EXISTING_NODE_UUID}"
        NODE_UUID="$EXISTING_NODE_UUID"
        setup_node
        log_warn "Existing-node mode: hosts NOT auto-created. Run 'web-sni-rotate init' manually after verifying node is online in panel."
    fi

    install_sni_rotator
    install_nstp_cli
    setup_logrotate
    setup_node_exporter   # no-op unless --monitor-from <ip> is set

    state_save
    print_summary
}

main "$@"
