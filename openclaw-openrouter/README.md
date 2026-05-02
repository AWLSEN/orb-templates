# OpenClaw on ORB Cloud — OpenRouter variant

Self-host an [OpenClaw](https://github.com/openclaw/openclaw) Gateway on ORB Cloud, backed by [OpenRouter](https://openrouter.ai) so you can pick **any model** in OpenRouter's catalog (Anthropic, OpenAI, Google, Meta, Mistral, DeepSeek, …).

For the GLM-only variant (cheaper if you already have a Z.AI GLM Coding Plan key), see the sibling [`openclaw`](../openclaw/) template.

**Why**: OpenClaw is a long-lived daemon that idles 90%+ of its life waiting for inbound messages. Every other host (Hetzner, DigitalOcean, ClawCloud, xCloud) charges flat-rate for that idle time. ORB Cloud charges $0 while the agent is asleep on NVMe; sub-second wake on the next inbound HTTP request.

## What's in this template

| | |
|---|---|
| LLM provider | **OpenRouter** — any model in [their catalog](https://openrouter.ai/models) |
| Model selector | `OPENROUTER_MODEL` env var at deploy time (e.g. `anthropic/claude-sonnet-4.5`) |
| Channels | None — interaction is via HTTP at `https://<computer-id>.orbcloud.dev/` |
| Onboarding | Auto-config in `start.sh`; user can run `openclaw onboard` later via the web terminal |
| RAM | 2 GB (raise to 4 GB if you turn on browser-automation skills) |
| Persistent state | `~/.openclaw/` — survives sleep/wake via CRIU |

## Deploy

```bash
export ORB_API_KEY=orb_...                       # from https://orbcloud.dev/dashboard/keys
export OPENROUTER_API_KEY=sk-or-v1-...           # from https://openrouter.ai/keys

bash <(curl -fsSL https://orbcloud.dev/templates/openclaw-openrouter)
```

Deploy returns:
- The gateway URL `https://<computer-id>.orbcloud.dev/`
- A web-terminal link for interactive `openclaw onboard` later
- The DELETE command for teardown

First deploy takes ~30–60s (npm install of `openclaw` is the long pole). Subsequent wake-on-request is <1s (incremental CRIU restore).

## Picking a model

By default, `openclaw onboard`'s wizard picks a sensible OpenRouter model for you. To pin a specific one, export `OPENROUTER_MODEL` before running the deploy command:

```bash
export OPENROUTER_MODEL=anthropic/claude-sonnet-4.5
bash <(curl -fsSL https://orbcloud.dev/templates/openclaw-openrouter)
```

`OPENROUTER_MODEL` accepts any model slug from <https://openrouter.ai/models>. A few common picks:

| Slug | Notes |
|---|---|
| `anthropic/claude-sonnet-4.5` | Strong general-purpose default for agent workloads |
| `anthropic/claude-haiku-4.5` | Cheaper, faster, smaller context |
| `openai/gpt-5` | OpenAI's flagship via OpenRouter |
| `google/gemini-2.5-pro` | Long context, multi-modal |
| `deepseek/deepseek-v3` | Strong code performance, lower cost |

You can switch later by editing `~/.openclaw/openclaw.json` via the web terminal — `agents.defaults.model.primary` is the field — and restarting the gateway.

## Talk to your gateway

Open the URL in a browser → OpenClaw's Control UI loads.

Or curl the OpenAI-compatible endpoint (enabled by default):

```bash
# Healthcheck (also wakes the agent if asleep)
curl https://<computer-id>.orbcloud.dev/healthz

# Send a message — gateway auth token is printed at deploy time
curl -X POST https://<computer-id>.orbcloud.dev/v1/chat/completions \
  -H "Authorization: Bearer <gateway-token>" \
  -H 'content-type: application/json' \
  -d '{"model":"openclaw","messages":[{"role":"user","content":"hello"}]}'
```

## How LLM traffic flows

```
your curl ──→ https://<computer-id>.orbcloud.dev/    (your gateway on ORB Cloud)
           ──→ openclaw gateway                       (running in your computer)
                     │  the openrouter provider in openclaw.json is configured
                     │  to send LLM calls through ORB's per-computer LLM proxy.
                     ▼
              ORB LLM proxy
                     │  forwards verbatim to:
                     ▼
              https://openrouter.ai/api/v1           (OpenRouter)
                     │  routes to whichever underlying provider matches the
                     ▼  model slug in your request body
              Anthropic / OpenAI / Google / …
```

LLM traffic flows through the ORB proxy, so the dashboard's call counter ticks for every call and ORB can buffer in-flight responses across the sleep/wake boundary — your gateway can be checkpointed mid-LLM-call and the response is delivered correctly when it wakes.

## Sleep & wake (the savings story)

After 120 seconds of no inbound HTTP and no agent CPU activity, ORB's idle detector demotes the computer to NVMe (~184 MB on disk; full RAM is freed). You stop being billed for runtime in that moment.

The next HTTP request to `<computer-id>.orbcloud.dev` triggers wake-on-request: ORB holds the request, restores the agent in <1s, then forwards the request to the now-warm gateway. The caller sees a small first-request latency bump and otherwise unchanged behavior.

## Tear down

```bash
SWARM_ID=...   # from the deploy output
curl -X DELETE -H "Authorization: Bearer $ORB_API_KEY" \
  https://api.orbcloud.dev/v1/swarms/$SWARM_ID
```

Deletes the computer, stops billing, frees the subdomain.
