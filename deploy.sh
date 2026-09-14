#!/bin/bash
# Deploy server to VPS via SSH
# Usage: bash deploy.sh [user@host]
#
# This script:
# 1. Pushes latest code from local main
# 2. SSHs into the VPS and runs git pull + restarts the server

set -e

HOST="${1:-root@ytmtranslate.chiuhuang.dev}"

echo "[1/3] Pushing local main..."
git push origin main

echo "[2/3] Deploying on $HOST..."
ssh "$HOST" 'bash -s' <<'REMOTE'
set -e
cd ~/ytmusicultimate 2>/dev/null || cd ~
git pull --ff-only origin main 2>/dev/null || {
    echo "git pull failed, fetching..."
    git fetch origin main
    git reset --hard origin/main
}

# Kill old server if running
pkill -f "python proxy_server.py" 2>/dev/null || true
sleep 1

# Start server in background with nohup
nohup python3 proxy_server.py > /dev/null 2>&1 &
echo "[OK] Server restarted (PID: $!)"
REMOTE

echo "[3/3] Done. Server should be live at https://$HOST:20016"
