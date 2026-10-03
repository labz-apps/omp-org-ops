# npm automation auth

Headless npm publishing for the oh-my-pi org, without an interactive 2FA
prompt. The token lives only in a mode `0600` npm userconfig on the machine that
publishes. It is never committed here, never passed in argv, and never printed
by these scripts.

## Use it

```sh
# provision (token comes from NPM_TOKEN or stdin, never from argv)
NPM_TOKEN='npm_...' ./scripts/npm-auth.sh provision

# or, without putting the token in the environment
printf '%s' "$TOKEN" | ./scripts/npm-auth.sh provision --token-stdin

# check it works, without uploading anything
./scripts/npm-verify-auth.sh --probe

# inspect, then remove
./scripts/npm-auth.sh show
./scripts/npm-auth.sh unset
```

`provision` is idempotent and replaces only the `_authToken` line for the
registry, so it never clobbers unrelated npmrc settings. It removes both the
canonical npm key form and the scheme-less variant, so re-running it on a
hand-written npmrc cannot leave a second credential behind. It creates the
parent directory if needed, writes through a temp file, and forces mode `0600`.

The scripts run on Linux and macOS.

Environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `NPM_TOKEN` | unset | Token value for automation |
| `NPM_REGISTRY` | `https://registry.npmjs.org/` | Registry to authenticate against |
| `NPM_CONFIG_USERCONFIG` | `$HOME/.npmrc` | npmrc path to write |
| `NPM_PROBE_SPEC` | `@buckeyestudio/toh-invariants@0.1.1-rc.2` | Package@version reused by `--probe` |

## Releases are approved, never assumed

The board approves each npm release explicitly. Approval is therefore an input to
the release gate, not something the tooling infers from a green CI run or a
comment.

`scripts/npm-release-gate.sh` is the check that has to pass before a publish. It
reads a manifest, then reports one line per check:

```
$ ./scripts/npm-release-gate.sh --package @oh-my-pi/pi-tui@18.5.0 --approved-by board
release gate
   package: @oh-my-pi/pi-tui@18.5.0
   date: 2026-10-03T03:07:45Z

   manifest       [pass] @oh-my-pi/pi-tui@18.5.0 (from --package)
   not_private    [pass] manifest is publishable
   scope          [fail] @oh-my-pi/pi-tui is maintained by can1357, not buckeyestudio; this token cannot publish it, and trusted publishing from CI is the route that can
   approval       [pass] approved by board on 2026-10-03

overall: fail
```

Without `--approved-by` the approval check fails, so no release can be gated green
by accident:

```
$ ./scripts/npm-release-gate.sh --package @buckeyestudio/toh@0.1.1-rc.3
   approval       [fail] no approval recorded, pass --approved-by <id>; the board approves each release
overall: fail
```

The gate **never uploads**. It is a precondition, not a publisher. Upload stays a
separate, deliberate step so that approving one version cannot quietly ship
another. `--check-registry` adds the one network call that says whether the
version is already taken. Only `E404` counts as free; any other failure reports
that it could not ask, so an unreachable registry can never read as a pass.
`--json` emits machine-readable results, and `--report`
writes the same evidence file shape as `npm-verify-auth.sh`.

Checks, and what each one actually catches for this org:

| Check | Catches |
| --- | --- |
| `manifest` | missing, malformed, or versionless `package.json` |
| `not_private` | `oh-my-pi`'s root manifest is `private: true`, so it is not publishable at all |
| `scope` | a package owned by another account, which no token can fix |
| `version_free` | a version already on the registry, or a registry we could not reach |
| `approval` | an unrecorded approval, or an approval the expired token cannot act on |

### Nothing is releasable yet

Run against the fork, the gate fails on `not_private` and `scope`. That is the
correct result, not a bug, and it is worth stating plainly:

- `labz-apps/oh-my-pi` root `package.json` is `"private": true`.
- The publishable parts are `packages/*`, all named `@oh-my-pi/*`, maintained by
  `can1357`.
- This token is `buckeyestudio`, so it cannot write any of them.
- The perf work in this org is also not ready to release: the upstream sync has
  not landed yet, so there is no new version to ship.

So an approval to "push a new release" currently has nothing behind it that this
token can publish. Publishing a fork of the upstream scope needs npm trusted
publishing (OIDC) from CI, which is a separate piece of work.

## What `--probe` proves

The interesting question is not "can npm log in" but "will `npm publish` stop
and demand a one-time passcode". The probe answers that without a publish.

It builds a throwaway package that reuses a version the account has *already*
published, then runs `npm publish` against it. The registry authenticates the
token, checks write access, applies the 2FA gate, and only then rejects the
write at the version rule:

```
npm http fetch PUT 403 https://registry.npmjs.org/@buckeyestudio%2ftoh-invariants
npm error 403 403 Forbidden - You cannot publish over the previously published versions: 0.1.1-rc.2.
```

Reaching that specific error means every earlier gate passed, including 2FA
bypass. Nothing is uploaded and no version is consumed: the probe tarball
shasum (`1cb04642…`) differs from the live tarball (`a608f5dd…`), and the
package's versions and dist-tags are unchanged afterwards.

A token that cannot publish fails differently, and the script reports it as a
failure: `E401`/`E402`, or an OTP prompt.

## Publishing rules on this account

`npm token list` metadata, read from `GET /-/npm/v1/tokens` with the token
itself, is the source of truth. Current state:

| Field | Value |
| --- | --- |
| Username | `buckeyestudio` |
| Permission | `package:write` |
| Scopes | every package the account can write |
| 2FA bypass | `true` |
| Expires | `2026-10-10T02:48:01Z` |

Scope matters more than it looks. Write access follows package ownership, and
the packages this org cares about belong to other accounts:

| Package | Maintainer | Publishable with this token |
| --- | --- | --- |
| `paperclipai` | `dotta` | no |
| `@oh-my-pi/*` | `can1357` | no |
| `@buckeyestudio/*` | `buckeyestudio` | yes |

So this token covers manual publishes of `@buckeyestudio/*` artifacts only. It
is not a way to publish the Paperclip CLI or a fork of the upstream
`@oh-my-pi` scope. For those, use npm trusted publishing (OIDC) from CI, which
needs no token and no 2FA at all.

## Rotation and expiry

The current token expires **2026-10-10**, one week after it was created. When it
does, publishes start failing and `./scripts/npm-verify-auth.sh` reports
`fail`. Fix it by issuing a new granular token on npmjs.com with:

- package permissions: **read and write**
- 2FA bypass: **on** (required for direct publishing)
- scope: the packages you intend to publish, or all packages
- expiry: as long as you are willing to re-issue

Then re-run `provision`. There is no rotation state to migrate, because the only
copy of the token is the npm userconfig on each publishing machine.

If npm ever stops honoring 2FA bypass for direct publishes, the failure shows up
as an OTP demand in the probe. The fix is trusted publishing, not a better
token: configure the GitHub Actions workflow and repo on the npm package page,
then drop the token entirely.

## Evidence log

| Date (UTC) | Machine | Result |
| --- | --- | --- |
| 2026-10-03 | linux x64, node v24.21.0, npm 11.19.0 | `npm whoami` -> `buckeyestudio`, no prompt |
| 2026-10-03 | same | token metadata: `package:write`, `bypass_2fa: true`, expires 2026-10-10 |
| 2026-10-03 | same | publish probe -> E403 at version rule, nothing published |
| 2026-10-03 | same | release gate -> `omp@0.0.0` fails `not_private` and `scope` |
| 2026-10-03 | same | release gate -> `@oh-my-pi/pi-tui@18.5.0` fails `scope`, maintainer `can1357` |
| 2026-10-03 | same | release gate -> `@buckeyestudio/toh@0.1.1-rc.2` fails `version_free`, already published |

Reproduce with `./scripts/npm-verify-auth.sh --probe` after `provision`.