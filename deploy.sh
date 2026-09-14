#!/bin/bash
# YTMusicUltimate Server Deploy Script
# Run ON the VPS:
#   curl -fsSL https://raw.githubusercontent.com/ChiuHuang/YTMult-with-better-lyrics/main/deploy.sh | bash
#
# Or with env vars:
#   env YTMT_SERVER=ytmtranslate.chiuhuang.dev \
#       YTMT_CLIENT_SECRET=... YTMT_CLIENT_ID=... \
#       bash <(curl -fsSL https://raw.githubusercontent.com/ChiuHuang/YTMult-with-better-lyrics/main/deploy.sh)
#
# Env vars (all optional, override config/admin_config.json):
#   YTMT_SERVER        - server host (default: 0.0.0.0)
#   YTMT_PORT          - server port (default: 20016)
#   YTMT_CLIENT_SECRET - Cubey JWT client secret
#   YTMT_CLIENT_ID     - Cubey JWT client ID
#   YTMT_REPO          - git repo URL (default: https://github.com/ChiuHuang/YTMult-with-better-lyrics.git)
#   YTMT_BRANCH        - git branch (default: main)
#   YTMT_DIR           - install directory (default: ~/ytmusicultimate)

set -euo pipefail

REPO="${YTMT_REPO:-https://github.com/ChiuHuang/YTMult-with-better-lyrics.git}"
BRANCH="${YTMT_BRANCH:-main}"
DIR="${YTMT_DIR:-$HOME/ytmusicultimate}"
PORT="${YTMT_PORT:-20016}"

echo "=== YTMusicUltimate Server Deploy ==="
echo "Repo:    $REPO"
echo "Branch:  $BRANCH"
echo "Dir:     $DIR"
echo "Port:    $PORT"
echo ""

# --- 1. Clone or pull ---
if [ -d "$DIR/.git" ]; then
    echo "[1/5] Updating existing repo..."
    cd "$DIR"
    git fetch origin "$BRANCH"
    git reset --hard "origin/$BRANCH"
else
    echo "[1/5] Cloning repo..."
    rm -rf "$DIR"
    git clone --branch "$BRANCH" "$REPO" "$DIR"
    cd "$DIR"
fi
echo "  -> $(git log --oneline -1)"

# --- 2. Python venv + deps ---
echo "[2/5] Setting up Python environment..."
if [ ! -d .venv ]; then
    python3 -m venv .venv
fi
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt 2>/dev/null || {
    # No requirements.txt? Install known deps manually
    .venv/bin/pip install -q flask flask-sock requests ytmusicapi cffi pycparser
}
echo "  -> venv ready"

# --- 3. Write config ---
echo "[3/5] Writing config..."
mkdir -p config
CFG="config/admin_config.json"

# Read existing config or start fresh
EXISTING=""
[ -f "$CFG" ] && EXISTING=$(cat "$CFG")

python3 -c "
import json, os, hashlib, secrets

cfg_path = '$CFG'
existing = {}
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        existing = json.load(f)

# Auto-generate password hash if not set
if 'password_hash' not in existing:
    pw = secrets.token_urlsafe(16)
    h = hashlib.sha256(pw.encode()).hexdigest()
    existing['password_hash'] = h
    print(f'  [SETUP] Generated admin password: {pw}')
    print(f'  [SETUP] Login at https://{os.environ.get(\"YTMT_SERVER\", \"your-server\")}:${PORT}/')

# Auto-generate secret_key if not set
if 'secret_key' not in existing:
    existing['secret_key'] = secrets.token_hex(32)

# Apply env var overrides
client_secret = os.environ.get('YTMT_CLIENT_SECRET')
client_id = os.environ.get('YTMT_CLIENT_ID')
if client_secret:
    existing['client_secret'] = client_secret
    print(f'  [CONFIG] client_secret set')
if client_id:
    existing['client_id'] = client_id
    print(f'  [CONFIG] client_id set')

with open(cfg_path, 'w') as f:
    json.dump(existing, f, indent=2)
print('  -> config written')
"

# --- 4. Kill old server ---
echo "[4/5] Stopping old server..."
pkill -f "python.*proxy_server.py" 2>/dev/null && echo "  -> killed old process" || echo "  -> no old process found"
sleep 1

# --- 5. Start server ---
echo "[5/5] Starting server on port $PORT..."
cd "$DIR"
nohup .venv/bin/python proxy_server.py > /dev/null 2>&1 &
NEWPID=$!
sleep 2

if kill -0 "$NEWPID" 2>/dev/null; then
    echo ""
    echo "=== Server running ==="
    echo "  PID:     $NEWPID"
    echo "  URL:     http://0.0.0.0:${PORT}"
    echo "  Logs:    $DIR/logs/server.log"
    echo "  Dashboard: https://${YTMT_SERVER:-your-server}:${PORT}/"
else
    echo ""
    echo "=== Server failed to start ==="
    echo "  Check: $DIR/logs/crash.log"
    tail -20 "$DIR/logs/crash.log" 2>/dev/null || true
    exit 1
fi
