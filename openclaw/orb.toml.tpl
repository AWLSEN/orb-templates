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
# onboard` on first run from start.sh). The provider URL is ALSO in
# openclaw.json at models.providers.zai.baseUrl — start.sh patches it to
# point at ORB's per-computer LLM proxy. So traffic flows agent → proxy
# → upstream Z.AI, fully observable on the dashboard. Confirmed live with
# SIGSTOP-during-checkpoint trace from the runtime.
ZAI_API_KEY = "${ZAI_API_KEY}"
HOME = "/root"
NODE_ENV = "production"
# Move Node's V8 compile cache off /tmp. Inside the sandbox, /tmp has a
# tmpfs mounted on top of an ext4 bind, and Node's `module.enableCompileCache()`
# (called by openclaw's entry.js) opens a watch on a cache file that ends up
# on the ext4 lower mount — invisible to CRIU's path resolution because the
# tmpfs shadows it. CRIU pre-dump then fails with `fsnotify: Can't dump that
# handle`. Pointing the cache at /agent/cache/node moves the watched inode
# onto the per-computer ext4 bind, no overlay, no tmpfs shadow — pre-dump
# resolves cleanly. See runtime/spec/criu-compat-known-issues.md item 3.
NODE_COMPILE_CACHE = "/agent/cache/node"

[build]
steps = [
  "mkdir -p /agent/code",
  "curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/openclaw/start.sh -o /agent/code/start.sh && chmod +x /agent/code/start.sh",
  "npm install -g openclaw@latest",
  "node --version && command -v openclaw && openclaw --version || true",
]
working_dir = "/agent/code"

[resources]
# runtime is the soft budget — the cgroup memory.max hard ceiling is set to
# `runtime × 3` by orb-runtime (see runtime/src/cgroup.rs MEMORY_MULTIPLIER).
# OpenClaw + ~35 plugin runtimes resident is 1-1.4GB; 2GB declared → 6GB
# cgroup max gives ample headroom for the CRIU dump's working set on top of
# resident memory without OOM-killing the agent mid-checkpoint.
runtime = "2GB"
disk    = "8GB"

[ports]
expose = [18789]

[llm]
# Upstream the per-computer LLM proxy forwards to. OpenClaw's openai-completions
# client sends `/chat/completions` (no `/v1/` prefix — Z.AI's GLM Coding Plan
# requires that exact path). Combined: the proxy receives /chat/completions
# from openclaw and forwards to https://api.z.ai/api/coding/paas/v4/chat/completions.
base_url = "https://api.z.ai/api/coding/paas/v4"
