# Templated orb.toml — deploy.sh substitutes the @PLACEHOLDER@ values before
# POSTing to /v1/swarms (with replicas=1). The substituted result is what the
# computer builds against.
#
# v0 scope:
#   - Telegram via long-polling (drop-in equivalent of upstream bux)
#   - Browser via Browser Use Cloud (chromium runs off-box)
#   - sleep = "never" because long-poll keeps the agent network-active
#     and browser_keeper.py sits in clock_nanosleep between rotations,
#     both of which prevent ORB's idle detector from firing
#   - Authentication via `claude /login` (Claude Max OAuth) — done once
#     post-deploy through the ORB web terminal at /terminal/<id>
#
# v0.5 (planned): swap Telegram polling for webhook mode → set
# sleep = "auto" → realize ORB's $0-idle savings story.

[agent]
name = "bux"
lang = "binary"
entry = "/agent/code/start.sh"

[agent.env]
HOME = "/root"
BROWSER_USE_API_KEY = "${BROWSER_USE_API_KEY}"
BUX_PROFILE_ID      = "${BUX_PROFILE_ID}"
TG_BOT_TOKEN        = "${TG_BOT_TOKEN}"
TG_SETUP_TOKEN      = "${TG_SETUP_TOKEN}"

[build]
steps = [
  "mkdir -p /agent/code",
  "curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/bux/start.sh -o /agent/code/start.sh",
  "chmod +x /agent/code/start.sh",
  "DEBIAN_FRONTEND=noninteractive apt-get update -qq",
  "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl git python3 python3-pip ca-certificates",
  "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -",
  "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs",
  "useradd -m -s /bin/bash bux 2>/dev/null || true",
  "mkdir -p /etc/bux /var/log/bux /opt/bux/agent /home/bux/.claude /home/bux/.bux/sessions /home/bux/workspaces /var/lib/bux",
  "git clone --depth 1 https://github.com/browser-use/bux /tmp/bux-src",
  "cp /tmp/bux-src/agent/browser_keeper.py /tmp/bux-src/agent/telegram_bot.py /tmp/bux-src/agent/box_agent.py /tmp/bux-src/agent/CLAUDE.md /opt/bux/agent/",
  "cp /tmp/bux-src/agent/requirements.txt /opt/bux/agent/",
  "pip install --break-system-packages -r /opt/bux/agent/requirements.txt",
  "npm install -g @anthropic-ai/claude-code browser-harness",
  "chown -R bux:bux /home/bux /var/log/bux /var/lib/bux /opt/bux 2>/dev/null || true",
  "rm -rf /tmp/bux-src",
]
working_dir = "/agent/code"

[resources]
# bux running locally is Python (telegram_bot, browser_keeper, claude wrapper)
# + Node.js (claude CLI) + browser-harness. Chromium itself is OFF-box (BU
# Cloud). Resident set is dominated by claude — typically 300-700 MB during
# active turns, near-idle between. 4 GB declared = 12 GB cgroup ceiling
# (runtime × 3) which gives plenty of headroom for parallel claude spawns
# across multiple Telegram conversation lanes.
runtime = "4GB"
disk    = "8GB"

[lifecycle]
# Long-poll Telegram + browser_keeper's 3.5-hour clock_nanosleep both
# block ORB's idle detector from firing. Pin in RAM until v0.5 swaps
# to webhook mode + a passive-sleep-loop keeper.
sleep = "never"

[llm]
# bux drives claude (Anthropic's CLI). When the user runs `claude /login`
# via the web terminal, claude uses Claude Max OAuth — outbound calls hit
# api.anthropic.com directly. This base_url tells ORB's per-computer LLM
# proxy where to forward; the `/login` path completes the OAuth, and
# subsequent message-level calls flow proxy → upstream so they're
# observable on the dashboard.
base_url = "https://api.anthropic.com"
