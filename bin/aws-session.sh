#!/usr/bin/env bash
# Keeps the AWS SSO session alive for local development and deploys. When an
# SSO session expires, SAM local's calls to DynamoDB and Cognito fail and the
# app looks like it lost its data; a deploy fails halfway.
#
#   aws-session.sh ensure   Check now; if the SSO session expired and this is
#                           an interactive terminal, run `aws sso login`.
#   aws-session.sh watch    Re-check every AWS_SESSION_CHECK_SECONDS (300) and
#                           log in again when the session expires (beside a
#                           local API, say).
#
# The profile is AWS_PROFILE, from the shell (the deploy has loaded the app's
# env files by then; an app's own wrapper can read its files first). With no
# profile the default credential chain is checked, and an expired session
# can't be renewed here (CI).

set -uo pipefail

INTERVAL="${AWS_SESSION_CHECK_SECONDS:-300}"
PROFILE="${AWS_PROFILE:-}"
profile_args=()
[[ -n "$PROFILE" ]] && profile_args=(--profile "$PROFILE")

# 0 = valid, 1 = SSO session expired (login fixes it), 2 = other failure
# (offline, no profile, ...: logging in won't help).
#
# The CLI keeps the role credentials it got through SSO in ~/.aws/cli/cache
# for up to an hour, and answers from them even once the SSO session behind
# them has expired, while Terraform and SAM (the Go and Java SDKs) never read
# that cache and fail. So the check runs with a HOME whose .aws links the real
# config, credentials and SSO token cache but has no cli/cache: the CLI has to
# use the SSO token, refreshing it the usual way (written back to the real
# token cache) when it is only due for a refresh.
check() {
  local out home status f
  home="$(mktemp -d "${TMPDIR:-/tmp}/aws-session.XXXXXX")" || return 2
  mkdir -p "$home/.aws"
  for f in config credentials sso; do
    [[ -e "$HOME/.aws/$f" ]] && ln -s "$HOME/.aws/$f" "$home/.aws/$f"
  done
  out=$(HOME="$home" aws sts get-caller-identity ${profile_args[@]+"${profile_args[@]}"} 2>&1 >/dev/null)
  status=$?
  rm -rf "$home"
  ((status == 0)) && return 0
  # The CLI's wording varies by version and by what expired: the SSO token
  # itself, or the role credentials it cached (InvalidClientTokenId, "the
  # security token included in the request is invalid"; iris, 2026-11-02).
  if grep -qiE 'token has expired|sso session|refresh failed|expiredtoken|UnauthorizedSSOToken|Error loading SSO Token|InvalidClientTokenId|security token included in the request is invalid' <<<"$out"; then
    return 1
  fi
  echo "[aws-session] AWS check failed (not an expired session): ${out##*$'\n'}" >&2
  return 2
}

banner() {
  printf '\n\033[1;33m%s\033[0m\n' "==============================================================="
  printf '\033[1;33m  %s\033[0m\n' "$@"
  printf '\033[1;33m%s\033[0m\n\n' "==============================================================="
}

login() {
  if [[ -z "$PROFILE" ]]; then
    echo "[aws-session] AWS SSO session expired, and no AWS_PROFILE is set to log in with." >&2
    return 1
  fi
  banner "AWS SSO session for profile '$PROFILE' expired." \
    "Running: aws sso login --profile $PROFILE (a browser window opens)"
  # Shown as it comes: when no browser opens, the URL and code to type are in
  # it, and a login that waits on them silently looks stuck.
  local out rc
  out="$(mktemp -t aws-sso-login)"
  aws sso login --profile "$PROFILE" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  if ((rc != 0)); then
    # The profile lost its SSO settings (iris, 2026-11-02: ~/.aws/config was
    # rewritten to a region only, with static keys in ~/.aws/credentials).
    if grep -q 'required SSO configuration' "$out"; then
      echo "[aws-session] Profile '$PROFILE' isn't an SSO profile any more: ~/.aws/config has no sso_* for it." >&2
      echo "[aws-session] Put it back (aws configure sso --profile $PROFILE), then run the deploy again." >&2
    fi
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
}

ensure() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "[aws-session] aws CLI not found: brew install awscli" >&2
    return 1
  fi
  check
  case $? in
    0) return 0 ;;
    2) return 1 ;;
  esac
  # Under the deploy UI the deploy has no terminal, but someone is watching
  # and aws sso login only needs a browser.
  if [[ (-t 0 && -t 1) || "${DEPLOY_UI:-}" == tui ]]; then
    login && check
    return $?
  fi
  echo "[aws-session] AWS SSO session expired. Run: aws sso login${PROFILE:+ --profile $PROFILE}" >&2
  return 1
}

watch() {
  while sleep "$INTERVAL"; do
    check
    case $? in
      1) login || echo "[aws-session] Login failed; will retry in ${INTERVAL}s." >&2 ;;
    esac
  done
}

case "${1:-}" in
  ensure) ensure ;;
  watch) watch ;;
  *)
    echo "usage: $0 ensure|watch" >&2
    exit 2
    ;;
esac
