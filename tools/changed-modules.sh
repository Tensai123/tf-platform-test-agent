#!/usr/bin/env bash
# Map the files changed between two git revisions to Terraform modules and stacks.
#
#   tools/changed-modules.sh <base-rev> <head-rev>     modules touched by the diff
#   tools/changed-modules.sh --all                      every module and stack
#
# Prints JSON:
#   { "base", "head", "mode",
#     "modules": [ { "path", "exists", "has_tests", "files": [{"path","status"}],
#                    "touches": {"code","tests","other"}, "used_by": [stack dirs] } ],
#     "other_files": [ {"path","status"} ] }
# `touches.code` = a top-level *.tf file of the module changed; `tests` = something
# under tests/; `other` = anything else (scripts, docs, lock file).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

if [[ "${1:-}" == "--all" ]]; then
  mode=all base="" head=""
  changes="$(list_modules | sed 's/^/X\t/; s/$/\//')"
elif [[ $# -eq 2 ]]; then
  mode=diff base="$1" head="$2"
  for rev in "$base" "$head"; do
    git rev-parse --verify --quiet "$rev^{commit}" >/dev/null || die "unknown revision: $rev"
  done
  # Three dots: what the head introduces relative to the merge base.
  changes="$(git diff --name-status --no-renames "$base...$head")"
else
  die "usage: changed-modules.sh <base-rev> <head-rev> | --all"
fi

printf '%s\n' "$changes" | python3 -I "$TOOLS_DIR/changed_modules.py" "$mode" "$base" "$head"
