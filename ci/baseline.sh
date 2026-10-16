#!/usr/bin/env bash
# Deterministic checks for every module: fmt, validate, terraform test, scanners.
# No LLM, no credentials. This is the check a team can require on every PR.
#
#   ci/baseline.sh <out-dir>
#
# Writes <out-dir>/baseline.json and <out-dir>/summary.md. Exit 1 when fmt,
# validate or any test fails. Scanner findings never fail the job: they are
# evidence for reviewers, and a rule a team disagrees with belongs in config.

source "$(dirname "${BASH_SOURCE[0]}")/../tools/lib.sh"

out="${1:?usage: baseline.sh <out-dir>}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

work="$(make_workcopy "$REPO_ROOT")"
trap 'rm -rf "$work"' EXIT
results="$work/.modules.jsonl"
: >"$results"

log "::group::terraform fmt"
fmt_ok=true
fmt_diff="$(sandbox none "$work" . "$TERRAFORM_IMAGE" -- fmt -check -recursive -diff -no-color 2>&1)" || fmt_ok=false
log "${fmt_diff:-formatted}"
log "::endgroup::"

while read -r module; do
  log "::group::$module"
  init_ok=true validate='null' tests='null'
  if ! init_err="$(tf_init "$work" "$module" 2>&1)"; then
    init_ok=false
    log "$init_err"
  else
    validate="$(sandbox none "$work" "$module" "$TERRAFORM_IMAGE" -- validate -json -no-color 2>/dev/null |
      jq -c '{ok: .valid, diagnostics: [.diagnostics[] | {severity, summary, detail}]}')" ||
      validate='{"ok":false,"diagnostics":[{"summary":"validate did not produce JSON"}]}'
    if compgen -G "$work/$module/tests/*.tftest.hcl" >/dev/null; then
      tests="$(tf_test "$work" "$module")"
    fi
  fi
  jq -nc --arg module "$module" --argjson init_ok "$init_ok" \
    --argjson validate "$validate" --argjson tests "$tests" \
    '{module: $module, init_ok: $init_ok, validate: $validate, tests: $tests}' | tee -a "$results" >&2
  log "::endgroup::"
done < <(list_modules)

log "::group::scanners"
scan="$("$TOOLS_DIR/scan.sh" --src "$REPO_ROOT")"
log "::endgroup::"

jq -s --argjson fmt_ok "$fmt_ok" --arg fmt_diff "$fmt_diff" --argjson scan "$scan" '
  {fmt: {ok: $fmt_ok, diff: ($fmt_diff | .[0:5000])},
   modules: .,
   scan: $scan,
   ok: ($fmt_ok and all(.[]; .init_ok and (.validate.ok // false)
                              and (.tests == null or .tests.status == "pass")))}
' "$results" >"$out/baseline.json"

jq -r '
  def icon(ok): if ok then "✅" else "❌" end;
  "## Terraform checks\n",
  "| Module | validate | tests |", "|---|---|---|",
  (.modules[] | "| `\(.module)` | \(icon(.init_ok and (.validate.ok // false))) | " +
     (if .tests == null then "— no tests"
      else "\(icon(.tests.status == "pass")) \(.tests.passed // 0) passed, \(.tests.failed // 0) failed"
           + (if (.tests.errored // 0) > 0 then ", \(.tests.errored) errored" else "" end) end) + " |"),
  "",
  "**terraform fmt:** \(icon(.fmt.ok))",
  "",
  "**Scanner findings:** \(.scan.findings | length) (TFLint \(.scan.findings | map(select(.source == "tflint")) | length), Checkov \(.scan.findings | map(select(.source == "checkov")) | length)). They do not fail this check; the test agent triages them on pull requests."
' "$out/baseline.json" >"$out/summary.md"

jq -e .ok "$out/baseline.json" >/dev/null
