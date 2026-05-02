# Templated orb.toml — deploy.sh substitutes the @PLACEHOLDER@ values before
# POSTing to /v1/swarms (with replicas=1). The substituted result is what the
# computer builds against.
#
# OpenRouter variant: any model OpenRouter offers, picked via OPENROUTER_MODEL
# at deploy time. Interaction is via the OpenClaw Gateway HTTP API at
# https://<id>.orbcloud.dev/. For the GLM-only variant see the sibling
# `openclaw` template.

[agent]
name = "openclaw-gateway"
lang = "binary"
entry = "/agent/code/start.sh"

[agent.env]
# OpenClaw stores LLM auth in its own profile store at
# ~/.openclaw/agents/main/agent/auth-profiles.json (written by `openclaw
# onboard` on first run from start.sh). The provider URL is ALSO in
# openclaw.json at models.providers.openrouter.baseUrl — start.sh patches
# it to point at ORB's per-computer LLM proxy. So traffic flows
# agent → proxy → upstream OpenRouter, fully observable on the dashboard.
OPENROUTER_API_KEY = "${OPENROUTER_API_KEY}"
# Optional: pick a specific OpenRouter model (e.g. "anthropic/claude-sonnet-4.5",
# "openai/gpt-5", "google/gemini-2.5-pro"). If empty, start.sh leaves whatever
# default `openclaw onboard` writes for the openrouter provider in place.
OPENROUTER_MODEL = "${OPENROUTER_MODEL}"
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
  "curl -fsSL https://raw.githubusercontent.com/AWLSEN/orb-templates/main/openclaw-openrouter/start.sh -o /agent/code/start.sh && chmod +x /agent/code/start.sh",
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
# Upstream the per-computer LLM proxy forwards to. OpenClaw's
# openai-completions client sends `/chat/completions` (no `/v1/` prefix);
# combined with this base URL the resulting upstream is
# https://openrouter.ai/api/v1/chat/completions — the standard OpenRouter
# OpenAI-compatible endpoint. Model selection happens inside the request
# body (`"model": "..."`), set by openclaw from agents.defaults.model.primary.
base_url = "https://openrouter.ai/api/v1"
