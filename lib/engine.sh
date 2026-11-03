# shellcheck shell=bash disable=SC2034 # globals the stages and drivers read
# The engine: dk_main runs a deploy from the app's declarations.
#
#   yarn deploy                  everything: the checklist, the version, Start
#   yarn deploy <group>          that group's targets (no version change, no Infra)
#   yarn deploy <group>:<target> one target
#   yarn deploy infra [args]     API → Infra (arguments go to the plan)
#   yarn deploy settings         every setting the targets need, and its source
#   yarn deploy demo             a pretend run of this app, touching nothing
#
# The one run (yarn deploy): Preflight asks everything in one sitting (the
# checklist, the version, then Start with the plan's summary and the store
# note), commits the bump, starts every target's lane and plans. After Start
# nothing is asked: Lint gates what leaves the machine (a failure takes the
# bump back), Infra applies, the gate opens and each target publishes by
# itself; one failing doesn't stop the others; Release needs them all.
#
# In a terminal the deploy UI (tui/) owns the screen and asks the questions
# (DEPLOY_TUI=0: the plain output with pinned rows). One deploy at a time per
# machine. Runs on macOS's bash 3.2.

DK_KIND=""
DO_INFRA=0
DO_RELEASE=0
UNDO_BUMP=0
TF_ARGS=()

# dk_config <key> <value> [<key> <value> ...]: the app's settings for the
# engine (CONTRACT.md, Config).
dk_config() {
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || die "dk_config: '$1' needs a value."
    [[ "$1" =~ ^[a-z_]+$ ]] || die "dk_config: '$1' isn't a config key."
    printf -v "DKC_$1" '%s' "$2"
    shift 2
  done
}

# dk_c <key> [<default>]
dk_c() { local var="DKC_$1"; if [[ -n "${!var:-}" ]]; then printf '%s' "${!var}"; else printf '%s' "${2:-}"; fi; }

die() { printf '\e[1;31m%s\e[0m\n' "$*" >&2; exit 1; }
warn() { printf '\e[1;33m%s\e[0m\n' "$*" >&2; }

# app_field <field>: from the root package.json's app block.
app_field() { node -p "(require('$ROOT/package.json').app || {}).$1 || ''" 2>/dev/null; }

# with_lock <name> <command> [<arg> ...]: run a command while no other lane
# holds <name> (a mkdir lock in $WORK). In a subshell of its own, with set -e
# back on: `command || rc=$?` would turn it off inside the command, and a die
# there would leave the lock held and the next lane waiting for ever. The
# drivers' locks: xcode and gradle (one build per toolchain), play (Play's
# track reads and uploads), prebuild (generated native projects).
with_lock() {
  local lock="$WORK/$1.lock" rc=0
  shift
  until mkdir "$lock" 2>/dev/null; do sleep 2; done
  set +e
  (
    set -e
    "$@"
  )
  rc=$?
  set -e
  rmdir "$lock"
  return "$rc"
}

# dk_expo_prebuild <platform> [<workspace>] [<VAR=value> ...]: expo prebuild
# --clean, one at a time (the prebuild lock): two at once race on what they
# share. CI=1: no prompts.
dk_expo_prebuild() {
  local platform=$1 ws=${2:-@repo/mobile}
  shift
  [[ $# -gt 0 ]] && shift
  with_lock prebuild env CI=1 "$@" bash -c "cd '$ROOT' && yarn workspace '$ws' prebuild --platform '$platform' --clean"
}

# dk_reload_env: the env files again, after an apply has synced new outputs
# into them: the app's reload_env_hook, else each of dk_config reload_env's
# files over the shell.
dk_reload_env() {
  local f
  if dk_has_hook reload_env_hook; then
    reload_env_hook
    return 0
  fi
  for f in $(dk_c reload_env); do load_env --override "$ROOT/$f"; done
  return 0
}

# stage_steps <stage>: the tracker's steps for a stage.
stage_steps() {
  local id
  case "$1" in
    Preflight)
      case "$DK_KIND" in
        all) echo "Git Options Tools AWS Checks Version Plan Confirm" ;;
        targets) echo "Git Tools AWS Checks Confirm" ;;
        infra) echo "Tools AWS" ;;
      esac
      ;;
    Lint) lint_steps ;;
    API) echo "Build" ;;
    Infra) if [[ "$DK_KIND" == all ]]; then echo "Apply Sync"; else echo "Init Plan Confirm Apply Sync"; fi ;;
    Release) echo "Push Tag GitHub" ;;
    *)
      id="$(dk_target_by_name "$1")" || return 0
      dk_target_steps "$id"
      ;;
  esac
}

# dk_usage
dk_usage() {
  local g ids
  echo "Usage: yarn deploy [<command>]" >&2
  echo "  (none)              everything: the checklist, the version, then Start" >&2
  for g in ${DK_GROUP_IDS[@]+"${DK_GROUP_IDS[@]}"}; do
    ids="$(dk_targets_of "$g" | tr '\n' '|')"
    printf '  %-19s %s (%s)\n' "${g}[:${ids%|}]" "$(dk_g "$g" label)" "no version change" >&2
  done
  [[ -z "$(dk_c infra_dir)" ]] || echo "  infra [plan args]   API → Infra, asking before the apply" >&2
  echo "  settings            every setting the targets need, and where it comes from" >&2
  echo "  demo                a pretend run through the deploy UI, touching nothing" >&2
}

# dk_parse <command> [<arg> ...]: DK_KIND, MODE, the selection, TF_ARGS.
dk_parse() {
  local cmd=${1:-all} group target id
  [[ $# -gt 0 ]] && shift
  TF_ARGS=("$@")
  MODE=$cmd
  case "$cmd" in
    all) DK_KIND=all ;;
    infra)
      [[ -n "$(dk_c infra_dir)" ]] || die "This app has no infrastructure (dk_config infra_dir)."
      DK_KIND=infra
      ;;
    settings | demo) DK_KIND=$cmd ;;
    help | -h | --help)
      dk_usage
      exit 0
      ;;
    *)
      group="${cmd%%:*}"
      target=""
      [[ "$cmd" == *:* ]] && target="${cmd#*:}"
      [[ " ${DK_GROUP_IDS[*]:-} " == *" $group "* ]] || {
        dk_usage
        exit 2
      }
      DK_KIND=targets
      for id in $(dk_targets_of "$group"); do
        [[ -z "$target" || "$id" == "$target" ]] && dk_set_on "$id" 1
      done
      dk_any_on || die "No target '$target' in $group: $(dk_targets_of "$group" | tr '\n' ' ')"
      ;;
  esac
  if [[ "$DK_KIND" != infra && ${#TF_ARGS[@]} -gt 0 ]]; then
    die "Only yarn deploy infra takes arguments (for the plan); the others ask for what they need."
  fi
}

# dk_stages: STAGES for this run.
dk_stages() {
  local id
  STAGES=(Preflight)
  case "$DK_KIND" in
    all)
      [[ "$(dk_c lint yes)" == no ]] || STAGES+=(Lint)
      [[ -z "$(dk_c infra_dir)" ]] || STAGES+=(Infra)
      for id in ${DK_TARGET_IDS[@]+"${DK_TARGET_IDS[@]}"}; do STAGES+=("$(dk_t "$id" name)"); done
      [[ "$(dk_c release yes)" == no ]] || STAGES+=(Release)
      ;;
    infra) STAGES+=(API Infra) ;;
    targets) for id in $(dk_targets_on); do STAGES+=("$(dk_t "$id" name)"); done ;;
  esac
}

# dk_options: yarn deploy's checklist (grouped: a group's row ticks or
# unticks all its targets), then the version. Lint always runs.
dk_options() {
  local -a labels=() parents=() defaults=() rows=()
  local g id i hidx have_infra have_release
  step Options "Options"
  pause_ticker
  have_infra=0
  have_release=0
  [[ -z "$(dk_c infra_dir)" ]] || have_infra=1
  [[ "$(dk_c release yes)" == no ]] || have_release=1
  if ((have_infra)); then
    labels+=("$(printf '%-14s %s' "API + Infra" "$(dk_c infra_label "build the API, terraform plan + apply")")")
    parents+=(-)
    defaults+=("$([[ "$(dk_c infra_default on)" == off ]] && echo 0 || echo 1)")
    rows+=(INFRA)
  fi
  for g in ${DK_GROUP_IDS[@]+"${DK_GROUP_IDS[@]}"}; do
    [[ -n "$(dk_targets_of "$g")" ]] || continue
    hidx=${#labels[@]}
    labels+=("$(dk_g "$g" label)")
    parents+=(h)
    defaults+=(1)
    rows+=("group:$g")
    for id in $(dk_targets_of "$g"); do
      labels+=("$(printf '%-12s %s' "$(dk_t "$id" name)" "$(dk_t "$id" label "$(dk_driver "$id" summary)")")")
      parents+=("$hidx")
      defaults+=("$([[ "$(dk_t "$id" default)" == off ]] && echo 0 || echo 1)")
      rows+=("target:$id")
    done
  done
  if ((have_release)); then
    labels+=("$(printf '%-14s %s' Release "push main, tag, GitHub release")")
    parents+=(-)
    defaults+=("$([[ "$(dk_c release_default on)" == off ]] && echo 0 || echo 1)")
    rows+=(RELEASE)
  fi
  echo
  echo "Deploy (Lint always runs; each target publishes once Infra is out):"
  while :; do
    PICK_DEFAULTS=("${defaults[@]}")
    PICK_PARENT=("${parents[@]}")
    PROMPT_TITLE="What to deploy" pick_many "${labels[@]}" || die "Nothing chosen."
    PICK_PARENT=()
    DO_INFRA=0 DO_RELEASE=0
    for i in "${!rows[@]}"; do
      case "${rows[i]}" in
        INFRA) DO_INFRA=${PICKS[i]} ;;
        RELEASE) DO_RELEASE=${PICKS[i]} ;;
        target:*) dk_set_on "${rows[i]#target:}" "${PICKS[i]}" ;;
      esac
    done
    if ((DO_INFRA + DO_RELEASE > 0)) || dk_any_on; then break; fi
    echo "Nothing ticked. Tick at least one."
  done
  if dk_any_versioned || ((DO_RELEASE)); then
    version_choose
  else
    # Nothing ships a version: keep it, no tag.
    version_read
    BUMP=skip NEXT_VERSION=$VERSION NEXT_BUILD=$BUILD RELEASED=0
    tag_exists "$TAG" && RELEASED=1
  fi
  resume_ticker
}

# dk_needs_aws: Infra, or a ticked target whose driver talks to AWS.
dk_needs_aws() {
  local id
  ((DO_INFRA)) && return 0
  for id in $(dk_targets_on); do
    [[ "$(dk_driver "$id" needs_aws)" == yes ]] && return 0
  done
  return 1
}

# dk_tools: the tools this run needs on PATH.
dk_tools() {
  local id tools="git node yarn jq"
  ((DO_INFRA)) && tools+=" terraform"
  dk_needs_aws && tools+=" aws"
  ((DO_RELEASE)) && tools+=" gh"
  for id in $(dk_targets_on); do tools+=" $(dk_driver "$id" tools) $(dk_t "$id" tools)"; done
  printf '%s\n' $tools | awk 'NF && !seen[$0]++' | tr '\n' ' '
}

# dk_checks: each ticked target's setup (settings, keys, gems) and its store's
# answer (is this build new?), before anything reaches production.
dk_checks() {
  local id name
  step Checks "Target setup and store checks"
  for id in $(dk_targets_on); do
    name="$(dk_t "$id" name)"
    if [[ "$DK_KIND" == targets ]] && dk_needs_outputs "$id" && ! dk_outputs_ready; then
      die "$name needs Infra's outputs (outputs_ready), which aren't there yet: deploy the infrastructure first (yarn deploy)."
    fi
    dk_driver "$id" preflight
    dk_hook "${id}_preflight"
    if declare -F "dk_$(dk_t "$id" driver)_check" >/dev/null || dk_has_hook "${id}_check"; then
      spinner_label "asking the store about $name"
      thread_run "$id-check" "$name check" dk_check_target "$id" || die "The $name check stopped the deploy (above)."
    fi
  done
  dk_any_on || echo "No target selected."
  return 0
}

# dk_check_target <id>: the driver's check, then the app's.
dk_check_target() {
  dk_driver "$1" check "$NEXT_VERSION" "$NEXT_BUILD"
  dk_hook "${1}_check" "$NEXT_VERSION" "$NEXT_BUILD"
}

# dk_note_needed: a ticked target takes a store note.
dk_note_needed() {
  local id
  for id in $(dk_targets_on); do [[ "$(dk_driver "$id" takes_note)" == yes ]] && return 0; done
  return 1
}

# deploy_summary: what Start would do, for confirm_run.
deploy_summary() {
  local head id line name
  head="$(git -C "$ROOT" rev-parse --short HEAD)"
  printf '\e[1mDeploy %s from main%s\e[0m\n' "$head" "${STAGE:+ to $STAGE}"
  if [[ "$DK_KIND" == all ]]; then
    if [[ "$BUMP" == none || "$BUMP" == skip ]]; then
      echo "  Version    $VERSION ($BUILD), unchanged"
    elif [[ "$BUMP" == drop ]]; then
      echo "  Version    $VERSION ($BUILD), the unpushed bump dropped"
    elif ((DO_RELEASE)); then
      echo "  Version    $VERSION ($BUILD), committed; pushed in Release"
    else
      echo "  Version    $VERSION ($BUILD), committed; not released, so it stays unpushed"
    fi
    ((BREAKING)) && echo "  Breaking   minBuild $BUILD: older builds must update from the apply on"
    echo "  Lint       all $(wc -w <<<"$(lint_steps)" | tr -d ' ') CI checks first; a failure stops everything and takes the bump back"
    if [[ -n "$(dk_c infra_dir)" ]]; then
      if ((!DO_INFRA)); then
        echo "  Infra      not selected"
      elif [[ "$INFRA_STATUS" == 0 ]]; then
        echo "  Infra      no changes to apply"
      else
        echo "  Infra      apply: $(sed -n 2p "$WORK/tfplan-summary")"
        tail -n +3 "$WORK/tfplan-summary" | sed 's/^/           /'
      fi
    fi
  else
    echo "  Version    $VERSION ($BUILD)"
  fi
  for id in ${DK_TARGET_IDS[@]+"${DK_TARGET_IDS[@]}"}; do
    name="$(dk_t "$id" name)"
    if dk_on "$id"; then
      if dk_has_hook "${id}_summary"; then line="$("${id}_summary")"; else line="$(dk_driver "$id" summary)"; fi
      printf '  %-10s %s\n' "$name" "$line"
    elif [[ "$DK_KIND" == all ]]; then
      printf '  %-10s not selected\n' "$name"
    fi
  done
  if [[ "$DK_KIND" == all && "$(dk_c release yes)" != no ]]; then
    if ((!DO_RELEASE)); then
      echo "  Release    not selected"
    elif ((RELEASED)); then
      echo "  Release    skipped: tag $TAG exists"
    elif [[ "$BUMP" == skip || "$BUMP" == drop ]]; then
      echo "  Release    skipped: no tag or release"
    else
      echo "  Release    push main, tag $TAG, GitHub release"
    fi
  fi
  [[ -z "$(dk_lanes_waiting)" ]] || echo "  (A first deploy: $(dk_lanes_waiting) start once Infra has filled in the outputs.)"
  dk_hook summary_hook
}

# cancel_run: stop with nothing changed (a bump this run made is taken back
# by cleanup).
cancel_run() {
  resume_ticker
  finish "Cancelled. Nothing was changed." 33
  exit 1
}

# confirm_run <summary> <with a note: 1|0>: the one question. Start goes on;
# Edit the note first takes a store note and asks again; Cancel stops with
# nothing changed. Nothing is asked after it.
confirm_run() {
  local summary=$1 note=${2:-0}
  local -a choices
  step Confirm "Confirm"
  spinner_label "waiting for an answer"
  pause_ticker
  while :; do
    echo
    printf '%s\n' "$summary"
    ((note)) && echo "  Note       $(notes_line)"
    echo "Nothing is asked after this."
    echo
    if ((note)); then choices=("Start" "Edit the note first" "Cancel"); else choices=("Start" "Cancel"); fi
    PROMPT_TITLE="Start the deploy?" pick 0 "${choices[@]}" || cancel_run
    case "${choices[PICKED]}" in
      Start) break ;;
      Cancel) cancel_run ;;
      *) notes_edit ;;
    esac
  done
  resume_ticker
}

# dk_cleanup: the EXIT trap.
dk_cleanup() {
  local rc=$? pid stopped=0 id name lane=""
  local -a lane_pids
  set +e
  stop_ticker
  # First: a lane at the gate must not wait for a run that is over.
  touch "$WORK/ship.stop"
  # A target whose build is reused (an archive kept by version, build and
  # commit) still building after a failure: waiting lets the next run reuse
  # it. Not when the bump is taken back (that build number won't ship) or
  # after Ctrl-C or a hangup. A Ctrl-C here stops the question or the wait;
  # the INT trap's exit would end cleanup halfway.
  for id in $(dk_targets_on); do
    name="$(dk_t "$id" name)"
    if [[ "$(dk_driver "$id" reuses)" == yes && -n "$(bg_pids "$name")" && ! -f "$WORK/$id-built" ]]; then
      lane="$name"
      break
    fi
  done
  if [[ -n "$lane" ]] && ((rc != 0 && rc != 129 && rc != 130 && rc != 143 && !LINT_FAILED && !UNDO_BUMP)) && [[ -t 0 || "${DEPLOY_UI:-}" == tui ]]; then
    trap 'stopped=1' INT TERM
    echo
    # In a subshell with Ctrl-C's default: read isn't interrupted by a
    # trapped signal, so Ctrl-C at the question is a no only this way.
    if (trap - INT TERM; confirm "The $lane build is still running in the background. Wait for it, so the next run can reuse it?"); then
      echo "Waiting (Ctrl-C to stop)…"
      for pid in $(bg_pids "$lane"); do
        ((stopped)) && break
        wait "$pid"
      done
    fi
  fi
  trap '' INT TERM
  # Lanes and lint checks still running, with everything they started, and
  # the lanes waited for so none writes to $WORK once it is gone.
  read -r -a lane_pids <<<"$(bg_pids | tr '\n' ' ')"
  for pid in ${lane_pids[@]+"${lane_pids[@]}"} $(jobs -p); do kill_tree "$pid"; done
  for pid in ${lane_pids[@]+"${lane_pids[@]}"}; do wait "$pid" 2>/dev/null; done
  # After the lanes: nothing is reading package.json now.
  ((LINT_FAILED || UNDO_BUMP)) && version_undo
  tracker_end "$rc"
  if [[ -n "${DEPLOY_WORK:-}" ]]; then
    # The deploy UI reads the last state and the threads' logs, which it
    # keeps with the run, then removes the rest; the plan, which holds
    # secrets, goes now.
    find "$WORK" -mindepth 1 -maxdepth 1 ! -name status ! -name threads ! -name lint ! -name '*-result' -exec rm -rf {} + 2>/dev/null
  else
    rm -rf "$WORK"
  fi
  if [[ "$(cat "$DEPLOY_LOCK/pid" 2>/dev/null)" == "$$" ]]; then rm -rf "$DEPLOY_LOCK"; fi
}

# dk_lock: one deploy at a time on this machine: two at once break each other
# (one run's build rewriting what another run's apply reads). mkdir is atomic;
# the lock holds the owner's pid, so one left by a killed run is taken over.
dk_lock() {
  local holder
  DEPLOY_LOCK="$(deploy_lock_path "$APP_SLUG")"
  mkdir -p "$(dirname "$DEPLOY_LOCK")"
  if ! mkdir "$DEPLOY_LOCK" 2>/dev/null; then
    holder=$(cat "$DEPLOY_LOCK/pid" 2>/dev/null || true)
    if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
      die "Another deploy is running (pid $holder: $(ps -o command= -p "$holder" | cut -c1-80)). Wait for it or stop it first."
    fi
    echo "Taking over the deploy lock from an earlier run that is gone (pid ${holder:-unknown})."
    mkdir -p "$DEPLOY_LOCK"
  fi
  echo $$ >"$DEPLOY_LOCK/pid"
}

# dk_identity: the app's names, from dk_config, else package.json's app block.
dk_identity() {
  APP_SLUG="$(dk_c slug "$(app_field slug)")"
  [[ -n "$APP_SLUG" ]] || die "No app slug: set app.slug in package.json or dk_config slug."
  APP_NAME="$(dk_c name "$(app_field displayName)")"
  APP_BUNDLE_ID="$(dk_c bundle_id "$(app_field bundleId)")"
  export APP_SLUG APP_NAME APP_BUNDLE_ID
}

# dk_declare_settings: every setting the declared targets' drivers need, so
# `yarn deploy settings` lists them and Preflight checks the ticked ones.
dk_declare_settings() {
  local id
  for id in ${DK_TARGET_IDS[@]+"${DK_TARGET_IDS[@]}"}; do dk_driver "$id" settings; done
  return 0
}

# dk_main <command> [<arg> ...]: the deploy.
dk_main() {
  cd "$ROOT"
  [[ "$(dk_c api)" == "$DK_API" ]] ||
    die "This app is written for deploykit API $(dk_c api '(unset)'); the installed kit is API $DK_API ($DK_VERSION). Read its CHANGELOG."

  # The app's env files, loaded once: run its deploy.sh again under the
  # loader. Values already in the shell win.
  if [[ -n "$(dk_c env_loader)" && "${DEPLOY_ENV_LOADED:-}" != 1 ]]; then
    # shellcheck disable=SC2046 # the loader is a command line, split on purpose
    exec env DEPLOY_ENV_LOADED=1 $(dk_c env_loader) bash "$DK_CALLER" "$@"
  fi
  export DEPLOY_ENV_LOADED=1
  # No pager: with a terminal on stdout the AWS CLI pipes through less, which
  # restores the screen on exit and with it the terminal's scroll region.
  export AWS_PAGER=""
  if [[ -z "${AWS_PROFILE:-}" && -n "$(dk_c aws_profile)" ]]; then
    AWS_PROFILE="$(dk_c aws_profile)"
    export AWS_PROFILE
  fi
  DK_SETTINGS_FILES="$(dk_c settings_files env/release.env)"
  dk_identity
  dk_parse "$@"
  dk_declare_settings

  if [[ "$DK_KIND" == settings ]]; then
    dk_settings_report
    exit $?
  fi
  if [[ "$DK_KIND" == demo ]]; then
    # shellcheck source=demo.sh
    source "$DK_ROOT/lib/demo.sh"
    dk_demo_setup
    DK_KIND=all
    MODE=demo
  fi

  # The deploy UI: in a terminal, hand it the terminal and run under it,
  # unless DEPLOY_TUI=0. It runs the app's deploy.sh again as its child with
  # DEPLOY_UI=tui (and the env files already loaded), so this happens once.
  # If it can't be built, the deploy runs with its plain output.
  local tui
  if [[ -z "${DEPLOY_UI:-}" && "${DEPLOY_TUI:-1}" != 0 && -t 0 && -t 1 ]]; then
    if tui="$(bash "$DK_ROOT/tui/build.sh")"; then
      exec "$tui" -- bash "$DK_CALLER" "$@"
    fi
    warn "The deploy UI didn't build (above), so this deploy uses the plain output."
  fi

  dk_lock
  # Under the deploy UI the UI made it, reads the tracker's state from it, and
  # removes it at the end.
  WORK="${DEPLOY_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/$APP_SLUG-deploy.XXXXXX")}"
  dk_infra_setup
  dk_stages
  trap dk_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # A hangup (the terminal closed or killed) otherwise runs cleanup with
  # status 0: lanes stopped, no failure shown.
  trap 'exit 129' HUP
  tracker_init

  case "$DK_KIND" in
    all) dk_run_all ;;
    infra) dk_run_infra ;;
    targets) dk_run_targets ;;
  esac
}

# dk_run_all: yarn deploy.
dk_run_all() {
  local id summary="" r tools
  stage Preflight
  preflight_git
  dk_options
  tools="$(dk_tools)"
  # shellcheck disable=SC2086 # a word list
  preflight_tools $tools
  if dk_needs_aws; then preflight_aws; else step_mark AWS s; fi
  ((DO_INFRA)) && dk_hook infra_preflight_hook
  dk_checks
  version_read
  dk_note_needed && notes_default "$NEXT_VERSION" "$NEXT_BUILD" "v$NEXT_VERSION+$NEXT_BUILD"
  version_step
  version_read
  [[ -z "$BUMP_COMMIT" ]] || UNDO_BUMP=1
  # The builds need only the version and the deployed outputs: they run from
  # here, beside the plan and then Lint, and wait at the gate.
  dk_start_lanes
  plan_step
  ((DO_INFRA)) && dk_hook infra_check_hook
  confirm_run "$(deploy_summary)" "$(dk_note_needed && echo 1 || echo 0)"
  UNDO_BUMP=0

  # Nothing leaves the machine until Lint passes: a failure stops the lanes
  # and takes the bump back.
  [[ "$(dk_c lint yes)" == no ]] || lint_stage
  if [[ -n "$(dk_c infra_dir)" ]]; then
    if ((DO_INFRA)); then
      stage Infra
      infra_apply_thread
    else
      stage_skip Infra "not selected"
      INFRA_RESULT="not selected"
    fi
  fi
  dk_reload_env
  # A first deploy's lanes, now that the outputs exist.
  dk_start_lanes all
  # Infra is out: the lanes may publish.
  touch "$WORK/ship.go"
  dk_join_lanes
  if [[ "$(dk_c release yes)" != no ]]; then
    if ((DO_RELEASE)); then
      release_stage
    else
      stage_skip Release "not selected"
      RELEASE_RESULT="not selected"
    fi
  fi
  [[ -z "$(dk_c infra_dir)" ]] || summary+=" Infra: $INFRA_RESULT."
  for id in ${DK_TARGET_IDS[@]+"${DK_TARGET_IDS[@]}"}; do
    summary+=" $(dk_t "$id" name): $(dk_lane_result "$id")."
  done
  [[ "$(dk_c release yes)" == no ]] || summary+=" Release: $RELEASE_RESULT."
  finish "Deployed $VERSION ($BUILD)${STAGE:+ to $STAGE}.$summary" 32
}

# dk_run_targets: yarn deploy <group>[:<target>], no version change.
dk_run_targets() {
  local id summary=""
  stage Preflight
  preflight_git
  DO_INFRA=0 DO_RELEASE=0
  version_read
  NEXT_VERSION=$VERSION NEXT_BUILD=$BUILD
  # shellcheck disable=SC2046 # a word list
  preflight_tools $(dk_tools)
  if dk_needs_aws; then preflight_aws; else step_mark AWS s; fi
  dk_checks
  dk_note_needed && notes_default "$VERSION" "$BUILD" "$TAG"
  confirm_run "$(deploy_summary)" "$(dk_note_needed && echo 1 || echo 0)"
  # No Infra in this run: the gate is open from the start.
  touch "$WORK/ship.go"
  dk_start_lanes all
  dk_join_lanes
  for id in $(dk_targets_on); do summary+=" $(dk_t "$id" name): $(dk_lane_result "$id")."; done
  finish "${summary# }" 32
}

# dk_run_infra: yarn deploy infra.
dk_run_infra() {
  stage Preflight
  preflight_tools node yarn jq terraform aws
  preflight_aws
  DO_INFRA=1
  dk_hook infra_preflight_hook
  api_stage
  infra_stage
  if [[ "$INFRA_RESULT" == "no changes" ]]; then
    finish "No changes${STAGE:+ in $STAGE}. Nothing to apply." 32
  else
    finish "Applied${STAGE:+ to $STAGE}: $INFRA_RESULT." 32
  fi
}
