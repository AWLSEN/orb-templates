# Codex auth modes

Codex CLI supports two auth modes; both work with this template, with very different
billing and DX characteristics. Pick exactly one — the deploy script errors if you set
both.

## OpenAI API key (recommended for first-time deploys)

Set `OPENAI_API_KEY=sk-...` in your env. The template uses Codex's API-key mode.

- **Billing**: pay-per-token via your OpenAI account. Costs are predictable and
  visible in the OpenAI dashboard.
- **Setup**: get a key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys);
  paste it into env. One line.
- **LLM endpoint**: ORB's plaintext proxy forwards to `https://api.openai.com/v1`.
- **Token refresh**: not applicable — keys don't expire on a schedule.

## ChatGPT auth (`auth.json`)

Set `CODEX_AUTH_JSON='...'` containing the JSON body of your local `~/.codex/auth.json`.
Use this if you have a ChatGPT Plus/Pro/Team plan and want to consume plan tokens
instead of API tokens.

- **Billing**: counted against your ChatGPT plan, not API spend.
- **Setup**: run `codex login` locally, then `cat ~/.codex/auth.json` and paste that
  full JSON blob into the env var. (Single-quote it in shell to preserve quotes:
  `CODEX_AUTH_JSON='{"auth_mode":"chatgpt",...}'`.)
- **LLM endpoint**: ORB's plaintext proxy forwards to `https://chatgpt.com/backend-api/codex`.
- **Token refresh**: codex auto-refreshes the access_token via `auth.openai.com/oauth/token`
  using the refresh_token. The refresh hits OpenAI directly (not through ORB's proxy),
  so as long as `auth.openai.com` is reachable from your computer's outbound network
  (default: yes), it just works. Refresh tokens are long-lived but if codex's CLI ever
  invalidates them, you'd need to re-run `codex login` locally and redeploy.

## What ORB does in either case

ORB Cloud runs a plaintext HTTP proxy on `127.0.0.1:8080` inside every replica's network
namespace. The wrapper script writes `~/.codex/config.toml` with
`openai_base_url = "http://127.0.0.1:8080"`, which causes Codex CLI to send all LLM
calls through the proxy — regardless of auth mode. The proxy then forwards over TLS to
the right upstream (`api.openai.com/v1` for API key, `chatgpt.com/backend-api/codex` for
ChatGPT auth) and buffers the full response so the agent can be checkpointed mid-call
without losing the in-flight LLM response.

That's the "pay only when thinking" promise mechanically: codex calls are buffered by
the proxy, the runtime can checkpoint the agent process to NVMe while waiting, and
deliver the response after restoring the agent on the next event.
