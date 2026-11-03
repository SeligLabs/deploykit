#!/usr/bin/env bash
# deploykit's check runner, over the app's one list of CI checks. The app's
# CI builds its verify matrix from it and the deploy's Lint stage runs it, so
# the two can't drift: add a check to the list and both pick it up.
#
#   checks.sh list            names, one per line
#   checks.sh matrix          {"include":[{"check":…,"lang":…}]} for CI
#   checks.sh run <name>      one check, output to the terminal
#   checks.sh run-all         every check, CI_CHECKS_JOBS (6) at a time,
#                                each logging to its own file in
#                                CI_CHECKS_LOG_DIR (a temp dir by default)
#
# lang names the toolchain a CI runner needs: js (Node + yarn install), go,
# or tf (Terraform; tf-test plans against placeholder zips, so no Go).
# local needs a Mac's Xcode, so it stays out of CI's matrix and runs only in
# run-all, where it skips (77) without one. lock says what a check can't run
# beside, for run-all: * runs alone (say, a check that regenerates a file every
# other check reads); any other word names something checks share (a build
# directory, Terraform's plugin cache), so checks with the same word take
# turns; - runs beside anything. A check starts as soon as it can, so one that waits
# doesn't hold up those behind it, except *: nothing passes that. Every check
# runs to the end, then run-all fails if any did, printing the end of each
# failed log. A check must not write what a deploy's apply reads (the
# Lambda zips Terraform deploys from), so the checks can run beside one.
#
# run-all prints one line per event, which the deploy Lint stage reads:
#   ▶ <name>   started
#   ✓ <name> <m:ss>   passed
#   ✗ <name> <m:ss>   failed
#   – <name> <m:ss>   skipped (the check exited 77: a tool it needs, such
#                     as Docker, isn't running here)
#
# Runs on macOS's bash 3.2.

set -euo pipefail

# The app being checked: DK_APP_ROOT, else the git checkout around the
# working directory.
ROOT="${DK_APP_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# The app's list: one check per line, `name|lang|lock|command`; # comments
# and blank lines are skipped. DK_CHECKS names the file (relative to the
# app's root), else scripts/checks.list.
LIST="${DK_CHECKS:-scripts/checks.list}"
[[ "$LIST" == /* ]] || LIST="$ROOT/$LIST"
[[ -f "$LIST" ]] || { echo "checks: no check list at $LIST (DK_CHECKS)" >&2; exit 2; }
CHECKS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  CHECKS+=("$line")
done <"$LIST"

field() {
  local IFS='|'
  local -a parts
  read -r -a parts <<<"$1"
  case "$2" in
    name) echo "${parts[0]}" ;;
    lang) echo "${parts[1]}" ;;
    lock) echo "${parts[2]}" ;;
    cmd) echo "${1#*|*|*|}" ;;
  esac
}

find_check() {
  local entry
  for entry in "${CHECKS[@]}"; do
    if [[ "$(field "$entry" name)" == "$1" ]]; then
      echo "$entry"
      return 0
    fi
  done
  echo "Unknown check: $1 (checks.sh list)" >&2
  return 1
}

mmss() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

list() {
  local entry
  for entry in "${CHECKS[@]}"; do field "$entry" name; done
}

matrix() {
  local entry out=""
  for entry in "${CHECKS[@]}"; do
    [[ "$(field "$entry" lang)" == local ]] && continue
    out+="{\"check\":\"$(field "$entry" name)\",\"lang\":\"$(field "$entry" lang)\"},"
  done
  printf '{"include":[%s]}\n' "${out%,}"
}

run_one() {
  local entry
  entry="$(find_check "$1")"
  cd "$ROOT"
  CI="${CI:-true}" exec bash -c "$(field "$entry" cmd)"
}

run_all() {
  local jobs="${CI_CHECKS_JOBS:-6}" logs="${CI_CHECKS_LOG_DIR:-}"
  if [[ -z "$logs" ]]; then
    logs="$(mktemp -d "${TMPDIR:-/tmp}/checks.XXXXXX")"
  fi
  mkdir -p "$logs"

  local count=${#CHECKS[@]} i pid entry name t0 skipped=0
  local -a running=() failed=() starts=() locks=()
  for ((i = 0; i < count; i++)); do locks[i]="$(field "${CHECKS[i]}" lock)"; done

  # start <index>: run a check in the background.
  start() {
    local n
    n="$(field "${CHECKS[$1]}" name)"
    (cd "$ROOT" && CI=true bash -c "$(field "${CHECKS[$1]}" cmd)") >"$logs/$n.log" 2>&1 </dev/null &
    running+=("$1:$!")
    starts[$1]=$(date +%s)
    echo "▶ $n"
  }

  # free <index>: nothing running stops this check.
  free() {
    local held
    for entry in ${running[@]+"${running[@]}"}; do
      held=${locks[${entry%%:*}]}
      [[ "$held" == '*' || "${locks[$1]}" == '*' ]] && return 1
      [[ "$held" == - || "$held" != "${locks[$1]}" ]] || return 1
    done
    return 0
  }

  # start_ready: start what can start, in list order, up to the slots.
  start_ready() {
    local n
    for ((n = 0; n < count; n++)); do
      [[ -z "${starts[n]:-}" ]] || continue
      if ((${#running[@]} < jobs)) && free "$n"; then
        start "$n"
      fi
      # Nothing passes an unstarted * check.
      [[ -n "${starts[n]:-}" || "${locks[n]}" != '*' ]] || return 0
    done
    return 0
  }

  # reap: collect every finished check; true when one finished.
  reap() {
    local -a still=()
    local done_any=1
    for entry in ${running[@]+"${running[@]}"}; do
      i=${entry%%:*}
      pid=${entry#*:}
      if kill -0 "$pid" 2>/dev/null; then
        still+=("$entry")
        continue
      fi
      name="$(field "${CHECKS[i]}" name)"
      t0=${starts[i]}
      local status=0
      wait "$pid" || status=$?
      if ((status == 0)); then
        echo "✓ $name $(mmss $(($(date +%s) - t0)))"
      elif ((status == 77)); then
        echo "– $name $(mmss $(($(date +%s) - t0))) skipped"
        skipped=$((skipped + 1))
      else
        echo "✗ $name $(mmss $(($(date +%s) - t0)))"
        failed+=("$i")
      fi
      done_any=0
    done
    running=(${still[@]+"${still[@]}"})
    return "$done_any"
  }

  start_ready
  while ((${#running[@]} > 0)); do
    if reap; then start_ready; else sleep 0.3; fi
  done

  if ((${#failed[@]} > 0)); then
    local names=""
    for i in "${failed[@]}"; do
      name="$(field "${CHECKS[i]}" name)"
      names+="$name "
      printf '\n── %s (last 40 lines of %s)\n' "$name" "$logs/$name.log"
      tail -n 40 "$logs/$name.log"
    done
    printf '\nFailed: %s\n' "${names% }" >&2
    return 1
  fi
  if ((skipped > 0)); then
    echo "$((count - skipped)) of $count checks passed, $skipped skipped. Logs: $logs"
  else
    echo "All $count checks passed. Logs: $logs"
  fi
}

case "${1:-}" in
  list) list ;;
  matrix) matrix ;;
  run) run_one "${2:?usage: checks.sh run <name>}" ;;
  run-all) run_all ;;
  *)
    echo "usage: checks.sh list | matrix | run <name> | run-all" >&2
    exit 2
    ;;
esac
