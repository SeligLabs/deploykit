# shellcheck shell=bash
# Preflight: what is deployed is exactly origin/main, the tools are here and
# the AWS session is live. Each target's own setup is its driver's preflight
# (drivers/*.sh). lib/env.sh is sourced.

# Git: on main, clean, and level with origin/main. Commits ahead are allowed
# only when every one is a release bump (chore(release): ...) left by an
# earlier run that failed before its Release stage.
#
# DEPLOY_SKIP_GIT_CHECK=1 skips this, for testing the deploy scripts
# themselves on a branch. Never deploy for real with it.
preflight_git() {
  step Git "Git: deploying origin/main"
  if [[ "${DEPLOY_SKIP_GIT_CHECK:-}" == 1 ]]; then
    warn "DEPLOY_SKIP_GIT_CHECK=1: deploying the working tree as it is ($(git -C "$ROOT" rev-parse --abbrev-ref HEAD))."
    return 0
  fi
  git -C "$ROOT" fetch --quiet origin main
  local branch dirty behind ahead ahead_other
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  [[ "$branch" == main ]] || die "On branch '$branch'. Deploys ship main: git switch main && git pull."
  dirty="$(git -C "$ROOT" status --porcelain)"
  [[ -z "$dirty" ]] || die "Uncommitted or untracked files. Commit, stash or remove them first:"$'\n'"$dirty"
  behind="$(git -C "$ROOT" rev-list --count HEAD..origin/main)"
  ((behind == 0)) || die "main is $behind commit(s) behind origin/main. Pull first."
  ahead_other="$(git -C "$ROOT" log --format='%h %s' origin/main..HEAD | command grep -v '^[0-9a-f]* chore(release): ' || true)"
  [[ -z "$ahead_other" ]] ||
    die "main has commits that aren't on origin/main. Push them (or open a PR) first:"$'\n'"$ahead_other"
  ahead="$(git -C "$ROOT" rev-list --count origin/main..HEAD)"
  if ((ahead > 0)); then
    echo "HEAD $(git -C "$ROOT" rev-parse --short HEAD): origin/main plus $ahead unpushed release commit(s), pushed in Release."
  else
    echo "HEAD $(git -C "$ROOT" rev-parse --short HEAD), level with origin/main."
  fi
}

# preflight_tools <tool> ...: each must be on PATH.
preflight_tools() {
  step Tools "Tools"
  local tool missing=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  ((${#missing[@]} == 0)) || die "Missing on PATH: ${missing[*]}"
  if [[ " $* " == *" gh "* ]]; then
    gh auth status >/dev/null 2>&1 || die "gh isn't logged in. Run: gh auth login"
  fi
  echo "Found: $*"
}

# Runs unfiltered: an expired session opens `aws sso login`.
preflight_aws() {
  step AWS "AWS session (${AWS_PROFILE:-default credentials})"
  require_region die
  check_session || die "No AWS session (${AWS_PROFILE:-default credentials})."
}
