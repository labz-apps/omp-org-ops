# omp-org-ops

Operations runbooks for the oh-my-pi org. Nothing here is a performance change
to the agent itself; this repo holds the tooling and docs that keep the org's
automation unblocked.

| Doc | What it covers |
| --- | --- |
| [docs/npm-publishing.md](docs/npm-publishing.md) | Headless npm publishing with a granular token, no 2FA prompt |

## Scripts

| Script | Purpose |
| --- | --- |
| `scripts/npm-auth.sh` | Write or remove npm registry auth in a mode `0600` npmrc |
| `scripts/npm-verify-auth.sh` | Prove the token can publish without an OTP, without uploading anything |

Both scripts take the token from `NPM_TOKEN` or stdin, never from argv, and
never print it. CI runs the offline self-test in `.github/workflows/ci.yml`; the
registry-facing checks are opt-in because they need network and a real token.

## Credentials

No credential is stored in this repo. The token lives in the npm userconfig of
the machine that publishes. Do not commit `.npmrc`.