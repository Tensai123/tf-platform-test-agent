# Solution: Terraform test agent

A pull request that changes Terraform gets a reviewer that writes and updates
`terraform test` files for the changed modules, proves them by running them and by
breaking the module on purpose, and tells people what it found. It never changes
infrastructure code.

```
pull_request ──► detect ──► agent ──► verify ──► publish ──► PR: tests commit, comment,
                (read)     (read +   (read)     (write)        inline findings, status,
                            LLM)                                 terraform-checks re-run
terraform-checks (fmt, validate, test, scan; no LLM): every PR and push, the required check
```

## 1. Main decisions, why, and what they cost

| Decision | Why | Given up |
|---|---|---|
| **Claude Code CLI as the agent runtime, behind one adapter** (`ci/run-agent.sh`) | Mature tool loop, file editing, permissions, budget/turn limits and structured output already exist and are tested; writing that loop myself would be more code and more bugs in three days. The adapter's contract (prompt in; test files + `report.json` out) is runtime-neutral: skills are plain Markdown + scripts, and verify/publish never see which LLM ran. | Lock-in at the adapter (~130 lines) and the agent file format. Moving to another runtime means a new adapter and translating `.claude/agents/tf-test-agent.md`; tools, skills' content, verify and publish stay. |
| **Deterministic tools do the work; the LLM decides** (`tools/`) | Diffing, running tests, scanning, mutating and linting are scripts the agent calls through skills. CI's `verify` uses the *same* scripts, so "green" means the same thing for both, and nothing the agent says is taken on trust. | Less agent freedom: it can only run what `tools/` offers. |
| **Sandbox for every Terraform/scanner execution** (`tools/lib.sh`) | `terraform test` executes code from the PR: `data "external"` programs, providers, test helper modules. Container: `--network none`, non-root, read-only rootfs, all capabilities dropped, no-new-privileges, pid/memory/CPU limits, killed on timeout, copy of the tree without `.git`, pinned image digests. Provider download is a separate networked step that executes no provider code. Test files that would pull remote helper modules or configure real providers are refused before that step. | Docker is required (present on GitHub runners); ~1 min of image pulls per job. |
| **Jobs split by privilege** | The job holding the LLM credential has a read-only token; jobs running PR code have no secrets; the only job with write access (`publish`) runs neither the LLM nor PR code, and only applies a patch `verify` already checked. | Four jobs and artifacts instead of one script; ~2–3 extra minutes. |
| **Agent configuration from the base branch, PR tree sanitised** (`ci/prepare-workdir.sh`) | Found while testing: under `claude -p` some repository-supplied configuration takes effect without a trust prompt (hooks, `env`, `.mcp.json`, nested skills/`CLAUDE.md`). A PR must not decide how its reviewer behaves, so every agent-config file in the PR is removed and the base branch's `.claude/`, `tools/`, `ci/` are put in place. Changes to them are reported on the PR as code that runs in CI. | Changes to the agent itself only take effect after merge (the agent never reviews with its own new version). |
| **Workload identity federation, no static secret** | The workflow exchanges its GitHub OIDC token for a short-lived Anthropic token bound to a Console service account, a dedicated workspace with a spend limit, and a rule that matches only `pull_request` runs of this repository (by numeric owner/repo ID). Nothing to leak or rotate. The OIDC-minting variables are removed from the agent's environment. | One-time Console setup; `ANTHROPIC_API_KEY` remains as a fallback. A consumer subscription token was rejected: the consumer terms are non-commercial and restrict automated access. |
| **Mutation check as a measure of test strength** (`tools/mutate.sh`) | A passing test only proves it runs. Flipping a boolean, swapping an enum to another allowed value, removing a `validation`, emptying a `for_each`: if no test fails, nothing protects that behaviour. The agent uses it to strengthen its tests; verify reports the score and the survivors on the PR. | Simple, line-based operators; equivalent mutants are possible and are listed, not hidden. |
| **Scanners as evidence, not a gate** (TFLint + azurerm ruleset, Checkov) | They give findings a rule ID and a line. The agent triages them (keeps, dismisses with a reason) and adds what scanners cannot see. | Two more images; scanner opinions are not enforced. |
| **Findings are reported, never fixed** | "Decisions about changing the infrastructure code stay with people." A test that fails because the module contradicts its intent becomes a finding with the evidence, never an assertion bent to the current value. | The PR stays unsafe until a person acts. |

Rejected: Terratest (needs real cloud), Conftest/OPA on `plan -json` (plan needs credentials; on HCL it duplicates Checkov), Infracost (needs an API key, out of scope), `pull_request_target` (would run the agent for forks, but with base-repo privileges next to untrusted code; the risk is not worth it here).

## 2. Running it

**Prerequisites**
- GitHub repository with Actions enabled; workflows in `.github/workflows/`.
- Claude Console: a workspace with a spend limit, a service account in it, a
  workload identity federation rule for `token.actions.githubusercontent.com` that
  matches this repository's `pull_request` runs. Repository variables:
  `ANTHROPIC_FEDERATION_RULE_ID`, `ANTHROPIC_ORGANIZATION_ID`,
  `ANTHROPIC_SERVICE_ACCOUNT_ID`, `ANTHROPIC_WORKSPACE_ID`, optionally `AGENT_MODEL`
  (default `sonnet`) and `AGENT_MODEL_FULL_SCAN`. Alternatively a secret
  `ANTHROPIC_API_KEY`.
- Label `agent:full-scan` for full-coverage runs.
- Recommended branch protection: require `baseline` (terraform-checks); treat
  `tf-test-agent` as advisory.

**On GitHub:** open a pull request that touches `modules/` or `stacks/`. Add the
`agent:full-scan` label to review everything.

**Locally** (Docker, `jq`, `python3`, Claude Code logged in):

```sh
ci/local-run.sh origin/main my-branch            # the whole pipeline, nothing is pushed
tools/run-tests.sh modules/network               # sandboxed terraform test, JSON summary
tools/mutate.sh modules/storage-account          # which behaviour no test catches
tools/scan.sh modules/function-app               # TFLint + Checkov, normalised
claude --agent tf-test-agent                     # the agent interactively
```

## 3. Where the agent and skills are, and how they are used

| Piece | File | Role during a run |
|---|---|---|
| Agent | `.claude/agents/tf-test-agent.md` | Role, boundaries (only `*/tests/*.tftest.hcl`), process, report rules. Run as the main thread with `claude -p --agent tf-test-agent`. |
| Skill `tf-change-analysis` | `.claude/skills/tf-change-analysis/` | Step 1: modules touched, kind of change, decision per module (create / update / skip + reason). Uses `tools/changed-modules.sh`, `tools/pr-diff.sh`. |
| Skill `tf-test-authoring` | `.claude/skills/tf-test-authoring/` + `reference/mocking.md`, `reference/patterns.md` | Step 2: what to test (a module's promises) and how; mock behaviour recorded from real runs (computed values under plan, invalid mocked IDs, `data "external"`). |
| Skill `tf-test-run` | `.claude/skills/tf-test-run/` | Step 3: `tools/lint-tests.sh --fix`, `tools/run-tests.sh`; how to read failures; when a failure is a finding. |
| Skill `tf-test-mutate` | `.claude/skills/tf-test-mutate/` | Step 4: `tools/mutate.sh`; strengthen tests for survivors that matter, record accepted ones. |
| Skill `tf-review` | `.claude/skills/tf-review/` + `reference/criteria.md` | Step 5: scanner triage (`tools/scan.sh`) plus generic review criteria; finding format. |
| Permissions | `.claude/settings.json` | Writes only to test files; Bash only for `tools/*`; no web, no `terraform`/`docker`/`curl` directly. Passed as flags in CI. |
| Output contract | `ci/report.schema.json` | Enforced with `--json-schema`; validated again, and checked against measurements, by `verify`. |

All skills are preloaded into the agent (their bodies are short); reference files
load on demand. The same agent and skills work interactively for a developer.

## 4. Example run

**Example pull request: [#6](https://github.com/Tensai123/tf-platform-test-agent/pull/6)**
(retention validation and a daily ingestion cap in `log-analytics-workspace`,
wired through the stack with a 1 GB/day cap in dev).

| Step | What happened |
|---|---|
| detect | `changed-modules.sh`: `modules/log-analytics-workspace` (code), `stacks/data-platform` (code, tfvars) |
| analysis (`tf-change-analysis`) | module → **update**: new `validation` and new input feeding the resource, existing tests did not cover them. Stack → **skip**: only a pass-through; the module exposes only `id`, so a stack test cannot observe the value (the agent tried, got `Unsupported attribute`, removed the run and reported it) |
| tests (`tf-test-authoring`, `tf-test-run`) | `tests/main.tftest.hcl` 3 → 9 runs: default quota, quota reaches the workspace, retention edges 30/730 accepted, 29/731 rejected (`expect_failures`) |
| strength (`tf-test-mutate`) | 4/4 mutants killed (validation removed, SKU swapped to another allowed value, retention and quota defaults changed) |
| review (`tf-review`) | 3 findings, posted inline on the changed lines: `daily_quota_gb` has no validation (low), the stack wiring cannot be tested through the module's outputs (low), retention is not exposed by the stack (info) |
| verify | patch only in `tests/`, lint clean, 9/9 pass on a clean checkout, mutation 4/4, report valid and consistent with measurements |
| publish | commit by `github-actions[bot]`, summary comment, 3 inline comments, status `tf-test-agent: tests verified; 3 finding(s), 0 high`, `terraform-checks` dispatched for the new commit |

23 turns, 48 s, $0.15 (Sonnet).

**Full-coverage pass: [#2](https://github.com/Tensai123/tf-platform-test-agent/pull/2)**
(label `agent:full-scan`): tests for the 5 modules and the stack that had none,
strengthened tests for the 3 that had some; 56 runs, all passing; mutation scores
64–100% per module (storage-account 5/13 before, 12/12 after), the stack 39%: most
of its survivors are module instance name templates, but one matters: nothing
asserts the stack's default `public_access_enabled = false`. The PR comment lists
every survivor, so a reviewer sees that gap rather than a green tick. 88 turns,
4.5 min, $0.59.

**Blind evaluation.** The base repository has issues I noticed before building the
agent. They were deliberately kept out of prompts and skills and used only to check
what the agent finds on its own (full scan above):

| Known issue | Agent |
|---|---|
| Function app allows plain FTP (`ftps_state = "AllAllowed"`) | found (medium) |
| Function app gets `Storage Blob Data Owner` on the lake | found (medium; the criteria would justify high) |
| `data "external"` runs a repository script during plan/test | found, but rated low as a reproducibility issue; it missed that this is pull request code executing in CI |
| README promises `uat`, no `envs/uat.tfvars` | missed |

It also reported, correctly, that three modules default to public network access
(high) and that the stack's private endpoints have no DNS zone. I left the skills as
they were after this evaluation rather than tune them to the known answers; the
production version would turn such cases into a regression set (section 9).

## 5. What the generated tests can and cannot show

These are unit tests of the modules: each module in isolation, providers mocked.

**Can:** what each module *plans* for given inputs: hard-coded settings, defaults,
derived names and tags, instance counts for `for_each`/`dynamic`, input validation
(rejects bad, accepts edge-of-good), wiring between resources (IDs, principals,
scopes) and outputs, with the provider schema still validating enum values. Mutation
results show which of those behaviours a test would catch breaking.

**Cannot:** that Azure accepts the configuration (API-side validation, quotas, name
availability, region/SKU support), that resources work together at runtime (DNS,
private endpoints, RBAC propagation, network paths), drift, or anything that depends
on real provider-computed values (mocks return made-up ones). Plan-time correctness
is necessary, not sufficient; integration tests in a real subscription would be the
next layer.

## 6. Assumptions

- Same-repository pull requests are the normal flow; contributors with write access
  are trusted to the level GitHub already trusts them (they can change workflows).
- The repository conventions in `README.md` are the intended behaviour; README,
  variable descriptions and validations count as the module's promises.
- Module tests use mocked providers only; `random`, `null`, `time` may run for real.
- `main` is the base branch; the agent's configuration on it has been reviewed.

## 7. Limitations

- **Fork pull requests** get no agent run (no OIDC token, no secrets); they still get
  `terraform-checks`.
- **Changes to the agent** take effect after merge, by design.
- **The workflow YAML itself comes from the pull request.** For `pull_request`
  events GitHub runs the workflow definition from the PR's merge commit; scripts and
  agent config are taken from the default branch tip, but a contributor with write
  access can still edit the YAML in their PR. CODEOWNERS on `.github/` plus required
  review closes this; `pull_request_target` would invert the problem (trusted YAML,
  privileged context next to untrusted code).
- **Learned on the first real runs** (and fixed): the event's `base.sha` is the base
  as of the PR's last sync, so trusted config is now resolved from the base branch
  tip in `detect`; GitHub issues OIDC `sub` claims with immutable IDs for this
  repository (`repo:Owner@<id>/repo@<id>:pull_request`), so the federation rule
  matches that form; after a re-run, artifacts of the same name from several
  attempts coexisted and a later job read the old one, so uploads overwrite.
- **The agent's own push** triggers `pull_request` runs that GitHub holds for
  approval (actor `github-actions[bot]`); they are not needed (`terraform-checks` is
  dispatched explicitly) and should not be approved, so the agent never loops on
  its own commit.
- **Bash permission rules are not a security boundary** (Claude Code's own docs say
  so); the boundary is the job design: read-only token, sandbox, verify discarding
  anything outside `tests/`.
- **Mutation operators are line-based** and cover literals, booleans, enums, numbers,
  `for_each`, validations and name templates, not expressions or multi-line values.
- **The test lint is a scanner, not an HCL parser**; Terraform's own checks (e.g. an
  assert must reference configuration) are the second layer.
- **Lock files** exist for only some modules, so provider versions within `~> 4.0`
  can differ between runs; the agent may not add them (outside `tests/`).
- **LLM non-determinism:** two runs on the same change can produce different tests.
  Verify guarantees they are valid, pass and are honestly reported; not that they are
  the same.
- **Cost and time:** a PR run is minutes and cents to a dollar; a full scan more.
  Per-run caps (`--max-turns`, `--max-budget-usd`), a workspace spend limit and
  `concurrency` bound it.

## 8. With many more modules, teams or repositories

- **Repositories:** move `tools/`, `ci/` and the skills into a central repository
  consumed as a versioned reusable workflow (`uses: org/tf-agent/.github/workflows/agent.yml@v1`)
  and a Claude Code plugin for the agent and skills; each repository keeps only
  config (paths, labels, model). One federation rule per repository (subject pinned
  by repository ID), one workspace per team for cost attribution.
- **Modules:** scope stays per change, so cost grows with PR size, not repo size.
  Run modules in parallel (matrix over `changed-modules.sh` output, one agent per
  module), cache provider plugins between jobs, and make full scans scheduled and
  incremental (only modules without tests or with a low mutation score).
- **Teams:** CODEOWNERS on `.claude/`, `tools/`, `ci/`, `.github/`; team-specific
  review criteria as additional skills; findings exported (SARIF to code scanning)
  so they are tracked, deduplicated and dismissible with an audit trail, rather than
  living only in comments.

## 9. For a production version

- Require CODEOWNERS approval for agent/CI paths and `baseline` as a required check;
  publish findings as SARIF.
- A GitHub App instead of `GITHUB_TOKEN` for the push (attributable bot identity,
  checks trigger natively, no dispatch workaround).
- Full transcript of each agent run kept as an artifact (`stream-json`) for audit.
- Evaluation set: modules with known defects, run on every change to the agent or
  skills, to catch regressions in what the agent finds (prompt changes are code).
- Integration tests in an ephemeral subscription for modules where plan-level tests
  are not enough, gated behind manual approval.
- Pre-built runner image with Terraform, scanners and provider cache to cut minutes.
- `.terraform.lock.hcl` for every module, enforced by `terraform-checks`.
