---
name: tf-test-authoring
description: Write or update `terraform test` files (*.tftest.hcl) for a Terraform module with mocked providers, so they run without cloud credentials. Use when a module needs new tests, when module code changed and its tests must follow, or when a test fails for reasons in the test itself.
---

# Writing terraform tests that mean something

A test earns its place when it would fail if the module stopped keeping a promise.
Before writing, list the module's promises, then write one `run` per promise.

## 1. Find the promises

Read `main.tf`, `variables.tf`, `outputs.tf` (and any file the module reads, such as
scripts or templates). A promise is anything a caller relies on:

| In the module | Promise to test | How |
|---|---|---|
| `validation` block | bad input is rejected | `expect_failures = [var.x]` with a value that breaks it; plus one valid edge value that passes |
| hard-coded security setting (TLS, public access, network default deny, HTTPS-only) | it stays that way | `assert` on the planned attribute |
| variable that switches behaviour (bool, optional object, nullable) | each branch does what it says | one `run` per branch, overriding `variables` |
| `for_each` / `count` / `dynamic` | one instance per input, none for empty input | `length(...)` and keyed lookups; a run with an empty collection |
| naming / tagging convention | names are derived as documented | assert exact derived names and tags |
| wiring between resources (IDs, principal IDs, scopes) | the right thing is connected | `command = apply` with mocks, compare attributes across resources |
| output | it exposes the documented value | `command = apply`, assert `output.x` |

Defaults matter: a module is reused, so what a caller gets *without* setting a
variable is a promise too. Test the defaults explicitly in their own `run`.

## 2. File layout and conventions

- Files live in `<module>/tests/`. Keep an existing `main.tftest.hcl` and add to it
  when the new runs belong with it; put a distinct concern in its own file
  (for example `tests/validation.tftest.hcl`, `tests/defaults.tftest.hcl`).
- `run` names are snake_case sentences of the promise: `rejects_invalid_cidr`,
  `defaults_disable_public_access`, `one_endpoint_per_lake`.
- Every `assert` has an `error_message` that says what is wrong in the module's
  terms, not "assertion failed".
- Use realistic but obviously fake values: zero UUIDs, `rg-test`, `westeurope`,
  well-formed Azure resource IDs (see mocking reference).
- Follow the repository conventions: `for_each` over `count`, `terraform fmt`.

## 3. Mocks: read the reference before the first run

Read [reference/mocking.md](reference/mocking.md). It records how the mocked
`azurerm` provider actually behaves in this repository (verified by running it), for
example that computed values are unknown under `command = plan`, that mocked IDs are
random strings the provider rejects when another resource parses them, and that a
`data "external"` source runs its program unless it is overridden.

Patterns with complete examples are in [reference/patterns.md](reference/patterns.md).

## 4. Rules that keep tests honest

- **Assert intent, not the current value.** If the code sets something unsafe or
  surprising (public access on by default, a broad role, a weak protocol), do NOT
  write a test that locks that value in as "expected". Write the test for the safe
  behaviour only if the module already provides it; otherwise leave it untested and
  raise a finding (tf-review). Changing infrastructure code is a human decision.
- **A failing test is information.** When a test you wrote fails, read the asserted
  values in the summary. If the test was wrong (wrong attribute path, mock gap), fix
  the test. If the module does not do what its variables, descriptions or the
  repository conventions say it should, keep the test out and report a finding with
  the failing evidence. Never weaken an assertion just to get green.
- **No tautologies.** `condition = true`, comparing a value with itself, or asserting
  a value you passed in as a variable and that the module only forwards proves little;
  assert what the module derives or decides.
- **Never call real infrastructure.** Every provider the module needs is mocked
  (`random`, `null`, `time` may run for real). No `provider` blocks in tests, no
  helper modules from remote sources.
- **Do not edit anything outside `tests/`.** Not the module, not other modules, not
  CI. If the module needs a change to be testable, say so in a finding.

## 5. Finish

Run `tools/lint-tests.sh --fix <module>` then `tools/run-tests.sh <module>` (skill
`tf-test-run`) until the lint is clean and every run passes, then check strength
with `tools/mutate.sh <module>` (skill `tf-test-mutate`).
