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
# Z.AI uses the standard Anthropic SDK env var name. Anthropic SDK reads this
# and sends it as the x-api-key header. The runtime ALSO injects
# ANTHROPIC_BASE_URL pointing at our per-computer LLM proxy, which forwards
# verbatim to [llm] base_url below — so calls are observable by ORB.
ANTHROPIC_AUTH_TOKEN = "${ZAI_API_KEY}"
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
# GLM coding plan via Z.AI's Anthropic-compatible endpoint.
base_url = "https://api.z.ai/api/anthropic"
