#!/bin/bash
# YTMusicUltimate Node Setup
# Usage (non-interactive):
#   bash <(curl -fsSL https://ytmtranslate.chiuhuang.dev/deploy.sh) --server=https://ytmtranslate.chiuhuang.dev --label=my-vps --node-id=... --node-key=...
#
# Usage (interactive TUI):
#   curl -fsSL https://ytmtranslate.chiuhuang.dev/deploy.sh -o deploy.sh && chmod +x deploy.sh && ./deploy.sh
#
# Auth: pass --node-id and --node-key from the dashboard's "Generate node"
# dialog (shown once). No admin password is needed -- the node script is
# fetched from the keyed /api/admin/nodes/generate/<id>?key=<key> endpoint.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SERVER=""
PASSWORD=""
LABEL=""
NODE_ID=""
NODE_KEY=""
NODE_DIR="${YTMT_NODE_DIR:-$HOME/ytmnode}"
JWT="${YTMT_JWT:-}"
NON_INTERACTIVE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --server) SERVER="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --node-id) NODE_ID="$2"; shift 2 ;;
        --node-key) NODE_KEY="$2"; shift 2 ;;
        --dir) NODE_DIR="$2"; shift 2 ;;
        --jwt) JWT="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        -h|--help) echo "Usage: $0 --server=URL --label=NAME [--node-id=ID --node-key=KEY] [--password=PW (legacy)] [--jwt=TOKEN]"; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
step() { echo -e "${BLUE}▶${NC} $1"; }

# Detect sudo (Docker containers often lack it)
SUDO=""
if command -v sudo &>/dev/null && [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

echo -e "${CYAN}${BOLD}YTMusicUltimate Node Setup${NC}"
echo

# 1. Interactive prompts
if [[ "$NON_INTERACTIVE" != "true" ]]; then
    [[ -z "$SERVER" ]] && read -p "$(echo -e "${BLUE}▶${NC} Server URL: ")" SERVER
    [[ -z "$LABEL" ]] && read -p "$(echo -e "${BLUE}▶${NC} Label [$(hostname)]: ")" LABEL
    LABEL="${LABEL:-$(hostname)}"
    if [[ -z "$NODE_ID" && -z "$NODE_KEY" ]]; then
        read -p "$(echo -e "${BLUE}▶${NC} Node ID (from dashboard Generate node): ")" NODE_ID
        read -s -p "$(echo -e "${BLUE}▶${NC} Node key (from dashboard Generate node): ")" NODE_KEY
        echo
    fi
    # Legacy fallback: admin password to auto-generate a node
    if [[ -z "$NODE_ID" || -z "$NODE_KEY" ]]; then
        read -s -p "$(echo -e "${BLUE}▶${NC} Admin password (legacy, to generate a node): ")" PW_INPUT
        echo
        [[ -n "$PW_INPUT" ]] && PASSWORD="$PW_INPUT"
    fi
    [[ -z "$NODE_DIR" || "$NODE_DIR" == "$HOME/ytmnode" ]] && read -p "$(echo -e "${BLUE}▶${NC} Install dir [$HOME/ytmnode]: ")" DIR_INPUT
    [[ -n "$DIR_INPUT" ]] && NODE_DIR="$DIR_INPUT"
else
    LABEL="${LABEL:-$(hostname)}"
    [[ -z "$SERVER" ]] && fail "--server is required"
fi

SERVER="${SERVER%/}"
[[ -z "$LABEL" ]] && LABEL="$(hostname)"

# 2. Check/install deps
step "Checking dependencies..."
for cmd in curl; do
    command -v "$cmd" &>/dev/null || fail "Missing: $cmd"
done

if ! command -v python3 &>/dev/null; then
    step "python3 not found -- installing..."
    if command -v apt-get &>/dev/null; then
        $SUDO apt-get update -y >/dev/null 2>&1 || true
        $SUDO apt-get install -y python3 python3-pip python3-venv >/dev/null 2>&1
    elif command -v apk &>/dev/null; then
        $SUDO apk add --no-cache python3 py3-pip 2>/dev/null || $SUDO apk add --no-cache python3
    elif command -v dnf &>/dev/null; then
        $SUDO dnf install -y python3 python3-pip python3-libs 2>/dev/null || $SUDO dnf install -y python3
    elif command -v yum &>/dev/null; then
        $SUDO yum install -y python3 python3-pip 2>/dev/null || $SUDO yum install -y python3
    else
        fail "python3 missing and no supported package manager found"
    fi
fi
command -v python3 &>/dev/null || fail "python3 still not available after install"
# Debian needs python3-venv for venv module; make sure it exists
if ! python3 -m venv --help >/dev/null 2>&1; then
    step "python3-venv missing -- installing..."
    if command -v apt-get &>/dev/null; then
        $SUDO apt-get install -y python3-venv >/dev/null 2>&1 || true
    fi
    python3 -m venv --help >/dev/null 2>&1 || warn "venv unavailable -- falling back to system pip"
fi
ok "Dependencies OK"

mkdir -p "$NODE_DIR"

# 3. Install pip packages (into a venv when possible)
step "Installing Python packages..."
PY=""
if python3 -m venv --help >/dev/null 2>&1; then
    if [[ ! -d "$NODE_DIR/venv" ]]; then
        python3 -m venv "$NODE_DIR/venv" >/dev/null 2>&1 || true
    fi
    if [[ -x "$NODE_DIR/venv/bin/python" ]]; then
        PY="$NODE_DIR/venv/bin/python"
    elif [[ -x "$NODE_DIR/venv/Scripts/python.exe" ]]; then
        PY="$NODE_DIR/venv/Scripts/python.exe"
    fi
fi
PY="${PY:-$(command -v python3)}"
"$PY" -m pip install -q --upgrade pip 2>/dev/null || true
"$PY" -m pip install -q websocket-client requests 2>/dev/null || \
    warn "Could not auto-install pip packages (node may need them)"
ok "Python packages ready ($PY)"

# 4. Download node.py
step "Downloading node script..."
NODE_URL="$SERVER/deploy.sh"  # placeholder

if [[ -n "$NODE_ID" && -n "$NODE_KEY" ]]; then
    # Keyed fetch: node_id + node_key authenticate, no password needed.
    step "Fetching node script with node id/key..."
    NODE_URL="$SERVER/api/admin/nodes/generate/$NODE_ID?key=$NODE_KEY"
    if ! curl -fsSL "$NODE_URL" -o "$NODE_DIR/node.py"; then
        fail "Could not fetch node script from $NODE_URL (check node id/key)"
    fi
    ok "Node script downloaded: $NODE_ID"
elif [[ -n "$PASSWORD" ]]; then
    step "Logging in to $SERVER..."
    COOKIE_JAR=$(mktemp)
    trap "rm -f '$COOKIE_JAR'" EXIT

    curl -fsSL -c "$COOKIE_JAR" -L -d "password=$PASSWORD" "$SERVER/login" > /dev/null 2>&1 || warn "Login failed, trying generate anyway..."

    step "Generating node..."
    GEN_RESP=$(curl -fsSL -b "$COOKIE_JAR" -L \
        -X POST -H "Content-Type: application/json" \
        -d "{\"label\": \"$LABEL\"}" \
        "$SERVER/api/admin/nodes/generate" 2>/dev/null || echo '{}')

    if echo "$GEN_RESP" | grep -q '"ok":true'; then
        NODE_DATA=$(python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['node_id']); print(d['node_key']); print(d['ws_url'])
print(d['server_url']); print(d['script_b64']); print(d['filename'])
" <<< "$GEN_RESP")
        NODE_ID=$(echo "$NODE_DATA" | sed -n '1p')
        NODE_KEY=$(echo "$NODE_DATA" | sed -n '2p')
        WS_URL=$(echo "$NODE_DATA" | sed -n '3p')
        SCRIPT_B64=$(echo "$NODE_DATA" | sed -n '5p')
        FILENAME=$(echo "$NODE_DATA" | sed -n '6p')

        echo "$SCRIPT_B64" | base64 -d > "$NODE_DIR/node.py"
        ok "Node generated: $NODE_ID"
    else
        warn "API generate failed. Download node.py manually from the admin panel."
        fail "Cannot continue without node script"
    fi
else
    fail "No credentials. Pass --node-id/--node-key from the dashboard, or --password for legacy generate"
fi

chmod +x "$NODE_DIR/node.py"

WS_URL="${WS_URL:-$(echo "$SERVER" | sed 's#^http#ws#')/ws/node}"

# 5. Create systemd service (or supervisor, or just run in background)
step "Setting up auto-start..."

create_systemd() {
    cat > /tmp/ytmu-node.service <<EOF
[Unit]
Description=YTMusicUltimate Lyrics Node
After=network.target

[Service]
Type=simple
WorkingDirectory=$NODE_DIR
Environment="YTMU_JWT=${JWT}"
ExecStart="$PY" $NODE_DIR/node.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    $SUDO mv /tmp/ytmu-node.service /etc/systemd/system/ytmu-node.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now ytmu-node
}

# Try systemd first, fall back to nohup
if command -v systemctl &>/dev/null; then
    create_systemd
    ok "Systemd service created and started"
elif command -v service &>/dev/null; then
    # sysvinit
    warn "systemd not found, using nohup background"
    $SUDO killall -q python3 2>/dev/null || true
    cd "$NODE_DIR"
    nohup "$PY" node.py > "$NODE_DIR/node.log" 2>&1 &
    ok "Node started in background (PID $!)"
else
    # No init system (Docker, etc.)
    warn "No init system found, running in background"
    $SUDO killall -q python3 2>/dev/null || true
    cd "$NODE_DIR"
    nohup "$PY" node.py > "$NODE_DIR/node.log" 2>&1 &
    ok "Node started in background (PID $!). Add to your container startup."
fi

# 6. Verify
sleep 2
if command -v systemctl &>/dev/null && systemctl is-active --quiet ytmu-node 2>/dev/null; then
    ok "Node is running!"
elif kill -0 $(pgrep -f "python3.*node.py" 2>/dev/null || echo 0) 2>/dev/null; then
    ok "Node process is alive"
else
    warn "Check logs: $NODE_DIR/node.log"
fi

echo
echo -e "${CYAN}${BOLD}=== Setup Complete ===${NC}"
echo -e "  Node ID:   $NODE_ID"
echo -e "  Label:     $LABEL"
echo -e "  Dir:       $NODE_DIR"
echo -e "  Server:    $SERVER"
echo -e "  WS URL:    $WS_URL"
echo
if command -v systemctl &>/dev/null; then
    echo -e "  Logs:      ${DIM}sudo journalctl -u ytmu-node -f${NC}"
    echo -e "  Restart:   ${DIM}sudo systemctl restart ytmu-node${NC}"
else
    echo -e "  Logs:      ${DIM}tail -f $NODE_DIR/node.log${NC}"
fi
echo