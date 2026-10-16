# Reduce `terraform test -json` output (slurped) to what a reader needs: per-run
# status and error diagnostics. Raw output is dropped on purpose; it can carry text
# from the code under test and is too long to reason about.
#
#   jq -s --arg module M --rawfile stderr FILE -f summarize-test.jq output.jsonl

def runs:
  [ .[] | select(.type == "test_run" and .test_run.progress == "complete")
    | {file: .test_run.path, run: .test_run.run, status: .test_run.status} ];

def diags:
  [ .[] | select(.type == "diagnostic" and .diagnostic.severity == "error")
    | {file: (.["@testfile"] // null), run: (.["@testrun"] // null),
       summary: .diagnostic.summary,
       detail: ((.diagnostic.detail // "") | .[0:1500]),
       values: [ (.diagnostic.snippet.values // [])[]
                 | {traversal, statement: (.statement | .[0:300])} ],
       range: (.diagnostic.range // null)} ];

(map(select(.type == "test_summary")) | last | .test_summary) as $s
| {
    module: $module,
    status: (if $s == null then "error" elif $s.status == "pass" then "pass" else "fail" end),
    passed: ($s.passed // 0), failed: ($s.failed // 0), errored: ($s.errored // 0),
    skipped: ($s.skipped // 0),
    runs: runs,
    diagnostics: diags
  }
| if .status == "error" then . + {detail: ($stderr | .[-2000:])} else . end
