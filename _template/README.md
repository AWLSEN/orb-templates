# `<your-template-name>` — `<one-line tagline>`

Skeleton for adding a new template. Copy this directory to `<name>/`, edit
the placeholders, and submit a PR.

The contract every template implements:

```
<name>/
├── README.md          ← human-readable, with a 3-step deploy block
├── orb.toml.tpl       ← orb.toml with @PLACEHOLDER@ values deploy.sh substitutes
├── deploy.sh          ← reads env vars, calls /v1/swarms (swarm-shape)
│                        OR /v1/computers + /v1/computers/{id}/agents (single-shape)
├── start-shard.sh     ← wrapper that runs in each replica's sandbox
├── template.json      ← agent-readable manifest
├── patches/           ← optional: small in-tree patches against upstream
└── docs/              ← optional: deeper documentation
```

## Choosing a shape — `swarm` vs `single`

Set `"shape"` in `template.json`:

- **`"shape": "swarm"`** — N parallel replicas, each with its own ORB_REPLICA_INDEX.
  Use for embarrassingly-parallel workloads (modulo-partition, queue workers,
  fan-out). The `clawsweeper/` template is the canonical example.

- **`"shape": "single"`** — one computer, one agent, no replica context. Use for
  long-running watchers, personal assistants, single-stream ETL, bots that respond
  to events on one channel.

`lib/deploy-common.sh` provides helpers for both: `orb_swarm_create` and
`orb_computer_create_and_deploy`. Source it and call the right one from your `deploy.sh`.

## What to fill in

1. **`orb.toml.tpl`** — your `[agent]`, `[source]`, `[build]`, `[resources]`,
   `[llm]` config. Use `@VAR@` placeholders for anything `deploy.sh` substitutes
   per-deploy (target repo, LLM base URL, cron schedule, etc.).

2. **`start-shard.sh`** — what runs when the agent process is spawned (and what
   ORB cron fires hourly, if you set up a cron). Materialize any auth files,
   set up env, then `exec` into the actual workload.

3. **`deploy.sh`** — read env vars (use `require_env` from the lib), validate them,
   render `orb.toml.tpl`, call the right helper, print the result.

4. **`template.json`** — the manifest. Required: `name`, `version`, `tagline`,
   `what_it_does`, `shape`, `required_secrets[]`, `required_inputs[]`,
   `human_deploy_command`, `agent_deploy_uri`. Optional: `required_one_of[]` (for
   either-or auth modes), `optional_inputs[]`, `default_replicas`, `max_replicas`.

5. **`README.md`** — write the 3-step deploy block at the top so it can be
   copy-pasted into a tweet. Then explain what the workload does and any setup
   gotchas.

## Test before shipping

Before opening a PR:

- Run `deploy.sh` against a real ORB org and a low-traffic target. Confirm the
  swarm spawns, agents reach `running` state, and the workload does what it says.
- Verify `template.json` is valid JSON (`jq . template.json`).
- Confirm `bash <(curl -fsSL https://orbcloud.dev/templates/<name>)` works once
  hosting routing is in place.
