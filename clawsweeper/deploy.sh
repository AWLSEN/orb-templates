#!/bin/bash
# clawsweeper deploy.sh — reads env vars, posts to ORB /v1/swarms.
# Hosted at https://orbcloud.dev/templates/clawsweeper for the curl-pipe-bash UX:
#
#     bash <(curl -fsSL https://orbcloud.dev/templates/clawsweeper)
#
# See https://orbcloud.dev/use-cases/clawsweeper/ for the full walkthrough.

set -e
set -u

TEMPLATE_BASE="${TEMPLATE_BASE:-https://raw.githubusercontent.com/AWLSEN/orb-templates/main/clawsweeper}"

# Source shared helpers (orb_swarm_create, require_env, etc.)
# When this script runs via curl-pipe-bash, /tmp/orb-claw-deploy is a fresh dir.
LIB_TMP=$(mktemp -d)
trap 'rm -rf "$LIB_TMP"' EXIT
curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/lib/deploy-common.sh -o "$LIB_TMP/lib.sh"
# shellcheck disable=SC1091
source "$LIB_TMP/lib.sh"

# ──────────────────────────────────────────────────────────────────────────────
# Inputs (env vars)
# ──────────────────────────────────────────────────────────────────────────────

require_env ORB_API_KEY GITHUB_TOKEN TARGET_REPO
require_one_of OPENAI_API_KEY CODEX_AUTH_JSON

REPORT_REPO="${REPORT_REPO:-$TARGET_REPO}"
REPLICAS="${REPLICAS:-5}"
CRON_SCHEDULE="${CRON_SCHEDULE:-17 * * * *}"

# Deterministic default name based on target repo.
TARGET_REPO_SHORT=$(echo "$TARGET_REPO" | tr '/' '-')
SWARM_NAME="${SWARM_NAME:-clawsweeper-${TARGET_REPO_SHORT}}"

# Pick LLM base_url and validate exactly-one auth mode.
if [ -n "${OPENAI_API_KEY:-}" ] && [ -n "${CODEX_AUTH_JSON:-}" ]; then
  echo "ERROR: set EITHER OPENAI_API_KEY or CODEX_AUTH_JSON, not both" >&2
  exit 1
fi
if [ -n "${OPENAI_API_KEY:-}" ]; then
  LLM_BASE_URL="https://api.openai.com/v1"
  AUTH_MODE="openai-api-key"
  CODEX_AUTH_JSON=""
else
  LLM_BASE_URL="https://chatgpt.com/backend-api/codex"
  AUTH_MODE="chatgpt-auth"
  OPENAI_API_KEY=""
fi

# ──────────────────────────────────────────────────────────────────────────────
# Render orb.toml from the template — fetch the .tpl, sed in real values.
# ──────────────────────────────────────────────────────────────────────────────

ORB_TOML=$(curl -fsSL "$TEMPLATE_BASE/orb.toml.tpl" \
  | sed -e "s|@TARGET_REPO@|$TARGET_REPO|g" \
        -e "s|@REPORT_REPO@|$REPORT_REPO|g" \
        -e "s|@LLM_BASE_URL@|$LLM_BASE_URL|g" \
        -e "s|@CRON_SCHEDULE@|$CRON_SCHEDULE|g")

# Convert TOML → JSON for the API body. The runtime accepts JSON for orb_config.
# We use python's tomllib (3.11+) which is on every modern bm/vps; users on old
# python can pip install tomli first. Fail loudly if neither is present.
TOML_AS_JSON=$(printf '%s' "$ORB_TOML" | python3 - <<'PY'
import json, sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
print(json.dumps(tomllib.loads(sys.stdin.read())))
PY
)

# ──────────────────────────────────────────────────────────────────────────────
# Compose org_secrets — the runtime resolves ${VAR} in agent.env against this.
# ──────────────────────────────────────────────────────────────────────────────

ORG_SECRETS=$(jq -n \
  --arg gh "$GITHUB_TOKEN" \
  --arg openai "$OPENAI_API_KEY" \
  --arg codex_auth "$CODEX_AUTH_JSON" \
  '{
    GITHUB_TOKEN: $gh,
    OPENAI_API_KEY: $openai,
    CODEX_AUTH_JSON: $codex_auth
   } | with_entries(select(.value != ""))')

# ──────────────────────────────────────────────────────────────────────────────
# Deploy.
# ──────────────────────────────────────────────────────────────────────────────

echo "→ swarm: $SWARM_NAME"
echo "→ target: $TARGET_REPO"
echo "→ report: $REPORT_REPO"
echo "→ replicas: $REPLICAS"
echo "→ auth: $AUTH_MODE"
echo "→ cron: $CRON_SCHEDULE"
echo

RESPONSE=$(orb_swarm_create "$SWARM_NAME" "$REPLICAS" "$TOML_AS_JSON" "$ORG_SECRETS")

echo "deployed:"
print_swarm_summary "$RESPONSE"

SWARM_ID=$(echo "$RESPONSE" | jq -r '.swarm_id')
echo
echo "Status:    GET    https://api.orbcloud.dev/v1/swarms/$SWARM_ID"
echo "Tear down: DELETE https://api.orbcloud.dev/v1/swarms/$SWARM_ID"
echo "Use-case:  https://orbcloud.dev/use-cases/clawsweeper/"
