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
- **LLM endpoint**: codex sends traffic **directly to** `https://chatgpt.com/backend-api/codex`,
  bypassing ORB's proxy. The codex binary hardcodes this URL in chatgpt-auth mode and
  ignores `openai_base_url` / `chatgpt_base_url` config options.
- **ORB observability**: ⚠️ proxy is **not in the path**. The dashboard's LLM-call
  counter stays at 0; the proxy's response-buffering across checkpoint isn't applied
  (in-flight survival falls back to TCP semantics + CRIU socket dump, which works for
  short sleeps and may time out for very long ones). Work still completes, ORB just
  has no per-call visibility into it.

## What you get either way

The customer-facing promises don't depend on the proxy being in the LLM path:

| | API-key mode | ChatGPT-auth mode |
|---|---|---|
| Sleep on idle (120s threshold, OS-signal-based) | ✅ | ✅ |
| Sub-second wake on next cron tick or HTTP request | ✅ | ✅ |
| Pay only for `cgroup.usage_usec` running time | ✅ | ✅ |
| Per-replica cost / cycle / runs metrics on dashboard | ✅ | ✅ |
| **LLM-call counter on dashboard** | ✅ | ❌ |
| **In-flight LLM response buffered by proxy** | ✅ | ❌ (TCP/CRIU fallback only) |

If the LLM-call counter matters to you (live demo, customer dashboard, etc.) — pick
API-key mode. Otherwise either is fine.
