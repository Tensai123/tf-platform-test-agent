# shellcheck shell=bash
# Shared helpers for the tools in this directory. Source it, do not execute it.
#
# Everything that runs Terraform (or a scanner) on repository code goes through
# `sandbox`. Repository code is untrusted in a pull request: `terraform test`
# runs `data "external"` programs, provider plugins and test helper modules. The
# sandbox gives that code no network, no credentials, no root and no .git.

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$TOOLS_DIR/.." && pwd)}"
# shellcheck source=versions.env
source "$TOOLS_DIR/versions.env"

CACHE_DIR="${TF_AGENT_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/tf-test-agent}"
PLUGIN_CACHE="$CACHE_DIR/plugins"
TFLINT_PLUGIN_CACHE="$CACHE_DIR/tflint-plugins"
mkdir -p "$PLUGIN_CACHE" "$TFLINT_PLUGIN_CACHE"

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# sandbox NETWORK WORKCOPY WORKDIR IMAGE [docker-run-extra...] -- [command args...]
#   NETWORK   none (anything that executes repository code) or bridge (only for
#             steps that download pinned dependencies and execute nothing)
#   WORKCOPY  host directory mounted read-write at /work
#   WORKDIR   working directory inside /work
# The container is killed after SANDBOX_TIMEOUT seconds (default 600); killing
# the docker client alone would leave the container running.
sandbox() {
  local network="$1" workcopy="$2" workdir="$3" image="$4"
  shift 4
  local extra=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do extra+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift

  local plugin_mode=ro name rc=0
  [[ "$network" != none ]] && plugin_mode=rw
  name="tf-agent-$$-${RANDOM}${RANDOM}"

  timeout "${SANDBOX_TIMEOUT:-600}" docker run --rm --name "$name" \
    --network "$network" \
    --user "$(id -u):$(id -g)" \
    --read-only --tmpfs /tmp:rw,size=512m \
    --cap-drop ALL --security-opt no-new-privileges \
    --pids-limit 256 --memory 2g --cpus 2 \
    -e HOME=/tmp -e TF_IN_AUTOMATION=1 -e CHECKPOINT_DISABLE=1 \
    -e TF_PLUGIN_CACHE_DIR=/plugins \
    -e TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true \
    -v "$PLUGIN_CACHE:/plugins:$plugin_mode" \
    -v "$workcopy:/work" -w "/work/$workdir" \
    "${extra[@]}" \
    "$image" "$@" || rc=$?
  if [[ $rc -eq 124 ]]; then
    docker kill "$name" >/dev/null 2>&1 || true
    log "sandbox: timed out after ${SANDBOX_TIMEOUT:-600}s"
  fi
  return "$rc"
}

# make_workcopy SRC -> prints a fresh directory holding SRC without .git and
# without local Terraform state. The caller removes it.
make_workcopy() {
  local src="$1" dst
  dst="$(mktemp -d "${TMPDIR:-/tmp}/tf-agent-work.XXXXXX")"
  rsync -a --exclude .git --exclude .terraform --exclude '*.tfstate*' "$src/" "$dst/"
  printf '%s\n' "$dst"
}

# tf_init WORKCOPY MODULE_DIR: download providers into the shared cache. This is
# the only Terraform step with network access, and it runs no provider code.
tf_init() {
  local workcopy="$1" module="$2"
  sandbox bridge "$workcopy" "$module" "$TERRAFORM_IMAGE" -- \
    init -backend=false -input=false -no-color >/dev/null
}

# tf_test WORKCOPY MODULE_DIR: run `terraform test` offline and print the JSON
# summary (see summarize-test.jq). Run tf_init first. Use summary_rc on the output.
tf_test() {
  local workcopy="$1" module="$2" rc=0 raw err
  raw="$(mktemp)" err="$(mktemp)"
  sandbox none "$workcopy" "$module" "$TERRAFORM_IMAGE" -- test -json -no-color \
    >"$raw" 2>"$err" || rc=$?
  if ! jq -s --arg module "$module" --rawfile stderr "$err" \
       -f "$TOOLS_DIR/summarize-test.jq" "$raw" 2>/dev/null; then
    jq -n --arg module "$module" --rawfile stderr "$err" --argjson rc "$rc" \
      '{module: $module, status: "error", exit_code: $rc, detail: ($stderr | .[-2000:])}'
  fi
  rm -f "$raw" "$err"
}

# summary_rc SUMMARY_JSON: 0 pass, 1 fail, 2 anything else.
summary_rc() {
  case "$(jq -r .status <<<"$1")" in pass) return 0 ;; fail) return 1 ;; *) return 2 ;; esac
}

# Module directories: every directory under modules/ and stacks/ with a .tf file.
list_modules() {
  (cd "$REPO_ROOT" && find modules stacks -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
    while read -r d; do compgen -G "$d/*.tf" >/dev/null && printf '%s\n' "$d"; done | sort)
}

# valid_module_dir PATH: guard against arbitrary paths reaching docker -w.
valid_module_dir() {
  [[ "$1" =~ ^(modules|stacks)/[A-Za-z0-9._-]+$ && "$1" != *..* ]]
}
