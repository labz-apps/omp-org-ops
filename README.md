# omp-org-ops

Operations runbooks for the oh-my-pi org. Nothing here is a performance change
to the agent itself; this repo holds the tooling and docs that keep the org's
automation unblocked.

| Doc | What it covers |
| --- | --- |
| [docs/performance-sop.md](docs/performance-sop.md) | How the org does research, code experiments, benchmarks, pull requests, merges, and publication |
| [docs/measurement-contract.md](docs/measurement-contract.md) | What is measured, what must be held constant, and the result file contract from harness to page |
| [docs/npm-publishing.md](docs/npm-publishing.md) | Headless npm publishing with a granular token, no 2FA prompt, and the release approval gate |

## Scripts

| Script | Purpose |
| --- | --- |
| `scripts/npm-auth.sh` | Write or remove npm registry auth in a mode `0600` npmrc |
| `scripts/npm-verify-auth.sh` | Prove the token can publish without an OTP, without uploading anything |
| `scripts/npm-release-gate.sh` | Decide whether one exact version may be published, under a recorded approval |
| `scripts/check-sop-links.sh` | Fail CI when a doc names a link, local path, or section that no longer exists |

`npm-release-gate.sh` never uploads. It is the precondition a publish has to pass:
it checks the manifest, the `private` flag, package ownership against the
authenticated account, optionally whether the version is free, and that an
approval is recorded. Without `--approved-by` it always fails.

The npm scripts take the token from `NPM_TOKEN` or stdin, never from argv, and
never print it. CI runs the offline self-test in `.github/workflows/ci.yml`; the
registry-facing checks are opt-in because they need network and a real token.
`check-sop-links.sh` is offline and runs on every pull request, so a runbook
cannot drift away from the repository it describes without the build noticing.

## Credentials

No credential is stored in this repo. The token lives in the npm userconfig of
the machine that publishes. Do not commit `.npmrc`.