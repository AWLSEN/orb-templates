# OpenClaw on ORB Cloud

Self-host an [OpenClaw](https://github.com/openclaw/openclaw) Gateway on ORB Cloud.

**Why**: OpenClaw is a long-lived daemon that idles 90%+ of its life waiting for inbound messages.
Every other host (Hetzner, DigitalOcean, ClawCloud, xCloud) charges flat-rate for that idle time.
ORB Cloud charges $0 while the agent is asleep on NVMe; sub-second wake on the next inbound HTTP request.

## Phase 1 — what's in this template

| | |
|---|---|
| LLM provider | **Z.AI GLM** (via the Anthropic-compatible endpoint at `api.z.ai/api/anthropic`) |
| Channels | None — interaction is via HTTP at `https://<computer-id>.orbcloud.dev/` |
| Onboarding | Auto-config in `start.sh`; user can run `openclaw onboard` later via the web terminal |
| RAM | 2 GB (raise to 4 GB if you turn on browser-automation skills) |
| Persistent state | `~/.openclaw/` — survives sleep/wake via CRIU |

## Deploy

```bash
export ORB_API_KEY=orb_...      # from https://orbcloud.dev/dashboard/keys
export ZAI_API_KEY=<32hex>.<rest>   # from https://z.ai/manage-apikey/apikey-list

bash <(curl -fsSL https://orbcloud.dev/templates/openclaw)
```

Deploy returns:
- The gateway URL `https://<computer-id>.orbcloud.dev/`
- A web-terminal link for interactive `openclaw onboard` later
- The DELETE command for teardown

First deploy takes ~30–60s (npm install of `openclaw` is the long pole).
Subsequent wake-on-request is <1s (incremental CRIU restore).

## Talk to your gateway

Open the URL in a browser → OpenClaw's Control UI loads.

Or curl the RPC:

```bash
# Healthcheck (also wakes the agent if asleep)
curl https://<computer-id>.orbcloud.dev/healthz

# Send a message to the main agent
curl -X POST https://<computer-id>.orbcloud.dev/api/agent/messages \
  -H 'content-type: application/json' \
  -d '{"message":"What's on my schedule today?"}'
```

(Exact RPC paths follow the OpenClaw [Gateway protocol](https://docs.openclaw.ai/reference/rpc).
We forward all traffic through to OpenClaw's HTTP server unchanged.)

## How LLM traffic flows

```
your curl ──→ https://<computer-id>.orbcloud.dev/    (your gateway on ORB Cloud)
           ──→ openclaw gateway                       (running in your computer)
                     │  the Anthropic SDK is configured to send LLM calls
                     │  through ORB's per-computer LLM proxy via
                     │  ANTHROPIC_BASE_URL.
                     ▼
              ORB LLM proxy
                     │  forwards verbatim to your configured upstream:
                     ▼
              https://api.z.ai/api/anthropic         (Z.AI GLM)
```

LLM traffic flows through the ORB proxy, so the dashboard's call counter
ticks for every call and ORB can buffer in-flight responses across the
sleep/wake boundary — your gateway can be checkpointed mid-LLM-call and
the response is delivered correctly when it wakes.

## Sleep & wake (the savings story)

After 120 seconds of no inbound HTTP and no agent CPU activity, ORB's idle
detector demotes the computer to NVMe (~184 MB on disk; full RAM is freed).
You stop being billed for runtime in that moment.

The next HTTP request to `<computer-id>.orbcloud.dev` triggers wake-on-request:
ORB holds the request, restores the agent in <1s, then forwards the request
to the now-warm gateway. The caller sees a small first-request latency bump
and otherwise unchanged behavior.

## Roadmap (Phase 2)

- Channel pairing — Telegram, Discord, Slack via webhooks; WhatsApp via QR pairing in the web terminal
- Multi-LLM-provider switcher — Anthropic, OpenAI, Z.AI, custom base_url
- Web onboarding form on orbcloud.dev (vs curl-pipe-bash)
- GitHub OAuth signup with a free-tier monthly cap

## Tear down

```bash
SWARM_ID=...   # from the deploy output
curl -X DELETE -H "Authorization: Bearer $ORB_API_KEY" \
  https://api.orbcloud.dev/v1/swarms/$SWARM_ID
```

Deletes the computer, stops billing, frees the subdomain.
