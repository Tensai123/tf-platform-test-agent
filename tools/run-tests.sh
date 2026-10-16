#!/usr/bin/env bash
# Run `terraform test` for one module inside the sandbox and print a compact JSON
# summary on stdout (see summarize-test.jq for the shape).
#
#   tools/run-tests.sh <module-dir> [--src <repo-root>]
#
# Exit: 0 all runs passed, 1 some run failed, 2 could not run (init error, no tests).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

module="" src="$REPO_ROOT"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) src="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) module="${1%/}"; shift ;;
  esac
done
[[ -n "$module" ]] || die "usage: run-tests.sh <module-dir> [--src <repo-root>]"
valid_module_dir "$module" || die "not a module directory: $module"
[[ -d "$src/$module" ]] || die "no such module: $src/$module"

if ! compgen -G "$src/$module/tests/*.tftest.hcl" >/dev/null; then
  jq -n --arg module "$module" \
    '{module: $module, status: "no_tests", passed: 0, failed: 0, errored: 0, runs: [], diagnostics: []}'
  exit 2
fi

# Refuse, before the networked init step, test files that would download remote
# helper modules or configure real providers; verify rejects them anyway, but the
# download itself must not happen.
if ! lint="$(python3 -I "$TOOLS_DIR/lint_tests.py" "$src" "$module")"; then
  blocking="$(jq -c '[.problems[] | select(.rule == "remote-helper-module" or .rule == "provider-block")]' <<<"$lint")"
  if [[ "$blocking" != "[]" ]]; then
    jq -n --arg module "$module" --argjson problems "$blocking" \
      '{module: $module, status: "refused", detail: "test files reference remote modules or real providers", problems: $problems}'
    exit 2
  fi
fi

work="$(make_workcopy "$src")"
trap 'rm -rf "$work"' EXIT

if ! init_out="$(tf_init "$work" "$module" 2>&1)"; then
  jq -n --arg module "$module" --arg d "$(tail -c 2000 <<<"$init_out")" \
    '{module: $module, status: "init_error", detail: $d}'
  exit 2
fi

summary="$(tf_test "$work" "$module")"
printf '%s\n' "$summary"
summary_rc "$summary"
