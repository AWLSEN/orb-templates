#!/bin/bash
# OpenClaw Gateway entry point (OpenRouter variant) — runs as the agent
# process inside the ORB sandbox. Spawned on initial deploy + on every
# restart after sleep/wake.
#
# Idempotent: subsequent runs reuse the auth profile from the first run
# (~/.openclaw/agents/main/agent/auth-profiles.json) so we don't re-onboard
# on every wake.

set -e
export PATH="/root/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$HOME/.openclaw"
# Honors NODE_COMPILE_CACHE in [agent.env] — the cache dir lives on the
# per-computer ext4 bind (no overlay, no tmpfs shadow), so CRIU pre-dump
# can resolve openclaw's inotify watch on the cache file. Detail in
# orb.toml.tpl's NODE_COMPILE_CACHE comment + spec item 3.
mkdir -p "${NODE_COMPILE_CACHE:-/agent/cache/node}"

: "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY must be set — runtime should inject from org_secrets}"

# Run onboard non-interactively the first time. The wizard supports
# --auth-choice openrouter-api-key, so we don't have to write
# auth-profiles.json by hand. Onboard:
#   - writes ~/.openclaw/agents/main/agent/auth-profiles.json with the key
#   - writes ~/.openclaw/openclaw.json with the openrouter provider config
#   - sets a default model from the wizard (we override below if the user
#     passed OPENROUTER_MODEL at deploy time)
if [ ! -f "$HOME/.openclaw/agents/main/agent/auth-profiles.json" ]; then
  echo "=== first run: onboarding for OpenRouter ==="
  openclaw onboard \
    --non-interactive \
    --accept-risk \
    --auth-choice openrouter-api-key \
    --openrouter-api-key "$OPENROUTER_API_KEY" || true

  # Onboard sets gateway.bind=loopback by default — keep that. ORB's port
  # expose mechanism uses socat on the netns LAN IP, forwarding to loopback,
  # so binding the gateway directly to LAN would EADDRINUSE conflict with
  # socat. Loopback is correct.

  # Three openclaw.json patches before first gateway start:
  #
  # 1. openrouter.baseUrl → ORB's per-computer LLM proxy. Onboard sets it to
  #    openrouter.ai directly; we point it at the proxy so traffic is
  #    observable (dashboard counter, checkpoint-buffer-during-LLM-call).
  #
  # 2. agents.defaults.model.primary ← OPENROUTER_MODEL (only if set).
  #    OpenRouter accepts any model in its catalog; we leave the wizard's
  #    default in place when the user didn't specify, and override otherwise.
  #
  # 3. gateway.http.endpoints.chatCompletions.enabled = true. Without this,
  #    every API path returns 404 except the SPA dashboard — there's no way
  #    to send the gateway a message via curl. We enable the OpenAI-compat
  #    /v1/chat/completions endpoint by default so deploy.sh's curl example
  #    works. The gateway's existing token auth (gateway.auth.token, written
  #    by `openclaw onboard`) gates access; we surface that token in the
  #    deploy.sh banner so users can authenticate.
  python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.openclaw/openclaw.json")
d = json.load(open(p))

proxy_url = os.environ.get("ORB_PROXY_URL")
if proxy_url:
    d.setdefault("models", {}).setdefault("providers", {}).setdefault("openrouter", {})["baseUrl"] = proxy_url
    print(f"  openrouter.baseUrl → {proxy_url}")

model = (os.environ.get("OPENROUTER_MODEL") or "").strip()
if model:
    d.setdefault("agents", {}).setdefault("defaults", {})["model"] = {"primary": model}
    d["agents"]["defaults"].setdefault("models", {})[model] = {"alias": model.split("/")[-1]}
    print(f"  agents.defaults.model.primary → {model}")
else:
    print("  agents.defaults.model.primary → (kept openclaw onboard default)")

# Enable OpenAI-compatible HTTP endpoint (disabled by default in openclaw).
gw = d.setdefault("gateway", {})
endpoints = gw.setdefault("http", {}).setdefault("endpoints", {})
endpoints.setdefault("chatCompletions", {})["enabled"] = True
endpoints.setdefault("responses", {})["enabled"] = True
print("  gateway.http.endpoints.chatCompletions.enabled → true")
print("  gateway.http.endpoints.responses.enabled → true")

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
