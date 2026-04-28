# Codex auth modes

Codex CLI supports two auth modes; both work with this template. Pick exactly one
— the deploy script errors if you set both.

## OpenAI API key (recommended)

Set `OPENAI_API_KEY=sk-...` in your env. Codex runs in API-key mode.

- **Billing**: pay-per-token via your OpenAI account. Visible in the OpenAI dashboard.
- **Setup**: get a key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys),
  paste into env.
- **LLM endpoint**: ORB's per-computer LLM proxy at `http://10.42.<subnet>.1:10000`,
  which forwards to `https://api.openai.com/v1`. Codex respects this via its
  `openai_base_url` config option.
- **ORB observability**: ✅ proxy sees every call; LLM-call counter on the dashboard
  ticks; in-flight responses are buffered across checkpoint/restore.

## ChatGPT auth (`auth.json`)

Set `CODEX_AUTH_JSON='...'` containing the JSON body of your local `~/.codex/auth.json`.
Use this if you want to consume your ChatGPT Plus/Pro/Team plan tokens instead of
paying per call.

- **Billing**: counted against your ChatGPT plan.
- **Setup**: run `codex login` locally, then `cat ~/.codex/auth.json` and paste that
  full JSON blob into the env var. (Single-quote it in shell so the JSON quotes
  survive: `CODEX_AUTH_JSON='{"auth_mode":"chatgpt",...}'`.)
- **LLM endpoint**: codex normally targets `https://chatgpt.com/backend-api/codex`.
  Whether that URL can be overridden to point at ORB's per-computer proxy in
  chatgpt-auth mode is **currently unverified** end-to-end on this template.
  An earlier test where I set both `openai_base_url` and `chatgpt_base_url` to
  broken URLs and saw codex still complete reviews suggested the URLs were ignored —
  but a parallel investigation in the OpenClaw template revealed I'd missed an
  override path there, so I no longer trust that conclusion without re-testing.
- **ORB observability**: 🟡 **unverified** in this mode. If proxy interception
  works, you get the same observability + checkpoint-buffer benefits as API-key
  mode. If it doesn't, traffic goes direct to chatgpt.com and the dashboard
  counter stays at 0. Either way, sleep / wake / cost-per-second still work.

## What you get either way

The customer-facing promises don't depend on the proxy being in the LLM path:

| | API-key mode | ChatGPT-auth mode |
|---|---|---|
| Sleep on idle (120s threshold, OS-signal-based) | ✅ | ✅ |
| Sub-second wake on next cron tick or HTTP request | ✅ | ✅ |
| Pay only for `cgroup.usage_usec` running time | ✅ | ✅ |
| Per-replica cost / cycle / runs metrics on dashboard | ✅ | ✅ |
| **LLM-call counter on dashboard** | ✅ | 🟡 unverified |
| **In-flight LLM response buffered by proxy** | ✅ | 🟡 unverified |

If the LLM-call counter matters to you (live demo, customer dashboard, etc.) and
you want a fully-verified path, pick API-key mode. ChatGPT-auth still works — we
just haven't yet pinned down whether the proxy is in path.
