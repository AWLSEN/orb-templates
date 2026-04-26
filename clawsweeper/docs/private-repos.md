# Private repos

The clawsweeper template works for both public and private GitHub repos with no
configuration difference — just provide a `GITHUB_TOKEN` with the right scopes.

## How it works

The `start-shard.sh` wrapper clones your target repo using the token in the URL:

```bash
TARGET_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${CLAWSWEEPER_TARGET_REPO}"
git clone --depth=1 "$TARGET_URL" /agent/openclaw
```

`gh` CLI inside clawsweeper picks up the same `GITHUB_TOKEN` env var automatically and
uses it for all API calls (issue list, comment, close, etc.).

## Token scopes

For the deploy to work end to end, your token needs:

- **Read on `TARGET_REPO`** — to enumerate issues + PRs, fetch their bodies and comments,
  and `git fetch` the latest main branch for context.
- **Write on `REPORT_REPO`** — to commit the per-item review markdown and update the
  workflow status block in the README. (`REPORT_REPO` defaults to the same as `TARGET_REPO`.)
- **Issues + PRs read/write** — clawsweeper's apply step (when enabled) closes issues,
  posts comments linking back to the audit file. Token must have those permissions.

For a personal-account token: classic `repo` scope covers all of it. For a fine-grained
token: select the target repo, grant Contents (read+write), Issues (read+write), and
Pull requests (read+write).

For an org repo where you want to scope tightly: a fine-grained token issued to a
service account with read on TARGET_REPO and contents/issues/pulls write on REPORT_REPO.
ORB encrypts this token at rest in its secret store so it's never visible after deploy.

## Token rotation

Want to rotate the token? Re-run the deploy with the new value:

```bash
export GITHUB_TOKEN=<new-token>
bash <(curl -fsSL https://orbcloud.dev/templates/clawsweeper)
```

ORB merges the new secret into the org's encrypted store and redeploys all replicas
with the updated env. Old token is replaced on every running replica.

## Caveat — clawsweeper's hardcoded constants

Upstream clawsweeper hardcodes `TARGET_REPO = "openclaw/openclaw"`. Our template
applies a small in-tree patch (`patches/env-overridable-repos.patch`) at build time
that makes this read from `process.env.CLAWSWEEPER_TARGET_REPO` first. Same for
`REPORT_REPO`.

The patch is small and we're upstreaming it. Once merged in clawsweeper main,
this template will use pristine upstream and the patch step becomes a no-op.
