---
name: tf-review
description: Review Terraform changes for things a human reviewer should know (security, reliability, correctness, consistency), using static scanner output as evidence and reading the code. Use for every pull request after the change analysis, and whenever a test reveals behaviour that contradicts intent.
---

# Findings for the reviewer

You help people trust this code; you do not change it. Every concern becomes a
finding with evidence and a recommendation. People decide.

## 1. Evidence from scanners

```bash
tools/scan.sh modules/<name> [stacks/<name> ...]
```

TFLint (azurerm ruleset) and Checkov results, deduplicated, with file and line.
Triage them, do not paste them:

- Keep a scanner finding when it is real for this code and relevant to the change.
- Drop it when it is noise here, and say why in one line in `dismissed_scanner_rules`
  (for example a customer-managed-key rule on a module with no CMK requirement).
- Scanner findings outside the pull request's change are context; report one only if
  it is serious (high) or the change makes it worse.

## 2. What scanners do not see: read the code

Go through [reference/criteria.md](reference/criteria.md) for each changed module
and the stacks that use it. It lists what to look for, with how to judge severity.

## 3. Write the finding

Each finding has:

- `severity`: `high` (exploitable or data loss), `medium` (weakens security or
  reliability, should be fixed before prod), `low` (hardening, consistency),
  `info` (worth knowing, no action required)
- `title`: one line, specific
- `file` and `line`: where a reviewer should look (the line in the module or stack)
- `source`: `agent`, or `scanner` with `rule_id`
- `why`: the consequence, concretely, in two or three sentences
- `recommendation`: what a person could change, without writing the patch for them
- `evidence`: what proves it (a test summary value, the scanner rule, a quote of the
  line)
- `in_diff`: whether the line is part of this pull request's change

Prefer few, precise findings over many generic ones. Do not report style issues
`terraform fmt` already handles, and do not report the absence of a feature the
repository clearly does not use.
