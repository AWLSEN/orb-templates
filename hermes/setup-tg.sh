#!/bin/bash
# hermes-setup-tg — interactive Telegram bot setup wizard.
#
# Run this from the ORB web terminal (https://api.orbcloud.dev/terminal/<id>)
# after deploy. Walks through @BotFather, captures the bot token, registers
# the webhook against the box's own subdomain, writes config to
# $HERMES_HOME/.env. The supervisor in start.sh notices the new env file
# and exec-replaces itself with `hermes gateway start`.

set -e

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; red=$'\033[31m'; reset=$'\033[0m'

HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
ENV_FILE="$HERMES_HOME/.env"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found — has the agent finished booting?" >&2; exit 1; }

# Pull subdomain that start.sh detected at boot. If hostname-based detection
# failed for any reason we fall back to asking.
SUBDOMAIN_URL=$(grep '^ORB_SUBDOMAIN_URL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)

cat <<EOF
${bold}════════════════════════════════════════════════════════════════${reset}
  hermes — Telegram bot setup
${bold}════════════════════════════════════════════════════════════════${reset}

  ${bold}1. Create a bot with @BotFather${reset}

     • On Telegram, message ${bold}@BotFather${reset}: ${dim}https://t.me/BotFather${reset}
     • Send: ${bold}/newbot${reset}
     • Pick any name (e.g. "my hermes")
     • Pick any unique username ending in _bot (e.g. ${bold}my_hermes_bot${reset})
     • BotFather replies with a token like ${dim}1234567890:ABC-def123...${reset}

EOF

while true; do
  printf "  ${bold}Paste the bot token:${reset} "
  read -r TOKEN
  TOKEN="${TOKEN// /}"
  if [ -z "$TOKEN" ]; then
    echo "  ${red}empty token, try again (or Ctrl-C to abort)${reset}"
    continue
  fi
  if ! printf '%s' "$TOKEN" | grep -Eq '^[0-9]+:[A-Za-z0-9_-]{30,}$'; then
    echo "  ${red}doesn't look like a Telegram bot token (expected <digits>:<random>)${reset}"
    continue
  fi
  break
done

echo ""
echo "  ${dim}validating token via Telegram getMe...${reset}"
ME_JSON=$(curl -fsSL --max-time 15 "https://api.telegram.org/bot${TOKEN}/getMe" 2>/dev/null || echo '{}')
USERNAME=$(printf '%s' "$ME_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",{}).get("username",""))' 2>/dev/null || true)

if [ -z "$USERNAME" ]; then
  echo "  ${red}getMe failed — token rejected by Telegram. Check it and rerun.${reset}"
  echo "  ${dim}response: ${ME_JSON}${reset}"
  exit 1
fi
echo "  ${green}✓ token valid, bot is @${USERNAME}${reset}"

# Confirm or override the subdomain.
if [ -z "$SUBDOMAIN_URL" ]; then
  printf "\n  ${bold}ORB subdomain URL${reset} (e.g. https://abc12345.orbcloud.dev): "
  read -r SUBDOMAIN_URL
  SUBDOMAIN_URL="${SUBDOMAIN_URL%/}"
fi

WEBHOOK_URL="${SUBDOMAIN_URL}/telegram"
WEBHOOK_SECRET=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)

# Register webhook with Telegram. setWebhook is idempotent — Telegram
# replaces any prior URL silently.
echo "  ${dim}registering webhook ${WEBHOOK_URL}...${reset}"
SET_JSON=$(curl -fsSL --max-time 15 -X POST \
  "https://api.telegram.org/bot${TOKEN}/setWebhook" \
  -d "url=${WEBHOOK_URL}" \
  -d "secret_token=${WEBHOOK_SECRET}" 2>/dev/null || echo '{}')
SET_OK=$(printf '%s' "$SET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok",False))' 2>/dev/null || echo "False")
if [ "$SET_OK" != "True" ]; then
  echo "  ${red}setWebhook failed:${reset}"
  echo "  ${dim}${SET_JSON}${reset}"
  exit 1
fi
echo "  ${green}✓ webhook registered with Telegram${reset}"

# Append (or replace) the relevant env keys atomically.
TMP=$(mktemp)
{
  grep -vE '^(TELEGRAM_BOT_TOKEN|TELEGRAM_WEBHOOK_URL|TELEGRAM_WEBHOOK_PORT|TELEGRAM_WEBHOOK_SECRET)=' "$ENV_FILE" 2>/dev/null || true
  echo "TELEGRAM_BOT_TOKEN=${TOKEN}"
  echo "TELEGRAM_WEBHOOK_URL=${WEBHOOK_URL}"
  echo "TELEGRAM_WEBHOOK_PORT=8443"
  echo "TELEGRAM_WEBHOOK_SECRET=${WEBHOOK_SECRET}"
} > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$ENV_FILE"

cat <<EOF

  ${green}✓ saved bot @${USERNAME}${reset}
  ${green}✓ webhook → ${WEBHOOK_URL}${reset}

  ${bold}2. Wait ~10 seconds${reset}

     The supervisor in /agent/code/start.sh polls every 10s for
     TELEGRAM_BOT_TOKEN to appear in $ENV_FILE and exec-replaces
     itself with \`hermes gateway start\` automatically. Watch:

       tail -f /var/log/hermes/gateway.log 2>/dev/null || journalctl -f

  ${bold}3. Send a test message${reset}

     Open ${bold}https://t.me/${USERNAME}${reset} on your phone and send any text.
     The first time will take a moment while the gateway boots; subsequent
     messages should be sub-second once the box wakes from sleep.

  ${dim}If you ever need to swap the bot or token, just rerun this script.${reset}

EOF
