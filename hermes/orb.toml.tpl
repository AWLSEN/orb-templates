# Templated orb.toml — deploy.sh substitutes the @PLACEHOLDER@ values before
# POSTing to /v1/swarms (with replicas=1).
#
# v0 scope: GLM Coding Plan only. Single LLM upstream, single model
# (zai/glm-4.7) — same default openclaw uses. Telegram bot is configured
# POST-DEPLOY via the in-sandbox wizard (`hermes-setup-tg`), so users only
# need ORB + GLM keys upfront.
#
# Sleep behaviour: `auto` (the canonical ORB shape). Hermes natively
# supports Telegram webhook mode via TELEGRAM_WEBHOOK_URL — once the
# wizard sets that, every Telegram message arrives as an HTTPS POST to
# https://<id>.orbcloud.dev/telegram, which fires ORB's wake-on-request,
# routes through the subdomain proxy, and lets the gateway sleep between
# messages. No long-poll, no continuous network noise.

[agent]
name = "hermes"
lang = "binary"
entry = "/agent/code/start.sh"

[agent.env]
HOME = "/root"
HERMES_HOME = "/root/.hermes"
GLM_API_KEY = "${GLM_API_KEY}"

[build]
# Hermes ships a heavy install (uv + Python deps + venv). Slim extras for
# v0: messaging (Telegram webhooks + Discord/Slack libs we don't yet use),
# cron, cli, pty, mcp. Skip voice (faster-whisper, ctranslate2 — wheel-only,
# slow), web (dashboard SPA — not needed for v0), [all] (pulls Playwright +
# Chromium — separate investigation, see runtime/spec/idle-sleep.md:101).
steps = [
  "mkdir -p /agent/code",
  "curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/hermes/start.sh -o /agent/code/start.sh",
  "curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/hermes/setup-tg.sh -o /usr/local/bin/hermes-setup-tg",
  "chmod +x /agent/code/start.sh /usr/local/bin/hermes-setup-tg",
  "curl -fsSL https://astral.sh/uv/install.sh | sh",
  "ln -sf /root/.local/bin/uv /usr/local/bin/uv",
  "ln -sf /root/.local/bin/uvx /usr/local/bin/uvx",
  "git clone --depth=1 https://github.com/NousResearch/hermes-agent /opt/hermes",
  "cd /opt/hermes && uv venv",
  "cd /opt/hermes && uv pip install -e '.[messaging,cron,cli,pty,mcp]'",
  "ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes",
  "mkdir -p /root/.hermes",
  "cat > /root/.hermes/config.yaml <<'YAML'\nmodel: 'zai:glm-4.7'\nproviders:\n  zai:\n    base_url: 'https://api.z.ai/api/coding/paas/v4'\ntoolsets: ['hermes-cli']\nYAML",
  "hermes --version || true",
]
working_dir = "/agent/code"

[resources]
# Hermes resident set ~600-900 MB with [messaging,cron,cli,pty,mcp] and a
# warm conversation. 2 GB declared = 6 GB cgroup ceiling (×3 multiplier)
# gives plenty of headroom.
runtime = "2GB"
disk    = "8GB"

[ports]
# Telegram webhook receiver. ORB's subdomain proxy at
# https://<id>.orbcloud.dev forwards inbound HTTPS to whichever port we
# expose; we pick 8443 (Hermes default for TELEGRAM_WEBHOOK_PORT).
expose = [8443]

[lifecycle]
# Webhook mode → no long-poll → idle detector can fire. Canonical ORB shape.
sleep = "auto"

[llm]
# GLM Coding Plan endpoint. Hermes routes via openai-compatible client
# under `zai` provider; we point both [llm] and the provider's base_url
# (in config.yaml above) at this URL so traffic flows agent → ORB proxy
# → upstream and is observable on the dashboard.
base_url = "https://api.z.ai/api/coding/paas/v4"
