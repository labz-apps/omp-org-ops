#!/usr/bin/env bash
# Keep the org runbooks honest.
#
# A runbook that names a command, a path, or a section that no longer exists is
# worse than no runbook: agents follow it, hit a missing file, and burn a
# heartbeat. This check is the guard. It runs offline and fails closed.
#
#   bash scripts/check-sop-links.sh
#
# Rules enforced:
#   1. every local markdown link in README.md and docs/ resolves to a real file
#   2. every bare local path quoted in backticks exists
#      (cross-repo paths are written owner/repo-qualified and are skipped)
#   3. every doc still carries the sections the programme depends on
#   4. every fenced code block is balanced
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

failures=0
fail() {
  printf 'FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}

docs=(README.md)
while IFS= read -r doc; do
  docs+=("$doc")
done < <(find docs -name '*.md' -type f | sort)

if [ "${#docs[@]}" -eq 0 ]; then
  echo "FAIL no docs found to check" >&2
  exit 1
fi

# --------------------------------------------------------------------------
# 1. local markdown links resolve
# --------------------------------------------------------------------------
for doc in "${docs[@]}"; do
  while IFS= read -r link; do
    case "$link" in
      '' | '#'* | http://* | https://* | mailto:*) continue ;;
    esac
    target="${link%%#*}"
    [ -n "$target" ] || continue
    case "$target" in
      /*) resolved="$repo_root$target" ;;
      *) resolved="$(dirname "$doc")/$target" ;;
    esac
    if [ ! -e "$resolved" ]; then
      fail "$doc: link target does not exist: $link"
    fi
  done < <(grep -oE '\]\([^)]*\)' "$doc" 2>/dev/null | sed -e 's/^](//' -e 's/)$//' || true)
done

# --------------------------------------------------------------------------
# 2. bare local paths quoted in backticks exist
#
# A token like `scripts/bench/cold-start.ts` is this repository's to keep
# honest. The same path in another repository is written owner/repo-qualified,
# so it never starts with one of these prefixes and is left alone.
# --------------------------------------------------------------------------
for doc in "${docs[@]}"; do
  while IFS= read -r token; do
    path="${token%/}"
    [ -n "$path" ] || continue
    if [ ! -e "$path" ]; then
      fail "$doc: local path does not exist: $path"
    fi
  done < <(grep -oE '`(docs|scripts|\.github)/[A-Za-z0-9._/-]*`' "$doc" 2>/dev/null |
    tr -d '`' | sort -u || true)
done

# --------------------------------------------------------------------------
# 3. required sections are still present
#
# Rename a heading and this fails, which is the point: a downstream agent or
# doc that points at a section must be updated in the same pull request.
# --------------------------------------------------------------------------
require_section() {
  local doc="$1" heading="$2"
  if ! grep -qF "## $heading" "$doc"; then
    fail "$doc: missing required section: ## $heading"
  fi
}

sop=docs/performance-sop.md
contract=docs/measurement-contract.md

if [ -f "$sop" ]; then
  for heading in \
    'The five rules' \
    'Stage 0 — research' \
    'Stage 1 — code experiment' \
    'Stage 2 — benchmark' \
    'Stage 3 — pull request' \
    'Stage 4 — merge and publish' \
    'Definition of done' \
    'Anti-patterns' \
    'Quick reference'; do
    require_section "$sop" "$heading"
  done
else
  fail "missing required document: $sop"
fi

if [ -f "$contract" ]; then
  for heading in \
    'What is measured' \
    'What must be held constant' \
    'Harness command' \
    'The result file' \
    'How deltas are computed' \
    'Importing and verifying' \
    'Failure modes to recognise'; do
    require_section "$contract" "$heading"
  done
else
  fail "missing required document: $contract"
fi

# --------------------------------------------------------------------------
# 4. fenced code blocks are balanced
# --------------------------------------------------------------------------
for doc in "${docs[@]}"; do
  fences="$(grep -cE '^ *```' "$doc" || true)"
  if [ $((fences % 2)) -ne 0 ]; then
    fail "$doc: unbalanced code fence ($fences fence lines)"
  fi
done

# --------------------------------------------------------------------------
checked=$((0))
for doc in "${docs[@]}"; do
  checked=$((checked + 1))
done

if [ "$failures" -ne 0 ]; then
  printf '\nFAIL %d problem(s) in %d document(s)\n' "$failures" "$checked" >&2
  exit 1
fi

printf 'ok   %d document(s) checked: links, local paths, sections, fences\n' "$checked"
