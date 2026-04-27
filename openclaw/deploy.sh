#!/bin/bash
# OpenClaw deploy.sh — provisions ONE ORB Cloud computer running an OpenClaw
# Gateway, exposed at https://<id>.orbcloud.dev (port 18789).
#
# Hosted at https://orbcloud.dev/templates/openclaw for curl-pipe-bash:
#
#     bash <(curl -fsSL https://orbcloud.dev/templates/openclaw)
#
# Phase 1 scope: GLM (Z.AI Anthropic-compatible) only. No channels — talk to
# your gateway via HTTP at <id>.orbcloud.dev. Channels (Telegram/Discord/Slack)
# come in Phase 2.

set -e
set -u

TEMPLATE_BASE="${TEMPLATE_BASE:-https://raw.githubusercontent.com/AWLSEN/orb-templates/main/openclaw}"

# Source shared helpers (orb_swarm_create, require_env, etc.)
LIB_TMP=$(mktemp -d)
trap 'rm -rf "$LIB_TMP"' EXIT
curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/lib/deploy-common.sh -o "$LIB_TMP/lib.sh"
# shellcheck disable=SC1091
source "$LIB_TMP/lib.sh"

# ──────────────────────────────────────────────────────────────────────────────
# Inputs (env vars)
# ──────────────────────────────────────────────────────────────────────────────

require_env ORB_API_KEY ZAI_API_KEY

# Random 6-char suffix so successive deploys don't collide on org-unique name.
SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)
DEPLOY_NAME="${DEPLOY_NAME:-openclaw-${SUFFIX}}"

# ──────────────────────────────────────────────────────────────────────────────
# Render orb.toml from the template — fetch the .tpl, no substitutions needed
# in Phase 1 (everything that varies is a ${VAR} secret reference resolved at
# deploy time by the cloud, not template-rendered).
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
# Compose org_secrets — the runtime resolves ${VAR} in agent.env against this.
# ──────────────────────────────────────────────────────────────────────────────

ORG_SECRETS=$(jq -n \
  --arg zai "$ZAI_API_KEY" \
  '{ZAI_API_KEY: $zai}')

# ──────────────────────────────────────────────────────────────────────────────
# Deploy.
# ──────────────────────────────────────────────────────────────────────────────

echo "→ deploy:    $DEPLOY_NAME"
echo "→ provider:  Z.AI (GLM, via Anthropic-compatible endpoint)"
echo "→ runtime:   2GB RAM, 4GB disk"
echo "→ exposes:   port 18789 (OpenClaw Gateway)"
echo

# Single-computer deploy via /v1/swarms with replicas=1. The swarm primitive
# already handles config-upload + build + secrets-persist + subdomain
# provisioning in one call; reusing it for "deploy one" is the simplest path.
RESPONSE=$(orb_swarm_create "$DEPLOY_NAME" 1 "$TOML_AS_JSON" "$ORG_SECRETS")

# Extract the single member's computer ID + subdomain URL.
SWARM_ID=$(echo "$RESPONSE" | jq -r '.swarm_id')
COMPUTER_ID=$(echo "$RESPONSE" | jq -r '.computers[0].id // empty')
SUBDOMAIN_URL=$(echo "$RESPONSE" | jq -r '"https://" + .computers[0].subdomain + "/"')

if [ -z "$COMPUTER_ID" ]; then
  echo "ERROR: deploy failed — no member returned." >&2
  echo "$RESPONSE" | jq . >&2 || echo "$RESPONSE" >&2
  exit 1
fi

# A short ID for the UX — first 8 chars of the UUID.
SHORT_ID=$(echo "$COMPUTER_ID" | cut -c1-8)

cat <<DEPLOYED

✓ deployed.

  Gateway URL:  $SUBDOMAIN_URL
  Health:       ${SUBDOMAIN_URL}healthz
  Computer:     $COMPUTER_ID  (short: $SHORT_ID)

  Cold-start (first wake) takes ~10–15s while npm finishes install.
  Subsequent wakes are < 1s (CRIU restore from incremental checkpoint).

  → Open the Gateway UI:        $SUBDOMAIN_URL
  → Open the web terminal:      https://api.orbcloud.dev/terminal/$COMPUTER_ID?key=\$ORB_API_KEY
  → Send a message via curl:    curl -X POST $SUBDOMAIN_URL/api/agent/messages -H 'content-type: application/json' -d '{"message":"hello"}'

  Tear down: curl -X DELETE -H "Authorization: Bearer \$ORB_API_KEY" \\
               https://api.orbcloud.dev/v1/swarms/$SWARM_ID

DEPLOYED
