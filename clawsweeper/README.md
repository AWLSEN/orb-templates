# clawsweeper template

Deploy [clawsweeper](https://github.com/openclaw/clawsweeper) — an hourly issue-triage bot — on
[ORB Cloud](https://orbcloud.dev) for any GitHub repo, public or private.

## What it does

Reviews open issues and PRs in your target repo every hour. For each item, asks Codex
"should this stay open?" with a fixed list of allowed close reasons (already-implemented,
cannot-reproduce, duplicate, not-actionable, stale-old). Conservative confidence gates plus
a per-item audit trail (`items/<n>.md` written to the report repo).

5 isolated workers, modulo-partitioned by item number. Each replica reviews a different
slice of items in parallel. Idle ~99% of the time between hourly cycles — pay only when
codex is thinking.

## Deploy in 3 steps

### 1. Get an ORB API key

Sign up at [orbcloud.dev](https://orbcloud.dev), copy your org API key from the dashboard.

### 2. Set 4 secrets

```bash
export ORB_API_KEY=orb_...                 # from orbcloud.dev/dashboard/keys
export GITHUB_TOKEN=ghp_...                # read on TARGET_REPO, write on REPORT_REPO
export OPENAI_API_KEY=sk-...               # OR set CODEX_AUTH_JSON instead (see below)
export TARGET_REPO=myorg/myrepo            # any GitHub repo, public or private
```

### 3. Deploy

```bash
bash <(curl -fsSL https://orbcloud.dev/templates/clawsweeper)
```

That's it. The script renders the orb.toml, posts to `/v1/swarms`, and prints the swarm ID +
member computers. The first review fires immediately on each replica; cron picks up at the
next `:17` past the hour.

## Auth modes — `OPENAI_API_KEY` vs `CODEX_AUTH_JSON`

Pick exactly one:

| Mode | Set this | When to use | LLM base URL |
|---|---|---|---|
| **OpenAI API key** | `OPENAI_API_KEY=sk-...` | Pay-per-token via your OpenAI account; simplest setup. | `https://api.openai.com/v1` |
| **ChatGPT auth** | `CODEX_AUTH_JSON='{"auth_mode":"chatgpt",...}'` | If you have a ChatGPT Plus/Pro plan and want to use plan tokens. Run `codex login` locally, then paste the contents of `~/.codex/auth.json`. | `https://chatgpt.com/backend-api/codex` |

The deploy script picks the right `[llm].base_url` for you. The ORB plaintext LLM proxy then
intercepts every codex call so checkpoint-during-LLM-wait works regardless of mode.

See [`docs/auth-modes.md`](./docs/auth-modes.md) for details.

## Optional inputs

| Variable | Default | Purpose |
|---|---|---|
| `REPORT_REPO` | same as `$TARGET_REPO` | Where review proposals land as `items/<n>.md` |
| `REPLICAS` | `5` | Number of parallel review workers (max 100) |
| `CRON_SCHEDULE` | `17 * * * *` | Standard 5-field cron, runs hourly at :17 by default |
| `SWARM_NAME` | `clawsweeper-${TARGET_REPO//\//-}` | Identifier; used in the `/v1/swarms/<id>` URL |

## Private repos — yes

The wrapper script clones `$TARGET_REPO` using your `GITHUB_TOKEN` in the URL
(`https://x-access-token:${GITHUB_TOKEN}@github.com/...`). As long as your token has
read access to the target and write access to the report repo, private repos work
identically to public ones. See [`docs/private-repos.md`](./docs/private-repos.md).

## Status / teardown

```bash
# Status
curl -H "Authorization: Bearer $ORB_API_KEY" \
  https://api.orbcloud.dev/v1/swarms/<swarm_id>

# Tear down
curl -X DELETE -H "Authorization: Bearer $ORB_API_KEY" \
  https://api.orbcloud.dev/v1/swarms/<swarm_id>
```

## How it works under the hood

Each of the 5 replicas runs in its own ORB computer (own netns, cgroup, LLM proxy,
checkpoint blob). Build steps clone clawsweeper, apply a small env-overridable patch
(see [`patches/`](./patches/)), npm install + build, install Codex CLI, write the wrapper.

The wrapper materializes Codex auth at `~/.codex/auth.json` + `~/.codex/config.toml`
(pointing codex at ORB's plaintext proxy on `127.0.0.1:8080`), clones the target repo
with token-in-URL, then runs `node dist/clawsweeper.js review --shard-index N --shard-count 5`.

ORB cron fires the same wrapper hourly via `nsenter` into the sandbox — works whether
the agent is sleeping or awake.

The patch in `patches/env-overridable-repos.patch` is being upstreamed to clawsweeper.
Once merged this template will use pristine upstream and the patch step becomes a no-op.

## Agent-driven deploy

The [`template.json`](./template.json) manifest is agent-readable. Point Claude Code, Cursor,
or any agent at `https://orbcloud.dev/templates/clawsweeper/template.json` and it can ask
you for the right inputs and run the deploy itself — same `POST /v1/swarms` underneath.
