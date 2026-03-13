#!/usr/bin/env bash
# =============================================================================
#  SLIP TUNNEL MANAGER  |  Advanced DNS Tunnel Automation
#  Based on: slipstream-rust-plus-deploy (Fox-Fig/slipstream-rust-deploy)
#  Features: Multi-DNS, Anti-DPI, Live Monitor, x-ui Outbound, Auto-Failover
# =============================================================================

set -uo pipefail
# Note: -e (errexit) intentionally omitted; arithmetic ops like (( n++ )) return
# non-zero when result is 0, which would kill the script with -e. We handle
# errors explicitly in each function instead.

# ─── ROOT CHECK ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run as root"
    exit 1
fi

# ─── COLOR PALETTE ──────────────────────────────────────────────────────────
PU='\033[38;5;99m'     # Purple  darker
TE='\033[38;5;44m'     # Teal
GR='\033[0;32m'        # Green   (success ONLY)
YL='\033[1;33m'        # Yellow  (warning ONLY)
RD='\033[0;31m'        # Red     (error ONLY)
PK='\033[38;5;213m'    # Pink    (questions ONLY)
BD='\033[1m'           # Bold
NC='\033[0m'           # Reset

# ─── MESSAGE HELPERS ────────────────────────────────────────────────────────
OK()  { echo -e "${GR}[✓] $*${NC}"; }
WN()  { echo -e "${YL}[⚠] $*${NC}"; }
ER()  { echo -e "${RD}[✗] $*${NC}" >&2; }
PL()  { echo -e "${PU}$*${NC}"; }
TL()  { echo -e "${TE}$*${NC}"; }
ASK() { echo -ne "${PK}$*${NC} "; }

# ─── GLOBAL VARIABLES ───────────────────────────────────────────────────────
SCRIPT_VER="2.1.0"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/slipstream-rust"
SYSTEMD_DIR="/etc/systemd/system"
SVC_USER="slipstream"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
DNS_POOL_FILE="${CONFIG_DIR}/dns-pool.conf"
DNS_ACTIVE_FILE="${CONFIG_DIR}/dns-active.conf"
DNS_FAILED_FILE="${CONFIG_DIR}/dns-failed.conf"
DOMAINS_FILE="${CONFIG_DIR}/domains.conf"
SS_OUTPUT_FILE="${CONFIG_DIR}/xui-outbound.json"
HEALTH_SCRIPT="/usr/local/bin/slipstream-dns-health.sh"
SCRIPT_PATH="/usr/local/bin/slipstream-manager"
BUILD_DIR="/opt/slipstream-rust-src"
BINARY_NAME="dns-cache-server"
SVC_NAME="dns-cache"
RELEASE_URL="https://github.com/Fox-Fig/slipstream-rust-deploy/releases/latest/download"
REPO_URL="https://github.com/Fox-Fig/slipstream-rust-plus.git"
LOG_FILE="/var/log/slipstream.log"
INSTALL_LOG="/tmp/slipstream-install.log"
PKG_MANAGER=""

# ─── BANNER ─────────────────────────────────────────────────────────────────
show_banner() {
    local COLS
    COLS=$(tput cols 2>/dev/null || echo 80)

    # Full-width block border
    local border="" i
    for (( i=0; i<COLS; i++ )); do
        if [[ $(( i % 2 )) -eq 0 ]]; then border+="${PU}█${NC}"; else border+="${TE}█${NC}"; fi
    done
    echo -e "$border"

    # Inline python to render full-width banner
    python3 /dev/stdin "$COLS" "$SCRIPT_VER" << 'PYEOF'
import sys
cols = int(sys.argv[1])
ver  = sys.argv[2]
PU = "\033[38;5;99m"
TE = "\033[38;5;44m"
NC = "\033[0m"
lines = [
    "\u2591\u2588\u2580\u2580\u2591\u2588\u2591\u2591\u2591\u2580\u2588\u2580\u2591\u2588\u2580\u2588\u2591\u2591\u2591\u2580\u2588\u2580\u2591\u2588\u2591\u2588\u2591\u2588\u2580\u2588\u2591\u2588\u2580\u2588\u2591\u2588\u2580\u2580\u2591\u2588\u2591\u2591",
    "\u2591\u2580\u2580\u2588\u2591\u2588\u2591\u2591\u2591\u2591\u2588\u2591\u2591\u2588\u2580\u2580\u2591\u2591\u2591\u2591\u2588\u2591\u2591\u2588\u2591\u2588\u2591\u2588\u2591\u2588\u2591\u2588\u2591\u2588\u2591\u2588\u2580\u2580\u2591\u2588\u2591\u2591",
    "\u2591\u2580\u2580\u2580\u2591\u2580\u2580\u2580\u2591\u2580\u2580\u2580\u2591\u2580\u2591\u2591\u2591\u2591\u2591\u2591\u2580\u2591\u2591\u2580\u2580\u2580\u2591\u2580\u2591\u2580\u2591\u2580\u2591\u2580\u2591\u2580\u2580\u2580\u2591\u2580\u2580\u2580",
]
raw_w = 42
for li, line in enumerate(lines):
    colored = ""
    for ci, ch in enumerate(line):
        colored += (PU if ci % 2 == 0 else TE) + ch + NC
    pad   = max(0, (cols - raw_w) // 2)
    right = max(0, cols - raw_w - pad)
    lf = (PU if li % 2 == 0 else TE) + "\u2591" * pad + NC
    rf = (TE if li % 2 == 0 else PU) + "\u2591" * right + NC
    print(lf + colored + rf)
sub = f"  DNS Tunnel v{ver} \u2502 Anti-DPI \u2502 Multi-DNS \u2502 Auto-Failover  "
lp  = max(0, (cols - len(sub)) // 2)
rp  = max(0, cols - len(sub) - lp)
print(PU + "\u2588" * lp + TE + sub + PU + "\u2588" * rp + NC)
PYEOF
    echo -e "$border"
    echo ""
}


# ─── SPINNER / LOADING ──────────────────────────────────────────────────────
_SPIN_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
_spin_idx=0

run_silent() {
    # Usage: run_silent "message" command [args...]
    local msg="$1"; shift
    _spin_idx=0

    "$@" >"$INSTALL_LOG" 2>&1 &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${PU}%s${NC} ${TE}%s${NC}  " \
            "${_SPIN_FRAMES[$_spin_idx]}" "$msg"
        _spin_idx=$(( (_spin_idx + 1) % 10 )) || _spin_idx=0
        sleep 0.1
    done

    local rc=0
    wait "$pid" || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "\r${GR}✓${NC} ${TE}%-60s${NC}\n" "$msg"
    else
        printf "\r${RD}✗${NC} ${YL}%-60s${NC}\n" "$msg (see $INSTALL_LOG)"
        return $rc
    fi
}

progress_bar() {
    # Usage: progress_bar "msg" 1 10   (step 1 of 10)
    local msg="$1" step="$2" total="$3"
    local width=40
    local filled=$(( step * width / total ))
    local bar="" i
    for (( i=0; i<width; i++ )); do
        if [[ $i -lt $filled ]]; then
            if [[ $(( i % 2 )) -eq 0 ]]; then bar+="${PU}█${NC}"; else bar+="${TE}█${NC}"; fi
        else
            bar+="░"
        fi
    done
    local pct=$(( step * 100 / total ))
    printf "\r${TE}%s${NC} [%s${NC}] ${PU}%3d%%${NC}" "$msg" "$bar" "$pct"
    [[ $step -eq $total ]] && echo ""
}

sep_line() {
    local COLS
    COLS=$(tput cols 2>/dev/null || echo 80)
    local line="" i
    for (( i=0; i<COLS; i++ )); do
        if [[ $(( i % 2 )) -eq 0 ]]; then line+="${PU}─${NC}"; else line+="${TE}─${NC}"; fi
    done
    echo -e "$line"
}

# Full-width solid separator
solid_line() {
    local COLS; COLS=$(tput cols 2>/dev/null || echo 80)
    local line="" i
    for (( i=0; i<COLS; i++ )); do
        if [[ $(( i % 2 )) -eq 0 ]]; then line+="${PU}━${NC}"; else line+="${TE}━${NC}"; fi
    done
    echo -e "$line"
}

box_start() {
    local title="$1"
    local COLS; COLS=$(tput cols 2>/dev/null || echo 80)
    echo ""
    sep_line
    echo -e "${PU}  ◈  ${TE}${BD}${title}${NC}"
    sep_line
}

# ─── OS DETECTION ───────────────────────────────────────────────────────────
detect_os() {
    if command -v apt &>/dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    else
        ER "No supported package manager found (apt/dnf/yum)"; exit 1
    fi
}

# ─── INSTALL DEPENDENCIES ────────────────────────────────────────────────────
install_deps() {
    detect_os

    case $PKG_MANAGER in
        apt)
            run_silent "Updating package lists" apt-get update -qq
            run_silent "Installing dependencies" apt-get install -y -qq \
                curl wget git openssl iptables iptables-persistent \
                shadowsocks-libev dnsutils cron net-tools iproute2 \
                libssl-dev pkg-config cmake build-essential
            ;;
        dnf|yum)
            run_silent "Updating repos" $PKG_MANAGER makecache -q
            run_silent "Installing dependencies" $PKG_MANAGER install -y -q \
                curl wget git openssl iptables iptables-services \
                shadowsocks-libev bind-utils cronie net-tools iproute \
                openssl-devel pkgconfig cmake gcc-c++
            # Enable EPEL for shadowsocks if needed
            $PKG_MANAGER install -y -q epel-release &>/dev/null || true
            $PKG_MANAGER install -y -q shadowsocks-libev &>/dev/null || true
            ;;
    esac

    # Install Rust toolchain if not present
    if ! command -v cargo &>/dev/null; then
        run_silent "Installing Rust toolchain" bash -c \
            'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet'
        source "$HOME/.cargo/env" 2>/dev/null || true
    fi
}

# ─── DOWNLOAD / BUILD BINARY ─────────────────────────────────────────────────
get_arch_name() {
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "linux-amd64" ;;
        aarch64|arm64)  echo "linux-arm64" ;;
        armv7l)         echo "linux-armv7" ;;
        riscv64)        echo "linux-riscv64" ;;
        mips64)         echo "linux-mips64" ;;
        mips64el)       echo "linux-mips64le" ;;
        mips)           echo "linux-mips" ;;
        mipsel)         echo "linux-mipsle" ;;
        *)              return 1 ;;
    esac
}

download_binary() {
    local arch_name
    if ! arch_name=$(get_arch_name); then
        WN "No prebuilt binary for this architecture"; return 1
    fi

    local bin_name="slipstream-server-${arch_name}"
    local tmp="/tmp/${bin_name}"

    # Get latest tag from GitHub API
    local tag
    tag=$(curl -fsSL "https://api.github.com/repos/Fox-Fig/slipstream-rust-deploy/releases/latest" \
        2>/dev/null | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    local url
    if [[ -n "$tag" ]]; then
        url="https://github.com/Fox-Fig/slipstream-rust-deploy/releases/download/${tag}/${bin_name}"
    else
        url="${RELEASE_URL}/${bin_name}"
    fi

    if curl -fsSL "$url" -o "$tmp" 2>/dev/null; then
        if file "$tmp" 2>/dev/null | grep -qiE "(executable|ELF)"; then
            chmod +x "$tmp"
            cp "$tmp" "${INSTALL_DIR}/${BINARY_NAME}"
            rm -f "$tmp"
            return 0
        fi
    fi
    rm -f "$tmp"
    return 1
}

build_from_source() {
    source "$HOME/.cargo/env" 2>/dev/null || source /root/.cargo/env 2>/dev/null || true
    if ! command -v cargo &>/dev/null; then
        ER "cargo not found. Cannot build from source."; exit 1
    fi

    mkdir -p "$BUILD_DIR"
    if [[ -d "${BUILD_DIR}/.git" ]]; then
        cd "$BUILD_DIR" && git pull -q
    else
        git clone -q "$REPO_URL" "$BUILD_DIR"
    fi
    cd "$BUILD_DIR"
    git submodule update --init --recursive -q

    # Apply patches from the deploy repo (ipv6_fallback, picoquic_utils)
    local patch_base
    patch_base="$(dirname "$(readlink -f "$0")")/patches"
    if [[ -d "$patch_base" ]]; then
        for pfile in "${patch_base}/ipv6_fallback.patch" "${patch_base}/picoquic_utils.h.patch"; do
            if [[ -f "$pfile" ]]; then
                git apply "$pfile" &>/dev/null || true
            fi
        done
    fi
    # Also try patches embedded next to the script (if user has the zip)
    for pfile in /tmp/slipstream-patches/ipv6_fallback.patch \
                 /tmp/slipstream-patches/picoquic_utils.h.patch; do
        [[ -f "$pfile" ]] && git apply "$pfile" &>/dev/null || true
    done

    [[ -f "${BUILD_DIR}/scripts/build_picoquic.sh" ]] && \
        bash "${BUILD_DIR}/scripts/build_picoquic.sh" &>/dev/null

    cargo build --release -p slipstream-server -q
    cp "${BUILD_DIR}/target/release/slipstream-server" "${INSTALL_DIR}/${BINARY_NAME}"
    chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
}

install_binary() {
    if ! download_binary; then
        WN "Prebuilt binary unavailable. Building from source (may take 10-20 min)…"
        run_silent "Building slipstream from source" build_from_source
    fi
}

# ─── SETUP USER & CERTS ──────────────────────────────────────────────────────
setup_user() {
    if ! id "$SVC_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "DNS Cache Service" "$SVC_USER"
    fi
    mkdir -p "$CONFIG_DIR"
    chown -R "$SVC_USER:$SVC_USER" "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
}

generate_cert() {
    local domain="$1"
    local prefix; prefix=$(echo "$domain" | tr '.' '_')
    CERT_FILE="${CONFIG_DIR}/${prefix}_cert.pem"
    KEY_FILE="${CONFIG_DIR}/${prefix}_key.pem"

    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$KEY_FILE" -out "$CERT_FILE" \
            -days 3650 -subj "/CN=internal-resolver" \
            -addext "subjectAltName=DNS:${domain},DNS:*.${domain}" \
            &>/dev/null
    fi
    chown "$SVC_USER:$SVC_USER" "$CERT_FILE" "$KEY_FILE"
    chmod 644 "$CERT_FILE"; chmod 600 "$KEY_FILE"
}

# ─── SHADOWSOCKS AUTO-CONFIG ─────────────────────────────────────────────────
generate_ss_config() {
    # Auto-generates password (no questions asked)
    SS_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
    SS_PORT="8388"
    SS_METHOD="chacha20-ietf-poly1305"
}

setup_shadowsocks() {
    # Ensure PKG_MANAGER is known
    [[ -z "${PKG_MANAGER:-}" ]] && detect_os
    local ss_installed=false
    local ss_conf_dir="/etc/shadowsocks-libev"
    local ss_conf_file="${ss_conf_dir}/config.json"

    # Try snap first, then pkg manager
    if command -v snap &>/dev/null && snap install shadowsocks-libev &>/dev/null 2>&1; then
        ss_installed=true
        ss_conf_dir="/var/snap/shadowsocks-libev/common/etc/shadowsocks-libev"
        ss_conf_file="${ss_conf_dir}/config.json"
    elif command -v ss-server &>/dev/null; then
        ss_installed=true
    else
        case $PKG_MANAGER in
            apt)
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                    shadowsocks-libev &>/dev/null && ss_installed=true ;;
            dnf|yum)
                $PKG_MANAGER install -y -q shadowsocks-libev &>/dev/null \
                    && ss_installed=true ;;
        esac
    fi

    [[ "$ss_installed" == false ]] && { ER "Failed to install shadowsocks-libev"; exit 1; }

    mkdir -p "$ss_conf_dir"
    cat > "$ss_conf_file" << EOF
{
    "server": "127.0.0.1",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "timeout": 300,
    "method": "${SS_METHOD}",
    "fast_open": false,
    "mode": "tcp_and_udp"
}
EOF
    chmod 644 "$ss_conf_file"

    # Create systemd service if missing
    if ! systemctl list-unit-files 2>/dev/null | grep -q "shadowsocks-libev-server@"; then
        local ss_bin
        ss_bin=$(command -v ss-server || echo "/usr/bin/ss-server")
        cat > "${SYSTEMD_DIR}/shadowsocks-libev-server@.service" << SVCEOF
[Unit]
Description=Shadowsocks-libev Server for %i
After=network.target

[Service]
Type=simple
ExecStart=${ss_bin} -c ${ss_conf_dir}/%i.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
        systemctl daemon-reload
    fi

    systemctl enable shadowsocks-libev-server@config &>/dev/null || true
    systemctl restart shadowsocks-libev-server@config 2>/dev/null || \
        systemctl restart shadowsocks-libev 2>/dev/null || true
}

# ─── ANTI-DPI + IPTABLES ─────────────────────────────────────────────────────
configure_antidpi() {
    local port="$1"

    # 1. Kernel optimizations (persisted)
    cat > /etc/sysctl.d/99-slipstream.conf << 'EOF'
# Slipstream Anti-DPI & Performance Tuning
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.udp_mem = 65536 131072 262144
net.core.netdev_max_backlog = 100000
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 1
# BBR congestion control for better throughput
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# QUIC/UDP optimization
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.conf.all.accept_source_route = 0
EOF
    sysctl -p /etc/sysctl.d/99-slipstream.conf &>/dev/null || true

    # 2. Increase open file limits
    cat > /etc/security/limits.d/99-slipstream.conf << EOF
${SVC_USER}  soft  nofile  65535
${SVC_USER}  hard  nofile  65535
EOF

    # 3. iptables rules
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    [[ -z "$iface" ]] && iface="eth0"

    # Flush existing slipstream rules first
    iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$port" 2>/dev/null || true

    # Allow slipstream port
    iptables -I INPUT -p udp --dport "$port" -j ACCEPT

    # Anti-DPI: Scrub DSCP bits so traffic can't be classified by QoS
    iptables -t mangle -I POSTROUTING -p udp --sport "$port" -j DSCP --set-dscp 0 2>/dev/null || true

    # Redirect port 53 -> slipstream port (IPv4)
    iptables -t nat -I PREROUTING -i "$iface" -p udp --dport 53 \
        -j REDIRECT --to-ports "$port"

    # Anti-DPI: NOTRACK to prevent conntrack from flagging tunnel patterns
    iptables -t raw -I PREROUTING -p udp --dport "$port" -j NOTRACK 2>/dev/null || true
    iptables -t raw -I OUTPUT -p udp --sport "$port" -j NOTRACK 2>/dev/null || true

    # IPv6 rules if available
    if command -v ip6tables &>/dev/null && [[ -f /proc/net/if_inet6 ]]; then
        local has_ipv6
        has_ipv6=$(ip -6 addr show 2>/dev/null | grep -v '::1' | grep -v 'fe80:' | grep 'inet6' || true)
        if [[ -n "$has_ipv6" ]]; then
            ip6tables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
            ip6tables -t nat -I PREROUTING -i "$iface" -p udp --dport 53 \
                -j REDIRECT --to-ports "$port" 2>/dev/null || true
        fi
    fi

    # 4. Traffic shaping - fair queuing for QUIC packets
    if command -v tc &>/dev/null; then
        tc qdisc del dev "$iface" root 2>/dev/null || true
        tc qdisc add dev "$iface" root handle 1: fq maxrate 1gbit 2>/dev/null || true
    fi

    # 5. Save iptables rules
    save_iptables "$iface" "$port"
}

save_iptables() {
    local iface="$1" port="$2"
    case $PKG_MANAGER in
        apt)
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            ;;
        dnf|yum)
            mkdir -p /etc/sysconfig
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
            ;;
    esac

    # Fallback restore service
    cat > "${SYSTEMD_DIR}/slipstream-iptables-restore.service" << EOF
[Unit]
Description=Restore DNS Tunnel Firewall Rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c " \
  iptables -I INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null; \
  iptables -t nat -I PREROUTING -i ${iface} -p udp --dport 53 -j REDIRECT --to-ports ${port} 2>/dev/null; \
  iptables -t mangle -I POSTROUTING -p udp --sport ${port} -j DSCP --set-dscp 0 2>/dev/null || true"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable slipstream-iptables-restore.service &>/dev/null || true
}

# ─── SYSTEMD SERVICE ─────────────────────────────────────────────────────────
create_service() {
    local domain="$1" port="$2" target_port="$3"
    local cert_file key_file
    cert_file="${CONFIG_DIR}/$(echo "$domain" | tr '.' '_')_cert.pem"
    key_file="${CONFIG_DIR}/$(echo "$domain" | tr '.' '_')_key.pem"

    # Detect IPv6
    local listen_host="0.0.0.0"
    if command -v ip &>/dev/null; then
        local ipv6_addr
        ipv6_addr=$(ip -6 addr show 2>/dev/null | grep -v '::1' | grep -v 'fe80:' | grep 'inet6' | awk '{print $2}' | head -1 || true)
        [[ -n "$ipv6_addr" ]] && listen_host="::"
    fi

    cat > "${SYSTEMD_DIR}/${SVC_NAME}.service" << EOF
[Unit]
Description=DNS Cache Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
ExecStart=${INSTALL_DIR}/${BINARY_NAME} \\
    --dns-listen-host ${listen_host} \\
    --dns-listen-port ${port} \\
    --target-address 127.0.0.1:${target_port} \\
    --domain ${domain} \\
    --cert ${cert_file} \\
    --key ${key_file}
Restart=always
RestartSec=3
KillMode=mixed
TimeoutStopSec=5
RuntimeMaxSec=7200
LimitNOFILE=65535

# Security hardening (stealth)
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${CONFIG_DIR}
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SVC_NAME}.service" &>/dev/null
}

# Extra domain service (for multi-domain support)
create_extra_domain_service() {
    local domain="$1" port="$2" target_port="$3"
    local svc="dns-cache-${port}"
    local cert_file="${CONFIG_DIR}/$(echo "$domain" | tr '.' '_')_cert.pem"
    local key_file="${CONFIG_DIR}/$(echo "$domain" | tr '.' '_')_key.pem"

    generate_cert "$domain"

    cat > "${SYSTEMD_DIR}/${svc}.service" << EOF
[Unit]
Description=DNS Cache Service (${port})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
ExecStart=${INSTALL_DIR}/${BINARY_NAME} \\
    --dns-listen-host 0.0.0.0 \\
    --dns-listen-port ${port} \\
    --target-address 127.0.0.1:${target_port} \\
    --domain ${domain} \\
    --cert ${cert_file} \\
    --key ${key_file}
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${svc}.service" &>/dev/null
    systemctl start  "${svc}.service" &>/dev/null
    iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
}

# ─── DNS POOL FUNCTIONS ───────────────────────────────────────────────────────
dns_pool_init() {
    touch "$DNS_POOL_FILE" "$DNS_ACTIVE_FILE" "$DNS_FAILED_FILE"
}

dns_pool_add() {
    local resolver="$1"
    # Normalize: add default port :53 if missing
    [[ "$resolver" != *:* ]] && resolver="${resolver}:53"
    if ! grep -qF "$resolver" "$DNS_POOL_FILE" 2>/dev/null; then
        echo "$resolver" >> "$DNS_POOL_FILE"
        TL "  Added to pool: ${resolver}"
    else
        WN "  Already in pool: ${resolver}"
    fi
}

dns_activate() {
    # Move top N from pool to active
    local n="${1:-3}"
    local count=0
    > "$DNS_ACTIVE_FILE"
    while IFS= read -r resolver && [[ $count -lt $n ]]; do
        [[ -z "$resolver" ]] && continue
        if ! grep -qF "$resolver" "$DNS_FAILED_FILE" 2>/dev/null; then
            echo "$resolver" >> "$DNS_ACTIVE_FILE"
            (( count++ )) || true
        fi
    done < "$DNS_POOL_FILE"
}

test_resolver() {
    local resolver="$1"
    local domain="${2:-}"
    local ip port

    ip="${resolver%:*}"
    port="${resolver#*:}"
    [[ "$ip" == "$resolver" ]] && port="53"

    # Use dig to check NS delegation for tunnel domain
    if command -v dig &>/dev/null; then
        local result
        result=$(timeout 8 dig @"$ip" -p "$port" "$domain" NS +time=5 +tries=1 2>/dev/null)
        if echo "$result" | grep -qiE "(NOERROR|NXDOMAIN|authority|AUTHORITY)"; then
            return 0
        fi
        # Fallback: any response means the resolver can reach us
        result=$(timeout 8 dig @"$ip" -p "$port" "probe.${domain}" A +time=5 +tries=1 2>/dev/null)
        if echo "$result" | grep -qiE "(NOERROR|NXDOMAIN|SERVFAIL)"; then
            return 0
        fi
    elif command -v nslookup &>/dev/null; then
        if timeout 8 nslookup "$domain" "$ip" &>/dev/null; then
            return 0
        fi
    fi
    return 1
}

run_dns_health_check() {
    # Called by cron/systemd timer
    local domain=""
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null || true

    local changed=false
    local failed_now=()

    while IFS= read -r resolver; do
        [[ -z "$resolver" ]] && continue
        if ! test_resolver "$resolver" "$domain"; then
            failed_now+=("$resolver")
            if ! grep -qF "$resolver" "$DNS_FAILED_FILE" 2>/dev/null; then
                echo "$resolver" >> "$DNS_FAILED_FILE"
                echo "[$(date)] FAILED: $resolver" >> "$LOG_FILE"
                changed=true
            fi
        fi
    done < "$DNS_ACTIVE_FILE"

    # Replace failed resolvers from backup pool
    if [[ "$changed" == true ]]; then
        local active_resolvers=()
        while IFS= read -r r; do
            [[ -z "$r" ]] && continue
            if ! grep -qF "$r" "$DNS_FAILED_FILE" 2>/dev/null; then
                active_resolvers+=("$r")
            fi
        done < "$DNS_POOL_FILE"

        local n_active
        n_active=$(wc -l < "$DNS_ACTIVE_FILE" 2>/dev/null || echo 3)
        dns_activate "$n_active"
        echo "[$(date)] DNS pool updated. Active: $(wc -l < "$DNS_ACTIVE_FILE") resolvers" >> "$LOG_FILE"
    fi
}

create_health_check() {
    cat > "$HEALTH_SCRIPT" << 'HEOF'
#!/usr/bin/env bash
CONFIG_DIR="/etc/slipstream-rust"
DNS_POOL_FILE="${CONFIG_DIR}/dns-pool.conf"
DNS_ACTIVE_FILE="${CONFIG_DIR}/dns-active.conf"
DNS_FAILED_FILE="${CONFIG_DIR}/dns-failed.conf"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
LOG_FILE="/var/log/slipstream.log"
DOMAIN=""
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null || true
[[ -z "$DOMAIN" ]] && exit 0

changed=false
while IFS= read -r resolver; do
    [[ -z "$resolver" ]] && continue
    ip="${resolver%:*}"; port="${resolver#*:}"
    [[ "$ip" == "$resolver" ]] && port="53"
    result=$(timeout 8 dig @"$ip" -p "$port" "$DOMAIN" NS +time=5 +tries=1 2>/dev/null || true)
    if ! echo "$result" | grep -qiE "(NOERROR|NXDOMAIN|authority)"; then
        if ! grep -qF "$resolver" "$DNS_FAILED_FILE" 2>/dev/null; then
            echo "$resolver" >> "$DNS_FAILED_FILE"
            echo "[$(date '+%F %T')] FAIL: $resolver" >> "$LOG_FILE"
            changed=true
        fi
    fi
done < "$DNS_ACTIVE_FILE"

if [[ "$changed" == true ]]; then
    n=$(wc -l < "$DNS_ACTIVE_FILE" 2>/dev/null || echo 3)
    > "$DNS_ACTIVE_FILE"
    count=0
    while IFS= read -r r && [[ $count -lt $n ]]; do
        [[ -z "$r" ]] && continue
        if ! grep -qF "$r" "$DNS_FAILED_FILE" 2>/dev/null; then
            echo "$r" >> "$DNS_ACTIVE_FILE"
            ((count++)) || true
        fi
    done < "$DNS_POOL_FILE"
    echo "[$(date '+%F %T')] Pool refreshed: $count active" >> "$LOG_FILE"
fi
HEOF
    chmod +x "$HEALTH_SCRIPT"

    # Schedule via cron every 30 minutes
    echo "*/30 * * * * root ${HEALTH_SCRIPT} >> /var/log/slipstream-health.log 2>&1" \
        > /etc/cron.d/slipstream-dns-health
    chmod 644 /etc/cron.d/slipstream-dns-health
}

# ─── x-UI / OUTBOUND CONFIG ──────────────────────────────────────────────────
generate_xui_config() {
    local server_ip="${1:-127.0.0.1}"
    local tcp_port="${2:-5201}"

    # Shadowsocks URI (SIP002 format)
    local userinfo; userinfo=$(echo -n "${SS_METHOD}:${SS_PASSWORD}" | base64 -w0)
    local ss_uri="ss://${userinfo}@${server_ip}:${tcp_port}#SLIP-TUNNEL"

    # Xray/V2Ray outbound JSON (for x-ui panel → Outbound section)
    cat > "$SS_OUTPUT_FILE" << EOF
{
  "_comment": "Paste this in x-ui → Outbound Configuration",
  "_note": "Port ${tcp_port} = slipstream-client local TCP port (--tcp-listen-port ${tcp_port})",
  "tag": "slipstream-tunnel-out",
  "protocol": "shadowsocks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": ${tcp_port},
        "method": "${SS_METHOD}",
        "password": "${SS_PASSWORD}",
        "level": 0
      }
    ]
  },
  "streamSettings": {
    "network": "tcp"
  }
}
EOF

    # Store SS URI for display
    echo "$ss_uri" > "${CONFIG_DIR}/ss-uri.txt"
    chmod 640 "$SS_OUTPUT_FILE" "${CONFIG_DIR}/ss-uri.txt" 2>/dev/null || true
}

# ─── SAVE / LOAD CONFIG ───────────────────────────────────────────────────────
save_config() {
    cat > "$CONFIG_FILE" << EOF
# Slipstream Tunnel Server Configuration
# Generated: $(date)
DOMAIN="${DOMAIN:-}"
NS_HOST="${NS_HOST:-}"
SERVER_IP="${SERVER_IP:-}"
TUNNEL_PORT="${TUNNEL_PORT:-5300}"
SS_PORT="${SS_PORT:-8388}"
SS_METHOD="${SS_METHOD:-chacha20-ietf-poly1305}"
SS_PASSWORD="${SS_PASSWORD:-}"
ACTIVE_DNS_COUNT="${ACTIVE_DNS_COUNT:-3}"
EOF
    chmod 640 "$CONFIG_FILE"
    chown root:"$SVC_USER" "$CONFIG_FILE" 2>/dev/null || true
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null || true
}

is_installed() {
    [[ -f "$CONFIG_FILE" && -f "${INSTALL_DIR}/${BINARY_NAME}" ]]
}

# ─── GET USER INPUT ───────────────────────────────────────────────────────────
get_user_input() {
    load_config

    box_start "Server Configuration"
    echo ""

    # Auto-detect public IP silently
    local detected_ip
    detected_ip=$(curl -fsSL --max-time 6 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]' ||                   curl -fsSL --max-time 6 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)

    TL "  ┌─ DNS Record Setup ──────────────────────────────────────────────"
    TL "  │  Add these records in your domain registrar panel:"
    TL "  │"
    if [[ -n "$detected_ip" ]]; then
        TL "  │  A   record:  ns.yourdomain.com  →  ${detected_ip}"
    else
        TL "  │  A   record:  ns.yourdomain.com  →  <YOUR_SERVER_IP>"
    fi
    TL "  │  NS  record:  s.yourdomain.com   →  ns.yourdomain.com"
    TL "  └─────────────────────────────────────────────────────────────────"
    echo ""

    # A Record Host
    while true; do
        if [[ -n "${NS_HOST:-}" ]]; then
            ASK "A Record Host (e.g. ns.example.com) [${NS_HOST}]:"
        else
            ASK "A Record Host (e.g. ns.example.com):"
        fi
        read -r input_ns
        input_ns="${input_ns:-${NS_HOST:-}}"
        if [[ -n "$input_ns" ]]; then NS_HOST="$input_ns"; break; fi
        WN "Required."
    done

    # NS Record Host
    while true; do
        if [[ -n "${DOMAIN:-}" ]]; then
            ASK "NS Record Host (e.g. s.example.com) [${DOMAIN}]:"
        else
            ASK "NS Record Host (e.g. s.example.com):"
        fi
        read -r input_dom
        input_dom="${input_dom:-${DOMAIN:-}}"
        if [[ -n "$input_dom" ]]; then DOMAIN="$input_dom"; break; fi
        WN "Required."
    done

    # Server IP - auto-detected
    if [[ -n "$detected_ip" ]]; then
        OK "Server IP detected: ${detected_ip}"
        ASK "Server IP [${detected_ip}]:"
        read -r input_ip
        SERVER_IP="${input_ip:-$detected_ip}"
    else
        ASK "Server Public IP:"
        read -r input_ip
        SERVER_IP="${input_ip:-${SERVER_IP:-}}"
    fi

    # Tunnel port
    ASK "Tunnel Port [${TUNNEL_PORT:-5300}]:"
    read -r input_port
    TUNNEL_PORT="${input_port:-${TUNNEL_PORT:-5300}}"

    echo ""
    sep_line
    PL "  DNS Resolver Pool Setup"
    TL "  ┌─ DNS Resolver Pool ─────────────────────────────────────────────"
    TL "  │  Enter your DNS resolvers one by one."
    TL "  │  Format:  IP  or  IP:PORT   (default port: 53)"
    TL "  │  Example: 1.1.1.1  /  8.8.8.8:53  /  9.9.9.9"
    TL "  │  Press Enter with no input when done."
    TL "  └─────────────────────────────────────────────────────────────────"

    dns_pool_init

    local idx=1
    while true; do
        ASK "DNS #${idx} (Enter = done):"
        read -r dns_input
        [[ -z "$dns_input" ]] && break
        dns_pool_add "$dns_input"
        (( idx++ )) || true
    done

    local pool_count
    pool_count=$(grep -c '.' "$DNS_POOL_FILE" 2>/dev/null || echo 0)

    if [[ $pool_count -eq 0 ]]; then
        WN "No DNS resolvers entered. Adding common resolvers as default…"
        dns_pool_add "1.1.1.1:53"
        dns_pool_add "8.8.8.8:53"
        dns_pool_add "9.9.9.9:53"
        dns_pool_add "208.67.222.222:53"
        pool_count=4
    fi

    echo ""
    TL "  Total resolvers in pool: ${pool_count}"
    echo ""
    TL "  ┌─ DNS Active Count ──────────────────────────────────────────────"
    TL "  │  Active resolvers run simultaneously. Extras stay as backup."
    TL "  │  If one fails, a backup takes its place automatically."
    TL "  └─────────────────────────────────────────────────────────────────"
    ASK "How many DNS resolvers active at once? [3]:"
    read -r input_n
    ACTIVE_DNS_COUNT="${input_n:-3}"
    ACTIVE_DNS_COUNT=$(( ACTIVE_DNS_COUNT + 0 ))
    [[ $ACTIVE_DNS_COUNT -gt $pool_count ]] && ACTIVE_DNS_COUNT=$pool_count
    [[ $ACTIVE_DNS_COUNT -lt 1 ]] && ACTIVE_DNS_COUNT=1

    dns_activate "$ACTIVE_DNS_COUNT"
}

# ─── FULL INSTALL ─────────────────────────────────────────────────────────────
do_install() {
    local total_steps=9
    local step=0

    echo ""
    box_start "Installing Slipstream Tunnel Server"
    echo ""

    step=$(( step + 1 ))
    progress_bar "Setting up environment" $step $total_steps
    detect_os
    mkdir -p "$CONFIG_DIR"

    step=$(( step + 1 ))
    progress_bar "Installing system dependencies" $step $total_steps
    install_deps

    step=$(( step + 1 ))
    progress_bar "Downloading tunnel binary" $step $total_steps
    install_binary

    step=$(( step + 1 ))
    progress_bar "Creating service user" $step $total_steps
    setup_user

    step=$(( step + 1 ))
    progress_bar "Generating TLS certificates" $step $total_steps
    generate_cert "$DOMAIN"

    step=$(( step + 1 ))
    progress_bar "Configuring Shadowsocks" $step $total_steps
    setup_shadowsocks

    step=$(( step + 1 ))
    progress_bar "Applying Anti-DPI firewall rules" $step $total_steps
    configure_antidpi "$TUNNEL_PORT"

    step=$(( step + 1 ))
    progress_bar "Creating systemd services" $step $total_steps
    create_service "$DOMAIN" "$TUNNEL_PORT" "$SS_PORT"
    create_health_check

    step=$(( step + 1 ))
    progress_bar "Saving configuration" $step $total_steps
    save_config
    generate_xui_config "$SERVER_IP" "${TUNNEL_PORT:-5300}"

    # Start services
    systemctl start "${SVC_NAME}.service" 2>/dev/null || true

    echo ""
    OK "Installation complete!"
}

# ─── LIVE MONITOR ─────────────────────────────────────────────────────────────
live_monitor() {
    load_config
    trap 'tput cnorm; echo ""; exit 0' INT TERM
    tput civis   # Hide cursor

    while true; do
        clear
        show_banner

        local COLS; COLS=$(tput cols 2>/dev/null || echo 80)
        local now; now=$(date '+%Y-%m-%d %H:%M:%S')

        # ── Tunnel Status ──
        sep_line
        echo -e "${PU}  ◈ TUNNEL STATUS${NC}"
        sep_line

        if systemctl is-active --quiet "${SVC_NAME}" 2>/dev/null; then
            local uptime_info
            uptime_info=$(systemctl show "${SVC_NAME}" --property=ActiveEnterTimestamp \
                2>/dev/null | cut -d= -f2 || echo "unknown")
            echo -e "  ${GR}● RUNNING${NC}  ${TE}since: ${uptime_info}${NC}"
        else
            echo -e "  ${RD}● STOPPED${NC}"
        fi

        if systemctl is-active --quiet "shadowsocks-libev-server@config" 2>/dev/null || \
           systemctl is-active --quiet "shadowsocks-libev" 2>/dev/null; then
            echo -e "  ${GR}● Shadowsocks${NC}  ${TE}port :${SS_PORT:-8388}  method: ${SS_METHOD:-chacha20}${NC}"
        else
            echo -e "  ${RD}● Shadowsocks: STOPPED${NC}"
        fi

        local domain_info="${DOMAIN:-N/A}  (NS: ${NS_HOST:-N/A})"
        echo -e "  ${PU}Domain:${NC} ${TE}${domain_info}${NC}"
        echo -e "  ${PU}Tunnel Port:${NC} ${TE}${TUNNEL_PORT:-5300}${NC}  ${PU}Server IP:${NC} ${TE}${SERVER_IP:-N/A}${NC}"

        # ── DNS Pool ──
        echo ""
        sep_line
        local pool_c active_c
        pool_c=$(grep -c '.' "$DNS_POOL_FILE" 2>/dev/null || echo 0)
        active_c=$(grep -c '.' "$DNS_ACTIVE_FILE" 2>/dev/null || echo 0)
        echo -e "${TE}  ◈ DNS POOL${NC}  ${PU}(${pool_c} total / ${active_c} active)${NC}"
        sep_line

        local idx=0
        while IFS= read -r resolver; do
            [[ -z "$resolver" ]] && continue
            local is_active=false is_failed=false
            grep -qF "$resolver" "$DNS_ACTIVE_FILE" 2>/dev/null && is_active=true
            grep -qF "$resolver" "$DNS_FAILED_FILE" 2>/dev/null && is_failed=true

            if $is_failed; then
                echo -e "  ${RD}✗${NC} ${YL}${resolver}${NC}  ${RD}[FAILED]${NC}"
            elif $is_active; then
                echo -e "  ${GR}✓${NC} ${TE}${resolver}${NC}  ${PU}[ACTIVE]${NC}"
            else
                echo -e "  ${PU}◌${NC} ${PU}${resolver}${NC}  ${TE}[STANDBY]${NC}"
            fi
            (( idx++ )) || true
            [[ $idx -ge 12 ]] && { echo -e "  ${TE}... and $((pool_c - 12)) more${NC}"; break; }
        done < "$DNS_POOL_FILE"

        # ── Network Stats ──
        echo ""
        sep_line
        echo -e "${PU}  ◈ NETWORK${NC}"
        sep_line
        local iface
        iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1 || echo "eth0")
        if [[ -f "/sys/class/net/${iface}/statistics/rx_bytes" ]]; then
            local rx tx
            rx=$(cat "/sys/class/net/${iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
            tx=$(cat "/sys/class/net/${iface}/statistics/tx_bytes" 2>/dev/null || echo 0)
            rx=$(awk "BEGIN{printf \"%.1f MB\", $rx/1048576}")
            tx=$(awk "BEGIN{printf \"%.1f MB\", $tx/1048576}")
            echo -e "  ${TE}Interface: ${iface}${NC}   ${PU}RX: ${rx}${NC}   ${TE}TX: ${tx}${NC}"
        fi

        # Recent log lines
        echo ""
        sep_line
        echo -e "${TE}  ◈ RECENT LOG${NC}"
        sep_line
        if [[ -f "$LOG_FILE" ]]; then
            tail -4 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
                if echo "$line" | grep -qi "fail"; then
                    echo -e "  ${RD}${line}${NC}"
                else
                    echo -e "  ${PU}${line}${NC}"
                fi
            done
        else
            journalctl -u "${SVC_NAME}" --no-pager -n 4 2>/dev/null | while IFS= read -r line; do
                echo -e "  ${TE}${line}${NC}"
            done
        fi

        echo ""
        echo -e "  ${PU}Last update: ${now}${NC}   ${TE}Press Ctrl+C to return to menu${NC}"
        sleep 5
    done

    tput cnorm
}

# ─── COLORED LOG VIEWER ───────────────────────────────────────────────────────
view_logs() {
    box_start "Live Colored Log (Ctrl+C to stop)"
    echo ""
    journalctl -u "${SVC_NAME}" -f --no-pager 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -qi "error\|fail\|crit"; then
            echo -e "${RD}${line}${NC}"
        elif echo "$line" | grep -qi "warn"; then
            echo -e "${YL}${line}${NC}"
        elif echo "$line" | grep -qi "start\|ready\|success\|active"; then
            echo -e "${GR}${line}${NC}"
        elif [[ $(( $(date +%S) % 2 )) -eq 0 ]]; then
            echo -e "${PU}${line}${NC}"
        else
            echo -e "${TE}${line}${NC}"
        fi
    done
}

# ─── DNS POOL MANAGEMENT MENU ─────────────────────────────────────────────────
dns_pool_menu() {
    load_config
    while true; do
        box_start "DNS Pool Management"
        echo ""
        PL "  1)  View DNS Pool"
        TL "  2)  Add Resolver(s) to Pool"
        PL "  3)  Test All Resolvers"
        TL "  4)  Remove Resolver"
        PL "  5)  Set Active Resolver Count"
        TL "  6)  Clear Failed List"
        PL "  7)  Show Active Client Command"
        TL "  0)  Back"
        echo ""
        ASK "Select option: "
        read -r opt

        case "$opt" in
            1)
                box_start "Current DNS Pool"
                echo ""
                local i=1
                while IFS= read -r r; do
                    [[ -z "$r" ]] && continue
                    local status="${TE}[STANDBY]${NC}"
                    grep -qF "$r" "$DNS_ACTIVE_FILE" 2>/dev/null && status="${GR}[ACTIVE]${NC}"
                    grep -qF "$r" "$DNS_FAILED_FILE" 2>/dev/null && status="${RD}[FAILED]${NC}"
                    if [[ $(( i % 2 )) -eq 0 ]]; then
                        echo -e "  ${PU}${i})${NC} ${TE}${r}${NC}  ${status}"
                    else
                        echo -e "  ${TE}${i})${NC} ${PU}${r}${NC}  ${status}"
                    fi
                    (( i++ )) || true
                done < "$DNS_POOL_FILE"
                echo ""
                ;;
            2)
                TL "  Enter resolvers (empty line = done):"
                local idx=1
                while true; do
                    ASK "Resolver #${idx} (empty = done): "
                    read -r dns_in
                    [[ -z "$dns_in" ]] && break
                    dns_pool_add "$dns_in"
                    (( idx++ )) || true
                done
                dns_activate "$ACTIVE_DNS_COUNT"
                OK "Pool updated."
                ;;
            3)
                box_start "Testing All Resolvers"
                echo ""
                while IFS= read -r resolver; do
                    [[ -z "$resolver" ]] && continue
                    printf "  ${TE}Testing %-22s${NC}" "$resolver"
                    if test_resolver "$resolver" "${DOMAIN:-example.com}"; then
                        echo -e " ${GR}[OK]${NC}"
                        # Remove from failed if it was there
                        if [[ -f "$DNS_FAILED_FILE" ]]; then
                            sed -i "/^${resolver//./\\.}$/d" "$DNS_FAILED_FILE" 2>/dev/null || true
                        fi
                    else
                        echo -e " ${RD}[FAIL]${NC}"
                        grep -qF "$resolver" "$DNS_FAILED_FILE" 2>/dev/null || \
                            echo "$resolver" >> "$DNS_FAILED_FILE"
                    fi
                done < "$DNS_POOL_FILE"
                dns_activate "$ACTIVE_DNS_COUNT"
                echo ""
                OK "Test complete. Active resolvers refreshed."
                ;;
            4)
                box_start "Remove Resolver"
                echo ""
                local arr=() i=1
                while IFS= read -r r; do
                    [[ -z "$r" ]] && continue
                    arr+=("$r")
                    echo -e "  ${PU}${i})${NC} ${TE}${r}${NC}"
                    (( i++ )) || true
                done < "$DNS_POOL_FILE"
                echo ""
                ASK "Enter number to remove (0=cancel): "
                read -r del_idx
                if [[ "$del_idx" =~ ^[0-9]+$ ]] && [[ $del_idx -gt 0 && $del_idx -le ${#arr[@]} ]]; then
                    local to_del="${arr[$((del_idx-1))]}"
                    sed -i "/^${to_del//./\\.}$/d" "$DNS_POOL_FILE" 2>/dev/null || true
                    sed -i "/^${to_del//./\\.}$/d" "$DNS_ACTIVE_FILE" 2>/dev/null || true
                    OK "Removed: ${to_del}"
                fi
                ;;
            5)
                local pool_c
                pool_c=$(grep -c '.' "$DNS_POOL_FILE" 2>/dev/null || echo 0)
                ASK "How many resolvers active simultaneously? (max ${pool_c}) [${ACTIVE_DNS_COUNT:-3}]: "
                read -r n
                n="${n:-${ACTIVE_DNS_COUNT:-3}}"
                [[ $n -gt $pool_c ]] && n=$pool_c
                ACTIVE_DNS_COUNT="$n"
                dns_activate "$n"
                save_config
                OK "Active resolver count set to ${n}"
                ;;
            6)
                > "$DNS_FAILED_FILE"
                dns_activate "$ACTIVE_DNS_COUNT"
                OK "Failed list cleared. Pool refreshed."
                ;;
            7)
                box_start "Client Connection Command"
                echo ""
                local resolver_args=""
                while IFS= read -r r; do
                    [[ -z "$r" ]] && continue
                    resolver_args+="--resolver ${r} "
                done < "$DNS_ACTIVE_FILE"
                PL "  # Run this on client machine:"
                echo ""
                echo -e "  ${TE}./slipstream-client \\${NC}"
                while IFS= read -r r; do
                    [[ -z "$r" ]] && continue
                    echo -e "    ${PU}--resolver ${r} \\${NC}"
                done < "$DNS_ACTIVE_FILE"
                echo -e "    ${TE}--domain ${DOMAIN:-s.example.com} \\${NC}"
                echo -e "    ${PU}--tcp-listen-port 5201 \\${NC}"
                echo -e "    ${TE}--keep-alive-interval 300${NC}"
                echo ""
                TL "  Download client:"
                echo -e "  ${PU}curl -Lo slipstream-client https://github.com/Fox-Fig/slipstream-rust-deploy/releases/latest/download/slipstream-client-linux-amd64${NC}"
                echo ""
                ;;
            0) return ;;
        esac
        echo ""; ASK "Press Enter to continue…"; read -r
    done
}

# ─── FEED DNS (HOTLOAD while tunnel is running) ───────────────────────────────
feed_dns() {
    load_config
    box_start "Feed New DNS Resolvers (Live – No Service Restart)"
    echo ""
    TL "  The tunnel will continue running. New resolvers are tested and added."
    TL "  Failed resolvers are replaced automatically."
    echo ""

    local added=0
    local idx=1
    while true; do
        ASK "New DNS Resolver #${idx} (empty = done): "
        read -r dns_in
        [[ -z "$dns_in" ]] && break

        [[ "$dns_in" != *:* ]] && dns_in="${dns_in}:53"
        printf "  ${TE}Testing %-22s${NC}" "$dns_in"
        if test_resolver "$dns_in" "${DOMAIN:-probe.tunnel.local}"; then
            echo -e " ${GR}[OK - Added to pool]${NC}"
            dns_pool_add "$dns_in"
            (( added++ )) || true
        else
            echo -e " ${RD}[UNREACHABLE - skipped]${NC}"
        fi
        (( idx++ )) || true
    done

    if [[ $added -gt 0 ]]; then
        dns_activate "$ACTIVE_DNS_COUNT"
        echo ""
        OK "${added} resolver(s) added to pool. Active resolvers updated."
        TL "  New pool size: $(grep -c '.' "$DNS_POOL_FILE" 2>/dev/null || echo 0)"
        TL "  Active now:    $(grep -c '.' "$DNS_ACTIVE_FILE" 2>/dev/null || echo 0)"
    else
        WN "No new resolvers added."
    fi
}

# ─── SHOW CONFIG & x-UI OUTBOUND ─────────────────────────────────────────────
show_config_and_xui() {
    load_config
    box_start "Configuration & x-ui Outbound"
    echo ""

    PL "  ── Server Info ─────────────────────────────────"
    echo -e "  ${TE}Domain:${NC}       ${PU}${DOMAIN:-N/A}${NC}"
    echo -e "  ${PU}NS Record:${NC}    ${TE}${NS_HOST:-N/A}${NC}"
    echo -e "  ${TE}Server IP:${NC}    ${PU}${SERVER_IP:-N/A}${NC}"
    echo -e "  ${PU}Tunnel Port:${NC}  ${TE}${TUNNEL_PORT:-5300}${NC}"
    echo ""

    PL "  ── Shadowsocks (auto-configured) ───────────────"
    echo -e "  ${TE}Port:${NC}         ${PU}${SS_PORT:-8388}${NC}"
    echo -e "  ${PU}Method:${NC}       ${TE}${SS_METHOD:-chacha20-ietf-poly1305}${NC}"
    echo -e "  ${TE}Password:${NC}     ${PU}${SS_PASSWORD:-N/A}${NC}"
    echo ""

    PL "  ── DNS Records Required ────────────────────────"
    echo -e "  ${TE}TYPE  NAME                    VALUE${NC}"
    echo -e "  ${PU}A     ${NS_HOST:-ns.example.com}   →  ${SERVER_IP:-YOUR_SERVER_IP}${NC}"
    echo -e "  ${TE}NS    ${DOMAIN:-s.example.com}       →  ${NS_HOST:-ns.example.com}${NC}"
    echo ""

    PL "  ── Active DNS Resolvers ────────────────────────"
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        echo -e "  ${TE}→  ${PU}${r}${NC}"
    done < "$DNS_ACTIVE_FILE"
    echo ""

    PL "  ── x-ui Outbound JSON (paste in Outbound panel) "
    sep_line
    if [[ -f "$SS_OUTPUT_FILE" ]]; then
        local jline=0
        while IFS= read -r line; do
            jline=$(( jline + 1 ))
            if [[ $(( jline % 2 )) -eq 0 ]]; then
                echo -e "  ${PU}${line}${NC}"
            else
                echo -e "  ${TE}${line}${NC}"
            fi
        done < "$SS_OUTPUT_FILE"
    fi
    sep_line
    echo ""

    PL "  ── Shadowsocks URI ─────────────────────────────"
    if [[ -f "${CONFIG_DIR}/ss-uri.txt" ]]; then
        echo -e "  ${GR}$(cat "${CONFIG_DIR}/ss-uri.txt")${NC}"
    fi
    echo ""

    PL "  ── Client Connection Command ───────────────────"
    echo -e "  ${TE}./slipstream-client \\${NC}"
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        echo -e "    ${PU}--resolver ${r} \\${NC}"
    done < "$DNS_ACTIVE_FILE"
    echo -e "    ${TE}--domain ${DOMAIN:-s.example.com} \\${NC}"
    echo -e "    ${PU}--tcp-listen-port 5201 \\${NC}"
    echo -e "    ${TE}--keep-alive-interval 300${NC}"
    echo ""
    echo -e "  ${TE}# Download client:${NC}"
    echo -e "  ${PU}curl -Lo slipstream-client \\${NC}"
    echo -e "  ${TE}  https://github.com/Fox-Fig/slipstream-rust-deploy/releases/latest/download/slipstream-client-linux-amd64${NC}"
}

# ─── TUNNEL CONTROL ───────────────────────────────────────────────────────────
tunnel_control() {
    box_start "Tunnel Control"
    echo ""
    PL "  1)  Start Tunnel"
    TL "  2)  Stop Tunnel"
    PL "  3)  Restart Tunnel"
    TL "  4)  Service Status"
    PL "  5)  Add Extra Domain"
    TL "  0)  Back"
    echo ""
    ASK "Select: "
    read -r opt
    case "$opt" in
        1)
            systemctl start "${SVC_NAME}" && OK "Tunnel started." || ER "Failed to start."
            systemctl start "shadowsocks-libev-server@config" &>/dev/null || true
            ;;
        2)
            systemctl stop "${SVC_NAME}" && OK "Tunnel stopped." || true
            ;;
        3)
            systemctl restart "${SVC_NAME}" && OK "Tunnel restarted." || ER "Failed to restart."
            ;;
        4)
            systemctl status "${SVC_NAME}" --no-pager -l 2>/dev/null | while IFS= read -r line; do
                if echo "$line" | grep -qi "active.*running"; then
                    echo -e "${GR}${line}${NC}"
                elif echo "$line" | grep -qi "inactive\|failed"; then
                    echo -e "${RD}${line}${NC}"
                elif [[ $(( RANDOM % 2 )) -eq 0 ]]; then
                    echo -e "${PU}${line}${NC}"
                else
                    echo -e "${TE}${line}${NC}"
                fi
            done
            ;;
        5)
            load_config
            echo ""
            ASK "New tunnel subdomain (e.g. s2.example.com): "
            read -r new_domain
            [[ -z "$new_domain" ]] && return
            ASK "Port for this domain [5301]: "
            read -r new_port
            new_port="${new_port:-5301}"

            local next_port=$new_port
            while [[ -f "${SYSTEMD_DIR}/dns-cache-${next_port}.service" ]]; do
                (( next_port++ )) || true
            done
            [[ "$next_port" != "$new_port" ]] && WN "Port $new_port in use, using $next_port instead."

            create_extra_domain_service "$new_domain" "$next_port" "$SS_PORT"
            iptables -I INPUT -p udp --dport "$next_port" -j ACCEPT 2>/dev/null || true

            # Record in domains file
            echo "${new_domain}|${next_port}" >> "$DOMAINS_FILE"

            OK "Extra domain added!"
            PL "  Domain:  ${new_domain}"
            TL "  Port:    ${next_port}"
            TL "  Clients must use: --resolver ${SERVER_IP}:${next_port}"
            ;;
        0) return ;;
    esac
    echo ""; ASK "Press Enter…"; read -r
}

# ─── FULL UNINSTALL ───────────────────────────────────────────────────────────
do_uninstall() {
    box_start "Full Uninstall"
    echo ""
    WN "This will completely remove Slipstream Tunnel from this server."
    ASK "Are you sure? Type YES to confirm: "
    read -r confirm
    [[ "$confirm" != "YES" ]] && { TL "Uninstall cancelled."; return; }

    echo ""

    run_silent "Stopping services" bash -c "
        systemctl stop ${SVC_NAME} 2>/dev/null || true
        systemctl disable ${SVC_NAME} 2>/dev/null || true
        systemctl stop shadowsocks-libev-server@config 2>/dev/null || true
        systemctl disable shadowsocks-libev-server@config 2>/dev/null || true
        systemctl stop slipstream-iptables-restore 2>/dev/null || true
        systemctl disable slipstream-iptables-restore 2>/dev/null || true
        # Stop all extra domain services
        for svc in /etc/systemd/system/dns-cache-*.service; do
            svcname=\$(basename \"\$svc\" .service)
            systemctl stop \"\$svcname\" 2>/dev/null || true
            systemctl disable \"\$svcname\" 2>/dev/null || true
        done
    "

    run_silent "Removing files" bash -c "
        rm -f ${INSTALL_DIR}/${BINARY_NAME}
        rm -f ${SYSTEMD_DIR}/${SVC_NAME}.service
        rm -f ${SYSTEMD_DIR}/slipstream-iptables-restore.service
        rm -f ${SYSTEMD_DIR}/dns-cache-*.service
        rm -f ${HEALTH_SCRIPT}
        rm -f /etc/cron.d/slipstream-dns-health
        rm -f /etc/sysctl.d/99-slipstream.conf
        rm -f /etc/security/limits.d/99-slipstream.conf
        rm -rf ${CONFIG_DIR}
        rm -rf ${BUILD_DIR}
        systemctl daemon-reload 2>/dev/null || true
    "

    run_silent "Removing iptables rules" bash -c "
        IFACE=\$(ip route show default 2>/dev/null | awk '/default/{print \$5}' | head -1)
        iptables -D INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || true
        iptables -t nat -D PREROUTING -i \"\${IFACE:-eth0}\" -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null || true
        iptables -t mangle -D POSTROUTING -p udp --sport 5300 -j DSCP --set-dscp 0 2>/dev/null || true
        ip6tables -D INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || true
        ip6tables -t nat -D PREROUTING -i \"\${IFACE:-eth0}\" -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null || true
    "

    run_silent "Removing service user" bash -c "
        id slipstream &>/dev/null && userdel slipstream 2>/dev/null || true
    "

    echo ""
    OK "Slipstream Tunnel has been completely removed."
    echo ""
    ASK "Also remove this management script? (yes/no) [no]: "
    read -r remove_script
    if [[ "$remove_script" =~ ^[Yy] ]]; then
        rm -f "$SCRIPT_PATH"
        OK "Management script removed."
        exit 0
    fi
}

# ─── SHOW FINAL SUCCESS INFO ──────────────────────────────────────────────────
show_success() {
    local COLS; COLS=$(tput cols 2>/dev/null || echo 80)

    echo ""
    # Full-width success box
    local border=""
    for (( i=0; i<COLS; i++ )); do
        [[ $(( i % 2 )) -eq 0 ]] && border+="${GR}═${NC}" || border+="${GR}═${NC}"
    done
    echo -e "$border"

    local title="  INSTALLATION COMPLETE  "
    local tpad=$(( (COLS - ${#title}) / 2 ))
    printf '%*s' "$tpad" ''
    echo -e "${GR}${BD}${title}${NC}"
    echo -e "$border"
    echo ""

    show_config_and_xui

    echo ""
    sep_line
    PL "  Management Commands"
    sep_line
    echo -e "  ${TE}Open menu:        ${PU}slipstream-manager${NC}"
    echo -e "  ${PU}Start service:    ${TE}systemctl start ${SVC_NAME}${NC}"
    echo -e "  ${TE}Stop service:     ${PU}systemctl stop ${SVC_NAME}${NC}"
    echo -e "  ${PU}View logs:        ${TE}journalctl -u ${SVC_NAME} -f${NC}"
    echo -e "  ${TE}Health check:     ${PU}${HEALTH_SCRIPT}${NC}"
    echo ""
}

# ─── INSTALL SELF TO /usr/local/bin ──────────────────────────────────────────
install_self() {
    local src
    src=$(readlink -f "$0")
    if [[ "$src" != "$SCRIPT_PATH" ]]; then
        cp "$src" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi
    # Always ensure shortcut 'slip' exists
    if [[ ! -f /usr/local/bin/slip ]]; then
        ln -sf "$SCRIPT_PATH" /usr/local/bin/slip 2>/dev/null || true
        OK "Shortcut created: type  slip  to open menu"
    fi
    # Add to /etc/profile.d so it shows in all shells
    cat > /etc/profile.d/slipstream.sh << 'PROFEOF'
# Slipstream DNS Tunnel Manager shortcut
alias slip='slipstream-manager'
PROFEOF
    chmod 644 /etc/profile.d/slipstream.sh 2>/dev/null || true
}

# ─── MAIN MENU ─────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        show_banner
        load_config

        # Status indicator
        if systemctl is-active --quiet "${SVC_NAME}" 2>/dev/null; then
            echo -e "  ${GR}● Tunnel: RUNNING${NC}  ${TE}Domain: ${DOMAIN:-N/A}${NC}"
        else
            echo -e "  ${RD}● Tunnel: STOPPED${NC}"
        fi
        echo ""
        sep_line

        PL "  1)  Live Tunnel Monitor"
        TL "  2)  DNS Pool Management"
        PL "  3)  Feed DNS (add resolvers live)"
        TL "  4)  View Colored Logs"
        PL "  5)  Show Config & x-ui Outbound"
        TL "  6)  Tunnel Control (start/stop/extra domain)"
        PL "  7)  Reinstall / Reconfigure"
        TL "  8)  Full Uninstall"
        PL "  0)  Exit"
        sep_line
        echo ""
        ASK "Select option: "
        read -r choice

        case "$choice" in
            1) live_monitor ;;
            2) dns_pool_menu ;;
            3) feed_dns; echo ""; ASK "Press Enter…"; read -r ;;
            4) view_logs ;;
            5) show_config_and_xui; echo ""; ASK "Press Enter…"; read -r ;;
            6) tunnel_control ;;
            7)
                get_user_input
                generate_ss_config
                do_install
                show_success
                echo ""; ASK "Press Enter to return to menu…"; read -r
                ;;
            8) do_uninstall ;;
            0) echo ""; TL "Goodbye."; echo ""; exit 0 ;;
            *) WN "Invalid option." ;;
        esac
    done
}

# ─── ENTRY POINT ─────────────────────────────────────────────────────────────
main() {
    clear
    show_banner

    # Handle CLI args
    case "${1:-}" in
        uninstall) do_uninstall; exit 0 ;;
        health)    run_dns_health_check; exit 0 ;;
        menu)      main_menu; exit 0 ;;
    esac

    # Install self to /usr/local/bin if not already there
    install_self

    if is_installed; then
        main_menu
    else
        # First run: wizard
        box_start "First-Time Setup Wizard"
        echo ""
        TL "  Welcome! Let's configure your Slipstream DNS Tunnel server."
        TL "  Before proceeding, ensure your DNS records are set:"
        echo ""
        PL "    A   record:  ns.yourdomain.com  →  THIS_SERVER_IP"
        TL "    NS  record:  s.yourdomain.com   →  ns.yourdomain.com"
        echo ""
        WN "  DNS propagation may take up to 24 hours."
        echo ""
        ASK "Press Enter to start setup or Ctrl+C to cancel…"
        read -r

        detect_os
        get_user_input
        generate_ss_config
        do_install
        show_success

        echo ""
        ASK "Press Enter to open management menu…"
        read -r
        main_menu
    fi
}

main "$@"
