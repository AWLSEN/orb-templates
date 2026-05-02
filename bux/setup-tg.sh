#!/bin/bash
# bux-setup-tg — interactive Telegram bot setup wizard.
#
# Run this from the ORB web terminal (https://api.orbcloud.dev/terminal/<id>)
# after deploy. Walks you through @BotFather, captures the bot token,
# generates a one-shot setup token, prints the deeplink for binding.
#
# When this script writes /etc/bux/tg.env, the supervisor in start.sh
# picks it up on its next watchdog tick (~5s) and starts telegram_bot.py.
# No manual restart needed.

set -e

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; red=$'\033[31m'; reset=$'\033[0m'

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo bux-setup-tg"; exit 1; }

cat <<EOF
${bold}════════════════════════════════════════════════════════════════${reset}
  bux — Telegram bot setup
${bold}════════════════════════════════════════════════════════════════${reset}

  This wizard captures your Telegram bot token and configures the bux
  supervisor to start the Telegram bot. You only run this once.

  ${bold}1. Create a bot with @BotFather${reset}

     • On Telegram, message ${bold}@BotFather${reset}: ${dim}https://t.me/BotFather${reset}
     • Send: ${bold}/newbot${reset}
     • Pick any name (e.g. "my bux")
     • Pick any unique username ending in _bot (e.g. ${bold}my_bux_bot${reset})
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
echo "  ${dim}validating with Telegram...${reset}"
ME_JSON=$(curl -fsSL --max-time 15 "https://api.telegram.org/bot${TOKEN}/getMe" 2>/dev/null || echo '{}')
USERNAME=$(printf '%s' "$ME_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",{}).get("username",""))' 2>/dev/null || true)

if [ -z "$USERNAME" ]; then
  echo "  ${red}getMe failed — token rejected by Telegram. Check it and rerun.${reset}"
  echo "  ${dim}response: ${ME_JSON}${reset}"
  exit 1
fi

SETUP_TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)

# Atomic write so the supervisor never sees a half-written file.
TMP=$(mktemp /etc/bux/tg.env.XXXX)
cat > "$TMP" <<EOF
TG_BOT_TOKEN=${TOKEN}
TG_SETUP_TOKEN=${SETUP_TOKEN}
EOF
chmod 640 "$TMP"
chgrp bux "$TMP" 2>/dev/null || true
mv "$TMP" /etc/bux/tg.env

# Clear any stale "first chat already bound" state from a previous setup run,
# so this new setup token actually controls the binding.
rm -f /etc/bux/tg-allowed.txt /etc/bux/tg-state.json /etc/bux/tg-queue.json 2>/dev/null || true

DEEPLINK="https://t.me/${USERNAME}?start=${SETUP_TOKEN}"

cat <<EOF

  ${green}✓ saved bot @${USERNAME}${reset}

  ${bold}2. Bind your chat${reset}

     Tap (or share to Telegram) the deeplink below. The first chat to
     redeem this link becomes the only one that can talk to your bux.
     Subsequent chats from anyone else are silently ignored.

     ${bold}${DEEPLINK}${reset}

  ${bold}3. Wait ~5 seconds${reset}

     The supervisor in /agent/code/start.sh polls every 5 seconds for
     this file to exist and starts telegram_bot.py automatically. Watch:

       tail -f /var/log/bux/tg.log

     Once the bot prints "starting" you can text it and it'll respond.

  ${dim}If you ever need to swap the bot or token, just rerun this script —
  it overwrites /etc/bux/tg.env and the supervisor picks up the change
  on the next watchdog tick.${reset}

EOF
