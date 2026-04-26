# Templated orb.toml — deploy.sh substitutes the @PLACEHOLDER@ values before
# POSTing to /v1/swarms. The substituted result is what each replica builds against.

[agent]
name = "clawsweeper-shard"
lang = "binary"
entry = "/agent/code/start-shard.sh"

[agent.env]
# Codex auth — one of these is set per the deploy.sh choice.
CODEX_AUTH_JSON = "${CODEX_AUTH_JSON}"
OPENAI_API_KEY  = "${OPENAI_API_KEY}"

# GitHub auth (used by gh CLI inside clawsweeper, and by start-shard.sh
# to clone private target repos).
GITHUB_TOKEN = "${GITHUB_TOKEN}"
GH_TOKEN     = "${GITHUB_TOKEN}"

# Target / report repos — picked up by clawsweeper.ts (after the patch
# in patches/env-overridable-repos.patch is applied at build time).
CLAWSWEEPER_TARGET_REPO = "@TARGET_REPO@"
CLAWSWEEPER_REPORT_REPO = "@REPORT_REPO@"

[source]
git    = "https://github.com/openclaw/clawsweeper"
branch = "main"

[build]
steps = [
  "curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/clawsweeper/patches/env-overridable-repos.patch | patch -p1",
  "npm install",
  "npm run build",
  "npm install -g @openai/codex",
  "mkdir -p /agent/packages/bin && ln -sf /usr/bin/git /agent/packages/bin/git",
  "GH_VERSION=2.45.0 && curl -fsSL \"https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz\" | tar xz -C /tmp && cp /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh /agent/packages/bin/gh && rm -rf /tmp/gh_${GH_VERSION}_linux_amd64 && /agent/packages/bin/gh --version",
  "curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/clawsweeper/start-shard.sh -o /agent/code/start-shard.sh && chmod +x /agent/code/start-shard.sh",
  "mkdir -p /agent/.orb && cat > /agent/.orb/cron.json <<'CRONJSON'\n{\"version\":1,\"jobs\":[{\"name\":\"review\",\"schedule\":\"@CRON_SCHEDULE@\",\"command\":\"/agent/code/start-shard.sh\",\"timeout_secs\":1800,\"skip_if_running\":true}]}\nCRONJSON",
]
working_dir = "/agent/code"

[resources]
runtime = "1GB"
disk    = "5GB"

[llm]
# Substituted by deploy.sh based on which auth mode the user chose:
#   OPENAI_API_KEY → https://api.openai.com/v1
#   CODEX_AUTH_JSON → https://chatgpt.com/backend-api/codex
base_url = "@LLM_BASE_URL@"
