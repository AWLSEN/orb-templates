#!/bin/bash
# bux deploy.sh — provisions ONE ORB Cloud computer running the bux
# Telegram bot + Browser Use Cloud browser combo, exposed via the
# Telegram side (no public HTTP).
#
# Hosted at https://orbcloud.dev/templates/bux for curl-pipe-bash:
#
#     bash <(curl -fsSL https://orbcloud.dev/templates/bux)
#
# v0 scope: faithful port of upstream bux. Long-poll Telegram, BU Cloud
# browser, Anthropic Claude Code via `claude /login` post-deploy. Pinned
# in RAM (sleep = "never") because polling + keeper rotation block the
# idle detector — see orb.toml.tpl for the rationale and the v0.5 plan.

set -e
set -u

TEMPLATE_BASE="${TEMPLATE_BASE:-https://raw.githubusercontent.com/AWLSEN/orb-templates/main/bux}"

# Source shared helpers (orb_swarm_create, require_env, etc.)
LIB_TMP=$(mktemp -d)
trap 'rm -rf "$LIB_TMP"' EXIT
curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/lib/deploy-common.sh -o "$LIB_TMP/lib.sh"
# shellcheck disable=SC1091
source "$LIB_TMP/lib.sh"

# ──────────────────────────────────────────────────────────────────────────────
# Inputs (env vars)
# ──────────────────────────────────────────────────────────────────────────────

require_env ORB_API_KEY BROWSER_USE_API_KEY TG_BOT_TOKEN

# Optional reuse: if BUX_PROFILE_ID is already set, we'll skip profile creation
# and reuse it. Otherwise deploy.sh asks BU to create a fresh profile per deploy
# so each deployment has its own browser state (cookies, logins, cache).
BUX_PROFILE_ID="${BUX_PROFILE_ID:-}"

# Random 6-char suffix so successive deploys don't collide on org-unique name.
SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
DEPLOY_NAME="${DEPLOY_NAME:-bux-${SUFFIX}}"

# Deeplink-based first-chat binding token. bux's telegram_bot.py reads this
# from /etc/bux/tg.env and accepts whichever Telegram chat redeems
# `/start <TG_SETUP_TOKEN>` first; subsequent chats are silently dropped.
TG_SETUP_TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)

# ──────────────────────────────────────────────────────────────────────────────
# Auto-create a Browser Use Cloud profile (one per deploy, by default).
# ──────────────────────────────────────────────────────────────────────────────

if [ -z "$BUX_PROFILE_ID" ]; then
  echo "→ creating BU Cloud profile..."
  PROFILE_JSON=$(curl -fsSL --max-time 15 -X POST "https://api.browser-use.com/api/v3/profiles" \
    -H "X-Browser-Use-API-Key: $BROWSER_USE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$DEPLOY_NAME\"}" 2>&1)
  BUX_PROFILE_ID=$(echo "$PROFILE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])' 2>/dev/null) || {
    echo "ERROR: BU profile creation failed." >&2
    echo "$PROFILE_JSON" >&2
    exit 1
  }
  echo "   profile_id: $BUX_PROFILE_ID"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Render orb.toml from the template — fetch the .tpl, no substitutions needed
# (everything that varies is a ${VAR} secret reference resolved at deploy time
# by the cloud, not template-rendered).
# ──────────────────────────────────────────────────────────────────────────────

ORB_TOML=$(curl -fsSL "$TEMPLATE_BASE/orb.toml.tpl")

# Convert TOML → JSON for the API body (the runtime accepts JSON for orb_config).
TOML_AS_JSON=$(printf '%s' "$ORB_TOML" | python3 -c '
import json, sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
print(json.dumps(tomllib.loads(sys.stdin.read())))
')

# ──────────────────────────────────────────────────────────────────────────────
# Compose org_secrets — runtime resolves ${VAR} in agent.env against this.
# ──────────────────────────────────────────────────────────────────────────────

ORG_SECRETS=$(jq -n \
  --arg bu_key "$BROWSER_USE_API_KEY" \
  --arg profile "$BUX_PROFILE_ID" \
  --arg tg_token "$TG_BOT_TOKEN" \
  --arg setup_token "$TG_SETUP_TOKEN" \
  '{
    BROWSER_USE_API_KEY: $bu_key,
    BUX_PROFILE_ID: $profile,
    TG_BOT_TOKEN: $tg_token,
    TG_SETUP_TOKEN: $setup_token
   }')

# ──────────────────────────────────────────────────────────────────────────────
# Deploy.
# ──────────────────────────────────────────────────────────────────────────────

echo "→ deploy:    $DEPLOY_NAME"
echo "→ provider:  Browser Use Cloud + Anthropic (via claude /login post-deploy)"
echo "→ resources: 4GB RAM, 8GB disk"
echo "→ exposes:   none (Telegram is outbound long-poll)"
echo

# Single-computer deploy via /v1/swarms with replicas=1. Pass explicit
# runtime_mb/disk_mb (4096/8192) to override the migration default of
# 512/1024 — bux's claude + node + python footprint exceeds the default.
RESPONSE=$(orb_swarm_create "$DEPLOY_NAME" 1 "$TOML_AS_JSON" "$ORG_SECRETS" 4096 8192)

# Extract the single member's computer ID.
SWARM_ID=$(echo "$RESPONSE" | jq -r '.swarm_id')
COMPUTER_ID=$(echo "$RESPONSE" | jq -r '.computers[0].id // empty')
SUBDOMAIN_URL=$(echo "$RESPONSE" | jq -r '"https://" + .computers[0].subdomain + "/"')

if [ -z "$COMPUTER_ID" ]; then
  echo "ERROR: deploy failed — no member returned." >&2
  echo "$RESPONSE" | jq . >&2 || echo "$RESPONSE" >&2
  exit 1
fi

SHORT_ID=$(echo "$COMPUTER_ID" | cut -c1-8)

# Resolve the bot username so we can render a working deeplink.
BOT_INFO=$(curl -sS --max-time 10 "https://api.telegram.org/bot${TG_BOT_TOKEN}/getMe" 2>/dev/null || echo '{}')
BOT_USERNAME=$(echo "$BOT_INFO" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("result",{}).get("username",""))' 2>/dev/null || echo '')
if [ -n "$BOT_USERNAME" ]; then
  DEEPLINK="https://t.me/${BOT_USERNAME}?start=${TG_SETUP_TOKEN}"
else
  DEEPLINK="(could not resolve bot username — check TG_BOT_TOKEN; fall back to messaging the bot manually with: /start ${TG_SETUP_TOKEN})"
fi

cat <<DEPLOYED

✓ deployed.

  Computer:     $COMPUTER_ID  (short: $SHORT_ID)
  Swarm:        $SWARM_ID
  Subdomain:    $SUBDOMAIN_URL  (no HTTP gateway — see "talk to your bot")
  BU profile:   $BUX_PROFILE_ID

  First boot takes ~2–4 minutes (apt + npm install + node modules build).
  After that, browser_keeper warms a BU session in ~10s.

──────────────────────────────────────────────────────────────────────────────
  next steps — in this exact order
──────────────────────────────────────────────────────────────────────────────

  1. Open the ORB web terminal so you can complete \`claude /login\`:

       https://api.orbcloud.dev/terminal/$COMPUTER_ID?key=\$ORB_API_KEY

     (paste your ORB_API_KEY when the page asks)

  2. In that terminal, become the bux user and authenticate Claude Code:

       sudo -iu bux
       claude /login

     OAuth opens in your laptop browser; paste the resulting code back into
     the terminal. After this, claude reuses the saved auth on every wake.

  3. Bind the Telegram bot. Open this link on your phone (or anywhere
     Telegram is signed in) and tap "start":

       $DEEPLINK

     The first chat to redeem this link binds the bot. Subsequent chats
     are silently ignored — first-chat-wins is bux's anti-hijack model.

  4. Text your bot. Try:

       you: hi
       bot: 🔒 This bot is now locked to this chat only.
       you: visit https://browser-use.com and tell me the page title

──────────────────────────────────────────────────────────────────────────────

  Logs (tail from the ORB web terminal):
    tail -f /var/log/bux/keeper.log     # browser session lifecycle
    tail -f /var/log/bux/tg.log         # Telegram bot

  Tear down:
    curl -X DELETE -H "Authorization: Bearer \$ORB_API_KEY" \\
      https://api.orbcloud.dev/v1/swarms/$SWARM_ID

  And delete the BU profile (fresh state per deploy):
    curl -X DELETE -H "X-Browser-Use-API-Key: \$BROWSER_USE_API_KEY" \\
      https://api.browser-use.com/api/v3/profiles/$BUX_PROFILE_ID

DEPLOYED
