# orb-templates

Deployable templates for [ORB Cloud](https://orbcloud.dev). Each template is a self-contained
swarm-shaped agent workload you can deploy on your own repo with one command.

## What's a template?

A template is everything ORB Cloud needs to spawn your workload as a fleet of independent agents:
the `orb.toml`, the wrapper script, any patches against upstream code, and a small `deploy.sh`
that takes your secrets and posts to `https://api.orbcloud.dev/v1/swarms`.

Two ways to deploy:

- **Manual** (the curl-pipe-bash way) — set 4 env vars, run one command. ~30 seconds.
- **Agent-driven** — point Claude Code / Cursor / any agent at the template's `template.json`;
  the agent reads the manifest, asks you for the inputs it needs, runs the deploy.

Same `POST /v1/swarms` underneath. Same outcome.

## Available templates

| Template | What it deploys | Replicas | LLM | Status |
|---|---|---|---|---|
| [`clawsweeper/`](./clawsweeper/) | Hourly issue-triage bot for any GitHub repo | 5 | Codex (OpenAI API key or ChatGPT auth) | shipped |
| [`openclaw/`](./openclaw/) | OpenClaw Gateway, idle-free, wake-on-HTTP | 1 | Z.AI GLM Coding Plan | shipped |
| [`openclaw-openrouter/`](./openclaw-openrouter/) | Same OpenClaw Gateway, any model in [OpenRouter](https://openrouter.ai/models)'s catalog | 1 | OpenRouter (model selectable via `OPENROUTER_MODEL`) | shipped |
| [`bux/`](./bux/) | [Browser Use Box](https://github.com/browser-use/bux) — 24/7 Claude Code agent + Browser Use Cloud + Telegram bot | 1 | Anthropic (`claude /login` post-deploy) | v0 (pinned, sleep=never; webhook in v0.5) |
| [`hermes/`](./hermes/) | [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent) — Telegram + GLM Coding Plan, native webhook mode | 1 | Z.AI GLM Coding Plan | v0 (sleep=auto, full ORB shape) |

More on the way.

## Adding a new template

Copy `_template/` into `<your-template-name>/`, edit the placeholder fields,
add a `patches/` directory if your upstream needs small modifications, and ship a PR.

Each template ships these files (the contract):

```
<your-template>/
├── README.md            ← human-readable, with the 3-step deploy
├── orb.toml.tpl         ← orb.toml with $VAR placeholders the deploy script substitutes
├── deploy.sh            ← reads env vars, calls /v1/swarms
├── start-shard.sh       ← wrapper that runs in each replica's sandbox
├── template.json        ← agent-readable manifest (required secrets, inputs, deploy URL)
├── patches/             ← optional: small in-tree patches against upstream
└── docs/                ← optional: deeper documentation
```

`lib/deploy-common.sh` provides shared helpers (env validation, /v1/swarms POST, status polling)
that every template's `deploy.sh` sources.

## Repo layout

```
orb-templates/
├── README.md              ← this file
├── _template/             ← skeleton for adding a new template
├── lib/
│   └── deploy-common.sh   ← shared helpers
└── <template-name>/       ← one directory per template
```

## Hosted entry points (curl-pipe-bash)

Each template has a hosted deploy script and manifest:

| URL | Purpose |
|---|---|
| `https://orbcloud.dev/templates/<name>` | the deploy script (`bash <(curl -fsSL ...)`) |
| `https://orbcloud.dev/templates/<name>/template.json` | agent-readable manifest |
| `https://orbcloud.dev/templates/` | catalog of all templates |
| `https://orbcloud.dev/use-cases/<name>/` | full marketing page |

These endpoints proxy to this repo's `main` branch via nginx on the orb-site VPS.
