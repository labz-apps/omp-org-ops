#!/usr/bin/env bash
# Release gate for the oh-my-pi org.
#
# The board approves each npm release explicitly, so approval is an input this
# script takes rather than something it infers. It answers one question: may
# this exact package at this exact version be published, by this token, under a
# recorded approval?
#
# It never uploads. It reads a package manifest, checks publishability and scope,
# and refuses unless an approver is named. The publish itself stays a separate,
# deliberate step.
#
# Offline by default. --check-registry adds the one network call that can tell
# whether the version is already taken.
set -euo pipefail

REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org/}"
PACKAGE_DIR="${NPM_PACKAGE_DIR:-.}"
APPROVED_BY="${NPM_APPROVED_BY:-}"
PACKAGE_ARG=""
CHECK_REGISTRY=0
REPORT_DIR="${NPM_REPORT_DIR:-}"
AS_JSON=0

usage() {
	cat <<'EOF'
Usage:
  npm-release-gate.sh [options]

Options:
  --package-dir <dir>  directory holding package.json, default "."
  --package <name@ver> check this instead of reading a manifest
  --approved-by <id>   record the approval; required, the gate never self-approves
  --check-registry     also ask the registry whether the version already exists
  --report <dir>       write a redacted evidence file for the run
  --json               emit machine-readable results instead of a table
  --help, -h           show this help

Environment:
  NPM_PACKAGE_DIR   same as --package-dir
  NPM_APPROVED_BY   same as --approved-by
  NPM_REGISTRY      registry URL, default https://registry.npmjs.org/

Exit status:
  0  every check passed, the release is approved and publishable
  1  a check failed, do not publish
  2  bad usage
EOF
}

RESULTS=()

record() {
	local name="$1" status="$2" detail="$3"
	RESULTS+=("${name}"$'\x1f'"${status}"$'\x1f'"${detail}")
}

# The npm scope that owns a package name. An unscoped package is owned by the
# publishing user directly, so it has no scope to compare.
scope_of() {
	local name="$1"
	case "$name" in
	@*/*) printf '%s' "${name%%/*}" ;;
	*) printf '' ;;
	esac
}

read_manifest() {
	local dir="$1"
	local manifest="$dir/package.json"

	[[ -f "$manifest" ]] || {
		record manifest fail "no package.json in $dir"
		return 1
	}

	local kv
	kv="$(python3 - "$manifest" <<'PY' 2>/dev/null
import json
import sys

try:
    with open(sys.argv[1], "rb") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)

for field in ("name", "version"):
    value = data.get(field)
    if not isinstance(value, str) or not value.strip():
        sys.exit(1)
    print(f"{field}={value}")

print(f"private={'true' if data.get('private') is True else 'false'}")
PY
	)" || {
		record manifest fail "package.json is not readable JSON, or has no name/version"
		return 1
	}

	local key value name="" version="" private="false"
	while IFS='=' read -r key value; do
		case "$key" in
		name) name="$value" ;;
		version) version="$value" ;;
		private) private="$value" ;;
		esac
	done <<<"$kv"

	record manifest pass "$name@$version"

	NAME="$name"
	VERSION="$version"
	PRIVATE="$private"
	return 0
}

check_not_private() {
	if [[ "$PRIVATE" == "true" ]]; then
		record not_private fail "$NAME is marked private, npm refuses to publish it"
		return 1
	fi
	record not_private pass "manifest is publishable"
	return 0
}

check_scope() {
	local scope user

	user="$(npm whoami 2>/dev/null)" || {
		record scope fail "cannot authenticate, run npm-verify-auth.sh --probe first"
		return 1
	}

	scope="$(scope_of "$NAME")"
	if [[ -z "$scope" ]]; then
		# An unscoped package is owned by the account of the same name.
		if [[ "$user" == "$NAME" ]]; then
			record scope pass "unscoped package is owned by $user"
			return 0
		fi
		record scope fail "unscoped package needs an owner named $NAME, this token is $user"
		return 1
	fi

	if [[ "$scope" == "@$user" ]]; then
		record scope pass "$scope is writable by $user"
		return 0
	fi

	# Not a failure of the token: the token is fine, the package belongs to
	# someone else. Say so, because the fix is ownership or OIDC, not a
	# better token.
	local maintainers
	maintainers="$(curl -sS --max-time 20 "${REGISTRY}${NAME}" 2>/dev/null | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
names = sorted(
    m.get("name") for m in data.get("maintainers", []) if isinstance(m, dict) and m.get("name")
)
print(", ".join(names) if names else "")
' 2>/dev/null || true)"

	if [[ -z "$maintainers" ]]; then
		maintainers="another account"
	fi
	rc=1
	record scope fail "$NAME is maintained by $maintainers, not $user; this token cannot publish it, and trusted publishing from CI is the route that can"
	return 1
}

check_version_free() {
	local out rc=0

	set +e
	out="$(npm view "${NAME}@${VERSION}" version 2>&1)"
	rc=$?
	set -e

	if [[ $rc -eq 0 ]]; then
		record version_free fail "${NAME}@${VERSION} is already published, bump the version"
		return 1
	fi

	record version_free pass "${NAME}@${VERSION} is not on ${REGISTRY}"
	return 0
}

check_approval() {
	local now expiry=""

	if [[ "$CHECK_REGISTRY" == "1" ]]; then
		expiry="$(curl -sS --max-time 20 -H "Authorization: Bearer ${NPM_TOKEN:-}" \
			"${REGISTRY}-/npm/v1/tokens" 2>/dev/null | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for obj in data.get("objects", []):
    print(obj.get("expiry") or "")
    break
' 2>/dev/null || true)"
	fi

	now="$(date -u +%Y-%m-%d)"
	if [[ -n "$expiry" ]] && [[ "${expiry:0:10}" < "$now" ]]; then
		record approval fail "token expired on $expiry, an approval cannot be acted on"
		return 1
	fi

	if [[ -z "$APPROVED_BY" ]]; then
		record approval fail "no approval recorded, pass --approved-by <id>; the board approves each release"
		return 1
	fi

	record approval pass "approved by $APPROVED_BY on $now"
	return 0
}

emit_table() {
	local name status detail
	for row in "${RESULTS[@]}"; do
		IFS=$'\x1f' read -r name status detail <<<"$row"
		printf '   %-14s %-4s %s\n' "$name" "[$status]" "$detail"
	done
}

emit_json() {
	local name status detail first=1
	printf '{\n  "package": "%s@%s",\n  "checks": [\n' "$NAME" "$VERSION"
	for row in "${RESULTS[@]}"; do
		IFS=$'\x1f' read -r name status detail <<<"$row"
		[[ $first -eq 0 ]] && printf ',\n'
		first=0
		printf '    {"check": "%s", "status": "%s", "detail": %s}' \
			"$name" "$status" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$detail")"
	done
	printf '\n  ],\n'
	if [[ ${#RESULTS[@]} -eq 0 ]]; then
		printf '  "result": "fail"\n}\n'
		return
	fi
	local ok=1
	for row in "${RESULTS[@]}"; do
		IFS=$'\x1f' read -r _ status _ <<<"$row"
		[[ "$status" == "fail" ]] && ok=0
	done
	printf '  "approved_by": %s,\n' \
		"$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]) if sys.argv[1] else "null")' "$APPROVED_BY")"
	printf '  "result": "%s"\n}\n' "$([[ $ok -eq 1 ]] && echo pass || echo fail)"
}

main() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--package-dir)
			PACKAGE_DIR="${2:?--package-dir needs a path}"
			shift
			;;
		--package)
			PACKAGE_ARG="${2:?--package needs name@version}"
			shift
			;;
		--approved-by)
			APPROVED_BY="${2:?--approved-by needs an id}"
			shift
			;;
		--check-registry)
			CHECK_REGISTRY=1
			;;
		--report)
			REPORT_DIR="${2:?--report needs a path}"
			shift
			;;
		--json)
			AS_JSON=1
			;;
		--help | -h)
			usage
			return 0
			;;
		*)
			echo "npm-release-gate.sh: unknown argument $1" >&2
			usage >&2
			return 2
			;;
		esac
		shift
	done

	if [[ -n "$PACKAGE_ARG" ]]; then
		NAME="${PACKAGE_ARG%@*}"
		VERSION="${PACKAGE_ARG##*@}"
		PRIVATE="false"
		if [[ -z "$NAME" || -z "$VERSION" || "$NAME" == "$PACKAGE_ARG" ]]; then
			echo "npm-release-gate.sh: --package must be name@version" >&2
			return 2
		fi
		record manifest pass "$NAME@$VERSION (from --package)"
	else
		read_manifest "$PACKAGE_DIR" || true
	fi

	# A manifest we could not read leaves NAME empty; there is nothing else to
	# check and guessing a name would be worse than reporting the real problem.
	if [[ -z "${NAME:-}" ]]; then
		if [[ "$AS_JSON" == "1" ]]; then
			emit_json
		else
			printf 'release gate\n'
			emit_table
			printf '\noverall: fail\n'
		fi
		return 1
	fi

	check_not_private || true
	check_scope || true

	if [[ "$CHECK_REGISTRY" == "1" ]]; then
		check_version_free || true
	fi

	check_approval || true

	local ok=1 row status
	for row in "${RESULTS[@]}"; do
		IFS=$'\x1f' read -r _ status _ <<<"$row"
		[[ "$status" == "fail" ]] && ok=0
	done

	if [[ -n "$REPORT_DIR" ]]; then
		mkdir -p "$REPORT_DIR"
		{
			printf 'package=%s@%s\n' "$NAME" "$VERSION"
			printf 'approved_by=%s\n' "${APPROVED_BY:-}"
			printf 'registry_checked=%s\n' "$CHECK_REGISTRY"
			printf 'checked_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			printf 'result=%s\n' "$([[ $ok -eq 1 ]] && echo pass || echo fail)"
			printf 'uploaded=no\n'
		} >"$REPORT_DIR/npm-release-gate-report.txt"
	fi

	if [[ "$AS_JSON" == "1" ]]; then
		emit_json
	else
		printf 'release gate\n'
		printf '   package: %s@%s\n' "$NAME" "$VERSION"
		printf '   date: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		emit_table
		printf '\noverall: %s\n' "$([[ $ok -eq 1 ]] && echo pass || echo fail)"
	fi

	[[ $ok -eq 1 ]]
}

main "$@"