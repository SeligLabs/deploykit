# shellcheck shell=bash disable=SC2034 # LINT_FAILED is read by deploy.sh
# Lint: every CI check, run locally by bin/checks.sh over the app's list, the list the CI
# verify matrix is built from. Each check logs to its own file in $WORK/lint;
# checks.sh runs them in parallel, the ones that write shared files alone,
# and prints the end of each failed log. Each check is a thread too
# (lib/tracker.sh), from checks.sh's event lines, so the deploy UI gives
# every check a page of its own.

# Read by cleanup, which takes back this run's version bump.
LINT_FAILED=0

# lint_checks <checks.sh arguments>: the runner over the app's list.
lint_checks() { DK_APP_ROOT="$ROOT" DK_CHECKS="$(dk_c checks scripts/checks.list)" bash "$DK_ROOT/bin/checks.sh" "$@"; }

lint_steps() { lint_checks list | tr '\n' ' '; }

# lint_timing <name> <event line>: a finished check's time, for the record.
lint_timing() {
  local t="${2##* }"
  timing Lint "$1" $((10#${t%:*} * 60 + 10#${t#*:}))
}

lint_stage() {
  stage Lint
  local names count status finished=0 line name
  names=" $(lint_steps) "
  count="$(wc -w <<<"$names" | tr -d ' ')"
  progress_total "$count" "checks"

  set +e
  CI_CHECKS_LOG_DIR="$WORK/lint" lint_checks run-all 2>&1 </dev/null |
    while IFS= read -r line; do
      name="${line#* }"
      name="${name%% *}"
      # Only checks.sh's own event lines; a failed log's tail is printed.
      [[ "$names" == *" $name "* ]] || line="  $line"
      case "$line" in
        "▶ "*)
          step_mark "$name" r
          thread_begin "lint-$name" "$name" "$WORK/lint/$name.log"
          ;;
        "✓ "*)
          step_mark "$name" d
          thread_end "lint-$name" d
          lint_timing "$name" "$line"
          finished=$((finished + 1))
          progress_set "$finished"
          printf '  \e[32m✓\e[0m %s\n' "${line#✓ }"
          ;;
        "– "*)
          step_mark "$name" s
          thread_end "lint-$name" s
          finished=$((finished + 1))
          progress_set "$finished"
          printf '  \e[2m–\e[0m %s\n' "${line#– }"
          ;;
        "✗ "*)
          step_mark "$name" f
          thread_end "lint-$name" f
          lint_timing "$name" "$line"
          finished=$((finished + 1))
          progress_set "$finished"
          printf '  \e[31m✗\e[0m %s\n' "${line#✗ }"
          ;;
        *) printf '%s\n' "$line" ;;
      esac
    done
  status=${PIPESTATUS[0]}
  set -e
  if ((status != 0)); then
    LINT_FAILED=1
    die "Lint failed. Nothing was deployed."
  fi
}
