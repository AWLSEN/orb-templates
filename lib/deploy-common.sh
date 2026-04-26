# Shared helpers sourced by every template's deploy.sh.
# Not a standalone script — `source` it.

set -e
set -u

ORB_API_BASE="${ORB_API_BASE:-https://api.orbcloud.dev}"

# ──────────────────────────────────────────────────────────────────────────────
# require_env — error out if a required env var is missing or empty.
# Usage: require_env ORB_API_KEY GITHUB_TOKEN TARGET_REPO
# ──────────────────────────────────────────────────────────────────────────────

require_env() {
  local missing=()
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      missing+=("$var")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: required env var(s) not set: ${missing[*]}" >&2
    echo "       see the template README for what each one is for." >&2
    exit 1
  fi
}

# require_one_of — error if NONE of the named env vars are set.
# Usage: require_one_of OPENAI_API_KEY CODEX_AUTH_JSON
require_one_of() {
  for var in "$@"; do
    if [ -n "${!var:-}" ]; then
      return 0
    fi
  done
  echo "ERROR: one of these env vars must be set: $*" >&2
  exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
# orb_swarm_create — POST to /v1/swarms.
# Usage: orb_swarm_create <name> <replicas> <orb_config_json> <org_secrets_json>
# Echoes the swarm response JSON to stdout. Exits non-zero on HTTP error.
# ──────────────────────────────────────────────────────────────────────────────

orb_swarm_create() {
  local name="$1" replicas="$2" orb_config="$3" org_secrets="$4"

  local body
  body=$(jq -n \
    --arg name "$name" \
    --argjson replicas "$replicas" \
    --argjson orb_config "$orb_config" \
    --argjson org_secrets "$org_secrets" \
    '{name: $name, replicas: $replicas, orb_config: $orb_config, org_secrets: $org_secrets}')

  # Use --data-binary so curl doesn't strip newlines/whitespace from the body
  # (the build step's cron.json heredoc embeds literal \n chars in JSON strings).
  local resp http_code
  resp=$(printf '%s' "$body" | curl -sS -w '\n%{http_code}' -X POST "$ORB_API_BASE/v1/swarms" \
    -H "Authorization: Bearer $ORB_API_KEY" \
    -H "content-type: application/json" \
    --data-binary @-)
  http_code=$(printf '%s' "$resp" | tail -n1)
  resp=$(printf '%s' "$resp" | sed '$d')

  case "$http_code" in
    201)
      printf '%s' "$resp"
      ;;
    207)
      # partial failure — some replicas didn't deploy; still print the body
      echo "WARN: swarm partially deployed (HTTP 207 — see 'failed' field)" >&2
      printf '%s' "$resp"
      ;;
    401)
      echo "ERROR: ORB_API_KEY rejected (401). Check the key at https://orbcloud.dev/dashboard/keys" >&2
      exit 1
      ;;
    409)
      echo "ERROR: swarm name '$name' already exists in your org. Pick a different SWARM_NAME or delete the existing one first." >&2
      exit 1
      ;;
    *)
      echo "ERROR: HTTP $http_code from $ORB_API_BASE/v1/swarms" >&2
      echo "$resp" >&2
      exit 1
      ;;
  esac
}

# orb_swarm_status — GET /v1/swarms/{id}, return the response.
orb_swarm_status() {
  local swarm_id="$1"
  curl -sf "$ORB_API_BASE/v1/swarms/$swarm_id" \
    -H "Authorization: Bearer $ORB_API_KEY"
}

# ──────────────────────────────────────────────────────────────────────────────
# orb_computer_create_and_deploy — for single-shape templates (one computer,
# one agent, no replica context). Two-step: POST /v1/computers, then POST
# /v1/computers/{id}/agents. Echoes a simplified response with id + agents.
#
# Usage: orb_computer_create_and_deploy <name> <runtime_mb> <disk_mb> \
#                                       <orb_config_json> <org_secrets_json>
# ──────────────────────────────────────────────────────────────────────────────

orb_computer_create_and_deploy() {
  local name="$1" runtime_mb="$2" disk_mb="$3" orb_config="$4" org_secrets="$5"

  # Step 1: create the computer
  local create_body create_resp computer_id http_code
  create_body=$(jq -n --arg name "$name" --argjson rmb "$runtime_mb" --argjson dmb "$disk_mb" \
    '{name: $name, runtime_mb: $rmb, disk_mb: $dmb}')
  create_resp=$(printf '%s' "$create_body" | curl -sS -w '\n%{http_code}' -X POST "$ORB_API_BASE/v1/computers" \
    -H "Authorization: Bearer $ORB_API_KEY" \
    -H "content-type: application/json" \
    --data-binary @-)
  http_code=$(printf '%s' "$create_resp" | tail -n1)
  create_resp=$(printf '%s' "$create_resp" | sed '$d')

  if [ "$http_code" != "201" ] && [ "$http_code" != "200" ]; then
    echo "ERROR: HTTP $http_code creating computer" >&2
    echo "$create_resp" >&2
    exit 1
  fi
  computer_id=$(printf '%s' "$create_resp" | jq -r '.id')

  # Step 2: deploy the agent (no replica context — this is single-shape)
  local deploy_body deploy_resp
  deploy_body=$(jq -n --argjson cfg "$orb_config" --argjson secrets "$org_secrets" \
    '{orb_config: $cfg, org_secrets: $secrets}')
  deploy_resp=$(printf '%s' "$deploy_body" | curl -sS -w '\n%{http_code}' -X POST \
    "$ORB_API_BASE/v1/computers/$computer_id/agents" \
    -H "Authorization: Bearer $ORB_API_KEY" \
    -H "content-type: application/json" \
    --data-binary @-)
  http_code=$(printf '%s' "$deploy_resp" | tail -n1)
  deploy_resp=$(printf '%s' "$deploy_resp" | sed '$d')

  if [ "$http_code" != "201" ] && [ "$http_code" != "200" ]; then
    echo "ERROR: HTTP $http_code deploying agent to $computer_id" >&2
    echo "$deploy_resp" >&2
    exit 1
  fi

  # Echo a unified response shape so deploy.sh can pretty-print
  jq -n --arg cid "$computer_id" --argjson dep "$deploy_resp" \
    '{shape: "single", computer_id: $cid, deploy: $dep}'
}

# print_computer_summary — pretty-print a single-shape deploy response.
print_computer_summary() {
  local resp="$1"
  echo "$resp" | jq -r '
    "computer_id: \(.computer_id)",
    "agents:     \(.deploy.agents | length) deployed",
    (.deploy.agents[] | "  pid \(.pid) on port \(.port)")
  '
}

# print_swarm_summary — pretty-print a swarm response.
print_swarm_summary() {
  local resp="$1"
  echo "$resp" | jq -r '
    "swarm_id: \(.swarm_id)",
    "name:     \(.name)",
    "deployed: \(.deployed) / \(.replicas)",
    (if (.failed | length) > 0 then "failed: \(.failed)" else empty end),
    "members:",
    (.computers[] | "  replica \(.replica_index): \(.id) → https://\(.subdomain)/")
  '
}
