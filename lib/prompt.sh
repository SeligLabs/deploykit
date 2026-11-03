# shellcheck shell=bash disable=SC2034 # globals read by deploy.sh
# deploykit's prompts (the engine's questions; an app's own scripts may use
# them too).
# Sourced, not run.
#
#   pick <default index> <option> ...   arrow keys (or j/k) + Enter; the
#                                       chosen index lands in PICKED. An
#                                       option of "" is a blank line and
#                                       "---" a rule; neither can be chosen.
#   pick_many <option> ...              a checklist: arrow keys (or j/k) to
#                                       move, Space to tick or untick, Enter
#                                       when done. Boxes start as PICK_DEFAULTS
#                                       says (1 or 0 per option; every box
#                                       ticked when unset). PICKS holds 1
#                                       (ticked) or 0 per option. Grouped
#                                       when PICK_PARENT is set, one entry
#                                       per option: h for a group's row, the
#                                       group row's index for its members,
#                                       - for neither. A group's box is
#                                       [x] all, [~] some, [ ] none of its
#                                       members; ticking it ticks them all
#                                       (or unticks them, when all were).
#   confirm <question> [<stop question>]
#                                       [y/n]; true on yes. y, yes, n and no
#                                       in any case; anything else, Enter
#                                       included, asks again. With a stop
#                                       question, a no is checked: yes to it
#                                       stops (false), no asks again.
#
#   ask_line <prompt> <default>         one line typed, into ASK_ANSWER; Enter
#                                       alone takes the default.
#   ask_lines <prompt>                  lines typed until an empty one, into
#                                       ASK_ANSWER; none leaves it empty.
#
# PROMPT_TITLE, set for the call (PROMPT_TITLE="What to deploy" pick_many
# ...), titles a pick or pick_many in the deploy UI.
#
# Under the deploy UI (DEPLOY_UI=tui, scripts/deploy/tui) every one of
# these asks through files instead of the terminal: tui_ask writes
# $WORK/ask/question and waits for $WORK/ask/answer-<id>; the format is in
# tui/ask.go. Without a terminal on stdin, pick reads a number and confirm a
# line; end of input answers no. Callers pause the tracker's ticker around
# these.
#
# Runs on macOS's bash 3.2.

PICKED=-1
PICKS=()
PICK_DEFAULTS=()
PICK_PARENT=()
ASK_PARENTS=""
ASK_ANSWER=""
ASK_SEQ=0

# in_tui: the deploy runs under the deploy UI, which asks the questions.
in_tui() { [[ "${DEPLOY_UI:-}" == tui && -n "${WORK:-}" ]]; }

# tui_ask <kind> <title> <default> [<option> ...]: one question to the
# deploy UI; the answer lands in ASK_ANSWER. Waits as long as it takes, but
# not for a UI that is gone (it would never answer).
tui_ask() {
  local kind=$1 title=$2 def=$3 dir="$WORK/ask" opt
  shift 3
  ASK_SEQ=$((ASK_SEQ + 1))
  mkdir -p "$dir"
  {
    echo "id=$ASK_SEQ"
    echo "kind=$kind"
    echo "title=$title"
    echo "default=$def"
    for opt in "$@"; do echo "option=$opt"; done
    [[ -z "$ASK_PARENTS" ]] || echo "parents=$ASK_PARENTS"
  } >"$dir/.question"
  mv -f "$dir/.question" "$dir/question"
  until [[ -f "$dir/answer-$ASK_SEQ" ]]; do
    if [[ -n "${DEPLOY_TUI_PID:-}" ]] && ! kill -0 "$DEPLOY_TUI_PID" 2>/dev/null; then
      echo "The deploy UI is gone, so nothing can answer: stopping." >&2
      exit 129
    fi
    sleep 0.1
  done
  ASK_ANSWER="$(cat "$dir/answer-$ASK_SEQ")"
  rm -f "$dir/question"
}

ask_line() {
  if in_tui; then
    tui_ask text "$1" "$2"
    return 0
  fi
  local v
  read -r -p "  $1 [$2]: " v || return 1
  ASK_ANSWER=${v:-$2}
}

ask_lines() {
  local line out=""
  if in_tui; then
    tui_ask lines "$1" ""
    return 0
  fi
  echo "$1"
  while IFS= read -r -p "  › " line; do
    [[ -z "$line" ]] && break
    out+="$line"$'\n'
  done
  ASK_ANSWER=${out%$'\n'}
}

# reserve_rows <n>: scroll so that n rows fit below the cursor before a list
# is drawn. pick and pick_many redraw by moving the cursor up n rows; a list
# drawn at the bottom of the tracker's scroll region scrolls as it prints,
# and that move then lands on the wrong rows (lines over the pinned ones).
reserve_rows() {
  local i
  for ((i = 0; i < $1; i++)); do printf '\n'; done
  printf '\e[%dA' "$1"
}

# keys_on / keys_off: the terminal in key-at-a-time mode (no echo, no line
# buffering) for a picker's whole life. Left to read -s -n, bash toggled
# that around every read, so an arrow key's trailing bytes could echo or
# slip between two reads and the picker lost the key or sat waiting.
# Ctrl-C still raises SIGINT. tracker_end puts the terminal back as well,
# for a run that ends at a picker.
TTY_KEYS_SAVED=""
keys_on() {
  TTY_KEYS_SAVED="$(stty -g </dev/tty 2>/dev/null)" || { TTY_KEYS_SAVED=""; return 0; }
  stty -echo -icanon min 1 time 0 </dev/tty 2>/dev/null || true
}
keys_off() {
  [[ -z "$TTY_KEYS_SAVED" ]] || stty "$TTY_KEYS_SAVED" </dev/tty 2>/dev/null || true
  TTY_KEYS_SAVED=""
}

# read_key <var> [<count>] [<timeout>]: <count> bytes (one key) from the
# terminal into <var>, after keys_on, in a subshell with Ctrl-C's default:
# bash 3.2 doesn't interrupt a key read for a trapped signal, so Ctrl-C at a
# picker did nothing and the run looked stuck. Now Ctrl-C ends the subshell,
# the pending INT trap then ends the run, and false here covers it, end of
# input and a timeout.
read_key() {
  local __v=$1 __n=${2:-1} __t=${3:-} __k
  if [[ -n "$__t" ]]; then
    __k="$(trap - INT; IFS= read -rn"$__n" -t "$__t" k || exit 1; printf '%s' "$k")" || return 1
  else
    __k="$(trap - INT; IFS= read -rn"$__n" k || exit 1; printf '%s' "$k")" || return 1
  fi
  printf -v "$__v" '%s' "$__k"
}

# is_separator <option>: a row pick shows but can't choose.
is_separator() { [[ -z "$1" || "$1" == --- ]]; }

pick() {
  local sel=$1 i key rest count n step
  shift
  local -a opts=("$@") choices=()
  count=${#opts[@]}

  if in_tui; then
    tui_ask pick "${PROMPT_TITLE:-}" "$sel" "$@"
    [[ "$ASK_ANSWER" =~ ^[0-9]+$ ]] && ((ASK_ANSWER < count)) || return 1
    PICKED=$ASK_ANSWER
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    for i in "${!opts[@]}"; do
      if is_separator "${opts[i]}"; then
        echo
        continue
      fi
      choices+=("$i")
      ((i == sel)) && n=${#choices[@]}
      printf '  %d) %s\n' "${#choices[@]}" "${opts[i]}"
    done
    read -r -p "Choose 1-${#choices[@]} [$n]: " key || return 1
    [[ -z "$key" ]] && key=$n
    if [[ ! "$key" =~ ^[0-9]+$ ]] || ((key < 1 || key > ${#choices[@]})); then
      echo "Not an option: $key" >&2
      return 1
    fi
    PICKED=${choices[key - 1]}
    return 0
  fi

  printf '\e[2m  ↑/↓ to move, Enter to choose\e[0m\n'
  reserve_rows "$count"
  printf '\e[?25l'
  keys_on
  while :; do
    for i in "${!opts[@]}"; do
      if ((i == sel)); then
        printf '\e[2K\e[1;36m  › %s\e[0m\n' "${opts[i]}"
      elif [[ "${opts[i]}" == --- ]]; then
        printf '\e[2K\e[2m    ──────\e[0m\n'
      else
        printf '\e[2K    %s\n' "${opts[i]}"
      fi
    done
    read_key key || { keys_off; printf '\e[?25h'; return 1; }
    step=0
    case "$key" in
      $'\e')
        read_key rest 2 1 || rest=""
        # [A / [B, or OA / OB when a tool left application cursor keys on.
        case "$rest" in
          '[A' | 'OA') step=-1 ;;
          '[B' | 'OB') step=1 ;;
        esac
        ;;
      k) step=-1 ;;
      j) step=1 ;;
      '') break ;;
    esac
    # Move to the next option that isn't a separator, if there is one.
    i=$((sel + step))
    while ((step != 0 && i >= 0 && i < count)) && is_separator "${opts[i]}"; do i=$((i + step)); done
    ((step != 0 && i >= 0 && i < count)) && sel=$i
    printf '\e[%dA' "$count"
  done
  keys_off
  printf '\e[?25h'
  PICKED=$sel
}

# pick_parent <index>: the option's entry in PICK_PARENT (- when ungrouped).
pick_parent() { local p="${PICK_PARENT[$1]:-}"; printf '%s' "${p:--}"; }

# pick_sync: each group row ticked when any of its members is.
pick_sync() {
  local i p
  for i in "${!PICKS[@]}"; do [[ "$(pick_parent "$i")" == h ]] && PICKS[i]=0; done
  for i in "${!PICKS[@]}"; do
    p="$(pick_parent "$i")"
    [[ "$p" =~ ^[0-9]+$ ]] && ((PICKS[i])) && PICKS[p]=1
  done
  return 0
}

# pick_toggle <index>: tick or untick one option, or a group's members.
pick_toggle() {
  local i=$1 j all=1
  if [[ "$(pick_parent "$i")" == h ]]; then
    for j in "${!PICKS[@]}"; do
      [[ "$(pick_parent "$j")" == "$i" ]] && ((!PICKS[j])) && all=0
    done
    for j in "${!PICKS[@]}"; do
      [[ "$(pick_parent "$j")" == "$i" ]] && PICKS[j]=$((1 - all))
    done
  else
    PICKS[i]=$((1 - PICKS[i]))
  fi
  pick_sync
}

# pick_box <index>: [x], [ ] or, for a partly ticked group, [~]; members
# indented under their group.
pick_box() {
  local i=$1 j on=0 off=0
  if [[ "$(pick_parent "$i")" == h ]]; then
    for j in "${!PICKS[@]}"; do
      if [[ "$(pick_parent "$j")" == "$i" ]]; then
        if ((PICKS[j])); then on=$((on + 1)); else off=$((off + 1)); fi
      fi
    done
    if ((on && off)); then printf '[~]'; elif ((on)); then printf '[x]'; else printf '[ ]'; fi
    return 0
  fi
  [[ "$(pick_parent "$i")" =~ ^[0-9]+$ ]] && printf '    '
  if ((PICKS[i])); then printf '[x]'; else printf '[ ]'; fi
}

pick_many() {
  local sel=0 i key rest count
  local -a opts=("$@")
  count=${#opts[@]}
  PICKS=()
  for i in "${!opts[@]}"; do PICKS[i]=${PICK_DEFAULTS[i]:-1}; done
  pick_sync

  if in_tui; then
    ASK_PARENTS=""
    if ((${#PICK_PARENT[@]} > 0)); then
      for i in "${!opts[@]}"; do ASK_PARENTS+="$(pick_parent "$i") "; done
      ASK_PARENTS="${ASK_PARENTS% }"
    fi
    tui_ask many "${PROMPT_TITLE:-}" "${PICKS[*]}" "$@"
    ASK_PARENTS=""
    read -r -a PICKS <<<"$ASK_ANSWER"
    ((${#PICKS[@]} == count)) || return 1
    pick_sync
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    for i in "${!opts[@]}"; do
      printf '  %d) %s %s\n' $((i + 1)) "$(pick_box "$i")" "${opts[i]}"
    done
    read -r -p "Numbers to tick or untick (e.g. 2 3; a group's number toggles it all), or Enter as shown: " key || return 1
    for i in $key; do
      if [[ ! "$i" =~ ^[0-9]+$ ]] || ((i < 1 || i > count)); then
        echo "Not an option: $i" >&2
        return 1
      fi
      pick_toggle $((i - 1))
    done
    return 0
  fi

  printf '\e[2m  ↑/↓ to move, Space to tick or untick (a group: all of it), Enter when done\e[0m\n'
  reserve_rows "$count"
  printf '\e[?25l'
  keys_on
  while :; do
    for i in "${!opts[@]}"; do
      if ((i == sel)); then
        printf '\e[2K\e[1;36m  › %s %s\e[0m\n' "$(pick_box "$i")" "${opts[i]}"
      else
        printf '\e[2K    %s %s\n' "$(pick_box "$i")" "${opts[i]}"
      fi
    done
    read_key key || { keys_off; printf '\e[?25h'; return 1; }
    case "$key" in
      $'\e')
        read_key rest 2 1 || rest=""
        case "$rest" in
          '[A' | 'OA') ((sel > 0)) && sel=$((sel - 1)) ;;
          '[B' | 'OB') ((sel < count - 1)) && sel=$((sel + 1)) ;;
        esac
        ;;
      k) ((sel > 0)) && sel=$((sel - 1)) ;;
      j) ((sel < count - 1)) && sel=$((sel + 1)) ;;
      ' ') pick_toggle "$sel" ;;
      '') break ;;
    esac
    printf '\e[%dA' "$count"
  done
  keys_off
  printf '\e[?25h'
}

# yes_no <question>: 0 for yes, 1 for no, 2 at end of input.
yes_no() {
  local answer
  if in_tui; then
    tui_ask confirm "$1" ""
    [[ "$ASK_ANSWER" == y ]]
    return
  fi
  while :; do
    answer=""
    read -r -p "$1 [y/n] " answer || return 2
    answer="$(printf '%s' "$answer" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    case "$answer" in
      y | yes) return 0 ;;
      n | no) return 1 ;;
      *) echo "  Answer y or n." ;;
    esac
  done
}

confirm() {
  local status
  while :; do
    status=0
    yes_no "$1" || status=$?
    ((status == 0)) && return 0
    ((status == 2)) && return 1
    [[ -z "${2:-}" ]] && return 1
    status=0
    yes_no "$2" || status=$?
    ((status == 1)) || return 1
  done
}
