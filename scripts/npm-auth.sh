#!/usr/bin/env bash
# Provision headless npm auth for the oh-my-pi org from a granular access token.
# The token is read from NPM_TOKEN or stdin only. It is never placed in argv,
# stdout, or a log line, and the file it writes is mode 0600.
set -euo pipefail

REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org/}"
USERCONFIG="${NPM_CONFIG_USERCONFIG:-${HOME}/.npmrc}"

# npm keys auth by bare host, without scheme or trailing slash.
registry_host() {
	local host="${1#*://}"
	printf '%s' "${host%/}"
}

# GNU stat and BSD stat disagree on the flag for octal mode. The npmrc ends up on
# developer laptops as often as on CI, so ask for the mode in a way both accept.
file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Drops every auth line for the registry, in both the canonical form npm writes
# (/host/:_authToken=) and the scheme-less variant, so re-running provision on a
# hand-written or older npmrc cannot leave a second credential behind.
drop_auth_lines() {
	local host="${1}" path="${2}"

	awk -v host="$host" '
		index($0, "//" host) == 1 {
			rest = substr($0, length("//" host) + 1)
			if (index(rest, "/:_authToken=") == 1) next
			if (index(rest, ":_authToken=") == 1) next
		}
		{ print }
	' "$path"
}

usage() {
	cat <<'EOF'
Usage:
  npm-auth.sh provision [--token-stdin] [--npmrc <path>]
  npm-auth.sh show [--npmrc <path>]
  npm-auth.sh unset [--npmrc <path>]

provision  writes registry auth into the npm userconfig file, replacing any
           previous _authToken line for that registry. Token source, in order
           of preference: --token-stdin, NPM_TOKEN, interactive prompt.
show       prints the config path, file mode, and whether a token is present.
           The token value is never printed.
unset      removes the _authToken line for the registry.

Environment:
  NPM_TOKEN              token value (preferred for automation)
  NPM_REGISTRY           registry URL, default https://registry.npmjs.org/
  NPM_CONFIG_USERCONFIG  npmrc path, default $HOME/.npmrc
EOF
}

read_token() {
	local from_stdin="${1:-0}"

	if [[ "$from_stdin" == "1" ]]; then
		cat
	elif [[ -n "${NPM_TOKEN:-}" ]]; then
		printf '%s' "$NPM_TOKEN"
	elif [[ -t 0 ]]; then
		read -r -s -p "npm token: " token
		printf '\n' >&2
		printf '%s' "$token"
	else
		echo "npm-auth.sh: no token available (use NPM_TOKEN or --token-stdin)" >&2
		exit 2
	fi
}

write_npmrc() {
	local token="${1}" path="${2}" tmp key

	key="//$(registry_host "$REGISTRY")/:_authToken="
	tmp="$(mktemp "${path}.XXXXXX")"
	chmod 600 "$tmp"

	if [[ -f "$path" ]]; then
		drop_auth_lines "$(registry_host "$REGISTRY")" "$path" |
			awk '/^registry=/ { next } { print }' >"$tmp"
	fi

	{
		printf 'registry=%s\n' "$REGISTRY"
		printf '%s%s\n' "$key" "$token"
	} >>"$tmp"

	mv -f "$tmp" "$path"
	chmod 600 "$path"
}

cmd_provision() {
	local from_stdin=0 path="$USERCONFIG" token

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--token-stdin)
			from_stdin=1
			;;
		--npmrc)
			path="${2:?--npmrc needs a path}"
			shift
			;;
		*)
			echo "npm-auth.sh: unknown argument $1" >&2
			usage >&2
			exit 2
			;;
		esac
		shift
	done

	token="$(read_token "$from_stdin")"
	token="${token#"${token%%[![:space:]]*}"}"
	token="${token%"${token##*[![:space:]]}"}"

	if ! printf '%s' "$token" | grep -Eq '^npm_[A-Za-z0-9]{20,}$'; then
		echo "npm-auth.sh: token does not look like an npm access token" >&2
		exit 2
	fi

	local dir
	dir="$(dirname "$path")"
	mkdir -p "$dir"

	write_npmrc "$token" "$path"
	unset token

	printf 'wrote %s (mode 0600, registry %s)\n' "$path" "$REGISTRY"
}

cmd_show() {
	local path="$USERCONFIG"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--npmrc)
			path="${2:?--npmrc needs a path}"
			shift
			;;
		*)
			echo "npm-auth.sh: unknown argument $1" >&2
			exit 2
			;;
		esac
		shift
	done

	if [[ ! -f "$path" ]]; then
		printf 'npmrc: %s (missing)\n' "$path"
		return 1
	fi

	local mode count
	mode="$(file_mode "$path")"
	count="$(grep -c "^//$(registry_host "$REGISTRY")/:_authToken=." "$path" || true)"

	printf 'npmrc: %s\n' "$path"
	printf 'mode: %s\n' "$mode"
	printf 'registry: %s\n' "$REGISTRY"
	printf 'token present: %s\n' "$([[ "$count" -gt 0 ]] && echo yes || echo no)"
	printf 'token lines: %s\n' "$count"

	[[ "$mode" == "600" && "$count" == "1" ]]
}

cmd_unset() {
	local path="$USERCONFIG" tmp
	[[ -f "$path" ]] || {
		printf 'npmrc: %s (missing, nothing to remove)\n' "$path"
		return 0
	}

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--npmrc)
			path="${2:?--npmrc needs a path}"
			shift
			;;
		*)
			echo "npm-auth.sh: unknown argument $1" >&2
			exit 2
			;;
		esac
		shift
	done

	tmp="$(mktemp "${path}.XXXXXX")"
	chmod 600 "$tmp"
	drop_auth_lines "$(registry_host "$REGISTRY")" "$path" >"$tmp"
	mv -f "$tmp" "$path"
	chmod 600 "$path"
	printf 'removed registry auth from %s\n' "$path"
}

main() {
	local cmd="${1:-usage}"
	shift || true

	case "$cmd" in
	provision)
		cmd_provision "$@"
		;;
	show)
		cmd_show "$@"
		;;
	unset)
		cmd_unset "$@"
		;;
	usage | --help | -h)
		usage
		;;
	*)
		echo "npm-auth.sh: unknown command $cmd" >&2
		usage >&2
		exit 2
		;;
	esac
}

main "$@"