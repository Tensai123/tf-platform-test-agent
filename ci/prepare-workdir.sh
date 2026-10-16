#!/usr/bin/env bash
# Turn a checkout of the pull request into the directory the agent works in.
#
#   ci/prepare-workdir.sh <pr-checkout> <trusted-checkout> [<removed-list-out>]
#
# The pull request decides the Terraform code under review. It must not decide how
# the reviewer behaves. In `claude -p`, several repository-supplied files take
# effect without any trust prompt: hooks, `env` and helper commands in settings,
# `.mcp.json` servers, and skills or CLAUDE.md files in subdirectories, which load
# when the agent reads files there. The tools the agent runs (tools/) are code too.
#
# So: remove every agent-configuration file from the PR tree, wherever it is, put the
# trusted copies from the base branch in place, and commit that locally so the
# agent's own changes stay separable with a plain `git diff`.

set -euo pipefail

pr="$(cd "${1:?usage: prepare-workdir.sh <pr-checkout> <trusted-checkout>}" && pwd)"
trusted="$(cd "${2:?}" && pwd)"
removed_out="${3:-/dev/null}"
TRUSTED_PATHS=(.claude tools ci .tflint.hcl)

for p in .claude/agents/tf-test-agent.md tools/lib.sh ci/report.schema.json; do
  [[ -e "$trusted/$p" ]] || { echo "trusted checkout has no $p (agent not on the base branch yet)" >&2; exit 3; }
done

cd "$pr"
removed="$(find . -path ./.git -prune -o \( \
    -name .claude -o -name CLAUDE.md -o -name CLAUDE.local.md -o -name AGENTS.md \
    -o -name .mcp.json -o -name .claude.json \) -print | sort)"
# For reviewers: the agent configuration and tooling this pull request changes (it
# was not used for the run). Needs PR_BASE_SHA; everything is removed regardless.
if [[ -n "${PR_BASE_SHA:-}" ]]; then
  git diff --name-only --no-renames "$PR_BASE_SHA...HEAD" |
    grep -E '(^|/)(\.claude/|CLAUDE(\.local)?\.md$|AGENTS\.md$|\.mcp\.json$|\.claude\.json$)|^(tools|ci)/|^\.tflint\.hcl$' \
    >"$removed_out" || true
else
  : >"$removed_out"
fi
if [[ -n "$removed" ]]; then
  printf 'removing agent configuration supplied by the pull request:\n%s\n' "$removed" >&2
  printf '%s\n' "$removed" | xargs -r rm -rf --
fi

for p in "${TRUSTED_PATHS[@]}"; do
  rm -rf -- "${pr:?}/$p"
  cp -a "$trusted/$p" "$pr/$p"
done

# Stage only what this script changed; anything else in the tree stays as checked out.
git add -A -- "${TRUSTED_PATHS[@]}"
[[ -n "$removed" ]] && printf '%s\n' "$removed" | xargs -r git add -A --
git -c user.name=tf-test-agent -c user.email=tf-test-agent@localhost \
  commit -q --no-verify --allow-empty -m "agent workdir: trusted configuration from base"
echo "workdir ready: $pr" >&2
