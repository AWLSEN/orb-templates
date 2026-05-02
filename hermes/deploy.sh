#!/bin/bash
# hermes deploy.sh (GLM Coding Plan variant) — provisions ONE ORB Cloud
# computer running Hermes Agent backed by Z.AI's GLM Coding Plan.
#
# Hosted at https://orbcloud.dev/templates/hermes for curl-pipe-bash:
#
#     bash <(curl -fsSL https://orbcloud.dev/templates/hermes)
#
# Telegram bot is configured POST-DEPLOY via `hermes-setup-tg` from the
# ORB web terminal — no @BotFather visit required before deploy.

set -e
set -u

TEMPLATE_BASE="${TEMPLATE_BASE:-https://raw.githubusercontent.com/AWLSEN/orb-templates/main/hermes}"

# Source shared helpers (orb_swarm_create, require_env, etc.)
LIB_TMP=$(mktemp -d)
trap 'rm -rf "$LIB_TMP"' EXIT
curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/lib/deploy-common.sh -o "$LIB_TMP/lib.sh"
# shellcheck disable=SC1091
source "$LIB_TMP/lib.sh"

# ──────────────────────────────────────────────────────────────────────────────
# Inputs (env vars)
# ──────────────────────────────────────────────────────────────────────────────

# GLM_API_KEY is the canonical name; ZAI_API_KEY is an alias upstream Hermes
# accepts. We accept either and forward as GLM_API_KEY into the sandbox.
if [ -z "${GLM_API_KEY:-}" ] && [ -n "${ZAI_API_KEY:-}" ]; then
  GLM_API_KEY="$ZAI_API_KEY"
fi
require_env ORB_API_KEY GLM_API_KEY

SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
DEPLOY_NAME="${DEPLOY_NAME:-hermes-${SUFFIX}}"

# ──────────────────────────────────────────────────────────────────────────────
# Render orb.toml from the template — runtime resolves ${VAR} in agent.env
# against org_secrets at deploy time.
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
  --arg glm_key "$GLM_API_KEY" \
  '{ GLM_API_KEY: $glm_key }')

# ──────────────────────────────────────────────────────────────────────────────
# Deploy.
# ──────────────────────────────────────────────────────────────────────────────

echo "→ deploy:    $DEPLOY_NAME"
echo "→ provider:  Z.AI GLM Coding Plan (zai/glm-4.7 default)"
echo "→ resources: 2GB RAM, 8GB disk"
echo "→ exposes:   port 8443 (Telegram webhook receiver)"
echo "→ telegram:  not yet configured — set up via hermes-setup-tg post-deploy"
echo

RESPONSE=$(orb_swarm_create "$DEPLOY_NAME" 1 "$TOML_AS_JSON" "$ORG_SECRETS" 2048 8192)

SWARM_ID=$(echo "$RESPONSE" | jq -r '.swarm_id')
COMPUTER_ID=$(echo "$RESPONSE" | jq -r '.computers[0].id // empty')
SUBDOMAIN_URL=$(echo "$RESPONSE" | jq -r '"https://" + .computers[0].subdomain + "/"')

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
  Subdomain:    $SUBDOMAIN_URL  (Telegram webhook lands here)

  First boot takes ~3-5 minutes (uv install + cloning hermes-agent +
  uv pip install -e '.[messaging,cron,cli,pty,mcp]'). Hermes is heavier
  than openclaw — it's a full agent framework with messaging integrations,
  not just a gateway.

──────────────────────────────────────────────────────────────────────────────
  next steps — open the ORB web terminal and run one command
──────────────────────────────────────────────────────────────────────────────

  Terminal URL (paste your ORB_API_KEY when the page asks):

      https://api.orbcloud.dev/terminal/$COMPUTER_ID?key=\$ORB_API_KEY

  Then in the terminal:

      hermes-setup-tg              # interactive Telegram bot setup wizard

  hermes-setup-tg walks you through @BotFather, captures the bot token,
  registers the Telegram webhook against this box's subdomain, writes
  config to /root/.hermes/.env. The supervisor in start.sh picks up
  the new env file within 10s and starts \`hermes gateway start\`.

  After setup, send your bot a message — the first one wakes the agent
  in <1s if it's asleep, then GLM responds.

──────────────────────────────────────────────────────────────────────────────

  Logs (tail from the web terminal):
    journalctl -f                          # if hermes uses systemd-style logging
    tail -f /var/log/hermes/*.log 2>/dev/null

  Tear down:
    curl -X DELETE -H "Authorization: Bearer \$ORB_API_KEY" \\
      https://api.orbcloud.dev/v1/swarms/$SWARM_ID

DEPLOYED
