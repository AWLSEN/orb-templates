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
#   - sets default model to zai/glm-5.1 (we override below — see GLM-4.7 note)
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

  # Two openclaw.json patches before first gateway start:
  #
  # 1. zai.baseUrl → ORB's per-computer LLM proxy. Onboard sets it to
  #    api.z.ai directly; we point it at the proxy so traffic is observable
  #    (dashboard counter, checkpoint-buffer-during-LLM-call). Verified live
  #    with the SIGSTOP+forward+SIGCONT trace.
  #
  # 2. agents.defaults.model.primary → zai/glm-4.7 (override onboard's
  #    glm-5.1 default). Z.AI's GLM Coding Plan applies a per-second
  #    concurrent-request rate cap to glm-5.1 that openclaw's tight
  #    retry-on-429 loop trips immediately (verified with direct burst
  #    tests: 5/8 HTTP 429 with error code 1302). glm-4.7 doesn't get
  #    rate-capped as aggressively under the same plan tier.
  python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.openclaw/openclaw.json")
d = json.load(open(p))

proxy_url = os.environ.get("ORB_PROXY_URL")
if proxy_url:
    d.setdefault("models", {}).setdefault("providers", {}).setdefault("zai", {})["baseUrl"] = proxy_url
    print(f"  zai.baseUrl → {proxy_url}")

# Override default model from glm-5.1 (rate-capped on burst) → glm-4.7
d.setdefault("agents", {}).setdefault("defaults", {})["model"] = {"primary": "zai/glm-4.7"}
d["agents"]["defaults"].setdefault("models", {})["zai/glm-4.7"] = {"alias": "GLM"}
print("  agents.defaults.model.primary → zai/glm-4.7")

json.dump(d, open(p, "w"), indent=2)
PY
fi

echo "=== openclaw gateway starting ==="
echo "    started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "    bind:    loopback (socat exposes LAN:18789 → 127.0.0.1:18789)"
echo "==="

# Gateway in foreground; ORB's idle detector handles sleep, wake-on-request
# handles wake. No --install-daemon (no systemd in the sandbox).
exec openclaw gateway --port 18789 --verbose
