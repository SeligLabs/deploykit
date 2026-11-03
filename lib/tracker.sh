# shellcheck shell=bash disable=SC2031 # S changes only inside bg_start's lane
# Progress tracker for scripts/deploy/deploy.sh. Sourced, not run.
#
# In a terminal the bottom three rows stay pinned while output scrolls above:
#
#    ✓ Preflight  ✓ Lint  ● Infra  ○ iOS  ○ Release              total 6:42
#      ✓ Init  ● Plan  ○ Confirm  ○ Apply
#      Plan  [█████████░░░░░░░░░░░]  84/187 resources refreshed    step 0:31
#
# Row 1 is every stage, row 2 the running stage's steps, row 3 the running
# step's progress (a bar when there is a count, a spinner when not). When
# output isn't a terminal the rows are left out and the output is plain.
#
# Background lanes: bg_start runs a stage in the background (the iOS archive
# while API and Infra run, then its upload) and bg_wait joins it. Each running
# lane gets a row of its own under row 3:
#
#      iOS  Archive [███████░░░░░░░░░░░░░]  412/980 build steps    step 3:51
#
# and folds into one row when the terminal is short. A lane runs in a
# subshell with its own state directory, $WORK/status/bg/<name>, and writes
# nothing else; its output goes to a log. Only the foreground writes the
# global state (stage_states, lanes), so nothing needs a lock. A lane never
# prompts: a lane that needs an answer waits on a file the foreground writes.
#
# The caller sets STAGES (names) and defines stage_steps <stage name>, which
# prints that stage's step names. State lives in files under $WORK/status: the
# ticker and count_lines run in subshells. States: p pending, r running,
# b running in the background, d done, f failed, s skipped.
#
# Every step, stage and lane appends "<date> <time> <mode> <stage> <step>
# <seconds>" to $TIMINGS (<step> is "-" for a stage or lane's whole time), and
# the deploy's slowest steps print at the end: `sort -k6 -rn` it to compare runs.
#
# Runs on macOS's bash 3.2.

TTY=0
TICKER=""
LANE=""
STTY_SAVED=""

put() { printf '%s\n' "$2" >"$S/.$1" && mv -f "$S/.$1" "$S/$1"; }
get() { local _v=""; IFS= read -r _v <"$S/$1" || true; printf -v "$2" '%s' "$_v"; }
# getd <dir> <key> <var>: get from another state directory (a lane's).
getd() { local _v=""; IFS= read -r _v <"$1/$2" 2>/dev/null || true; printf -v "$3" '%s' "$_v"; }

term_rows() { local sz; sz="$(stty size </dev/tty 2>/dev/null)" || return 1; echo "${sz% *}"; }

mmss() { printf -v "$2" '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

# set_state <file> <index> <state>: one entry of a space-separated state list.
set_state() {
  local s
  local -a st
  get "$1" s
  read -r -a st <<<"$s"
  st[$2]=$3
  put "$1" "${st[*]}"
}

# states_like <count> <state>: "p p p ..." for a new list.
states_like() {
  local out="" i
  for ((i = 0; i < $1; i++)); do out+="$2 "; done
  printf '%s' "${out% }"
}

# render_items <names> <states>: "✓ A  ● B  ○ C  " for rows 1 and 2.
render_items() {
  local out="" i
  local -a names st
  read -r -a names <<<"$1"
  read -r -a st <<<"$2"
  for i in "${!names[@]}"; do
    case "${st[i]:-p}" in
      d) out+=$'\e[32m✓ '"${names[i]}"$'\e[0m  ' ;;
      r) out+=$'\e[1;36m● '"${names[i]}"$'\e[0m  ' ;;
      b) out+=$'\e[36m◐ '"${names[i]}"$'\e[0m  ' ;;
      f) out+=$'\e[1;31m✗ '"${names[i]}"$'\e[0m  ' ;;
      s) out+=$'\e[2m– '"${names[i]}"$'\e[0m  ' ;;
      *) out+=$'\e[2m○ '"${names[i]}"$'\e[0m  ' ;;
    esac
  done
  printf '%s' "$out"
}

# progress_row <state dir> <name>: row 3's text for a stage or lane: the
# running step (or <name>), a bar or spinner, and the step's time.
progress_row() {
  local d=$1 steps cur_step step_start n total label ln lt label2
  local now i r name t_step bar="" filled detail
  local -a step_names
  local spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  getd "$d" steps steps; getd "$d" cur_step cur_step; getd "$d" step_start step_start
  getd "$d" n n; getd "$d" total total; getd "$d" label label
  getd "$d" ln ln; getd "$d" lt lt; getd "$d" label2 label2
  now="$(date +%s)"
  read -r -a step_names <<<"$steps"
  mmss $((now - ${step_start:-now})) t_step
  # The running step, or the stage itself while steps run in parallel.
  if ((${cur_step:--1} >= 0)); then name="${step_names[cur_step]}"; else name=$2; fi
  r=$'\e[1m'"$name"$'\e[0m  '
  if ((${total:-0} > 0)); then
    filled=$((n * 20 / total))
    ((filled <= 20)) || filled=20
    for ((i = 0; i < 20; i++)); do
      if ((i < filled)); then bar+="█"; else bar+="░"; fi
    done
    # An estimate can run over: show the count alone then.
    if ((n > total)); then detail="$n $label"; else detail="$n/$total $label"; fi
    ((${lt:-0} > 0)) && detail+=" · $ln/$lt $label2"
    r+=$'\e[36m['"$bar"$']\e[0m  '"$detail"
  else
    r+=$'\e[36m'"${spin[now % 10]}"$'\e[0m '"${label:-working}"
  fi
  printf '%s' "$r"$'   \e[2mstep '"$t_step"$'\e[0m'
}

# lane_row <name>: a background lane's row.
lane_row() {
  local d="$S/bg/$1" pid log
  getd "$d" pid pid
  if [[ -f "$d/ok" ]]; then
    printf '%s' "   $1  "$'\e[32m✓ done\e[0m'
  elif [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    printf '%s' "   $1  $(progress_row "$d" "$1")"
  else
    getd "$d" log log
    printf '%s' "   $1  "$'\e[1;31m✗ stopped (log: '"${log#"$ROOT"/}"$')\e[0m'
  fi
}

# lanes_folded <names>: every running lane on one row.
lanes_folded() {
  local name out="" d n total label
  for name in $1; do
    d="$S/bg/$name"
    getd "$d" n n; getd "$d" total total; getd "$d" label label
    if [[ -f "$d/ok" ]]; then out+="$name ✓ · "
    elif ((${total:-0} > 0)); then out+="$name $n/$total · "
    else out+="$name ${label:-working} · "
    fi
  done
  printf '%s' $'   \e[2mbackground:\e[0m '"${out% · }"
}

# pinned_rows <terminal rows> <lane count>: rows the tracker keeps; lanes
# fold into one row when the output would get fewer than 8.
pinned_rows() {
  if (($2 == 0)); then echo 3
  elif (($1 - 3 - $2 >= 8)); then echo $((3 + $2))
  else echo 4
  fi
}

draw() {
  ((TTY)) || return 0
  local stage_states cur_stage steps step_states started
  local rows pinned lanes final final_style
  get stage_states stage_states; get cur_stage cur_stage; get steps steps; get step_states step_states
  get started started; get rows rows; get pinned pinned; get lanes lanes
  get final final; get final_style final_style

  local now t_total r1 r2 r3 out name top i=0
  now="$(date +%s)"
  mmss $((now - started)) t_total

  r1=" $(render_items "${STAGES[*]}" "$stage_states")"$'\e[2mtotal '"$t_total"$'\e[0m'
  r2=""
  [[ -n "$steps" ]] && r2="   $(render_items "$steps" "$step_states")"
  if [[ -n "$final" ]]; then
    r3=$'   \e['"$final_style"'m'"$final"$'\e[0m'
  elif ((cur_stage >= 0)); then
    r3="   $(progress_row "$S" "${STAGES[cur_stage]}")"
  else
    r3=""
  fi

  # Save the cursor, turn off autowrap (long rows clip instead of wrapping),
  # rewrite the pinned rows, restore. One printf, so it is one write.
  top=$((rows - pinned + 1))
  out=$'\e7\e[?7l'
  out+=$'\e['"$top"$';1H\e[2K'"$r1"
  out+=$'\e['"$((top + 1))"$';1H\e[2K'"$r2"
  out+=$'\e['"$((top + 2))"$';1H\e[2K'"$r3"
  if ((pinned > 3)); then
    if ((pinned == 3 + $(wc -w <<<"$lanes"))); then
      for name in $lanes; do
        out+=$'\e['"$((top + 3 + i))"$';1H\e[2K'"$(lane_row "$name")"
        i=$((i + 1))
      done
    else
      out+=$'\e['"$((top + 3))"$';1H\e[2K'"$(lanes_folded "$lanes")"
    fi
  fi
  out+=$'\e[?7h\e8'
  printf '%s' "$out"
}

# set_pinned <rows>: move the scroll region's bottom so the tracker keeps
# <rows> rows. Growing scrolls the output up a line per row first, so no
# output is drawn over; shrinking clears the rows given back. Foreground
# only, with the ticker paused.
set_pinned() {
  ((TTY)) || return 0
  local rows old new=$1 b
  get rows rows; get pinned old
  while ((old < new)); do
    b=$((rows - old))
    # At the region's bottom a newline scrolls the region up a line; the
    # saved cursor follows its line up.
    printf '\e7\e[%d;1H\n\e8\e[1A\e7\e[1;%dr\e8' "$b" $((b - 1))
    old=$((old + 1))
  done
  if ((old > new)); then
    printf '\e7'
    for ((b = rows - old + 1; b <= rows - new; b++)); do printf '\e[%d;1H\e[2K' "$b"; done
    printf '\e[1;%dr\e8' $((rows - new))
  fi
  put pinned "$new"
  draw
}

# Scroll output in rows 1..N-3 and keep the last three rows for the tracker.
term_init() {
  ((TTY)) || return 0
  local rows
  if ! rows="$(term_rows)" || ((rows < 8)); then
    TTY=0
    return 0
  fi
  put rows "$rows"
  put pinned 3
  # Make room for the rows, then set the scroll region (which homes the
  # cursor, hence the save/restore).
  printf '\n\n\n\e[3A\e7\e[1;%dr\e8' $((rows - 3))
}

# assert_region: set the scroll region to what the tracker believes it is.
# A tool run on the terminal in between (a pager, anything using the
# alternate screen) can reset it to the whole screen; the output then runs
# under the pinned rows and a prompt drawn there is overdrawn, so it looks
# stuck. Cheap, so the ticker does it every second and every prompt first.
assert_region() {
  ((TTY)) || return 0
  local rows pinned
  get rows rows; get pinned pinned
  printf '\e7\e[1;%dr\e8' $((rows - pinned))
}

tick() {
  set +e
  local last rows lanes pinned
  get rows last
  while sleep 1; do
    rows="$(term_rows)"
    if [[ -n "$rows" && "$rows" != "$last" ]] && ((rows >= 8)); then
      last=$rows
      put rows "$rows"
      get lanes lanes
      pinned="$(pinned_rows "$rows" "$(wc -w <<<"$lanes")")"
      put pinned "$pinned"
    fi
    assert_region
    draw
  done
}

start_ticker() {
  ((TTY)) || return 0
  [[ -z "$TICKER" ]] || return 0
  tick &
  TICKER=$!
}

stop_ticker() {
  [[ -n "$TICKER" ]] || return 0
  kill "$TICKER" 2>/dev/null || true
  wait "$TICKER" 2>/dev/null || true
  TICKER=""
}

# pause_ticker / resume_ticker around prompts, so redraws don't land in the
# middle of what the user is typing.
pause_ticker() { stop_ticker; assert_region; draw; }
resume_ticker() { start_ticker; }

# timing <stage> <step> <seconds>: one line of the run's record. Appends only,
# from any lane; it never stops a deploy.
timing() {
  printf '%s %s %s\n' "$1" "$2" "$3" >>"$WORK/timings" 2>/dev/null || true
  printf '%s %s %s %s %s\n' "$(date '+%F %T')" "$MODE" "$1" "$2" "$3" >>"$TIMINGS" 2>/dev/null || true
}

# timing_stage: the stage this shell is running: the lane's, or the foreground's.
timing_stage() {
  local cur
  if [[ -n "${LANE:-}" ]]; then
    echo "$LANE"
  else
    get cur_stage cur
    ((cur >= 0)) && echo "${STAGES[cur]}"
  fi
  return 0
}

# timing_step_end: record the running step, before anything moves it on.
timing_step_end() {
  local cur steps started
  local -a names
  get cur_step cur
  ((cur >= 0)) || return 0
  get steps steps; get step_start started
  read -r -a names <<<"$steps"
  timing "$(timing_stage)" "${names[cur]}" $(($(date +%s) - ${started:-0}))
}

# timing_stage_end: record the running step and the stage's whole time (a
# joined lane has recorded its own).
timing_stage_end() {
  local started name
  timing_step_end
  name="$(timing_stage)"
  [[ -n "$LANE" || ! -d "$S/bg/$name" ]] || return 0
  get stage_start started
  [[ -n "$started" ]] && timing "$name" - $(($(date +%s) - started))
  return 0
}

# timing_summary: this run's slowest steps, leaving out waits for an answer or
# for the upload gate, which aren't work.
timing_summary() {
  [[ -s "$WORK/timings" ]] || return 0
  local stage step seconds dur
  echo "Slowest steps (all runs: ${TIMINGS/#$HOME/\~}):"
  command grep -vE ' (-|Gate|Confirm|Options|Notes) ' "$WORK/timings" | sort -k3 -rn | head -n 8 | while read -r stage step seconds; do
    mmss "$seconds" dur
    printf '  %6s  %s %s\n' "$dur" "$stage" "$step"
  done
}

reset_progress() {
  put n 0; put total 0; put label ""; put ln 0; put lt 0; put label2 ""
  put step_start "$(date +%s)"
}

# close_steps [<state>]: pending steps of the running stage become skipped,
# running ones <state> (default done).
close_steps() {
  local s i to=${1:-d}
  local -a st
  get step_states s
  read -r -a st <<<"$s"
  for i in "${!st[@]}"; do
    case "${st[i]}" in
      r) st[i]=$to ;;
      p) st[i]=s ;;
    esac
  done
  put step_states "${st[*]}"
}

stage_index() {
  local i
  for i in "${!STAGES[@]}"; do
    [[ "${STAGES[i]}" == "$1" ]] && { echo "$i"; return 0; }
  done
  echo "tracker: unknown stage $1" >&2
  return 1
}

step_index() {
  local steps i
  local -a names
  get steps steps
  read -r -a names <<<"$steps"
  for i in "${!names[@]}"; do
    [[ "${names[i]}" == "$1" ]] && { echo "$i"; return 0; }
  done
  echo "tracker: unknown step $1" >&2
  return 1
}

# stage <name>: finish the running stage and start this one.
stage() {
  local cur idx steps count
  local -a _names
  get cur_stage cur
  if ((cur >= 0)); then
    timing_stage_end
    close_steps
    set_state stage_states "$cur" d
  fi
  idx="$(stage_index "$1")"
  steps="$(stage_steps "$1")"
  read -r -a _names <<<"$steps"
  count=${#_names[@]}
  put cur_stage "$idx"
  set_state stage_states "$idx" r
  put steps "$steps"
  # A stage whose first steps ran in a background lane carries on from them.
  if [[ -f "$S/bg/$1/step_states" ]]; then
    put step_states "$(cat "$S/bg/$1/step_states")"
  else
    put step_states "$(states_like "$count" p)"
  fi
  put cur_step -1
  put stage_start "$(date +%s)"
  reset_progress
  printf '\n\e[1;35m━━ %s\e[0m\n' "$1"
  draw
}

# stage_skip <name> [<reason>]: mark a stage that won't run.
stage_skip() {
  set_state stage_states "$(stage_index "$1")" s
  [[ -z "${2:-}" ]] || printf '\n\e[2m━━ %s skipped: %s\e[0m\n' "$1" "$2"
  draw
}

# step <name> [<heading>]: finish the running step and start this one.
step() {
  local cur idx
  get cur_step cur
  if ((cur >= 0)); then
    timing_step_end
    local s; local -a st
    get step_states s
    read -r -a st <<<"$s"
    [[ "${st[cur]}" == r ]] && set_state step_states "$cur" d
  fi
  idx="$(step_index "$1")"
  put cur_step "$idx"
  set_state step_states "$idx" r
  reset_progress
  echo "==> ${2:-$1}"
  draw
}

# step_mark <name> <state>: set a step's state without moving the cursor
# (parallel work, skipped steps).
step_mark() { set_state step_states "$(step_index "$1")" "$2"; draw; }

# progress_total <total> <label> [<second total> <second label>]
progress_total() {
  put total "$1"; put label "$2"
  put lt "${3:-0}"; put label2 "${4:-}"
  draw
}

# progress_set <n>
progress_set() { put n "$1"; draw; }

# spinner_label <text>: what the spinner row says when there is no count.
spinner_label() { put label "$1"; draw; }

# finish <message> <sgr colour>: the tracker's last row.
finish() { put final "$1"; put final_style "$2"; draw; }

# Threads: a piece of work with an output of its own (the API build, the
# Terraform plan and apply, the web upload, each Lint check; a lane is one
# too, in its own way). Its output goes to $WORK/threads/<key>.log and it is
# registered in $S/threads/<key>/ (title, log, state, started, ended), where
# the deploy UI finds it and gives it a page. The deploy's own output is then
# a summary: each thread's start and end, and on a failure its last lines.
# Without the UI its output also goes to the terminal, as before.

# thread_begin <key> <title> <log>: register a thread as running.
thread_begin() {
  local d="$S/threads/$1"
  mkdir -p "$d" "$(dirname "$3")"
  S=$d put title "$2"
  S=$d put log "$3"
  S=$d put started "$(date +%s)"
  S=$d put state r
}

# thread_end <key> <state>: d done, f failed, s skipped.
thread_end() {
  local d="$S/threads/$1"
  [[ -d "$d" ]] || return 0
  S=$d put ended "$(date +%s)"
  S=$d put state "$2"
}

# threads_stop: every thread still running when the deploy ends was cut
# short (ctrl+c, a failure elsewhere): failed, so no page shows it running.
threads_stop() {
  local d state
  for d in "$S"/threads/*/; do
    [[ -d "$d" ]] || continue
    IFS= read -r state <"$d/state" 2>/dev/null || state=""
    [[ "$state" == r ]] && thread_end "$(basename "$d")" f
  done
  return 0
}

# thread_run <key> <title> <command> [<arg> ...]: run a command as a thread
# and return its status. It runs in a subshell either way: a die inside it
# ends the thread, not the deploy, and its reason is in the log, which the
# summary then shows (under the UI, its last lines). Anything it hands back
# goes through a file (tracker state is files already).
thread_run() {
  local key=$1 title=$2 log="$WORK/threads/$1.log" rc t0 dur
  shift 2
  thread_begin "$key" "$title" "$log"
  t0=$(date +%s)
  in_tui && printf '\e[2m  ▸ %s\e[0m\n' "$title"
  set +e
  if in_tui; then
    ("$@") </dev/null >>"$log" 2>&1
    rc=$?
  else
    ("$@") </dev/null 2>&1 | tee -a "$log"
    rc=${PIPESTATUS[0]}
  fi
  set -e
  mmss $(($(date +%s) - t0)) dur
  if ((rc == 0)); then
    thread_end "$key" d
    printf '  \e[32m✓\e[0m %s \e[2m%s\e[0m\n' "$title" "$dur"
  else
    thread_end "$key" f
    printf '  \e[31m✗\e[0m %s failed after %s\n' "$title" "$dur"
    if in_tui; then
      printf '\e[2m    its last lines (the whole of it: the %s page):\e[0m\n' "$title"
      tail -n 20 "$log" | sed 's/^/    │ /'
    fi
  fi
  return "$rc"
}

# count_lines <regex> [<second regex>]: pass lines through unchanged and count
# the ones matching <regex> (and of those, <second regex>) as step progress.
count_lines() {
  local re=$1 lre=${2:-} line n=0 ln=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
    if [[ "$line" =~ $re ]]; then
      n=$((n + 1))
      put n "$n"
      if [[ -n "$lre" && "$line" =~ $lre ]]; then
        ln=$((ln + 1))
        put ln "$ln"
      fi
      draw
    fi
  done
}

tracker_init() {
  S="$WORK/status"
  mkdir -p "$S"
  TIMINGS="${XDG_CACHE_HOME:-$HOME/.cache}/$APP_SLUG/deploy-timings"
  mkdir -p "$(dirname "$TIMINGS")"
  if [[ -t 1 && "${TERM:-dumb}" != dumb ]] && stty size </dev/tty >/dev/null 2>&1; then
    TTY=1
  fi
  # Put back at the end: a picker ended by Ctrl-C (keys_on in prompt.sh),
  # or a tool, can leave echo off or the cursor hidden.
  if [[ -t 0 ]]; then STTY_SAVED="$(stty -g </dev/tty 2>/dev/null)" || STTY_SAVED=""; fi
  put started "$(date +%s)"
  # For the deploy UI (scripts/deploy/tui), which has no other way to know:
  # the stages, the mode, and every stage's steps up front (one line each,
  # "<stage> <step> ..."), so it can lay the panel out once and estimate the
  # stages still to come step by step.
  put stages "${STAGES[*]}"
  put mode "$MODE"
  local _stage
  for _stage in "${STAGES[@]}"; do
    printf '%s %s\n' "$_stage" "$(stage_steps "$_stage")"
  done >"$S/.plan"
  mv -f "$S/.plan" "$S/plan"
  put cur_stage -1
  put stage_start ""
  put stage_states "$(states_like ${#STAGES[@]} p)"
  put steps ""
  put step_states ""
  put cur_step -1
  reset_progress
  put final ""; put final_style ""
  put rows 0
  put pinned 3
  put lanes ""
  mkdir -p "$S/bg"
  term_init
  draw
  start_ticker
}

# tracker_end <exit code>: from the EXIT trap. Marks the running stage and
# step done or failed, pending ones skipped, and gives the screen back with
# the tracker left as the summary.
tracker_end() {
  local rc=$1 cur s final rows i
  local -a st
  stop_ticker
  threads_stop
  get cur_stage cur
  if ((cur >= 0)); then
    timing_stage_end
    get cur_step i
    if ((rc == 0)); then
      close_steps
      set_state stage_states "$cur" d
    else
      ((i >= 0)) && set_state step_states "$i" f
      # Still running (a parallel lint check stopped by the failure): skipped.
      close_steps s
      set_state stage_states "$cur" f
    fi
  fi
  get stage_states s
  read -r -a st <<<"$s"
  for i in "${!st[@]}"; do
    case "${st[i]}" in
      p) st[i]=s ;;
      # A lane still running when the deploy ended was stopped.
      b) if [[ -f "$S/bg/${STAGES[i]}/ok" ]]; then st[i]=d; else st[i]=f; fi ;;
    esac
  done
  put stage_states "${st[*]}"
  get final final
  if [[ -z "$final" && $rc -ne 0 ]]; then
    case $rc in
      130) finish "Stopped (ctrl+c)." 33 ;;
      129) finish "Stopped: the terminal or the deploy UI went away." "1;31" ;;
      143) finish "Stopped (terminated)." "1;31" ;;
      *) finish "Failed (exit $rc)." "1;31" ;;
    esac
  fi
  [[ -z "${STTY_SAVED:-}" ]] || stty "$STTY_SAVED" </dev/tty 2>/dev/null || true
  if ((TTY)); then
    draw
    get rows rows
    printf '\e[r\e[%d;1H\e[?25h\n' "$rows"
  else
    get final final
    [[ -z "$final" ]] || echo "$final"
  fi
  timing_summary
}

# bg_start <stage> <log> <function> [<arg> ...]: run <function> as <stage>'s
# background lane, its output in <log>. It runs with set -e like the rest, in
# a subshell whose tracker calls (step, progress_*, spinner_label,
# count_lines) write only its own state directory. It must not call stage,
# stage_skip, finish or a prompt. Its last act is the ok file, so a lane that
# is gone without one failed.
bg_start() {
  local name=$1 log=$2 fn=$3 d="$S/bg/$1" steps lanes rows
  shift 3
  local -a _names
  rm -rf "$d" && mkdir -p "$d"
  steps="$(stage_steps "$name")"
  read -r -a _names <<<"$steps"
  S=$d put steps "$steps"
  S=$d put step_states "$(states_like ${#_names[@]} p)"
  S=$d put cur_step -1
  S=$d reset_progress
  S=$d put started "$(date +%s)"
  S=$d put stage_start "$(date +%s)"
  S=$d put log "$log"
  mkdir -p "$(dirname "$log")"
  (
    trap - EXIT INT TERM
    # Below Lint in the scheduler, and everything the lane starts with it:
    # an xcodebuild archive and a Gradle bundle beside Jest at the same
    # priority starve it (single test files took 50 s and
    # passed Jest's timeout). The builds still take every core Lint leaves,
    # and wait at the upload gate anyway. (The subshell's own PID: bash 3.2,
    # macOS's, has no $BASHPID.)
    renice -n 10 -p "$(exec sh -c 'echo $PPID')" >/dev/null 2>&1 || true
    # shellcheck disable=SC2030 # the lane's own S, on purpose
    S=$d TTY=0 TICKER="" LANE=$name
    trap 'timing_stage_end' EXIT
    "$fn" "$@"
    put ok 1
  ) >"$log" 2>&1 </dev/null &
  S=$d put pid "$!"
  set_state stage_states "$(stage_index "$name")" b
  printf '\n\e[1;35m━━ %s\e[0m \e[2min the background (log: %s)\e[0m\n' "$name" "${log#"$ROOT"/}"
  get lanes lanes
  lanes="${lanes:+$lanes }$name"
  put lanes "$lanes"
  get rows rows
  pause_ticker
  set_pinned "$(pinned_rows "$rows" "$(wc -w <<<"$lanes")")"
  resume_ticker
}

# bg_running <stage>: its lane exists and hasn't been joined.
bg_running() {
  local lanes
  get lanes lanes
  [[ " $lanes " == *" $1 "* ]]
}

# bg_wait <stage>: called in that stage (stage <stage> first, which starts
# from the lane's steps so far): wait for the lane, take over its steps, take
# its row away, and with the end of its log, return its failure.
bg_wait() {
  local name=$1 d="$S/bg/$1" pid log started lanes rows rc=0 dur cur
  getd "$d" pid pid; getd "$d" log log; getd "$d" started started
  log="${log#"$ROOT"/}"
  if kill -0 "$pid" 2>/dev/null; then
    echo "==> Waiting for the lane in the background (log: $log)"
    spinner_label "waiting for the background lane"
  fi
  wait "$pid" || rc=$?
  [[ -f "$d/ok" ]] || ((rc != 0)) || rc=1
  # The lane's steps, as they ended, are this stage's; on a failure its
  # running step is the one tracker_end marks failed.
  local s i
  local -a st
  getd "$d" step_states s
  read -r -a st <<<"$s"
  getd "$d" cur_step cur
  if ((rc == 0)); then
    for i in "${!st[@]}"; do [[ "${st[i]}" == r ]] && st[i]=d; done
    cur=-1
  fi
  put step_states "${st[*]}"
  put cur_step "$cur"
  reset_progress
  mmss $(($(date +%s) - started)) dur
  get lanes lanes
  lanes=" $lanes "
  lanes="${lanes/ $name / }"
  lanes="${lanes# }"
  lanes="${lanes% }"
  put lanes "$lanes"
  if ((rc == 0)); then
    printf '  \e[32m✓\e[0m %s finished in the background, %s\n' "$name" "$dur"
  else
    printf '  \e[31m✗\e[0m %s failed in the background after %s. The end of %s:\n' "$name" "$dur" "$log"
    getd "$d" log log
    tail -n 30 "$log" 2>/dev/null | sed 's/^/  │ /' || true
  fi
  get rows rows
  pause_ticker
  set_pinned "$(pinned_rows "$rows" "$(wc -w <<<"$lanes")")"
  resume_ticker
  return "$rc"
}

# bg_started <stage>: bg_start ran for it.
bg_started() { [[ -d "$S/bg/$1" ]]; }

# kill_tree <pid>: TERM a process and everything under it. Background jobs
# of a script ignore SIGINT, so Ctrl-C reaches none of them by itself.
kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$child"; done
  kill "$1" 2>/dev/null || true
}

# bg_pids [<stage> ...]: the pids of lanes still running, all of them or
# only those stages'.
bg_pids() {
  local lanes name pid
  get lanes lanes
  for name in $lanes; do
    [[ $# -eq 0 || " $* " == *" $name "* ]] || continue
    getd "$S/bg/$name" pid pid
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
  done
  return 0
}
