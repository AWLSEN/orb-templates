#!/bin/bash
# bux deploy.sh — provisions ONE ORB Cloud computer running the bux
# Telegram bot + Browser Use Cloud browser combo.
#
# Hosted at https://orbcloud.dev/templates/bux for curl-pipe-bash:
#
#     bash <(curl -fsSL https://orbcloud.dev/templates/bux)
#
# v0 scope: faithful port of upstream bux. Long-poll Telegram, BU Cloud
# browser, Anthropic Claude Code via `claude /login` post-deploy.
#
# Telegram bot is configured POST-DEPLOY via the in-sandbox wizard
# (`bux-setup-tg`), so users never need to visit @BotFather before
# running this script. Only ORB and Browser Use keys are required upfront.

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

require_env ORB_API_KEY BROWSER_USE_API_KEY

# Optional reuse: if BUX_PROFILE_ID is already set, we'll skip profile creation
# and reuse it. Otherwise deploy.sh asks BU to create a fresh profile per deploy
# so each deployment has its own browser state (cookies, logins, cache).
BUX_PROFILE_ID="${BUX_PROFILE_ID:-}"

# Random 6-char suffix so successive deploys don't collide on org-unique name.
SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
DEPLOY_NAME="${DEPLOY_NAME:-bux-${SUFFIX}}"

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
# Render orb.toml from the template — fetch the .tpl, runtime resolves ${VAR}
# in agent.env against org_secrets at deploy time.
# ──────────────────────────────────────────────────────────────────────────────

ORB_TOML=$(curl -fsSL "$TEMPLATE_BASE/orb.toml.tpl")

TOML_AS_JSON=$(printf '%s' "$ORB_TOML" | python3 -c '
import json, sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
print(json.dumps(tomllib.loads(sys.stdin.read())))
')

ORG_SECRETS=$(jq -n \
  --arg bu_key "$BROWSER_USE_API_KEY" \
  --arg profile "$BUX_PROFILE_ID" \
  '{
    BROWSER_USE_API_KEY: $bu_key,
    BUX_PROFILE_ID: $profile
   }')

# ──────────────────────────────────────────────────────────────────────────────
# Deploy.
# ──────────────────────────────────────────────────────────────────────────────

echo "→ deploy:    $DEPLOY_NAME"
echo "→ provider:  Browser Use Cloud + Anthropic (claude /login post-deploy)"
echo "→ resources: 4GB RAM, 8GB disk"
echo "→ telegram:  not yet configured — set up via bux-setup-tg post-deploy"
echo

RESPONSE=$(orb_swarm_create "$DEPLOY_NAME" 1 "$TOML_AS_JSON" "$ORG_SECRETS" 4096 8192)

SWARM_ID=$(echo "$RESPONSE" | jq -r '.swarm_id')
COMPUTER_ID=$(echo "$RESPONSE" | jq -r '.computers[0].id // empty')

if [ -z "$COMPUTER_ID" ]; then
  echo "ERROR: deploy failed — no member returned." >&2
  echo "$RESPONSE" | jq . >&2 || echo "$RESPONSE" >&2
  exit 1
fi

SHORT_ID=$(echo "$COMPUTER_ID" | cut -c1-8)

cat <<DEPLOYED

✓ deployed.

  Computer:     $COMPUTER_ID  (short: $SHORT_ID)
  Swarm:        $SWARM_ID
  BU profile:   $BUX_PROFILE_ID

  First boot takes ~2–4 minutes (apt + nodejs + npm + python deps).
  Once browser_keeper.py is up, /home/bux/.claude/browser.env appears.

──────────────────────────────────────────────────────────────────────────────
  next steps — open the ORB web terminal and run two commands
──────────────────────────────────────────────────────────────────────────────

  Terminal URL (paste your ORB_API_KEY when the page asks):

      https://api.orbcloud.dev/terminal/$COMPUTER_ID?key=\$ORB_API_KEY

  Then in the terminal:

      sudo -iu bux
      claude /login                 # OAuth in your laptop browser → paste code

      exit                          # back to root

      bux-setup-tg                  # interactive Telegram bot setup wizard

  bux-setup-tg walks you through @BotFather, captures the bot token,
  prints the deeplink to bind your chat. The supervisor picks up the
  config on its next 5-second tick — no manual restart needed.

──────────────────────────────────────────────────────────────────────────────

  Logs (tail from the web terminal):
    tail -f /var/log/bux/keeper.log     # browser session lifecycle
    tail -f /var/log/bux/tg.log         # Telegram bot (after setup)

  Tear down:
    curl -X DELETE -H "Authorization: Bearer \$ORB_API_KEY" \\
      https://api.orbcloud.dev/v1/swarms/$SWARM_ID

  And delete the BU profile (fresh state per deploy):
    curl -X DELETE -H "X-Browser-Use-API-Key: \$BROWSER_USE_API_KEY" \\
      https://api.browser-use.com/api/v3/profiles/$BUX_PROFILE_ID

DEPLOYED
