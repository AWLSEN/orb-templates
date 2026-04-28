# Templated orb.toml — deploy.sh substitutes the @PLACEHOLDER@ values before
# POSTing to /v1/swarms (with replicas=1). The substituted result is what the
# computer builds against.
#
# Phase 1 scope: GLM (Z.AI's Anthropic-compatible endpoint) is the only LLM
# upstream. No channels — interaction is via the OpenClaw Gateway HTTP API
# at https://<id>.orbcloud.dev/. Telegram/Discord/Slack pairing land in Phase 2.

[agent]
name = "openclaw-gateway"
lang = "binary"
entry = "/agent/code/start.sh"

[agent.env]
# OpenClaw stores LLM auth in its own profile store at
# ~/.openclaw/agents/main/agent/auth-profiles.json (written by `openclaw
# onboard` on first run from start.sh). It does NOT honor standard SDK env
# vars like ANTHROPIC_AUTH_TOKEN — its provider URLs are hardcoded per
# auth-choice. Same shape as codex chatgpt-auth: traffic bypasses ORB's LLM
# proxy. Documented limitation; workload still runs, just no per-call
# metering on the dashboard.
ZAI_API_KEY = "${ZAI_API_KEY}"
HOME = "/root"
NODE_ENV = "production"

[build]
steps = [
  "mkdir -p /agent/code",
  "curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/openclaw/start.sh -o /agent/code/start.sh && chmod +x /agent/code/start.sh",
  "npm install -g openclaw@latest",
  "node --version && command -v openclaw && openclaw --version || true",
]
working_dir = "/agent/code"

[resources]
runtime = "2GB"
disk    = "4GB"

[ports]
expose = [18789]

[llm]
# OpenClaw uses its own provider URLs (hardcoded per auth-choice) and
# bypasses ORB's per-computer LLM proxy. This [llm] base_url is therefore
# unused by OpenClaw itself — but the deploy schema requires it, and any
# OTHER process inside this computer that respects ANTHROPIC_BASE_URL would
# correctly route through the proxy to this upstream.
base_url = "https://api.z.ai/api/coding/paas/v4"
