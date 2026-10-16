#!/usr/bin/env bash
# Run the static scanners (TFLint with the azurerm ruleset, Checkov) in the sandbox
# and print their findings in one normalised JSON shape:
#
#   tools/scan.sh [--src <repo-root>] [<module-dir>...]     (default: every module)
#
#   { "findings": [ { "source": "tflint"|"checkov", "rule", "title", "severity",
#                     "module", "file", "line", "end_line", "resource", "guideline" } ],
#     "errors": [ { "source", "module", "message" } ] }
#
# Each module is scanned on its own, so findings reflect the module's defaults (what
# every caller gets) rather than the values one stack happens to pass. The scanners
# are evidence for the reviewer; they are not a gate.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

src="$REPO_ROOT" modules=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) src="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) valid_module_dir "${1%/}" || die "not a module directory: $1"
       modules+=("${1%/}"); shift ;;
  esac
done
[[ ${#modules[@]} -gt 0 ]] || mapfile -t modules < <(REPO_ROOT="$src" list_modules)

work="$(make_workcopy "$src")"
trap 'rm -rf "$work"' EXIT
out="$work/.scan"
mkdir -p "$out"

# TFLint: plugin download is the only networked step; the config is ours, from the
# repository root, so a pull request cannot point TFLint at another plugin source
# without that change being visible in the diff.
tflint_mounts=(-e TFLINT_PLUGIN_DIR=/tflint-plugins)
if ! sandbox bridge "$work" . "$TFLINT_IMAGE" "${tflint_mounts[@]}" \
     -v "$TFLINT_PLUGIN_CACHE:/tflint-plugins:rw" -- --init --config /work/.tflint.hcl \
     >"$out/tflint-init.log" 2>&1; then
  jq -n --rawfile m "$out/tflint-init.log" '{source:"tflint", module:null, message:($m|.[-1500:])}' \
    >>"$out/errors.jsonl"
fi

for module in "${modules[@]}"; do
  sandbox none "$work" "$module" "$TFLINT_IMAGE" "${tflint_mounts[@]}" \
    -v "$TFLINT_PLUGIN_CACHE:/tflint-plugins:ro" -- \
    --config /work/.tflint.hcl --format json --force >"$out/tflint.json" 2>"$out/tflint.err" || true
  if jq -e . "$out/tflint.json" >/dev/null 2>&1; then
    jq -c --arg module "$module" '
      (.issues[] | {source: "tflint", rule: .rule.name, title: .message,
                    severity: .rule.severity, module: $module,
                    file: ($module + "/" + .range.filename), line: .range.start.line,
                    end_line: .range.end.line, resource: null, guideline: .rule.link}),
      (.errors[] | {error: true, source: "tflint", module: $module, message: .message})
    ' "$out/tflint.json" >>"$out/findings.jsonl"
  else
    jq -n --arg module "$module" --rawfile m "$out/tflint.err" \
      '{source:"tflint", module:$module, message:($m|.[-1500:])}' >>"$out/errors.jsonl"
  fi

  sandbox none "$work" "$module" "$CHECKOV_IMAGE" -- \
    -d . --framework terraform -o json --skip-download --compact --quiet \
    >"$out/checkov.json" 2>"$out/checkov.err" || true
  if jq -e . "$out/checkov.json" >/dev/null 2>&1; then
    # An empty result is `[]` or an object without failed checks.
    jq -c --arg module "$module" '
      (if type == "array" then .[] else . end) | (.results.failed_checks // [])[]
      | {source: "checkov", rule: .check_id, title: .check_name,
         severity: (.severity // null), module: $module,
         file: ($module + .file_path), line: .file_line_range[0],
         end_line: .file_line_range[1], resource: .resource, guideline: .guideline}
    ' "$out/checkov.json" >>"$out/findings.jsonl"
  else
    jq -n --arg module "$module" --rawfile m "$out/checkov.err" \
      '{source:"checkov", module:$module, message:($m|.[-1500:])}' >>"$out/errors.jsonl"
  fi
done

touch "$out/findings.jsonl" "$out/errors.jsonl"
# A stack scan re-reports findings of the modules it calls. Normalise the paths and
# keep one finding per (source, rule, file, line), listing where it was seen.
jq -s '
  def norm: if test("[^/]+/\\.\\./") then sub("[^/]+/\\.\\./"; "") | norm else . end;
  {findings: (map(select(.error | not) | .file |= norm)
              | group_by([.source, .rule, .file, .line])
              | map(.[0] + {seen_in: (map(.module) | unique)} | del(.module))
              | sort_by(.file, .line, .rule)),
   errors: map(select(.error) | del(.error))}' "$out/findings.jsonl" >"$out/merged.json"
jq -s --slurpfile merged "$out/merged.json" \
  '{findings: $merged[0].findings, errors: ($merged[0].errors + .)}' "$out/errors.jsonl"
