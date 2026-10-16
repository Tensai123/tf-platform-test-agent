#!/usr/bin/env bash
# Show what the pull request changes, optionally limited to one module or file.
# The agent gets this instead of raw git: git has options that write files
# (diff --output) or run programs (external diff drivers, textconv).
#
#   tools/pr-diff.sh [<path>]        uses PR_BASE_SHA and PR_HEAD_SHA
#   tools/pr-diff.sh --stat

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT" || exit 1

base="${PR_BASE_SHA:-}" head="${PR_HEAD_SHA:-HEAD}"
[[ -n "$base" ]] || base="$(git merge-base origin/main HEAD 2>/dev/null)" ||
  die "set PR_BASE_SHA (no PR context and no origin/main to compare with)"

args=(--no-pager -c core.pager=cat -c diff.external= diff --no-ext-diff --no-textconv
      --no-color --unified=5)
if [[ "${1:-}" == "--stat" ]]; then
  exec git "${args[@]}" --stat "$base...$head"
fi

path="${1:-}"
if [[ -n "$path" ]]; then
  [[ "$path" != -* && "$path" != *..* ]] || die "invalid path: $path"
  exec git "${args[@]}" "$base...$head" -- "$path"
fi
exec git "${args[@]}" "$base...$head"
