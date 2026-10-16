#!/usr/bin/env bash
# Independent verification of what the agent produced. Trusts nothing the agent says:
# re-checks the patch, re-runs lint, tests and mutations on a clean checkout of the
# pull request, and checks the report against the schema and against what it measured.
# No LLM, no credentials, no write access.
#
#   ci/verify.sh <trusted-dir> <pr-dir> <agent-out> <out-dir>
#
#   <trusted-dir>  base branch checkout: the tools and schema used here
#   <pr-dir>       clean checkout of the pull request head; the patch is applied to it
#   <agent-out>    run-agent.sh output (tests.patch, report.json, rejected-files.txt, ...)
#
# Writes <out-dir>/verified.json. Exit 0 when the tests may be pushed: the patch is
# valid, lint is clean and every affected module's tests pass. Exit 1 otherwise.

set -euo pipefail

trusted="$(cd "${1:?usage: verify.sh <trusted-dir> <pr-dir> <agent-out> <out-dir>}" && pwd)"
pr="$(cd "${2:?}" && pwd)"
agent="$(cd "${3:?}" && pwd)"
out="${4:?}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
tools="$trusted/tools"
MAX_PATCH_BYTES="${MAX_PATCH_BYTES:-300000}"
allowed_re='^(modules|stacks)/[A-Za-z0-9._-]+/tests/[A-Za-z0-9._-]+\.tftest\.hcl$'

patch="$agent/tests.patch"
patch_problems=()
patch_files=()

# --- 1. The patch: only test files, only additions/modifications, applies cleanly --------
if [[ -s "$patch" ]]; then
  size="$(wc -c <"$patch")"
  (( size <= MAX_PATCH_BYTES )) || patch_problems+=("patch is $size bytes (limit $MAX_PATCH_BYTES)")
  mapfile -t patch_files < <(git -C "$pr" apply --numstat "$patch" 2>/dev/null | cut -f3)
  [[ ${#patch_files[@]} -gt 0 ]] || patch_problems+=("patch cannot be parsed")
  for f in "${patch_files[@]}"; do
    [[ "$f" =~ $allowed_re ]] || patch_problems+=("patch touches a file outside tests/: $f")
  done
  if git -C "$pr" apply --summary "$patch" | grep -qE '^ *(delete|rename|copy) |mode change'; then
    patch_problems+=("patch deletes, renames or changes the mode of files")
  fi
  if grep -q '^GIT binary patch' "$patch"; then patch_problems+=("patch contains binary data"); fi
  git -C "$pr" apply --check "$patch" 2>/dev/null || patch_problems+=("patch does not apply to the pull request head")
  if [[ ${#patch_problems[@]} -eq 0 ]]; then
    git -C "$pr" apply "$patch"
  fi
fi
patch_ok=true
[[ ${#patch_problems[@]} -eq 0 ]] || patch_ok=false

# --- 2. Modules to verify: those the patch touches and those the agent tested ------------
mapfile -t modules < <(
  { printf '%s\n' "${patch_files[@]}" | sed -nE 's#^((modules|stacks)/[^/]+)/tests/.*#\1#p'
    [[ -s "$agent/report.json" ]] &&
      jq -r '.modules[]? | select(.decision != "skip") | .path' "$agent/report.json" 2>/dev/null
  } | grep -E '^(modules|stacks)/[A-Za-z0-9._-]+$' | sort -u)

lint='{"ok":true,"checked":[],"problems":[]}'
: >"$out/tests.jsonl"
: >"$out/mutation.jsonl"
existing=()
for m in "${modules[@]}"; do [[ -d "$pr/$m" ]] && existing+=("$m"); done

if $patch_ok && [[ ${#existing[@]} -gt 0 ]]; then
  # --- 3. Lint (no --fix: verify never edits) -----------------------------------------
  lint="$("$tools/lint-tests.sh" --src "$pr" "${existing[@]}")" || true

  # --- 4. Tests, then mutations where tests pass -----------------------------------
  for m in "${existing[@]}"; do
    summary="$("$tools/run-tests.sh" --src "$pr" "$m")" || true
    printf '%s\n' "$summary" | jq -c . >>"$out/tests.jsonl"
    if [[ "$(jq -r .status <<<"$summary")" == pass ]]; then
      "$tools/mutate.sh" --src "$pr" "$m" | jq -c . >>"$out/mutation.jsonl" || true
    fi
  done
fi
jq -s . "$out/tests.jsonl" >"$out/tests.json"

# --- 5. The report: schema, and claims against measurements ------------------------------
report_check='{"valid":false,"problems":["no report"],"mismatches":[]}'
if [[ -s "$agent/report.json" ]]; then
  report_check="$(python3 -I "$trusted/ci/validate_report.py" "$trusted/ci/report.schema.json" \
    "$agent/report.json" "$pr" "$out/tests.json")"
fi

touch "$agent/rejected-files.txt" "$agent/removed-config.txt"
jq -n \
  --argjson patch_ok "$patch_ok" \
  --argjson patch_files "$(printf '%s\n' "${patch_files[@]}" | jq -R . | jq -sc 'map(select(length > 0))')" \
  --argjson patch_problems "$(printf '%s\n' "${patch_problems[@]}" | jq -R . | jq -sc 'map(select(length > 0))')" \
  --argjson lint "$lint" \
  --slurpfile tests "$out/tests.jsonl" \
  --slurpfile mutation "$out/mutation.jsonl" \
  --argjson report "$report_check" \
  --rawfile rejected "$agent/rejected-files.txt" \
  --rawfile removed "$agent/removed-config.txt" '
  {
    patch: {ok: $patch_ok, files: $patch_files, problems: $patch_problems},
    lint: $lint,
    tests: $tests,
    mutation: [$mutation[] | del(.mutants) + {survivors: [(.mutants // [])[]
                 | select(.result == "survived") | {file, line, operator, original, mutated}]}],
    report: $report,
    rejected_files: ($rejected | split("\n") | map(select(length > 0))),
    removed_config: ($removed | split("\n") | map(select(length > 0)))
  }
  | .ok = (.patch.ok and .lint.ok and all(.tests[]; .status == "pass"))
  | .push = (.ok and (.patch.files | length > 0))
' >"$out/verified.json"

jq '{ok, push, patch: .patch.problems, lint: .lint.problems, report: .report,
     tests: [.tests[] | {module, status, passed, failed}],
     mutation: [.mutation[] | {module, score, killed, survived}]}' "$out/verified.json" >&2
jq -e .ok "$out/verified.json" >/dev/null
