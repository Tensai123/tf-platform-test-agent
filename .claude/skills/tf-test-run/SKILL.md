---
name: tf-test-run
description: Run a module's terraform tests safely and read the result. Use after writing or changing any *.tftest.hcl file, and before reporting test results.
---

# Running tests

Always run tests through the repository tool, never with a bare `terraform`:

```bash
tools/lint-tests.sh --fix modules/<name>   # format + static checks; fix every problem it lists
tools/run-tests.sh modules/<name>          # JSON summary; exit 0 pass, 1 fail, 2 could not run
```

`run-tests.sh` copies the repository without `.git`, downloads providers, then runs
`terraform test` in a container with no network, no credentials and no root. Test
code can execute programs (for example through `data "external"`); this is why.

## Reading the summary

```json
{"status": "fail", "passed": 2, "failed": 1, "errored": 0,
 "runs": [{"file": "tests/main.tftest.hcl", "run": "x", "status": "fail"}],
 "diagnostics": [{"run": "x", "summary": "Test assertion failed",
                  "detail": "<error_message>",
                  "values": [{"traversal": "azurerm_x.this.attr", "statement": "is \"actual\""}]}]}
```

- `values` shows what the asserted expression actually evaluated to. Start there.
- `status: "error"` / `errored > 0`: Terraform could not evaluate the run (invalid
  mock, unknown value under plan, schema validation). This is a test problem: see
  tf-test-authoring `reference/mocking.md`.
- `status: "init_error"`: provider download or configuration error; report it, do
  not work around it by editing module code.
- `skip` runs: an earlier run in the same file errored; fix that one first.

## When a run fails

1. Is the assertion wrong (attribute path, expected value, mock gap)? Fix the test.
2. Does the module contradict its own variables, descriptions, outputs or the
   repository conventions? Then the test found something real. Remove that run from
   the file, keep the evidence (`values`), and report a finding. Do not change the
   module and do not flip the assertion to the current value.

Stop after a handful of attempts on the same run; report it as unresolved with the
last summary instead of looping.
