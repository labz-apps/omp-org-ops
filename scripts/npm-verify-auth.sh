#!/usr/bin/env bash
# Verify npm automation auth for the oh-my-pi org.
#
# Read-only checks (default): identity via `npm whoami`, then token metadata
# from the registry, redacted. Reports whether the token bypasses 2FA, what it
# may write, and when it expires.
#
# Optional --probe: proves the *publish* path is authorized without uploading
# anything. It builds a throwaway package that reuses a version already
# published by the account, so the registry accepts the write request, passes
# authn/authz/2FA, and then rejects it at the version-conflict rule. Success is
# E403 "You cannot publish over the previously published versions". Nothing is
# published and no version is consumed. A 401/402, or an OTP prompt, fails.
set -euo pipefail

REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org/}"
PROBE_SPEC="${NPM_PROBE_SPEC:-@buckeyestudio/toh-invariants@0.1.1-rc.2}"
REPORT_DIR="${NPM_REPORT_DIR:-}"

usage() {
	cat <<'EOF'
Usage:
  npm-verify-auth.sh [--probe] [--report <dir>]

  --probe         run the non-destructive publish authorization probe
  --report <dir>  write a redacted evidence file for the run

Environment:
  NPM_TOKEN        token to inspect; defaults to the value in the npm userconfig
  NPM_REGISTRY     registry URL, default https://registry.npmjs.org/
  NPM_PROBE_SPEC   package@version to reuse for the probe
EOF
}

fail=0

read -r -d '' PARSE_TOKEN_META <<'PY' || true
import json
import os
import sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)

want = os.environ["MATCH"]
for obj in data.get("objects", []):
    if obj.get("token") != want:
        continue
    permissions = ", ".join(
        f"{p.get('name')}:{p.get('action')}" for p in obj.get("permissions", [])
    )
    scopes = ", ".join(str(s.get("name")) for s in obj.get("scopes", []))
    bypass = bool(obj.get("bypass_2fa"))
    revoked = bool(obj.get("revoked"))
    ok = bypass and not revoked
    print(f"   name: {obj.get('name')}")
    print(f"   bypass 2FA: {str(bypass).lower()}")
    print(f"   permissions: {permissions or 'none'}")
    print(f"   scopes: {scopes or 'every package the account can write'}")
    print(f"   expires: {obj.get('expiry')}")
    print(f"   revoked: {str(revoked).lower()}")
    print(f"   publish without 2FA: {'yes' if ok else 'no'}")
    print(f"   {'pass' if ok else 'fail'}")
    sys.exit(0 if ok else 3)
sys.exit(1)
PY

resolve_token() {
	if [[ -n "${NPM_TOKEN:-}" ]]; then
		printf '%s' "$NPM_TOKEN"
		return
	fi
	local userconfig="${NPM_CONFIG_USERCONFIG:-${HOME}/.npmrc}"
	local host="${REGISTRY#*://}"
	[[ -f "$userconfig" ]] || return 0
	sed -n "s|^//${host%/}/:_authToken=||p" "$userconfig" | head -n 1 || true
}

masked_token() {
	local token="$1"
	if [[ ${#token} -le 12 ]]; then
		printf '***'
	else
		printf '%s...%s' "${token:0:8}" "${token: -4}"
	fi
}

check_identity() {
	local whoami
	printf '== identity\n'
	if whoami="$(npm whoami 2>&1)"; then
		printf '   npm whoami: %s (no prompt, no OTP)\n' "$whoami"
	else
		printf '   npm whoami FAILED:\n%s\n' "$whoami"
		fail=1
	fi
}

check_token_metadata() {
	local token="$1" body masked rc=0 out

	printf '== token metadata (read from %s)\n' "${REGISTRY}-/npm/v1/tokens"
	masked="$(masked_token "$token")"

	body="$(curl -sS --max-time 30 -H "Authorization: Bearer $token" "${REGISTRY}-/npm/v1/tokens" 2>/dev/null || true)"
	if [[ -z "$body" ]]; then
		printf '   token metadata unavailable (token may lack token:read)\n'
		printf '   fail\n'
		return 1
	fi

	out="$(MATCH="$masked" python3 -c "$PARSE_TOKEN_META" "$body" 2>/dev/null)" || rc=$?
	printf '%s\n' "$out"

	if [[ $rc -eq 0 ]]; then
		return 0
	fi

	if [[ $rc -eq 3 ]]; then
		printf '   supplied token cannot publish without 2FA\n'
	else
		printf '   supplied token not found in the token list\n'
	fi
	return 1
}

check_publish_probe() {
	local spec="$1" name version workdir output code

	name="${spec%@*}"
	version="${spec##*@}"
	workdir="$(mktemp -d)"

	printf '== publish authorization probe (no upload)\n'
	printf '   reusing already published %s@%s\n' "$name" "$version"

	mkdir -p "$workdir/pkg"
	cat >"$workdir/pkg/package.json" <<EOF
{
  "name": "$name",
  "version": "$version",
  "description": "publish auth probe, never uploaded",
  "license": "MIT"
}
EOF
	printf '{}\n' >"$workdir/pkg/index.js"

	set +e
	output="$(cd "$workdir/pkg" && npm publish --ignore-scripts --tag rc --provenance=false 2>&1)"
	code=$?
	set -e
	rm -rf "$workdir"

	if [[ $code -eq 0 ]]; then
		printf '   UNEXPECTED: publish succeeded, the probe reused a live version\n'
		printf '   fail\n'
		fail=1
		return 0
	fi

	if printf '%s' "$output" | grep -q "cannot publish over the previously published versions"; then
		printf '   registry rejected the write at the version rule (E403)\n'
		printf '   authn, authz, and 2FA bypass all passed; nothing published\n'
		printf '   pass\n'
		return 0
	fi

	printf '   unexpected publish failure:\n'
	printf '%s\n' "$output" | sed 's/^/   | /'
	printf '   fail\n'
	fail=1
}

main() {
	local probe=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--probe)
			probe=1
			;;
		--report)
			REPORT_DIR="${2:?--report needs a path}"
			shift
			;;
		--help | -h)
			usage
			return 0
			;;
		*)
			echo "npm-verify-auth.sh: unknown argument $1" >&2
			usage >&2
			return 2
			;;
		esac
		shift
	done

	local token
	token="$(resolve_token)"
	if [[ -z "$token" ]]; then
		echo "npm-verify-auth.sh: no npm token found in NPM_TOKEN or the npm userconfig" >&2
		return 2
	fi

	printf 'registry: %s\n' "$REGISTRY"
	printf 'token: %s (redacted)\n' "$(masked_token "$token")"
	printf 'node: %s npm: %s\n' "$(node --version)" "$(npm --version)"
	printf 'date: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	check_identity
	echo
	check_token_metadata "$token" || fail=1
	echo

	if [[ "$probe" == "1" ]]; then
		check_publish_probe "$PROBE_SPEC"
		echo
	fi

	if [[ -n "$REPORT_DIR" ]]; then
		mkdir -p "$REPORT_DIR"
		{
			printf 'registry=%s\n' "$REGISTRY"
			printf 'token=%s\n' "$(masked_token "$token")"
			printf 'npm_version=%s\n' "$(npm --version)"
			printf 'node_version=%s\n' "$(node --version)"
			printf 'publish_probe=%s\n' "$probe"
			printf 'result=%s\n' "$([[ $fail -eq 0 ]] && echo pass || echo fail)"
			printf 'verified_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		} >"$REPORT_DIR/npm-auth-report.txt"
		printf 'report: %s\n' "$REPORT_DIR/npm-auth-report.txt"
	fi

	printf 'overall: %s\n' "$([[ $fail -eq 0 ]] && echo pass || echo fail)"
	[[ $fail -eq 0 ]]
}

main "$@"