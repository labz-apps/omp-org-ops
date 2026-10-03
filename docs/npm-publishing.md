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
registry, so it never clobbers unrelated npmrc settings. It creates the parent
directory if needed, writes through a temp file, and forces mode `0600`.

Environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `NPM_TOKEN` | unset | Token value for automation |
| `NPM_REGISTRY` | `https://registry.npmjs.org/` | Registry to authenticate against |
| `NPM_CONFIG_USERCONFIG` | `$HOME/.npmrc` | npmrc path to write |
| `NPM_PROBE_SPEC` | `@buckeyestudio/toh-invariants@0.1.1-rc.2` | Package@version reused by `--probe` |

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

Reproduce with `./scripts/npm-verify-auth.sh --probe` after `provision`.