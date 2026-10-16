#!/usr/bin/env bash
# Run the pull request pipeline locally, the way CI runs it: a fresh clone of the
# head, trusted agent config from the base, the agent, then the independent verify.
# Uses your local Claude Code login. Nothing is pushed or posted.
#
#   ci/local-run.sh <base-ref> <head-ref> [--all] [--title T] [--body B] [--out DIR]

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_ref="" head_ref="" mode=diff title="" body="" out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) mode=all; shift ;;
    --title) title="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) if [[ -z "$base_ref" ]]; then base_ref="$1"; else head_ref="$1"; fi; shift ;;
  esac
done
[[ -n "$base_ref" && -n "$head_ref" ]] || { sed -n '6,7p' "$0"; exit 1; }

base_sha="$(git -C "$repo" rev-parse --verify "$base_ref^{commit}")"
head_sha="$(git -C "$repo" rev-parse --verify "$head_ref^{commit}")"
run="$(mktemp -d "${TMPDIR:-/tmp}/tf-agent-local.XXXXXX")"
out="${out:-$run/out}"
mkdir -p "$out"
echo "run dir: $run" >&2

git clone -q --no-local "$repo" "$run/work"
git -C "$run/work" checkout -q --detach "$head_sha"
git clone -q --no-local "$repo" "$run/trusted"
git -C "$run/trusted" checkout -q --detach "$base_sha"

export PR_BASE_SHA="$base_sha" PR_HEAD_SHA="$head_sha" PR_NUMBER=local AGENT_MODE="$mode"
export AGENT_AUTH="${AGENT_AUTH:-local}" REMOVED_CONFIG="$out/removed-config.txt"

"$run/trusted/ci/prepare-workdir.sh" "$run/work" "$run/trusted" "$REMOVED_CONFIG"
if [[ "$mode" == all ]]; then
  (cd "$run/work" && tools/changed-modules.sh --all) >"$out/changes.json"
else
  (cd "$run/work" && tools/changed-modules.sh "$base_sha" "$head_sha") >"$out/changes.json"
fi
printf '%s' "$title" >"$run/title"; printf '%s' "$body" >"$run/body"
"$run/trusted/ci/build-prompt.sh" "$out/changes.json" "$run/title" "$run/body" >"$out/prompt.txt"

"$run/trusted/ci/run-agent.sh" "$run/work" "$out/prompt.txt" "$out" || echo "agent exited non-zero" >&2

if [[ -x "$run/trusted/ci/verify.sh" ]]; then
  "$run/trusted/ci/verify.sh" "$run/trusted" "$head_sha" "$out" || echo "verify reported problems" >&2
fi
echo "results: $out" >&2
