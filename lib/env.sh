# shellcheck shell=bash
# deploykit's environment helpers. Source it; it runs nothing and reads no
# file until a function is called. Runs on macOS's bash 3.2, under set -u and
# set -e alike.

DK_ENV_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# require_region [fail]: stop unless AWS_REGION is set; Terraform's backend
# and provider and SAM all read it. <fail> reports the message, for a script
# with its own way to (the deploy's die); otherwise it goes to stderr. Either
# way the script exits 1.
# shellcheck disable=SC2120 # <fail> is optional
require_region() {
  [[ -n "${AWS_REGION:-}" ]] && return 0
  local message="AWS_REGION is empty: set it in the app's env files to the stack's region."
  if [[ $# -gt 0 ]]; then
    "$1" "$message"
  else
    echo "$message" >&2
  fi
  exit 1
}

# load_env [--override] <file>: export each non-empty KEY=value in the file,
# if the file exists (bootstrap can run before it does). Quotes around a value
# are dropped; comments and blank values are skipped, so a blank `AWS_PROFILE=`
# means "unset", not "". A variable already set stays as it is, so the first
# file loaded wins; with --override the file's value replaces it.
load_env() {
  local override=0 line key value
  if [[ "${1:-}" == --override ]]; then
    override=1
    shift
  fi
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *=* ]] || continue

    key="${line%%=*}"
    key="${key//[[:space:]]/}"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi

    [[ -n "$value" ]] || continue
    if ((override)) || [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done <"$1"
  return 0
}

# deploy_lock_path <slug>: the one-deploy-at-a-time lock (the engine holds
# it; an app's own scripts, such as a read-only plan, can check it).
deploy_lock_path() {
  printf '%s\n' "${TMPDIR:-/tmp}/$1-deploy.lock"
}

# check_session: bin/aws-session.sh ensure, its exit status the caller's to
# act on.
check_session() {
  bash "$DK_ENV_LIB_ROOT/bin/aws-session.sh" ensure
}
