#!/bin/bash
# =============================================================================
# WireGuard Tunnel Auto-Build Script
# FOR OFFICIAL USE ONLY (FOUO)
# =============================================================================

set -euo pipefail

# ── Colors for output ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ── Gather user inputs ───────────────────────────────────────────────────────
header "WireGuard Tunnel Build"

read -rp "Which Set? (1, 2, 3, etc): " WG_SET
WG_SET="${WG_SET// /}"   # strip spaces
if ! [[ "$WG_SET" =~ ^[0-9]+$ ]]; then
    error "Set must be a positive integer. Exiting."
    exit 1
fi

read -rp "What is the Mission name? (snph2, sknt, etc): " MISSION_NAME
MISSION_NAME="${MISSION_NAME// /}"   # strip spaces
if [[ -z "$MISSION_NAME" ]]; then
    error "Mission name cannot be empty. Exiting."
    exit 1
fi

# ── Derive WG server IP ──────────────────────────────────────────────────────
header "Detecting Host IP"

# Get the primary non-loopback IP address
HOST_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$HOST_IP" ]]; then
    error "Could not determine host IP address. Exiting."
    exit 1
fi
log "Host IP detected: ${HOST_IP}"

# Build WG server IP: first three octets + .254
IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$HOST_IP"
WG_SERVER_IP="${oct1}.${oct2}.${oct3}.254"
log "WireGuard server IP: ${WG_SERVER_IP}"

# ── Locate configuration file ────────────────────────────────────────────────
header "Locating Configuration File"

CONF_DIR="/mnt/share/N_Files"
CONF_FILENAME="wg_conf_${MISSION_NAME}_set${WG_SET}"
CONF_PATH="${CONF_DIR}/${CONF_FILENAME}"

if [[ ! -f "$CONF_PATH" ]]; then
    error "Configuration file not found: ${CONF_PATH}"
    error "Expected file: wg_conf_${MISSION_NAME}_set${WG_SET}"
    exit 1
fi
log "Found configuration file: ${CONF_PATH}"

# ── Parse the conf file ──────────────────────────────────────────────────────
header "Parsing Configuration File"

parse_field() {
    grep -i "$1" "$CONF_PATH" | head -1 | sed 's/.*:\s*//' | tr -d '[:space:]'
}

OUTER_PRIVATE_KEY=$(parse_field "Outer_Tunnel_Private_Key")
OUTER_ADDRESS=$(parse_field "Outer Tunnel Interface Address")
OUTER_LISTEN_PORT=$(parse_field "Outer Tunnel ListenPort")
OUTER_MTU=$(parse_field "Outer Tunnel MTU")
OUTER_PEER_PUBKEY=$(parse_field "Outer_Tunnel_Public_Key")
OUTER_ENDPOINT=$(parse_field "Redirector2_IP")
OUTER_ALLOWED_IPS=$(parse_field "AllowedIPs \(Client Subnets\)" | head -1)

INNER_PRIVATE_KEY=$(parse_field "Inner_Tunnel_Private_Key")
INNER_ADDRESS=$(parse_field "Inner Tunnel Interface Address")
INNER_LISTEN_PORT=$(parse_field "Inner Tunnel ListenPort")
INNER_MTU_RAW=$(parse_field "Inner Tunnel MTU")
INNER_PEER_PUBKEY=$(parse_field "Inner_Client_Public_Key")
INNER_ENDPOINT=$(parse_field "Inner Tunnel Peer Endpoint")

# Grab AllowedIPs lines separately since there are two
INNER_ALLOWED_IPS=$(grep -i "AllowedIPs" "$CONF_PATH" | tail -1 | sed 's/.*:\s*//')

# Handle MTU range (e.g. "1280-1340") — pick the lower value
if [[ "$INNER_MTU_RAW" =~ ^([0-9]+)-[0-9]+$ ]]; then
    INNER_MTU="${BASH_REMATCH[1]}"
else
    INNER_MTU="$INNER_MTU_RAW"
fi

# Grab PersistentKeepalive values
OUTER_KEEPALIVE=$(grep -i "PersistentKeepalive" "$CONF_PATH" | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')
INNER_KEEPALIVE=$(grep -i "PersistentKeepalive" "$CONF_PATH" | tail -1 | sed 's/.*=\s*//' | tr -d '[:space:]')

log "Outer tunnel: address=${OUTER_ADDRESS}, port=${OUTER_LISTEN_PORT}"
log "Inner tunnel: address=${INNER_ADDRESS}, port=${INNER_LISTEN_PORT}"

# ── Determine destination conf file names ────────────────────────────────────
header "Determining WireGuard Interface Names"

if [[ "$WG_SET" -eq 1 ]]; then
    OUTER_CONF_NAME="wg0.conf"
    INNER_CONF_NAME="wg1.conf"
    OUTER_IFACE="wg0"
    INNER_IFACE="wg1"
else
    OUTER_CONF_NAME="wg0_set${WG_SET}.conf"
    INNER_CONF_NAME="wg1_set${WG_SET}.conf"
    OUTER_IFACE="wg0_set${WG_SET}"
    INNER_IFACE="wg1_set${WG_SET}"
fi

log "Outer conf: ${OUTER_CONF_NAME}  (interface: ${OUTER_IFACE})"
log "Inner conf: ${INNER_CONF_NAME}  (interface: ${INNER_IFACE})"

# ── Build the two WireGuard conf file contents ───────────────────────────────
OUTER_CONF_CONTENT="[Interface]
# Outer Tunnel - Mission: ${MISSION_NAME} Set${WG_SET}
PrivateKey = ${OUTER_PRIVATE_KEY}
Address = ${OUTER_ADDRESS}
ListenPort = ${OUTER_LISTEN_PORT}
MTU = ${OUTER_MTU}

[Peer]
PublicKey = ${OUTER_PEER_PUBKEY}
Endpoint = ${OUTER_ENDPOINT}
AllowedIPs = ${OUTER_ALLOWED_IPS}
PersistentKeepalive = ${OUTER_KEEPALIVE}
"

INNER_CONF_CONTENT="[Interface]
# Inner Tunnel - Mission: ${MISSION_NAME} Set${WG_SET}
PrivateKey = ${INNER_PRIVATE_KEY}
Address = ${INNER_ADDRESS}
ListenPort = ${INNER_LISTEN_PORT}
MTU = ${INNER_MTU}

[Peer]
PublicKey = ${INNER_PEER_PUBKEY}
Endpoint = ${INNER_ENDPOINT}
AllowedIPs = ${INNER_ALLOWED_IPS}
PersistentKeepalive = ${INNER_KEEPALIVE}
"

# ── SCP config file to WG server ─────────────────────────────────────────────
header "Transferring Configuration File to WG Server (${WG_SERVER_IP})"

log "Copying ${CONF_FILENAME} to ${WG_SERVER_IP}:/etc/wireguard/"
scp "$CONF_PATH" "root@${WG_SERVER_IP}:/etc/wireguard/${CONF_FILENAME}" || {
    error "SCP transfer failed. Check SSH connectivity to ${WG_SERVER_IP}."
    exit 1
}
log "Transfer complete."

# ── SSH into WG server and build tunnels ──────────────────────────────────────
header "SSHing into WG Server and Building Tunnels"

ssh "root@${WG_SERVER_IP}" bash -s \
    "$WG_SET" \
    "$OUTER_CONF_NAME" \
    "$INNER_CONF_NAME" \
    "$OUTER_IFACE" \
    "$INNER_IFACE" \
    "$OUTER_CONF_CONTENT" \
    "$INNER_CONF_CONTENT" << 'REMOTE_SCRIPT'

#!/bin/bash
set -euo pipefail

WG_SET="$1"
OUTER_CONF_NAME="$2"
INNER_CONF_NAME="$3"
OUTER_IFACE="$4"
INNER_IFACE="$5"
OUTER_CONF_CONTENT="$6"
INNER_CONF_CONTENT="$7"

WG_DIR="/etc/wireguard"
cd "$WG_DIR"

echo "[+] Current directory: $(pwd)"
echo "[+] Existing .conf files:"
ls -1 *.conf 2>/dev/null || echo "    (none found)"

# ── Bring down all active WireGuard interfaces ──────────────────────────────
echo ""
echo "=== Bringing Down Existing WireGuard Interfaces ==="

for conf_file in *.conf; do
    [[ -f "$conf_file" ]] || continue
    iface="${conf_file%.conf}"
    if ip link show "$iface" &>/dev/null 2>&1; then
        echo "[+] Bringing down interface: ${iface}"
        wg-quick down "$iface" 2>/dev/null && echo "    Done." || echo "    Already down or not active."
    else
        echo "[!] Interface ${iface} not active — skipping wg-quick down."
    fi
done

# ── Rename inner.conf / outer.conf if present (Set 1 only) ──────────────────
if [[ "$WG_SET" -eq 1 ]]; then
    echo ""
    echo "=== Renaming Legacy conf Files (Set 1) ==="
    if [[ -f "outer.conf" ]]; then
        echo "[+] Renaming outer.conf -> wg0.conf"
        mv -v "outer.conf" "wg0.conf"
    fi
    if [[ -f "inner.conf" ]]; then
        echo "[+] Renaming inner.conf -> wg1.conf"
        mv -v "inner.conf" "wg1.conf"
    fi
fi

# ── Write the new conf files ─────────────────────────────────────────────────
echo ""
echo "=== Writing New WireGuard Configuration Files ==="

echo "[+] Writing ${OUTER_CONF_NAME}"
printf '%s\n' "$OUTER_CONF_CONTENT" > "${WG_DIR}/${OUTER_CONF_NAME}"
chmod 600 "${WG_DIR}/${OUTER_CONF_NAME}"

echo "[+] Writing ${INNER_CONF_NAME}"
printf '%s\n' "$INNER_CONF_CONTENT" > "${WG_DIR}/${INNER_CONF_NAME}"
chmod 600 "${WG_DIR}/${INNER_CONF_NAME}"

echo "[+] Configuration files written:"
ls -lh "${WG_DIR}/"*.conf

# ── Bring up the new interfaces ──────────────────────────────────────────────
echo ""
echo "=== Bringing Up WireGuard Interfaces ==="

echo "[+] Bringing up outer tunnel: ${OUTER_IFACE}"
wg-quick up "$OUTER_IFACE" && echo "    ${OUTER_IFACE} is UP." || {
    echo "[ERROR] Failed to bring up ${OUTER_IFACE}"
    exit 1
}

echo "[+] Bringing up inner tunnel: ${INNER_IFACE}"
wg-quick up "$INNER_IFACE" && echo "    ${INNER_IFACE} is UP." || {
    echo "[ERROR] Failed to bring up ${INNER_IFACE}"
    exit 1
}

# ── Add firewall rules (firewalld, zone=public, permanent) ───────────────────
echo ""
echo "=== Configuring Firewall (firewalld) ==="

if command -v firewall-cmd &>/dev/null; then
    # Determine ports from conf files
    OUTER_PORT=$(grep -i "ListenPort" "${WG_DIR}/${OUTER_CONF_NAME}" | awk '{print $3}')
    INNER_PORT=$(grep -i "ListenPort" "${WG_DIR}/${INNER_CONF_NAME}" | awk '{print $3}')

    for PORT in "$OUTER_PORT" "$INNER_PORT"; do
        if [[ -n "$PORT" ]]; then
            echo "[+] Opening UDP port ${PORT} (zone=public, permanent)"
            firewall-cmd --zone=public --add-port="${PORT}/udp" --permanent && \
                echo "    Port ${PORT}/udp opened." || \
                echo "[!] Could not open port ${PORT}/udp — may already exist."
        fi
    done

    echo "[+] Adding WireGuard interfaces to public zone (permanent)"
    firewall-cmd --zone=public --add-interface="${OUTER_IFACE}" --permanent 2>/dev/null || true
    firewall-cmd --zone=public --add-interface="${INNER_IFACE}" --permanent 2>/dev/null || true

    echo "[+] Reloading firewalld"
    firewall-cmd --reload && echo "    Firewalld reloaded."
else
    echo "[!] firewalld not found — skipping firewall configuration."
fi

# ── Enable systemd services for auto-restart on reboot ──────────────────────
echo ""
echo "=== Enabling systemd WireGuard Services ==="

for IFACE in "$OUTER_IFACE" "$INNER_IFACE"; do
    SERVICE="wg-quick@${IFACE}.service"
    echo "[+] Enabling and starting: ${SERVICE}"
    systemctl enable "$SERVICE" && echo "    Enabled: ${SERVICE}" || echo "[!] Could not enable ${SERVICE}"
    systemctl start  "$SERVICE" 2>/dev/null && echo "    Started: ${SERVICE}" || echo "[!] ${SERVICE} already running or could not start."
done

# ── Final status ─────────────────────────────────────────────────────────────
echo ""
echo "=== WireGuard Interface Status ==="
wg show

echo ""
echo "=== Systemd Service Status ==="
systemctl status "wg-quick@${OUTER_IFACE}" --no-pager || true
systemctl status "wg-quick@${INNER_IFACE}" --no-pager || true

echo ""
echo "[+] WireGuard build complete for Mission: Set ${WG_SET}"

REMOTE_SCRIPT

log "Remote build script finished."
header "Build Complete"
log "Mission: ${MISSION_NAME} | Set: ${WG_SET}"
log "Outer interface: ${OUTER_IFACE} | Inner interface: ${INNER_IFACE}"
log "WG Server: ${WG_SERVER_IP}"