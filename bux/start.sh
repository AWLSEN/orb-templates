#!/bin/bash
# bux entry point — runs as the agent process inside the ORB sandbox.
# Spawned on initial deploy + on every restart.
#
# Idempotent: env files are rewritten on every boot from injected secrets;
# the bux Python processes then re-read them.

set -e
export PATH="/usr/local/bin:/usr/bin:/bin"
export HOME="/root"

# ── 1. Make sure bux's expected directory layout exists ────────────────────
# (Build steps already created these, but recreate idempotently in case the
# computer rootfs got partially wiped or the bux user state was reset.)
mkdir -p /etc/bux /var/log/bux /var/lib/bux
mkdir -p /home/bux/.claude /home/bux/.bux/sessions /home/bux/workspaces
mkdir -p /home/bux/.config /home/bux/.npm-global

# ── 2. Write secret files from injected env vars ───────────────────────────
# bux's Python code reads these as systemd-style EnvironmentFile=. We
# regenerate them on every boot so secret rotation works without a rebuild.
: "${BROWSER_USE_API_KEY:?BROWSER_USE_API_KEY must be set — runtime should inject from org_secrets}"
: "${BUX_PROFILE_ID:?BUX_PROFILE_ID must be set — deploy.sh should auto-create this}"
: "${TG_BOT_TOKEN:?TG_BOT_TOKEN must be set — runtime should inject from org_secrets}"
: "${TG_SETUP_TOKEN:?TG_SETUP_TOKEN must be set — deploy.sh should generate this}"

cat > /etc/bux/env <<EOF
BROWSER_USE_API_KEY=${BROWSER_USE_API_KEY}
BUX_PROFILE_ID=${BUX_PROFILE_ID}
EOF
chmod 640 /etc/bux/env

cat > /etc/bux/tg.env <<EOF
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_SETUP_TOKEN=${TG_SETUP_TOKEN}
EOF
chmod 640 /etc/bux/tg.env

# Ownership: prefer bux user where the user exists (fresh build) but don't
# fail the boot if it doesn't (warm restart, partial rootfs, etc.).
chown -R bux:bux /home/bux /var/log/bux /var/lib/bux /opt/bux 2>/dev/null || true
chgrp bux /etc/bux/env /etc/bux/tg.env 2>/dev/null || true

echo "=== bux starting ==="
echo "    started:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "    bu profile: ${BUX_PROFILE_ID}"
echo "    bot token:  ${TG_BOT_TOKEN%%:*}:****"
echo "==="

# ── 3. Browser keeper in background ────────────────────────────────────────
# Maintains the BU Cloud browser session, writes /home/bux/.claude/browser.env
# every ~3.5 hours on rotation. Logs to /var/log/bux/keeper.log so you can
# tail it from the ORB web terminal if a session fails to come up.
(
  set -a
  # shellcheck disable=SC1091
  source /etc/bux/env
  set +a
  cd /opt/bux/agent
  exec python3 browser_keeper.py
) >> /var/log/bux/keeper.log 2>&1 &
KEEPER_PID=$!
echo "    keeper pid: ${KEEPER_PID}"

# Wait for browser.env to land — claude's browser-harness skill requires
# BU_CDP_WS to be readable before the agent can drive the browser. 60s
# is generous; first session usually comes up in 8-15s.
echo "    waiting for browser.env..."
for i in $(seq 1 30); do
  if [ -f /home/bux/.claude/browser.env ]; then
    echo "    browser session up after ${i}x2s"
    break
  fi
  if ! kill -0 "$KEEPER_PID" 2>/dev/null; then
    echo "ERROR: keeper exited before browser.env was written" >&2
    tail -30 /var/log/bux/keeper.log >&2 || true
    exit 1
  fi
  sleep 2
done
[ -f /home/bux/.claude/browser.env ] || {
  echo "ERROR: keeper failed to produce browser.env after 60s" >&2
  tail -30 /var/log/bux/keeper.log >&2 || true
  exit 1
}

# ── 4. Telegram bot in foreground ──────────────────────────────────────────
# This is the long-running entry the runtime monitors. If the bot exits
# (token revoked, network gone, etc.), the agent process exits and ORB
# can re-spawn or surface the failure.
(
  set -a
  # shellcheck disable=SC1091
  source /etc/bux/env
  # shellcheck disable=SC1091
  source /etc/bux/tg.env
  set +a
  cd /opt/bux/agent
  exec python3 telegram_bot.py
) 2>&1 | tee -a /var/log/bux/tg.log
