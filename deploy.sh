#!/bin/bash
# YTMusicUltimate Node Deploy
# Generates a lyrics node on the server and runs it.
#
# Usage:
#   env YTMT_SERVER=https://ytmtranslate.chiuhuang.dev \
#       YTMT_ADMIN_PASSWORD=yourpassword \
#       YTMT_NODE_LABEL=my-vps \
#       bash <(curl -fsSL https://raw.githubusercontent.com/ChiuHuang/YTMult-with-better-lyrics/main/deploy.sh)
#
# Env vars:
#   YTMT_SERVER        - main server URL (required, e.g. https://ytmtranslate.chiuhuang.dev)
#   YTMT_ADMIN_PASSWORD - admin panel password (required)
#   YTMT_NODE_LABEL    - human-readable label for this node (default: hostname)
#   YTMT_NODE_DIR      - directory to store node.py (default: ~/ytmnode)
#   YTMT_JWT           - optional Cubey JWT to contribute to shared pool

set -euo pipefail

SERVER="${YTMT_SERVER:?YTMT_SERVER is required (e.g. https://ytmtranslate.chiuhuang.dev)}"
PASSWORD="${YTMT_ADMIN_PASSWORD:?YTMT_ADMIN_PASSWORD is required}"
LABEL="${YTMT_NODE_LABEL:-$(hostname)}"
NODE_DIR="${YTMT_NODE_DIR:-$HOME/ytmnode}"

echo "=== YTMusicUltimate Node Deploy ==="
echo "Server:  $SERVER"
echo "Label:   $LABEL"
echo "Dir:     $NODE_DIR"
echo ""

# --- 1. Login to get session cookie ---
echo "[1/4] Logging in..."
COOKIE_JAR=$(mktemp)
trap "rm -f '$COOKIE_JAR'" EXIT

# Follow redirects, save cookies
curl -fsSL -c "$COOKIE_JAR" -L \
    -d "password=$PASSWORD" \
    "$SERVER/login" > /dev/null 2>&1 || true

# Verify we're logged in by hitting a protected endpoint
if ! curl -fsSL -b "$COOKIE_JAR" -L "$SERVER/" | grep -q "dashboard\|admin\|logout" 2>/dev/null; then
    echo "  [FAIL] Login failed. Check YTMT_ADMIN_PASSWORD."
    exit 1
fi
echo "  [OK] Logged in"

# --- 2. Generate node script ---
echo "[2/4] Generating node..."
NODE_SCRIPT=$(curl -fsSL -b "$COOKIE_JAR" -L \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"label\": \"$LABEL\"}" \
    "$SERVER/api/admin/nodes/generate")

# Verify it looks like a Python script
if ! echo "$NODE_SCRIPT" | head -1 | grep -q "#!/usr/bin/env python3"; then
    echo "  [FAIL] Did not receive a valid node script"
    echo "  Response: $(echo "$NODE_SCRIPT" | head -5)"
    exit 1
fi

# Extract node_id from the script (embedded as NODE_ID = "...")
NODE_ID=$(echo "$NODE_SCRIPT" | grep -oP 'NODE_ID\s*=\s*"\K[^"]+' || echo "unknown")
echo "  [OK] Generated node $NODE_ID"

# --- 3. Save and install ---
echo "[3/4] Installing node..."
mkdir -p "$NODE_DIR"
echo "$NODE_SCRIPT" > "$NODE_DIR/node.py"
chmod +x "$NODE_DIR/node.py"

# Install deps if needed
pip3 install -q websocket-client requests 2>/dev/null || \
    pip install -q websocket-client requests 2>/dev/null || \
    python3 -m pip install -q websocket-client requests 2>/dev/null || \
    echo "  [WARN] Could not auto-install deps. Run: pip3 install websocket-client requests"

echo "  [OK] Saved to $NODE_DIR/node.py"

# --- 4. Kill old node and start ---
echo "[4/4] Starting node..."
pkill -f "python.*node.py" 2>/dev/null && sleep 1 || true

cd "$NODE_DIR"
if [ -n "${YTMT_JWT:-}" ]; then
    export YTMU_JWT="$YTMT_JWT"
fi

nohup python3 node.py > "$NODE_DIR/node.log" 2>&1 &
NEWPID=$!
sleep 2

if kill -0 "$NEWPID" 2>/dev/null; then
    echo ""
    echo "=== Node running ==="
    echo "  PID:     $NEWPID"
    echo "  Node ID: $NODE_ID"
    echo "  Label:   $LABEL"
    echo "  Log:     $NODE_DIR/node.log"
    echo "  Server:  $SERVER"
    echo ""
    echo "  View logs: tail -f $NODE_DIR/node.log"
else
    echo ""
    echo "=== Node failed to start ==="
    echo "  Check: $NODE_DIR/node.log"
    tail -20 "$NODE_DIR/node.log" 2>/dev/null || true
    exit 1
fi
