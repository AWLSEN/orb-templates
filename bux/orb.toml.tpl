# Templated orb.toml — deploy.sh substitutes the @PLACEHOLDER@ values before
# POSTing to /v1/swarms (with replicas=1). The substituted result is what the
# computer builds against.
#
# v0 scope:
#   - Telegram via long-polling (drop-in equivalent of upstream bux).
#     Bot is configured POST-DEPLOY via the in-sandbox setup wizard
#     (`bux setup-tg`), so users never need to visit @BotFather before
#     running deploy.sh. start.sh runs a watchdog that picks up the bot
#     env file as soon as the wizard writes it.
#   - Browser via Browser Use Cloud (chromium runs off-box).
#   - sleep = "never" because long-poll keeps the agent network-active
#     and browser_keeper.py sits in clock_nanosleep between rotations,
#     both of which prevent ORB's idle detector from firing.
#   - Authentication via `claude /login` (Claude Max OAuth) — done once
#     post-deploy through the ORB web terminal at /terminal/<id>.
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

[build]
steps = [
  "mkdir -p /agent/code",
  "curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/bux/start.sh -o /agent/code/start.sh",
  "curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/bux/setup-tg.sh -o /usr/local/bin/bux-setup-tg",
  "chmod +x /agent/code/start.sh /usr/local/bin/bux-setup-tg",
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
# Resident set is dominated by claude — typically 300-700 MB during active
# turns, near-idle between. 4 GB declared = 12 GB cgroup ceiling (runtime ×
# 3) which gives plenty of headroom for parallel claude spawns across
# multiple Telegram conversation lanes.
runtime = "4GB"
disk    = "8GB"

[lifecycle]
sleep = "never"

[llm]
# `claude /login` (Claude Max OAuth) and subsequent message-level calls
# flow through ORB's per-computer LLM proxy → upstream. Per-call observable
# on the dashboard.
base_url = "https://api.anthropic.com"
