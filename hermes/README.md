# Hermes on ORB Cloud — GLM Coding Plan variant

Self-host [Hermes Agent](https://github.com/NousResearch/hermes-agent) on ORB Cloud, backed by Z.AI's [GLM Coding Plan](https://z.ai). Same upstream Hermes, no patches — uses Hermes's native Telegram webhook mode to deliver the canonical ORB shape: idle between messages = $0, sub-second wake on the next inbound text.

For OpenRouter-backed (any model) variant see the sibling [`hermes-openrouter`](../hermes-openrouter/) template.

## Why Hermes is a stronger ORB-fit than openclaw or bux

| | openclaw | bux | **hermes** |
|---|---|---|---|
| Inbound shape | HTTP gateway (port 18789) | Telegram long-poll, no HTTP | **Telegram webhook (HTTPS)** |
| ORB wake-on-request fits? | yes | no (no inbound) | **yes (on every Telegram message)** |
| Idle detector fires? | yes | no (long-poll keeps it network-active) | **yes** |
| `[lifecycle] sleep` | `auto` | `never` | **`auto`** |
| Out-of-the-box patch needed? | no | yes (webhook patch in v0.5) | **none** |

## What's in this template

| | |
|---|---|
| LLM provider | **Z.AI GLM Coding Plan** (`zai/glm-4.7` default) |
| Inbound | Telegram via webhook (registered against `<id>.orbcloud.dev/telegram`) |
| Resources | 2 GB RAM / 8 GB disk |
| Sleep | `auto` — gateway is event-driven, idle detector demotes after 120s |
| Auth | `GLM_API_KEY` upfront, Telegram bot token post-deploy |

## Deploy

Two keys upfront — Telegram comes after:

```bash
export ORB_API_KEY=orb_...                   # https://orbcloud.dev/dashboard/keys
export GLM_API_KEY=<32hex>.<rest>            # https://z.ai/manage-apikey/apikey-list
                                             # (ZAI_API_KEY is also accepted)

bash <(curl -fsSL https://orbcloud.dev/templates/hermes)
```

First boot takes ~3-5 minutes — Hermes is a heavy install (uv venv + clone NousResearch/hermes-agent + `uv pip install -e '.[messaging,cron,cli,pty,mcp]'`). Slim extras: skip voice, web dashboard, browser/Playwright (those are a separate v0.5 question).

## Post-deploy: configure Telegram

Open the web terminal printed by `deploy.sh`:

```
https://api.orbcloud.dev/terminal/<computer-id>?key=$ORB_API_KEY
```

Then run the wizard:

```bash
hermes-setup-tg
```

The wizard:
- Walks you through `@BotFather` → `/newbot` (one minute on Telegram)
- Validates the token via `getMe`
- Registers the webhook against `https://<id>.orbcloud.dev/telegram` via `setWebhook`
- Atomic-writes `TELEGRAM_BOT_TOKEN` + `TELEGRAM_WEBHOOK_URL` + `TELEGRAM_WEBHOOK_PORT=8443` + `TELEGRAM_WEBHOOK_SECRET` to `/root/.hermes/.env`

The supervisor in `start.sh` polls every 10s for `TELEGRAM_BOT_TOKEN` to appear and exec-replaces itself with `hermes gateway start`. No manual restart.

Open `https://t.me/<your-bot>` on your phone and send any text — first message wakes the box if asleep, then GLM responds via the gateway.

## How traffic flows

```
you ─► Telegram ─► HTTPS POST ─► https://<id>.orbcloud.dev/telegram
                                          │
                                          ▼
                                ORB subdomain proxy
                                "agent asleep? wake it"
                                          │
                                          ▼
                                hermes gateway on :8443
                                          │
                                          ▼
                                hermes (zai provider)
                                          │
                                          ▼
                                ORB LLM proxy (per-computer)
                                          │
                                          ▼
                                https://api.z.ai/api/coding/paas/v4
                                          │
                                          ▼
                                GLM Coding Plan responds
                                          │
                                          ▼
                                hermes formats reply, sends via TG outbound
                                          │
                                          ▼
                                idle 120s → ORB demotes box → $0
```

LLM calls flow through ORB's per-computer LLM proxy, so the dashboard call counter ticks for every claude-equivalent turn. Telegram inbound goes through the subdomain proxy; outbound replies hit `api.telegram.org` directly.

## Sleep & wake

After 120 seconds of no Telegram traffic and no agent CPU activity, ORB's idle detector demotes the gateway to NVMe (~190 MB on disk). Next Telegram message → ORB holds the inbound POST, restores the agent in <1s, forwards. Caller-side latency: small first-message bump, otherwise unchanged.

## Tear down

```bash
SWARM_ID=...   # from the deploy output
curl -X DELETE -H "Authorization: Bearer $ORB_API_KEY" \
  https://api.orbcloud.dev/v1/swarms/$SWARM_ID
```

## Troubleshooting

**Hermes gateway never starts after running `hermes-setup-tg`.** Check `/root/.hermes/.env` for `TELEGRAM_BOT_TOKEN=` (non-empty). If present, `start.sh`'s supervisor should exec into `hermes gateway start` within 10s. Check the agent process — `ps aux | grep hermes` — to see whether `hermes gateway start` is the foreground process.

**Telegram messages don't arrive.** Verify the webhook registration: `curl https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getWebhookInfo` from the web terminal. The `url` should be `https://<id>.orbcloud.dev/telegram`. If it's wrong (e.g. left over from a prior deploy), rerun `hermes-setup-tg`.

**`hermes gateway start` errors on missing model.** Check `/root/.hermes/config.yaml` — should have `model: zai:glm-4.7` and `providers.zai.base_url`. Build steps write this; if it's wrong, edit + restart the agent (`POST /v1/computers/<id>/agents` from outside, or kill PID 1 inside).
