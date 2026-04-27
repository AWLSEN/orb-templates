#!/bin/bash
# OpenClaw Gateway entry point — runs as the agent process inside the ORB
# sandbox. Spawned once on initial deploy. After this exits or sleeps, ORB's
# subdomain proxy wakes us on inbound HTTP to <id>.orbcloud.dev:18789.

set -e

export PATH="/root/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"

# OpenClaw expects ~/.openclaw/. Pre-create it so first run doesn't race.
mkdir -p "$HOME/.openclaw"

# Required envvar from agent.env (set by ORB's secret resolver).
: "${ANTHROPIC_AUTH_TOKEN:?ANTHROPIC_AUTH_TOKEN must be set — runtime should inject from org_secrets}"

# OpenClaw's Anthropic SDK reads ANTHROPIC_BASE_URL (injected by ORB at agent
# spawn AND on every cron-fired run, value: http://10.42.<subnet>.1:10000).
# That points at the per-computer LLM proxy, which forwards to [llm].base_url
# (https://api.z.ai/api/anthropic). All Z.AI traffic flows through ORB's proxy
# → dashboard LLM-call counter ticks → checkpoint-buffer-during-sleep applies.
#
# If for any reason the runtime hasn't set it (e.g. testing outside ORB),
# fail loudly rather than silently bypass.
: "${ANTHROPIC_BASE_URL:?ANTHROPIC_BASE_URL not set — the ORB runtime must inject this at agent spawn}"

echo "=== openclaw gateway starting ==="
echo "    proxy:  $ANTHROPIC_BASE_URL"
echo "    [llm]:  https://api.z.ai/api/anthropic (set in orb.toml)"
echo "    started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "==="

# Seed a minimal openclaw.json so the gateway can start without interactive
# onboarding. The user can later run `openclaw onboard` via the web terminal
# at https://api.orbcloud.dev/terminal/<id>?key=... to add channels, skills,
# etc. — that flow updates the same config.
if [ ! -f "$HOME/.openclaw/openclaw.json" ]; then
  cat > "$HOME/.openclaw/openclaw.json" <<'OPENCLAW_JSON'
{
  "$schema": "https://openclaw.ai/schemas/openclaw.json",
  "gateway": {
    "mode": "local",
    "bind": "all",
    "port": 18789,
    "controlUi": {
      "allowedOrigins": ["*"]
    }
  },
  "agents": {
    "main": {
      "model": {
        "provider": "anthropic",
        "id": "claude-sonnet-4"
      }
    }
  }
}
OPENCLAW_JSON
fi

# Start the Gateway in foreground (no --install-daemon: there's no systemd
# inside the ORB sandbox; ORB itself is the daemon manager via idle-detect +
# wake-on-request).
exec openclaw gateway --port 18789 --bind 0.0.0.0 --verbose
