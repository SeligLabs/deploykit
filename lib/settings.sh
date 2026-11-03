# shellcheck shell=bash
# Settings: the per-machine values a deploy needs (store keys, signing keys,
# the AWS profile), by one set of names in every app (CONTRACT.md lists them).
#
# dk_setting <NAME> prints the first value found, from:
#   1. the shell environment
#   2. an alias's old name (dk_alias), with a one-time deprecation warning
#   3. the app's settings_source_hook <NAME>, when it defines one (the
#      keychain, 1Password, anything that can print a value)
#   4. the settings files, in order (dk_config settings_files; default
#      env/release.env), KEY=value lines as the env files have
#   5. a declared default (dk_setting_declare)
# and nothing when none has it; dk_setting_source says which one answered.
#
# dk_setting_require <NAME> ... stops with each missing one's hint.
# dk_settings_export <NAME> ... exports the resolved values (for fastlane).
#
# Runs on macOS's bash 3.2: no associative arrays, so the declarations live
# in DKS_<NAME>_<field> variables.

DK_SETTING_NAMES=()
DK_SETTING_WARNED=" "

# dk_setting_declare <NAME> <hint> [<default>]: a setting a driver or the app
# needs, with what to do when it's missing.
dk_setting_declare() {
  local name=$1
  [[ " ${DK_SETTING_NAMES[*]:-} " == *" $name "* ]] || DK_SETTING_NAMES+=("$name")
  printf -v "DKS_${name}_hint" '%s' "$2"
  printf -v "DKS_${name}_default" '%s' "${3:-}"
}

# dk_alias <NAME> <OLD_NAME> ...: read old names while an app moves to the
# normalized ones.
dk_alias() {
  local name=$1
  shift
  printf -v "DKS_${name}_aliases" '%s' "$*"
}

# dk_setting_file_value <file> <NAME>: the last NAME= line's value, unquoted.
dk_setting_file_value() {
  [[ -f "$1" ]] || return 0
  sed -n "s/^[[:space:]]*$2=//p" "$1" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# dk_setting_lookup <NAME>: sets DK_SETTING_VALUE and DK_SETTING_FROM.
dk_setting_lookup() {
  local name=$1 old file var value
  DK_SETTING_VALUE="" DK_SETTING_FROM=""
  var="DKS_${name}_aliases"
  # The environment: the name, then its old names.
  if [[ -n "${!name:-}" ]]; then
    DK_SETTING_VALUE="${!name}" DK_SETTING_FROM=env
    return 0
  fi
  for old in ${!var:-}; do
    if [[ -n "${!old:-}" ]]; then
      dk_setting_old "$old" "$name" "${!old}"
      return 0
    fi
  done
  if declare -F settings_source_hook >/dev/null; then
    value="$(settings_source_hook "$name" 2>/dev/null)" || value=""
    if [[ -n "$value" ]]; then
      DK_SETTING_VALUE=$value DK_SETTING_FROM=hook
      return 0
    fi
  fi
  # The files: the name in any of them first, so a setting renamed in one
  # file beats its old name left in another.
  for file in ${DK_SETTINGS_FILES:-env/release.env}; do
    [[ "$file" == /* ]] || file="$ROOT/$file"
    value="$(dk_setting_file_value "$file" "$name")"
    if [[ -n "$value" ]]; then
      DK_SETTING_VALUE=$value DK_SETTING_FROM="${file#"$ROOT"/}"
      return 0
    fi
  done
  for old in ${!var:-}; do
    for file in ${DK_SETTINGS_FILES:-env/release.env}; do
      [[ "$file" == /* ]] || file="$ROOT/$file"
      value="$(dk_setting_file_value "$file" "$old")"
      if [[ -n "$value" ]]; then
        dk_setting_old "$old" "$name" "$value"
        return 0
      fi
    done
  done
  var="DKS_${name}_default"
  if [[ -n "${!var:-}" ]]; then
    DK_SETTING_VALUE="${!var}" DK_SETTING_FROM=default
  fi
  return 0
}

# dk_setting_old <old> <name> <value>: found under an old name; says so once
# per run (lookups run in subshells, so what was said is kept in $WORK).
dk_setting_old() {
  local warned="${WORK:-}/settings-warned"
  DK_SETTING_VALUE=$3 DK_SETTING_FROM="alias $1"
  if [[ -n "${WORK:-}" && -d "$WORK" ]]; then
    grep -qxF "$1" "$warned" 2>/dev/null && return 0
    echo "$1" >>"$warned"
  else
    [[ "$DK_SETTING_WARNED" != *" $1 "* ]] || return 0
    DK_SETTING_WARNED+="$1 "
  fi
  warn "Setting $1 is the old name of $2: rename it (deploykit CONTRACT.md, Settings)."
}

# dk_setting <NAME>: the value, or nothing.
dk_setting() {
  dk_setting_lookup "$1"
  printf '%s' "$DK_SETTING_VALUE"
}

# dk_setting_path <NAME>: the value as an absolute path: a leading ~
# expanded, a relative one taken from the app's root.
dk_setting_path() {
  local v
  v="$(dk_setting "$1")"
  v="${v/#\~/$HOME}"
  [[ -z "$v" || "$v" == /* ]] || v="$ROOT/$v"
  printf '%s' "$v"
}

# dk_setting_require <NAME> ...: stop on the first missing one, with its hint.
dk_setting_require() {
  local name hint
  for name in "$@"; do
    dk_setting_lookup "$name"
    [[ -n "$DK_SETTING_VALUE" ]] && continue
    hint="DKS_${name}_hint"
    die "Setting $name is empty (${DK_SETTINGS_FILES:-env/release.env}, the environment, or settings_source_hook).${!hint:+ ${!hint}}"
  done
}

# dk_settings_export <NAME> ...: export each one's resolved value, so tools
# the deploy runs (fastlane) read them from the environment.
dk_settings_export() {
  local name
  for name in "$@"; do
    dk_setting_lookup "$name"
    [[ -n "$DK_SETTING_VALUE" ]] || continue
    # Paths absolute, so they hold from any directory.
    if [[ "$name" == *_PATH ]]; then export "$name=$(dk_setting_path "$name")"; else export "$name=$DK_SETTING_VALUE"; fi
  done
}

# dk_settings_report: every declared setting, where its value came from
# (masked), or what's missing. `yarn deploy settings`.
dk_settings_report() {
  local name shown missing=0 hint
  printf '\e[1mSettings\e[0m (files: %s)\n' "${DK_SETTINGS_FILES:-env/release.env}"
  for name in ${DK_SETTING_NAMES[@]+"${DK_SETTING_NAMES[@]}"}; do
    dk_setting_lookup "$name"
    if [[ -z "$DK_SETTING_VALUE" ]]; then
      hint="DKS_${name}_hint"
      printf '  \e[31m✗\e[0m %-36s missing  %s\n' "$name" "${!hint:-}"
      missing=$((missing + 1))
      continue
    fi
    case "$name" in
      *PASSWORD* | *SECRET* | *TOKEN*) shown="••••••" ;;
      *) shown="$DK_SETTING_VALUE" ;;
    esac
    ((${#shown} > 48)) && shown="${shown:0:45}..."
    printf '  \e[32m✓\e[0m %-36s %-48s \e[2m%s\e[0m\n' "$name" "$shown" "$DK_SETTING_FROM"
  done
  ((missing == 0)) || printf '%d missing.\n' "$missing"
  return "$((missing > 0))"
}

# dk_from_keychain <service> <NAME>: a generic-password item's value, for a
# settings_source_hook (macOS only; nothing elsewhere).
dk_from_keychain() {
  command -v security >/dev/null 2>&1 || return 0
  security find-generic-password -s "$1" -a "$2" -w 2>/dev/null || true
}

# dk_from_op <vault/item> <field>: a 1Password field, for a
# settings_source_hook (needs the op CLI, signed in).
dk_from_op() {
  command -v op >/dev/null 2>&1 || return 0
  op read "op://$1/$2" 2>/dev/null || true
}
