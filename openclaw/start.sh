#!/bin/bash
# OpenClaw Gateway entry point — runs as the agent process inside the ORB
# sandbox. Spawned on initial deploy + on every restart after sleep/wake.
#
# Idempotent: subsequent runs reuse the auth profile from the first run
# (~/.openclaw/agents/main/agent/auth-profiles.json) so we don't re-onboard
# on every wake.

set -e
export PATH="/root/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$HOME/.openclaw"

: "${ZAI_API_KEY:?ZAI_API_KEY must be set — runtime should inject from org_secrets}"

# Run onboard non-interactively the first time. The wizard supports
# --auth-choice zai-coding-global for the GLM Coding Plan, so we don't have
# to write auth-profiles.json by hand. Onboard:
#   - writes ~/.openclaw/agents/main/agent/auth-profiles.json with the key
#   - writes ~/.openclaw/openclaw.json with the right model + provider config
#   - sets default model to zai/glm-5.1 (the GLM coding plan flagship)
if [ ! -f "$HOME/.openclaw/agents/main/agent/auth-profiles.json" ]; then
  echo "=== first run: onboarding for Z.AI GLM Coding Plan ==="
  openclaw onboard \
    --non-interactive \
    --accept-risk \
    --auth-choice zai-coding-global \
    --zai-api-key "$ZAI_API_KEY" || true

  # Onboard sets gateway.bind=loopback by default — keep that. ORB's port
  # expose mechanism uses socat on the netns LAN IP, forwarding to loopback,
  # so binding the gateway directly to LAN would EADDRINUSE conflict with
  # socat. Loopback is correct.

  # Override zai.baseUrl from api.z.ai (default) to ORB's per-computer LLM
  # proxy. The runtime injects ANTHROPIC_BASE_URL but openclaw stores
  # provider URLs in models.providers.zai.baseUrl — so we patch the json
  # directly. This routes ALL openclaw LLM traffic through ORB's proxy:
  # dashboard LLM-call counter ticks, in-flight responses are buffered
  # across checkpoint, idle agents auto-checkpoint mid-LLM-call.
  if [ -n "${ORB_PROXY_URL:-}" ]; then
    python3 - <<PY
import json, os
p = os.path.expanduser("~/.openclaw/openclaw.json")
d = json.load(open(p))
d.setdefault("models", {}).setdefault("providers", {}).setdefault("zai", {})["baseUrl"] = os.environ["ORB_PROXY_URL"]
json.dump(d, open(p, "w"), indent=2)
print(f"  zai.baseUrl → {os.environ['ORB_PROXY_URL']} (ORB LLM proxy)")
PY
  fi
fi

echo "=== openclaw gateway starting ==="
echo "    started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "    bind:    loopback (socat exposes LAN:18789 → 127.0.0.1:18789)"
echo "==="

# Gateway in foreground; ORB's idle detector handles sleep, wake-on-request
# handles wake. No --install-daemon (no systemd in the sandbox).
exec openclaw gateway --port 18789 --verbose
