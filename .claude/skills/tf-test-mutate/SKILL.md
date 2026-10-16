---
name: tf-test-mutate
description: Measure whether a module's tests would notice the module breaking, by running them against single-point mutations of the module. Use after the tests of a module pass, to find promises nothing checks.
---

# Mutation check

```bash
tools/mutate.sh modules/<name>        # JSON; only runs when the tests pass first
```

The tool copies the module and changes one thing at a time: flips a boolean,
changes a literal or number, swaps an enum to another allowed value, removes a
`validation` block, empties a `for_each`, changes a name template. For each mutant
it runs the tests:

- `killed`: some run failed, the tests protect this behaviour.
- `survived`: everything still passed, nothing checks this behaviour.
- `invalid`: Terraform rejected the mutant before any assertion; ignore it.

`score` = killed / (killed + survived).

## What to do with survivors

Go through each survived mutant and decide:

1. **It matters** (security setting, network default, validation, naming a caller
   relies on, count of instances): add or tighten an assertion, rerun tests, rerun
   the mutation check.
2. **It does not matter for callers** (a cosmetic literal): leave it, and list it as
   accepted in the report with the reason.
3. **The surviving value is the unsafe one and is what the code does today**: do not
   assert it. This usually means a finding (tf-review).

A high score is not the goal; knowing which behaviour is unprotected is. Do not add
assertions that only restate the current literal without a reason a reviewer would
accept, and do not change module code to kill mutants.
