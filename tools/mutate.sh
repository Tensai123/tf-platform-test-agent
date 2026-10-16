#!/usr/bin/env bash
# Mutation check for one module: break the module one promise at a time and see
# whether its tests notice. Tests that stay green against a broken module only
# exercise the code; they do not protect it.
#
#   tools/mutate.sh <module-dir> [--src <repo-root>] [--max N]
#
# Prints JSON: { module, baseline, total, killed, survived, invalid, score,
#                mutants: [ {id, operator, file, line, original, mutated,
#                            result: killed|survived|invalid, failed_runs} ] }
#   killed   - at least one test run failed: the tests caught it
#   survived - every test passed: nothing checks this behaviour
#   invalid  - Terraform rejected the mutant before any assertion ran; it says
#              nothing about the tests and is left out of the score
# Exit: 0 when it ran (whatever the score), 2 when the baseline is not green.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

module="" src="$REPO_ROOT" max="${MUTATE_MAX:-60}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) src="$(cd "$2" && pwd)"; shift 2 ;;
    --max) max="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) module="${1%/}"; shift ;;
  esac
done
[[ -n "$module" ]] || die "usage: mutate.sh <module-dir> [--src <repo-root>] [--max N]"
valid_module_dir "$module" || die "not a module directory: $module"
[[ "$max" =~ ^[0-9]+$ ]] || die "--max must be a number"

work="$(make_workcopy "$src")"
trap 'rm -rf "$work"' EXIT
tf_init "$work" "$module" 2>/dev/null || die "terraform init failed for $module"

baseline="$(tf_test "$work" "$module")"
if ! summary_rc "$baseline"; then
  jq -n --arg module "$module" --argjson baseline "$baseline" \
    '{module: $module, baseline: $baseline.status, error: "tests must pass before mutating",
      baseline_summary: $baseline}'
  exit 2
fi

mutants="$(python3 -I "$TOOLS_DIR/mutate.py" list "$work/$module" | jq --argjson max "$max" '.[:$max]')"
results="$work/.mutants.jsonl"
: >"$results"

classify() { # summary -> killed|survived|invalid
  # Killed: an assertion failed, or a run that expects a failure no longer got it
  # (Terraform reports that as an error, not a failed assertion).
  if jq -e '.failed > 0 or any(.diagnostics[]?;
              .summary | test("^(Test assertion failed|Missing expected failure)"))' \
       <<<"$1" >/dev/null; then
    echo killed
  elif [[ "$(jq -r .status <<<"$1")" == pass ]]; then
    echo survived
  else
    echo invalid
  fi
}

# The mocked provider still validates enums ("expected x to be one of [...]"). A
# made-up string is then rejected before any test runs, so swap in another allowed
# value instead: that is the mutation a real mistake would look like.
enum_swap() { # mutant summary -> mutant with another allowed value, or nothing
  jq -c --argjson s "$2" '
    ([$s.diagnostics[]?.detail, $s.diagnostics[]?.summary] | map(select(. != null))
     | map(capture("one of \\[(?<opts>[^\\]]*)\\], got") | .opts) | first) as $opts
    | (.original | capture("= *\"(?<v>[^\"]*)\"") | .v) as $orig
    | select($opts != null and .operator == "change_string")
    | ($opts | [scan("\"([^\"]*)\"")[0]] | map(select(. != $orig)) | first) as $alt
    | select($alt != null)
    | .operator = "swap_enum"
    | .mutated = (.mutated | sub("\"[^\"]*\"$"; "\"" + $alt + "\""))
    | .replacement = (.replacement | sub("\"[^\"]*\"$"; "\"" + $alt + "\""))
  ' <<<"$1"
}

while read -r mutant; do
  file="$(jq -r .file <<<"$mutant")"
  cp "$work/$module/$file" "$work/.original"
  python3 -I "$TOOLS_DIR/mutate.py" apply "$work/$module" "$mutant"
  summary="$(tf_test "$work" "$module")"
  result="$(classify "$summary")"

  if [[ "$result" == invalid ]] && swapped="$(enum_swap "$mutant" "$summary")" && [[ -n "$swapped" ]]; then
    cp "$work/.original" "$work/$module/$file"
    mutant="$swapped"
    python3 -I "$TOOLS_DIR/mutate.py" apply "$work/$module" "$mutant"
    summary="$(tf_test "$work" "$module")"
    result="$(classify "$summary")"
  fi

  jq -c --arg result "$result" --argjson s "$summary" \
    'del(.replacement) + {result: $result,
      failed_runs: [$s.runs[]? | select(.status != "pass") | .run],
      error: (if $result == "invalid" then ($s.diagnostics[0].summary // $s.detail // null) else null end)}' \
    <<<"$mutant" >>"$results"

  cp "$work/.original" "$work/$module/$file"
done < <(jq -c '.[]' <<<"$mutants")

jq -s --arg module "$module" '
  (map(select(.result == "killed")) | length) as $k
  | (map(select(.result == "survived")) | length) as $s
  | {module: $module, baseline: "pass", total: length, killed: $k, survived: $s,
     invalid: (map(select(.result == "invalid")) | length),
     score: (if ($k + $s) == 0 then null else ($k / ($k + $s) * 100 | round) end),
     mutants: .}' "$results"
