#!/bin/bash
# hermes entry point — runs as the agent process inside the ORB sandbox.
#
# Architecture: thin supervisor that spawns `hermes gateway start` once
# Telegram is configured. Until then, runs in idle mode (just keeps the
# sandbox alive so the user can open the web terminal and run
# `hermes-setup-tg`).

set -e
export PATH="/usr/local/bin:/root/.local/bin:/usr/bin:/bin"
export HOME="/root"
export HERMES_HOME="${HERMES_HOME:-/root/.hermes}"

mkdir -p "$HERMES_HOME"

: "${GLM_API_KEY:?GLM_API_KEY must be set — runtime should inject from org_secrets}"

# ── 1. Make GLM_API_KEY visible to the hermes process ─────────────────────
# Hermes reads provider keys from .env in HERMES_HOME (or from process env).
# We append to .env idempotently so post-deploy edits via `hermes-setup-tg`
# (which appends TELEGRAM_BOT_TOKEN etc.) don't fight us.
if ! grep -q '^GLM_API_KEY=' "$HERMES_HOME/.env" 2>/dev/null; then
  echo "GLM_API_KEY=${GLM_API_KEY}" >> "$HERMES_HOME/.env"
  chmod 600 "$HERMES_HOME/.env"
fi

# ── 2. Auto-detect this computer's subdomain ──────────────────────────────
# Telegram webhook URL needs to be HTTPS to a publicly reachable URL. ORB's
# subdomain proxy fronts every computer at https://<short-id>.orbcloud.dev,
# where <short-id> is the first 8 chars of the computer UUID. The sandbox
# hostname is set by the runtime to the short ID, so we read it cheaply.
SHORT_ID=$(hostname 2>/dev/null | tr -d '\n')
if [ -n "$SHORT_ID" ]; then
  ORB_SUBDOMAIN_URL="https://${SHORT_ID}.orbcloud.dev"
  if ! grep -q '^ORB_SUBDOMAIN_URL=' "$HERMES_HOME/.env" 2>/dev/null; then
    echo "ORB_SUBDOMAIN_URL=${ORB_SUBDOMAIN_URL}" >> "$HERMES_HOME/.env"
  fi
fi

echo "=== hermes supervisor starting ==="
echo "    started:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "    home:       ${HERMES_HOME}"
echo "    subdomain:  ${ORB_SUBDOMAIN_URL:-(unknown — hostname returned empty)}"
echo "==="

# ── 3. Start the gateway if Telegram is configured, else wait ─────────────
tg_configured() {
  grep -q '^TELEGRAM_BOT_TOKEN=.\+' "$HERMES_HOME/.env" 2>/dev/null
}

if tg_configured; then
  echo "[supervisor] Telegram configured — starting hermes gateway"
  exec hermes gateway start
fi

echo "[supervisor] no TELEGRAM_BOT_TOKEN yet."
echo "[supervisor] open the ORB web terminal and run 'hermes-setup-tg'."
echo "[supervisor] the supervisor will pick up the bot token within 10s and start the gateway."

# Watchdog loop: poll for tg.env every 10s. Once configured, exec hermes gateway.
while true; do
  sleep 10
  if tg_configured; then
    echo "[supervisor] Telegram now configured — starting hermes gateway"
    exec hermes gateway start
  fi
done
