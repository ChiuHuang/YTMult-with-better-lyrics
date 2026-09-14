#!/bin/bash
# YTMusicUltimate Node Setup (TUI + systemd)
# Usage (non-interactive):
#   bash <(curl -fsSL https://raw.githubusercontent.com/ChiuHuang/YTMult-with-better-lyrics/main/deploy.sh) \
#     --server=https://ytmtranslate.chiuhuang.dev --password=xxx --label=my-vps
#
# Usage (interactive TUI):
#   curl -fsSL https://raw.githubusercontent.com/ChiuHuang/YTMult-with-better-lyrics/main/deploy.sh -o deploy.sh && chmod +x deploy.sh && ./deploy.sh

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Defaults ---
SERVER="${YTMT_SERVER:-}"
PASSWORD="${YTMT_ADMIN_PASSWORD:-}"
LABEL="${YTMT_NODE_LABEL:-}"
NODE_DIR="${YTMT_NODE_DIR:-$HOME/ytmnode}"
JWT="${YTMT_JWT:-}"
NON_INTERACTIVE=false

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --server) SERVER="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --dir) NODE_DIR="$2"; shift 2 ;;
        --jwt) JWT="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        -h|--help)
            cat <<EOF
YTMusicUltimate Node Setup

Usage:
  $0 [options]

Options:
  --server URL       Main server URL (e.g. https://ytmtranslate.chiuhuang.dev)
  --password PASS    Admin panel password
  --label NAME       Node label (default: hostname)
  --dir PATH         Install directory (default: ~/ytmnode)
  --jwt TOKEN        Optional Cubey JWT to contribute
  --non-interactive  Skip prompts (requires --server and --password)
  -h, --help         Show this help

Environment variables (alternative to flags):
  YTMT_SERVER, YTMT_ADMIN_PASSWORD, YTMT_NODE_LABEL, YTMT_NODE_DIR, YTMT_JWT

One-liner (run on any VPS):
  curl -fsSL https://raw.githubusercontent.com/ChiuHuang/YTMult-with-better-lyrics/main/deploy.sh | bash
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Helper functions ---
print_header() {
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║  YTMusicUltimate Lyrics Node Setup                           ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
}

print_step() { echo -e "${BLUE}▶${NC} $1"; }
print_ok() { echo -e "${GREEN}✓${NC} $1"; }
print_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
print_err() { echo -e "${RED}✗${NC} $1"; }
print_dim() { echo -e "${DIM}$1${NC}"; }

prompt_input() {
    local prompt="$1" var_name="$2" default="${3:-}" secret="${4:-false}"
    local value=""
    if [[ -n "${!var_name:-}" ]]; then
        value="${!var_name}"
        echo -e "${BLUE}▶${NC} $prompt: ${GREEN}(from env/args)${NC}"
    else
        if [[ "$secret" == "true" ]]; then
            read -s -p "$(echo -e "${BLUE}▶${NC} $prompt: ")" value
            echo
        else
            read -p "$(echo -e "${BLUE}▶${NC} $prompt [$default]: ")" value
            value="${value:-$default}"
        fi
        eval "$var_name=\"$value\""
    fi
}

# --- Main ---
print_header

# 1. Get config (interactive or from args/env)
if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ -z "$SERVER" || -z "$PASSWORD" ]]; then
        print_err "Non-interactive mode requires --server and --password"
        exit 1
    fi
    LABEL="${LABEL:-$(hostname)}"
else
    echo -e "${BOLD}Enter node configuration:${NC}"
    echo
    prompt_input "Server URL (e.g. https://ytmtranslate.chiuhuang.dev)" SERVER "" false
    prompt_input "Admin password" PASSWORD "" true
    prompt_input "Node label" LABEL "$(hostname)" false
    prompt_input "Install directory" NODE_DIR "$HOME/ytmnode" false
    prompt_input "Cubey JWT (optional)" JWT "" false
    echo
fi

# Normalize server URL (remove trailing slash)
SERVER="${SERVER%/}"

# 2. Check dependencies
print_step "Checking dependencies..."
for cmd in curl python3 pip3; do
    if ! command -v "$cmd" &>/dev/null; then
        print_err "Missing dependency: $cmd"
        exit 1
    fi
done
print_ok "All dependencies found"

# 3. Login to server
print_step "Logging in to $SERVER..."
COOKIE_JAR=$(mktemp)
trap "rm -f '$COOKIE_JAR'" EXIT

LOGIN_RESP=$(curl -fsSL -c "$COOKIE_JAR" -L \
    -d "password=$PASSWORD" \
    -w "\n%{http_code}" \
    "$SERVER/login" 2>/dev/null || true)

HTTP_CODE=$(echo "$LOGIN_RESP" | tail -1)
if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "302" ]]; then
    print_err "Login failed (HTTP $HTTP_CODE). Check password and server URL."
    exit 1
fi
print_ok "Logged in"

# 4. Generate node
print_step "Generating node..."
GEN_RESP=$(curl -fsSL -b "$COOKIE_JAR" -L \
    -X POST -H "Content-Type: application/json" \
    -d "{\"label\": \"$LABEL\"}" \
    "$SERVER/api/admin/nodes/generate")

if ! echo "$GEN_RESP" | grep -q '"ok":true'; then
    print_err "Failed to generate node"
    echo "$GEN_RESP" | head -5
    exit 1
fi

# Parse JSON response (using python for robustness)
NODE_DATA=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data['node_id'])
print(data['node_key'])
print(data['ws_url'])
print(data['server_url'])
print(data['script_b64'])
print(data['filename'])
print(data['deploy_one_liner'])
" <<< "$GEN_RESP")

NODE_ID=$(echo "$NODE_DATA" | sed -n '1p')
NODE_KEY=$(echo "$NODE_DATA" | sed -n '2p')
WS_URL=$(echo "$NODE_DATA" | sed -n '3p')
SERVER_URL=$(echo "$NODE_DATA" | sed -n '4p')
SCRIPT_B64=$(echo "$NODE_DATA" | sed -n '5p')
FILENAME=$(echo "$NODE_DATA" | sed -n '6p')
DEPLOY_ONE_LINER=$(echo "$NODE_DATA" | sed -n '7p')

print_ok "Node created: $NODE_ID"

# 5. Save node script
print_step "Saving node script to $NODE_DIR..."
mkdir -p "$NODE_DIR"
echo "$SCRIPT_B64" | base64 -d > "$NODE_DIR/node.py"
chmod +x "$NODE_DIR/node.py"
print_ok "Saved $FILENAME"

# 6. Install Python deps
print_step "Installing Python dependencies..."
pip3 install -q websocket-client requests 2>/dev/null || \
    pip install -q websocket-client requests 2>/dev/null || \
    python3 -m pip install -q websocket-client requests 2>/dev/null
print_ok "Dependencies installed"

# 7. Create systemd service
print_step "Setting up systemd service..."
SERVICE_FILE="/etc/systemd/system/ytmu-node.service"

# Check if we can use sudo
if ! sudo -n true 2>/dev/null; then
    print_warn "Need sudo for systemd setup. You may be prompted for password."
fi

sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=YTMusicUltimate Lyrics Node
After=network.target

[Service]
Type=simple
WorkingDirectory=$NODE_DIR
Environment="YTMU_JWT=${JWT}"
ExecStart=/usr/bin/python3 $NODE_DIR/node.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

print_ok "Service file created: $SERVICE_FILE"

# 8. Enable and start
print_step "Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable --now ytmu-node
print_ok "Service enabled and started"

# 9. Verify
sleep 2
if systemctl is-active --quiet ytmu-node; then
    print_ok "Node is running!"
else
    print_warn "Service started but may have issues. Check logs:"
    echo -e "  ${DIM}sudo journalctl -u ytmu-node -f${NC}"
fi

# 10. Show summary
echo
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║  Setup Complete                                               ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "  ${BOLD}Node ID:${NC}      $NODE_ID"
echo -e "  ${BOLD}Label:${NC}        $LABEL"
echo -e "  ${BOLD}Directory:${NC}    $NODE_DIR"
echo -e "  ${BOLD}Server:${NC}       $SERVER_URL"
echo -e "  ${BOLD}WS URL:${NC}       $WS_URL"
echo
echo -e "  ${BOLD}Logs:${NC}"
echo -e "    ${DIM}sudo journalctl -u ytmu-node -f${NC}"
echo
echo -e "  ${BOLD}Control:${NC}"
echo -e "    ${DIM}sudo systemctl status ytmu-node${NC}"
echo -e "    ${DIM}sudo systemctl restart ytmu-node${NC}"
echo -e "    ${DIM}sudo systemctl stop ytmu-node${NC}"
echo

# Show the one-liner for next time
echo -e "${BOLD}One-liner for future deploys:${NC}"
echo -e "${DIM}curl -fsSL https://raw.githubusercontent.com/ChiuHuang/YTMult-with-better-lyrics/main/deploy.sh | bash -s -- --server=$SERVER_URL --password='***REDACTED***' --label=$LABEL${NC}"
echo
print_dim "Save your credentials securely. The node key is only in $NODE_DIR/node.py"