#!/bin/bash
# bux entry point — runs as the agent process inside the ORB sandbox.
# Spawned on initial deploy + on every restart.
#
# Architecture: this is a thin watchdog that supervises two children:
#   - browser_keeper.py — always running, maintains the BU Cloud browser
#   - telegram_bot.py   — only running when /etc/bux/tg.env exists with a
#                         valid TG_BOT_TOKEN. Configured post-deploy via
#                         `bux-setup-tg` from the ORB web terminal.
#
# This decoupling means the user never has to set up a Telegram bot before
# running `deploy.sh`. They run deploy → open the web terminal → run
# `bux-setup-tg` → the watchdog picks up the bot env file on the next
# poll cycle (~5s) and starts telegram_bot.py automatically.

set -e
export PATH="/usr/local/bin:/usr/bin:/bin"
export HOME="/root"

# ── 1. Make sure bux's expected directory layout exists ────────────────────
mkdir -p /etc/bux /var/log/bux /var/lib/bux
mkdir -p /home/bux/.claude /home/bux/.bux/sessions /home/bux/workspaces
mkdir -p /home/bux/.config /home/bux/.npm-global

# ── 2. Write secret files from injected env vars ───────────────────────────
# bux's Python code reads /etc/bux/env as systemd-style EnvironmentFile=.
# Regenerate on every boot so secret rotation works without a rebuild.
: "${BROWSER_USE_API_KEY:?BROWSER_USE_API_KEY must be set — runtime should inject from org_secrets}"
: "${BUX_PROFILE_ID:?BUX_PROFILE_ID must be set — deploy.sh should auto-create this}"

cat > /etc/bux/env <<EOF
BROWSER_USE_API_KEY=${BROWSER_USE_API_KEY}
BUX_PROFILE_ID=${BUX_PROFILE_ID}
EOF
chmod 640 /etc/bux/env

chown -R bux:bux /home/bux /var/log/bux /var/lib/bux /opt/bux 2>/dev/null || true
chgrp bux /etc/bux/env 2>/dev/null || true

echo "=== bux supervisor starting ==="
echo "    started:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "    bu profile: ${BUX_PROFILE_ID}"
echo "==="

# ── 3. Helpers ─────────────────────────────────────────────────────────────

KEEPER_PID=""
TG_PID=""

start_keeper() {
  (
    set -a
    # shellcheck disable=SC1091
    source /etc/bux/env
    set +a
    cd /opt/bux/agent
    exec python3 browser_keeper.py
  ) >> /var/log/bux/keeper.log 2>&1 &
  KEEPER_PID=$!
  echo "[supervisor] keeper started pid=${KEEPER_PID}"
}

start_tg() {
  (
    set -a
    # shellcheck disable=SC1091
    source /etc/bux/env
    # shellcheck disable=SC1091
    source /etc/bux/tg.env
    set +a
    cd /opt/bux/agent
    exec python3 telegram_bot.py
  ) >> /var/log/bux/tg.log 2>&1 &
  TG_PID=$!
  echo "[supervisor] telegram_bot started pid=${TG_PID}"
}

is_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

tg_env_configured() {
  [ -f /etc/bux/tg.env ] && grep -q '^TG_BOT_TOKEN=.\+' /etc/bux/tg.env 2>/dev/null
}

# ── 4. Initial spawn ───────────────────────────────────────────────────────
start_keeper

if tg_env_configured; then
  echo "[supervisor] /etc/bux/tg.env present — starting telegram_bot"
  start_tg
else
  echo "[supervisor] /etc/bux/tg.env not yet configured."
  echo "[supervisor] Run 'bux-setup-tg' from the ORB web terminal to enable Telegram."
fi

# ── 5. Watchdog loop ───────────────────────────────────────────────────────
# Restart keeper if it dies. Start telegram_bot when tg.env appears, restart
# if it dies. Tear everything down cleanly on SIGTERM.

trap 'echo "[supervisor] SIGTERM, shutting down"; \
      [ -n "$TG_PID" ] && kill "$TG_PID" 2>/dev/null || true; \
      [ -n "$KEEPER_PID" ] && kill "$KEEPER_PID" 2>/dev/null || true; \
      wait; exit 0' TERM INT

while true; do
  sleep 5

  if ! is_alive "$KEEPER_PID"; then
    echo "[supervisor] keeper died, restarting in 5s"
    sleep 5
    start_keeper
  fi

  if tg_env_configured; then
    if ! is_alive "$TG_PID"; then
      [ -n "$TG_PID" ] && echo "[supervisor] telegram_bot died, restarting"
      start_tg
    fi
  fi
done
