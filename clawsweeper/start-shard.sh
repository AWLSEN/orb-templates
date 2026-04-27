#!/bin/bash
# clawsweeper-shard wrapper — runs ONE review pass for this replica's shard.
# Invoked on agent spawn AND fired hourly by ORB cron.

set -e

# PATH explicitly — the runtime sets PATH but symlinks make Node's spawn
# happy on overlay-backed paths. /agent/packages/bin contains symlinks to
# /usr/bin/git and /usr/bin/gh installed by the build step.
export PATH="/agent/packages/bin:/root/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ──────────────────────────────────────────────────────────────────────────────
# Codex auth — we accept either ChatGPT-mode auth.json or API-key mode.
# The deploy.sh decides which by setting CODEX_AUTH_JSON or OPENAI_API_KEY.
# ──────────────────────────────────────────────────────────────────────────────

mkdir -p $HOME/.codex
if [ -n "${CODEX_AUTH_JSON:-}" ]; then
  printf '%s' "$CODEX_AUTH_JSON" > $HOME/.codex/auth.json
  chmod 600 $HOME/.codex/auth.json
fi

# Point codex at ORB's per-computer LLM proxy regardless of auth mode.
# The proxy forwards verbatim to the [llm].base_url set in orb.toml.
# ORB_PROXY_URL is injected by the runtime at agent spawn AND on every
# cron-fired run, e.g. http://10.42.<subnet>.1:10000. Falling back to a
# bare default would silently bypass the proxy, so we fail loudly instead.
#
# Codex has TWO base-url config keys with different meanings:
#   - openai_base_url   = API-key mode (OPENAI_API_KEY)
#   - chatgpt_base_url  = ChatGPT-auth mode (CODEX_AUTH_JSON)
# Setting both ensures the proxy is used regardless of which auth mode
# the deploy chose. Without chatgpt_base_url, ChatGPT-auth runs go direct
# to chatgpt.com and silently bypass the proxy.
: "${ORB_PROXY_URL:?ORB_PROXY_URL not set — runtime must inject it}"
cat > $HOME/.codex/config.toml <<CONF
openai_base_url = "${ORB_PROXY_URL}"
chatgpt_base_url = "${ORB_PROXY_URL}"
CONF

# ──────────────────────────────────────────────────────────────────────────────
# Target repo clone — uses GITHUB_TOKEN so private repos work the same as
# public ones. On second+ invocation (cron-fired), git fetches updates.
# ──────────────────────────────────────────────────────────────────────────────

: "${CLAWSWEEPER_TARGET_REPO:?CLAWSWEEPER_TARGET_REPO must be set}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"

TARGET_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${CLAWSWEEPER_TARGET_REPO}"
if [ -d /agent/openclaw/.git ]; then
  cd /agent/openclaw && git fetch origin --depth=1 main >/dev/null 2>&1 || true
else
  git clone --depth=1 "$TARGET_URL" /agent/openclaw
fi

# ──────────────────────────────────────────────────────────────────────────────
# Review this shard's slice of the target repo.
# ORB injects ORB_REPLICA_INDEX (0..N-1) and ORB_REPLICA_COUNT (N) into the
# environment when the agent is spawned via /v1/swarms.
# ──────────────────────────────────────────────────────────────────────────────

cd /agent/code
echo "=== clawsweeper replica ${ORB_REPLICA_INDEX:-?}/${ORB_REPLICA_COUNT:-?} ==="
echo "    target: ${CLAWSWEEPER_TARGET_REPO}"
echo "    report: ${CLAWSWEEPER_REPORT_REPO:-${CLAWSWEEPER_TARGET_REPO}}"
echo "    triggered: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "==="

exec node dist/clawsweeper.js review \
  --shard-index "${ORB_REPLICA_INDEX:-0}" \
  --shard-count "${ORB_REPLICA_COUNT:-1}"
