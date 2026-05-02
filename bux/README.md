# bux on ORB Cloud

Self-host [bux](https://github.com/browser-use/bux) — a 24/7 Claude Code agent with a real browser, texted via Telegram — on ORB Cloud.

**Why on ORB**: bux is a long-lived agent box. Upstream's deploy story is "rent a $5 VPS." ORB lets you skip the VPS provisioning, get a clean sandbox + web terminal + subdomain in one command, and keeps the door open to migrate to webhook-mode for $0-idle in v0.5.

## What you get

- **Claude Code** running 24/7, authenticated via your `claude /login` (Anthropic API key OR Claude Max OAuth — your call)
- A real **Chromium** session via [browser-harness](https://github.com/browser-use/browser-harness), running on **Browser Use Cloud** (not in your sandbox, so CRIU can checkpoint your agent cleanly)
- A **Telegram bot** for texting your agent — first-chat-wins binding, subsequent chats are silently dropped
- The **ORB web terminal** (`/terminal/<computer-id>`) for `claude /login` and any debugging — same UX as SSH-ing to a box, no key management needed

## Deploy

Only **two** keys upfront — no Telegram setup required before deploy:

```bash
export ORB_API_KEY=orb_...               # https://orbcloud.dev/dashboard/keys
export BROWSER_USE_API_KEY=bu_...        # https://cloud.browser-use.com/new-api-key

bash <(curl -fsSL https://orbcloud.dev/templates/bux)
```

Deploy returns:
- The computer ID + ORB web terminal URL
- The teardown command

First boot takes ~2–4 minutes (apt + node + npm + python deps). After that, `browser_keeper.py` warms a Browser Use Cloud session in ~10s. The Telegram bot waits — `start.sh` runs a supervisor that polls every 5s for `/etc/bux/tg.env` to appear; until then only the keeper is running.

## Post-deploy, in this order

Open the web terminal printed by `deploy.sh`:

```
https://api.orbcloud.dev/terminal/<computer-id>?key=$ORB_API_KEY
```

### 1. Authenticate Claude Code

```bash
sudo -iu bux
claude /login
```

OAuth opens in your laptop browser; paste the resulting code back into the terminal. Claude saves the auth at `/home/bux/.claude/` — preserved across reboots, sleep/wake (when v0.5 lands), and re-deploys (as long as you don't delete the computer).

### 2. Set up the Telegram bot

Back as root (`exit` from the bux user shell), run the wizard:

```bash
bux-setup-tg
```

The wizard:
- Walks you through `@BotFather` → `/newbot` (one minute on Telegram)
- Captures the bot token, validates it via `getMe`
- Generates a one-shot setup token
- Writes `/etc/bux/tg.env` atomically
- Prints a `t.me/<your-bot>?start=<token>` deeplink

The supervisor in `start.sh` picks up the env file on its next 5-second tick and starts `telegram_bot.py` automatically. Tail `/var/log/bux/tg.log` to confirm.

Then tap the deeplink. The first chat to redeem it binds the bot — subsequent chats from anyone else are silently ignored (bux's first-chat-wins anti-hijack model).

### 3. Text your agent

```
you: visit https://browser-use.com and tell me the page title
bot: 🧠 on it…
bot: Title: "Browser Use - the AI browser agent that gets stuff done"
```

Follow-ups work — every message is its own claude turn but shares memory with previous ones in the same chat:

```
you: now check if there's a pricing page linked
bot: yes — https://browser-use.com/pricing. Want me to summarize it?
```

## How LLM + browser traffic flows

```
you ─► Telegram ─► (long-poll) ─► telegram_bot.py ──► claude
                                                       │
                                                       ├─► ORB LLM proxy ─► api.anthropic.com
                                                       │   (per-call observable on dashboard)
                                                       │
                                                       └─► browser-harness ─► BU Cloud
                                                           CDP-over-WSS         (chromium runs here)
```

Anthropic LLM calls flow through ORB's per-computer LLM proxy, so the dashboard's call counter ticks for every claude turn. Browser traffic goes directly to Browser Use Cloud over WSS — that's intentional, it's how the chromium-in-the-sandbox CRIU problem is sidestepped.

## Sleep & wake

**v0 (this template): pinned in RAM** (`sleep = "never"`). Two reasons:

- **Telegram long-poll re-opens every ~25–30s.** ORB's idle detector watches network bytes over a 120s window and sees activity, so the demote never fires.
- **`browser_keeper.py` sits in a 3.5-hour `clock_nanosleep`** between session rotations. The runtime treats `clock_nanosleep` as "intentional scheduled wakeup" (per `runtime/spec/idle-sleep.md:101`) and doesn't demote.

Both are solvable, but they need real patches. v0 ships the faithful port; v0.5 swaps Telegram to webhook mode and rewrites the keeper's sleep loop to use `select.select` (passive). Then `sleep = "auto"` and the box demotes between messages — sub-second wake on the next `setWebhook` POST from Telegram.

## Tear down

```bash
SWARM_ID=...   # from the deploy output
curl -X DELETE -H "Authorization: Bearer $ORB_API_KEY" \
  https://api.orbcloud.dev/v1/swarms/$SWARM_ID

# And clean up the BU Cloud profile (fresh per-deploy state):
BUX_PROFILE_ID=...   # from the deploy output
curl -X DELETE -H "X-Browser-Use-API-Key: $BROWSER_USE_API_KEY" \
  https://api.browser-use.com/api/v3/profiles/$BUX_PROFILE_ID
```

## Roadmap

- **v0.5** — Telegram webhook mode + passive-sleep keeper → `sleep = "auto"`, $0-idle works
- **v0.6** — optional `claude` ↔ `codex` agent switching (bux upstream supports this; we just expose it as an `[agent.env]` flag)
- **v0.7** — multi-tenant: 1 swarm = N replicas, each its own profile + bot token, deploys via `POST /v1/swarms` with `replicas=N`
