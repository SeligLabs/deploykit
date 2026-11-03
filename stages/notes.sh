# shellcheck shell=bash disable=SC2034 # globals read by deploy.sh
# Notes: the release note for the build this deploy uploads (TestFlight's
# "What to Test" and Play's release notes, which keep 500 characters), and
# the GitHub release's notes.
#
# notes_default writes the generated note (the commits on main since the
# previous release tag) to NOTES_FILE, which the store stages hand to their
# uploads; Start shows its first line and offers to type another
# (notes_edit), so the rest of the deploy runs unattended.

NOTES_FILE=""
NOTES_SOURCE=generated
NOTES_MAX_LINES=25

# notes_since <tag to skip>: the latest v* tag reachable from HEAD other than
# <tag to skip> (the one this deploy ships, if HEAD already carries it).
notes_since() {
  git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' --exclude "$1" HEAD 2>/dev/null || true
}

# notes_changes <since>: one line per change on main after <since> (all of
# history without it), newest first. A merged pull request is its title and
# number; release bumps, "Version bump" and branch merges are left out.
notes_changes() {
  local range=HEAD
  [[ -n "$1" ]] && range="$1..HEAD"
  git -C "$ROOT" log --first-parent --format='%s%x1f%b%x1e' "$range" |
    awk 'BEGIN { RS = "\036"; FS = "\037" }
      {
        sub(/^\n+/, "", $1)
        subject = $1
        if (subject == "") next
        if (subject ~ /^chore\(release\): / || subject ~ /^Version bump$/ || subject ~ /^Merge branch /) next
        if (match(subject, /^Merge pull request #[0-9]+/)) {
          number = substr(subject, 21, RLENGTH - 20)
          split($2, body, "\n")
          subject = (body[1] != "" ? body[1] : subject) " (#" number ")"
        }
        print subject
      }'
}

# notes_generate <version> <build> <tag to skip>: the default notes.
notes_generate() {
  local since label count
  local -a changes
  since="$(notes_since "$3")"
  changes=()
  while IFS= read -r line; do changes+=("$line"); done < <(notes_changes "$since")
  count=${#changes[@]}

  # The tag v1.2.0+31 reads as "v1.2.0 (31)", like the heading.
  label="$since"
  [[ "$since" == *+* ]] && label="${since%%+*} (${since#*+})"

  echo "$APP_NAME $1 ($2)"
  echo
  if ((count == 0)); then
    echo "No new changes${label:+ since $label}: a rebuild."
    return 0
  fi
  echo "Changes${label:+ since $label}:"
  local i
  for ((i = 0; i < count && i < NOTES_MAX_LINES; i++)); do echo "- ${changes[i]}"; done
  ((count > NOTES_MAX_LINES)) && echo "- …and $((count - NOTES_MAX_LINES)) more"
  return 0
}

# notes_default <version> <build> <tag>: the generated note into NOTES_FILE,
# with no question; Start shows it and offers to edit it (notes_edit).
notes_default() {
  NOTES_FILE="$WORK/whats-new.txt"
  NOTES_SOURCE=generated
  notes_generate "$1" "$2" "$3" >"$NOTES_FILE"
}

# notes_edit: type a note, ending with an empty line; an empty answer keeps
# the one there is.
notes_edit() {
  echo
  printf "\e[1mThe store note (TestFlight's What to Test, Play's release notes)\e[0m\n"
  echo "Now:"
  sed 's/^/  │ /' "$NOTES_FILE"
  ask_lines "Type a new one, ending with an empty line, or press Enter to keep this one:" || ASK_ANSWER=""
  if [[ -n "${ASK_ANSWER//[[:space:]]/}" ]]; then
    printf '%s\n' "$ASK_ANSWER" >"$NOTES_FILE"
    NOTES_SOURCE=yours
  fi
}

# notes_line: the note's first line, its length and where it came from.
notes_line() {
  echo "$(head -n 1 "$NOTES_FILE") ($(wc -l <"$NOTES_FILE" | tr -d ' ') lines, $NOTES_SOURCE)"
}
