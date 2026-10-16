#!/usr/bin/env bash
# Static checks on the test files of one or more modules (see lint_tests.py), and
# a `terraform fmt -check` of those files in the sandbox.
#
#   tools/lint-tests.sh [--src <repo-root>] [--fix] <module-dir>...
#
# --fix runs `terraform fmt` on the tests/ directories first (formatting only).
# Prints JSON { ok, checked, problems: [{file, line, rule, message}] }; exit 1 on problems.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

src="$REPO_ROOT" fix=false modules=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) src="$(cd "$2" && pwd)"; shift 2 ;;
    --fix) fix=true; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) valid_module_dir "${1%/}" || die "not a module directory: $1"; modules+=("${1%/}"); shift ;;
  esac
done
[[ ${#modules[@]} -gt 0 ]] || die "usage: lint-tests.sh [--src <repo-root>] [--fix] <module-dir>..."

fmt_problems='[]'
for module in "${modules[@]}"; do
  [[ -d "$src/$module/tests" ]] || continue
  if $fix; then
    # Formatting rewrites files in place, so it runs on the real tree, but only on
    # tests/ and inside the sandbox (terraform fmt executes no repository code).
    sandbox none "$src" "$module/tests" "$TERRAFORM_IMAGE" -- fmt -no-color . >/dev/null
  fi
  if ! out="$(sandbox none "$src" "$module/tests" "$TERRAFORM_IMAGE" -- fmt -check -list=true -no-color . 2>&1)"; then
    fmt_problems="$(jq -c --arg module "$module" --arg out "$out" '. + [
      $out | split("\n")[] | select(length > 0)
      | {file: ($module + "/tests/" + .), line: 1, rule: "fmt",
         message: "not formatted; run tools/lint-tests.sh --fix"}]' <<<"$fmt_problems")"
  fi
done

rc=0
result="$(python3 -I "$TOOLS_DIR/lint_tests.py" "$src" "${modules[@]}")" || rc=$?
jq --argjson fmt "$fmt_problems" '.problems += $fmt | .ok = (.problems | length == 0)' <<<"$result"
[[ $rc -eq 0 && "$fmt_problems" == "[]" ]]
