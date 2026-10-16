#!/usr/bin/env bash
# The one place that knows which agent runtime is used (Claude Code CLI). Everything
# around it - tools, verification, publishing - only sees the contract:
#   in:  a checkout of the pull request with trusted agent config, a prompt
#   out: changes under */tests/*.tftest.hcl, and <out>/report.json (ci/report.schema.json)
#
#   ci/run-agent.sh <work-dir> <prompt-file> <out-dir>
#
# Authentication, in the order the CLI resolves it:
#   ANTHROPIC_API_KEY                             static key (fallback)
#   ANTHROPIC_FEDERATION_RULE_ID + ANTHROPIC_ORGANIZATION_ID (+ SERVICE_ACCOUNT_ID,
#   WORKSPACE_ID)                                 workload identity federation: the
#                                                 GitHub OIDC token is exchanged for a
#                                                 short-lived Anthropic token
# Limits: AGENT_MODEL, AGENT_MAX_TURNS (60), AGENT_MAX_BUDGET_USD (5), AGENT_TIMEOUT (2400s)

set -euo pipefail

work="$(cd "${1:?usage: run-agent.sh <work-dir> <prompt-file> <out-dir>}" && pwd)"
prompt_file="${2:?}"
out="${3:?}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
ci_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '%s\n' "$*" >&2; }

# --- Workload identity federation ------------------------------------------------
# Mirrors anthropics/claude-code-action: keep a fresh GitHub OIDC token in a file the
# CLI re-reads on refresh (GitHub tokens are short-lived; each is single-use for the
# exchange), and share one exchanged token through a profile cache.
refresher_pid=""
wif_dir=""
cleanup() {
  if [[ -n "$refresher_pid" ]]; then kill "$refresher_pid" 2>/dev/null || true; fi
  if [[ -n "$wif_dir" ]]; then rm -rf "$wif_dir"; fi
}
trap cleanup EXIT

fetch_oidc() { # -> writes the token file
  local token
  token="$(curl -fsS --retry 3 -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${ANTHROPIC_OIDC_AUDIENCE:-https://api.anthropic.com}" |
    jq -r .value)"
  [[ -n "$token" && "$token" != null ]] || return 1
  echo "::add-mask::$token"
  umask 077
  printf '%s' "$token" >"$wif_dir/identity-token.tmp"
  mv "$wif_dir/identity-token.tmp" "$wif_dir/identity-token"
}

if [[ -z "${ANTHROPIC_API_KEY:-}" && -n "${ANTHROPIC_FEDERATION_RULE_ID:-}" ]]; then
  [[ -n "${ANTHROPIC_ORGANIZATION_ID:-}" ]] || { log "federation needs ANTHROPIC_ORGANIZATION_ID"; exit 2; }
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]] || { log "federation needs 'id-token: write'"; exit 2; }
  wif_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/wif.XXXXXX")"
  fetch_oidc || { log "could not fetch a GitHub OIDC token"; exit 2; }
  mkdir -p "$wif_dir/config/configs"
  echo '{"version":"1.0","authentication":{"type":"oidc_federation"}}' >"$wif_dir/config/configs/default.json"
  export ANTHROPIC_IDENTITY_TOKEN_FILE="$wif_dir/identity-token"
  export ANTHROPIC_CONFIG_DIR="$wif_dir/config" ANTHROPIC_PROFILE=default
  ( while sleep 240; do fetch_oidc || log "warning: OIDC token refresh failed"; done ) &
  refresher_pid=$!
  log "auth: workload identity federation (rule $ANTHROPIC_FEDERATION_RULE_ID)"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  log "auth: API key"
elif [[ "${AGENT_AUTH:-}" == local ]]; then
  log "auth: the local Claude Code login (developer machine only)"
else
  log "no Anthropic credentials configured"; exit 2
fi

# --- Run ---------------------------------------------------------------------------
# The agent's environment loses the means to mint new GitHub OIDC tokens and any
# GitHub token: it only needs the model, the repository and the tools.
model_args=()
[[ -n "${AGENT_MODEL:-}" ]] && model_args=(--model "$AGENT_MODEL")

# Project allow rules are ignored in an untrusted folder under `claude -p`; pass the
# trusted rules (prepare-workdir.sh put the base branch's settings in place) as flags.
settings="$work/.claude/settings.json"
mapfile -t allow < <(jq -r '.permissions.allow[]' "$settings")
mapfile -t deny < <(jq -r '.permissions.deny[]' "$settings")

rc=0
(
  cd "$work"
  timeout "${AGENT_TIMEOUT:-2400}" env \
    -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL \
    -u GITHUB_TOKEN -u GH_TOKEN \
    claude -p "$(cat "$prompt_file")" \
      --agent tf-test-agent \
      --setting-sources project \
      --permission-mode dontAsk \
      --allowedTools "${allow[@]}" \
      --disallowedTools "${deny[@]}" \
      --json-schema "$(cat "$ci_dir/report.schema.json")" \
      --output-format json \
      --max-turns "${AGENT_MAX_TURNS:-60}" \
      --max-budget-usd "${AGENT_MAX_BUDGET_USD:-5}" \
      "${model_args[@]}" </dev/null
) >"$out/claude.json" 2>"$out/claude.stderr" || rc=$?

if ! jq -e . "$out/claude.json" >/dev/null 2>&1; then
  log "agent produced no JSON result (exit $rc)"; tail -c 3000 "$out/claude.stderr" >&2 || true
  jq -n --argjson rc "$rc" '{ok: false, exit_code: $rc, reason: "no result"}' >"$out/run-meta.json"
  exit 1
fi

jq '{ok: (.is_error | not), subtype, num_turns, total_cost_usd, duration_ms,
     stop_reason, terminal_reason,
     permission_denials: [(.permission_denials // [])[] | {tool_name, tool_input}] | .[0:50],
     models: (.modelUsage // {} | keys)}' "$out/claude.json" >"$out/run-meta.json"
jq '.structured_output // empty' "$out/claude.json" >"$out/report.json"
[[ -s "$out/report.json" ]] || { log "agent finished without a structured report"; exit 1; }

# --- Collect changes ------------------------------------------------------------------
# Everything the agent changed, split into what it may change and what it may not.
cd "$work"
git add -A -N . >/dev/null 2>&1 || true
git -c core.quotepath=off diff --name-only >"$out/changed-files.txt"
allowed_re='^(modules|stacks)/[A-Za-z0-9._-]+/tests/[A-Za-z0-9._-]+\.tftest\.hcl$'
grep -E "$allowed_re" "$out/changed-files.txt" >"$out/allowed-files.txt" || true
grep -vE "$allowed_re" "$out/changed-files.txt" >"$out/rejected-files.txt" || true
if [[ -s "$out/allowed-files.txt" ]]; then
  mapfile -t allowed_files <"$out/allowed-files.txt"
  git diff --no-ext-diff --no-textconv -- "${allowed_files[@]}" >"$out/tests.patch"
else
  : >"$out/tests.patch"
fi
log "agent changed $(wc -l <"$out/changed-files.txt") file(s); $(wc -l <"$out/rejected-files.txt") outside tests/ discarded"
exit "$rc"
