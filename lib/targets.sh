# shellcheck shell=bash
# Groups and targets: everything an app ships, declared as data.
#
#   dk_group <group> <label>
#   dk_target <group> <id> --driver site|fastlane|fn [--<option> <value> | --<flag>] ...
#
# A target is one thing built and shipped to one place (the iOS app to
# TestFlight, a site to its bucket). Its id is unique in the app (ios,
# android, tvos, androidtv, macos, app, www). Every target, whatever its
# driver, runs one lifecycle in a background lane of its own:
#
#   build (check, prepare, build, verify)  →  gate  →  publish
#
# The gate opens once Infra is out (yarn deploy) or at once (a group or a
# target on its own), and never before Lint passes. A lane that finds nothing
# to publish (the store already has this build) hands its result back
# without waiting. The driver does the work (drivers/*.sh); the app's hooks,
# all optional, fill in what is its own (CONTRACT.md, Hooks).
#
# Options every driver reads:
#   --name <Name>          the stage's name in the tracker (default: iOS,
#                          Android, tvOS, AndroidTV, macOS for those ids,
#                          else the id); its result file is <name>-result
#   --label <text>         the checklist's and Start's description
#   --default off          start unticked in the checklist
#   --waits-for outputs    build only once outputs_ready (the app's hook)
#                          says Infra's outputs exist; on a first deploy the
#                          lane starts after Infra
#   --steps "<A B ...>"    the tracker's steps, replacing the driver's (keep
#                          Gate where the lane waits; hooks may use extra steps)
#   --log <path>           the lane's log (default <dir>/build/deploy-<id>.log,
#                          or the app's cache without --dir)
#
# Runs on macOS's bash 3.2: no associative arrays, so a target's settings live
# in DKT_<id>_<option> variables and the lists in indexed arrays.

DK_GROUP_IDS=()
DK_TARGET_IDS=()
# Flags: options that take no value.
DK_TARGET_FLAGS=" play reuse no_reuse early "

# dk_group <group> <label>
dk_group() {
  [[ "$1" =~ ^[a-z][a-z0-9]*$ ]] || die "dk_group: '$1' isn't a lowercase name."
  [[ " ${DK_GROUP_IDS[*]:-} " != *" $1 "* ]] || die "dk_group: '$1' is declared twice."
  DK_GROUP_IDS+=("$1")
  printf -v "DKG_$1_label" '%s' "${2:-$1}"
}

# dk_default_name <id>: the tracker name for the well-known ids.
dk_default_name() {
  case "$1" in
    ios) echo iOS ;;
    android) echo Android ;;
    tvos) echo tvOS ;;
    androidtv) echo AndroidTV ;;
    macos) echo macOS ;;
    msstore) echo MSStore ;;
    *) echo "$1" ;;
  esac
}

# dk_target <group> <id> [--<option> <value> | --<flag>] ...
dk_target() {
  local group=$1 id=$2 key name
  shift 2
  [[ " ${DK_GROUP_IDS[*]:-} " == *" $group "* ]] || die "dk_target $id: no group '$group' (dk_group first)."
  [[ "$id" =~ ^[a-z][a-z0-9]*$ ]] || die "dk_target: '$id' isn't a lowercase name."
  [[ " ${DK_TARGET_IDS[*]:-} " != *" $id "* ]] || die "dk_target: '$id' is declared twice (ids are unique in the app)."
  DK_TARGET_IDS+=("$id")
  printf -v "DKT_${id}_group" '%s' "$group"
  while [[ $# -gt 0 ]]; do
    [[ "$1" == --* ]] || die "dk_target $id: expected an option, got '$1'."
    key="${1#--}"
    key="${key//-/_}"
    if [[ "$DK_TARGET_FLAGS" == *" $key "* ]]; then
      printf -v "DKT_${id}_${key}" '%s' 1
      shift
    else
      [[ $# -ge 2 ]] || die "dk_target $id: --$key needs a value."
      printf -v "DKT_${id}_${key}" '%s' "$2"
      shift 2
    fi
  done
  [[ -n "$(dk_t "$id" driver)" ]] || die "dk_target $id: --driver is required (site, fastlane or fn)."
  name="$(dk_t "$id" name "$(dk_default_name "$id")")"
  [[ "$name" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || die "dk_target $id: --name '$name' must be one word."
  printf -v "DKT_${id}_name" '%s' "$name"
  printf -v "DKT_${id}_on" '%s' 0
}

# dk_t <id> <option> [<default>]: a target's option.
dk_t() {
  local var="DKT_$1_$2"
  if [[ -n "${!var:-}" ]]; then printf '%s' "${!var}"; else printf '%s' "${3:-}"; fi
}

# dk_g <group> label: a group's label.
dk_g() { local var="DKG_$1_$2"; printf '%s' "${!var:-}"; }

# dk_targets_of <group>: its target ids, in declaration order.
dk_targets_of() {
  local id
  for id in ${DK_TARGET_IDS[@]+"${DK_TARGET_IDS[@]}"}; do
    [[ "$(dk_t "$id" group)" == "$1" ]] && printf '%s\n' "$id"
  done
  return 0
}

# dk_target_by_name <Name>: the id of the target whose tracker name it is.
dk_target_by_name() {
  local id
  for id in ${DK_TARGET_IDS[@]+"${DK_TARGET_IDS[@]}"}; do
    [[ "$(dk_t "$id" name)" == "$1" ]] && { printf '%s' "$id"; return 0; }
  done
  return 1
}

dk_on() { [[ "$(dk_t "$1" on 0)" == 1 ]]; }
dk_set_on() { printf -v "DKT_$1_on" '%s' "$2"; }

# dk_targets_on: the ticked target ids, in order.
dk_targets_on() {
  local id
  for id in ${DK_TARGET_IDS[@]+"${DK_TARGET_IDS[@]}"}; do
    dk_on "$id" && printf '%s\n' "$id"
  done
  return 0
}

dk_any_on() { [[ -n "$(dk_targets_on)" ]]; }

# dk_result_file <id>: where the lane hands back its result (the deploy UI
# reads <name lowercased>-result too).
dk_result_file() { printf '%s/%s-result' "$WORK" "$(dk_t "$1" name | tr '[:upper:]' '[:lower:]')"; }

# dk_result <id> <text>: the lane's result, for the summary and the UI.
dk_result() { printf '%s\n' "$2" >"$(dk_result_file "$1")"; }

# dk_target_log <id>: the lane's log, outside anything a build replaces so it
# outlives the run: beside its --dir's build output, else in the app's cache.
dk_target_log() {
  local dir
  dir="$(dk_t "$1" dir)"
  if [[ -n "$dir" ]]; then
    dk_t "$1" log "$ROOT/$dir/build/deploy-$1.log"
  else
    dk_t "$1" log "${XDG_CACHE_HOME:-$HOME/.cache}/$APP_SLUG/lanes/deploy-$1.log"
  fi
}

# dk_hook <name> [<arg> ...]: call the app's hook when it defines one.
dk_hook() {
  local fn=$1
  shift
  if declare -F "$fn" >/dev/null; then "$fn" "$@"; fi
}

# dk_has_hook <name>
dk_has_hook() { declare -F "$1" >/dev/null; }

# dk_driver <id> <phase> [<arg> ...]: the target's driver for one phase
# (tools, preflight, check, build, publish, summary, steps, needs_aws). A
# driver that has no such phase does nothing.
dk_driver() {
  local id=$1 phase=$2 fn
  shift 2
  fn="dk_$(dk_t "$id" driver)_$phase"
  declare -F "$fn" >/dev/null || return 0
  "$fn" "$id" "$@"
}

# dk_target_steps <id>: its steps; Gate only where a lane waits for Infra.
# dk_any_versioned: a ticked target ships a version (a store build does; a
# site doesn't: its driver says versioned no), so the version is asked.
dk_any_versioned() {
  local id
  for id in $(dk_targets_on); do
    [[ "$(dk_driver "$id" versioned)" == no ]] || return 0
  done
  return 1
}

dk_target_steps() {
  local steps out="" s
  steps="$(dk_t "$1" steps)"
  [[ -n "$steps" ]] || steps="$(dk_driver "$1" steps)"
  for s in $steps; do
    [[ "$s" == Gate && "$DK_KIND" != all ]] && continue
    out+="$s "
  done
  printf '%s' "${out% }"
}

# dk_needs_outputs <id>: the target waits for Infra's outputs.
dk_needs_outputs() { [[ "$(dk_t "$1" waits_for)" == outputs ]]; }

# dk_outputs_ready: the app's outputs_ready hook, or true without one.
dk_outputs_ready() {
  if dk_has_hook outputs_ready; then outputs_ready; else return 0; fi
}

# dk_lane_run <id>: a target's lane, in the background: build, gate, publish.
dk_lane_run() {
  local id=$1
  rm -f "$(dk_result_file "$id")"
  if dk_needs_outputs "$id" && ! dk_outputs_ready; then
    die "Infra's outputs aren't there yet (outputs_ready): deploy the infrastructure first."
  fi
  dk_driver "$id" build
  touch "$WORK/$id-built"
  # Nothing to publish (the store has this build already).
  [[ ! -f "$(dk_result_file "$id")" ]] || return 0
  dk_gate || return 0
  dk_hook "${id}_before_publish"
  dk_driver "$id" publish
}

# dk_gate: a built lane waits (lanes never prompt): ship.go once Infra is out,
# ship.stop when the run is over (false). Then the env again, since the apply
# may have changed what the publish reads.
dk_gate() {
  if [[ "$DK_KIND" == all ]]; then
    step Gate "Built. Waiting for Infra"
    spinner_label "built; waiting for Infra"
  fi
  until [[ -f "$WORK/ship.go" || -f "$WORK/ship.stop" ]]; do sleep 2; done
  [[ ! -f "$WORK/ship.stop" ]] || return 1
  dk_reload_env
}

# dk_start_lanes [all]: every ticked target's lane, except one waiting for
# outputs that don't exist yet (a first deploy); `all` starts those too,
# after Infra.
dk_start_lanes() {
  local id planned=""
  for id in $(dk_targets_on); do planned+=" $(dk_t "$id" name)"; done
  put lanes_planned "${planned# }"
  for id in $(dk_targets_on); do
    bg_started "$(dk_t "$id" name)" && continue
    if [[ "${1:-}" == all ]] || ! dk_needs_outputs "$id" || dk_outputs_ready; then
      bg_start "$(dk_t "$id" name)" "$(dk_target_log "$id")" dk_lane_run "$id"
    fi
  done
  return 0
}

# dk_lanes_waiting: ticked targets whose lanes wait for Infra's outputs.
dk_lanes_waiting() {
  local id out=""
  for id in $(dk_targets_on); do
    dk_needs_outputs "$id" && ! dk_outputs_ready && out+=" $(dk_t "$id" name)"
  done
  printf '%s' "${out# }"
}

# dk_join_lanes: each target's stage in turn, whatever the others did: one
# target failing doesn't stop another mid-publish. Fails at the end, naming
# them all; the foreground's after_publish hooks run for those that passed.
dk_join_lanes() {
  local id name failed="" last="" lastname=""
  for id in ${DK_TARGET_IDS[@]+"${DK_TARGET_IDS[@]}"}; do
    name="$(dk_t "$id" name)"
    [[ " ${STAGES[*]} " == *" $name "* ]] || continue
    lastname=$name
    if ! bg_started "$name"; then
      stage_skip "$name" "not selected"
      continue
    fi
    stage "$name"
    [[ -z "$last" ]] || set_state stage_states "$(stage_index "$last")" f
    last=""
    if bg_wait "$name"; then
      dk_hook "${id}_after_publish"
    else
      failed+=" $name"
      last=$name
    fi
  done
  [[ -n "$failed" ]] || return 0
  # The last one's failure is tracker_end's to mark, through die; when it
  # passed, it is finished here so tracker_end doesn't.
  if [[ -z "$last" && -n "$lastname" ]]; then
    close_steps
    set_state stage_states "$(stage_index "$lastname")" d
    put cur_stage -1
  fi
  if ((DO_RELEASE)); then die "Failed:$failed. The other targets carried on; Release didn't run."; fi
  die "Failed:$failed. The other targets carried on."
}

# dk_lane_result <id>: what a lane handed back.
dk_lane_result() {
  local f
  f="$(dk_result_file "$1")"
  if [[ -f "$f" ]]; then cat "$f"; elif dk_on "$1"; then echo "no result"; else echo "not selected"; fi
}
