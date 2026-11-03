# shellcheck shell=bash
# Terraform's outputs, read live: the deploy takes them from the state, not
# from a copy in an env file that may be stale on this machine. The app maps
# environment names to outputs:
#
#   dk_config outputs "API_URL=api_url WEB_BUCKET=web_bucket *_TABLE=table_names"
#
# A name with * takes a map output: one variable per key, the key upper-cased
# in place of the * (table_names {users = "users"} → USERS_TABLE=users).
# Read in Preflight (after the AWS check) and again after the apply, and
# exported over whatever the env files said, for the builds and the hooks.
# On a first deploy there are none yet: then the lanes that --waits-for
# outputs start after the apply.
#
# The read inits Terraform in a data directory of its own (the cache's
# tf-outputs/), with dk_config tf_init_args, so it never races the plan's
# init or a Lint check's in infra_dir/.terraform.
#
# yarn deploy env-sync writes the same values into env files, for local dev
# servers (dk_config outputs_files; an app's env_sync_hook instead).

dk_outputs_enabled() { [[ -n "$(dk_c outputs)" && -n "$(dk_c infra_dir)" ]]; }

# dk_outputs_fetch <json file>: terraform output -json, from the state.
dk_outputs_fetch() {
  local json=$1 dir log="${1%.json}-init.log"
  local -a args=()
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/$APP_SLUG/tf-outputs"
  mkdir -p "$dir"
  # A variable tf_init_args names but the env files don't set: say so,
  # rather than set -u's bare "unbound variable".
  if ! (eval "args=($(dk_c tf_init_args))") 2>/dev/null; then
    echo "tf_init_args names a variable that isn't set ($(dk_c tf_init_args)): check the env files." >"$log"
    return 1
  fi
  eval "args=($(dk_c tf_init_args))"
  TF_DATA_DIR="$dir" terraform -chdir="$ROOT/$(dk_c infra_dir)" init -input=false -reconfigure -lockfile=readonly \
    ${args[@]+"${args[@]}"} >"$log" 2>&1 || return 1
  TF_DATA_DIR="$dir" terraform -chdir="$ROOT/$(dk_c infra_dir)" output -json >"$json.tmp" 2>>"$log" || return 1
  mv "$json.tmp" "$json"
}

# dk_outputs_values <json file>: NAME=value lines, one per mapped output
# that has a value.
dk_outputs_values() {
  local json=$1 pair var name
  local -a pairs=()
  # Split, never globbed: *_TABLE=table_names would match a file of that name.
  read -ra pairs <<<"$(dk_c outputs)"
  for pair in ${pairs[@]+"${pairs[@]}"}; do
    var=${pair%%=*} name=${pair#*=}
    if [[ "$var" == *'*'* ]]; then
      jq -r --arg n "$name" --arg v "$var" '
        (.[$n].value // {}) | to_entries[] as $e
        | "\($v | sub("\\*"; ($e.key | ascii_upcase | gsub("-"; "_"))))=\($e.value)"' "$json"
    else
      jq -r --arg n "$name" --arg v "$var" '
        .[$n].value // empty | "\($v)=\(if type == "string" then . else tojson end)"' "$json"
    fi
  done
}

# dk_outputs_export: the last read's values into the deploy's shell.
dk_outputs_export() {
  local line
  [[ -s "${WORK:-}/outputs.json" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] && export "${line%%=*}=${line#*=}"
  done < <(dk_outputs_values "$WORK/outputs.json")
}

# dk_outputs_read: fetch and export, in Preflight and after the apply.
dk_outputs_read() {
  local n
  dk_outputs_enabled || return 0
  spinner_label "reading Terraform's outputs"
  if dk_outputs_fetch "$WORK/outputs.json"; then
    dk_outputs_export
    n="$(dk_outputs_values "$WORK/outputs.json" | wc -l | tr -d ' ')"
    if ((n > 0)); then echo "Terraform outputs: $n values, read from the state."; else echo "Terraform has no outputs yet (a first deploy)."; fi
  else
    rm -f "$WORK/outputs.json"
    echo "No Terraform outputs to read (a first deploy, or the backend isn't there yet): $(tail -n 1 "$WORK/outputs-init.log" 2>/dev/null)"
  fi
}

# dk_outputs_ready_default: every mapped (non-map) output has a value in
# the state's last read, not merely in the shell: an env file's stale copy
# must not make a lane think Infra is out (villagely's move found a web
# deploy publishing to a stale bucket that way).
dk_outputs_ready_default() {
  local pair var values=""
  local -a pairs=()
  [[ -s "${WORK:-}/outputs.json" ]] && values="$(dk_outputs_values "$WORK/outputs.json")"
  read -ra pairs <<<"$(dk_c outputs)"
  for pair in ${pairs[@]+"${pairs[@]}"}; do
    var=${pair%%=*}
    [[ "$var" == *'*'* ]] && continue
    grep -q "^$var=." <<<"$values" || return 1
  done
  return 0
}

# dk_env_sync_command: yarn deploy env-sync. The outputs into the files
# dk_config outputs_files names (default env/<APP_ENV or prod>.env), each
# written in place, keys it lacks appended:
#   env/prod.env              every mapped value
#   env/.env!API_URL          all but those (! separated)
#   env/local.env:A,B         only those
# Words are expanded (env/$STAGE.env). An app's env_sync_hook <json file>
# replaces all that.
dk_env_sync_command() {
  local json spec file only except values
  dk_outputs_enabled || die "This app maps no Terraform outputs (dk_config outputs)."
  check_session || die "No AWS session (${AWS_PROFILE:-default credentials}): it reads the Terraform state."
  json="$(mktemp -d "${TMPDIR:-/tmp}/$APP_SLUG-env-sync.XXXXXX")/outputs.json"
  dk_outputs_fetch "$json" || die "terraform output failed: $(tail -n 3 "${json%.json}-init.log")"
  if dk_has_hook env_sync_hook; then
    env_sync_hook "$json"
  else
    values="$(dk_outputs_values "$json")"
    [[ -n "$values" ]] || die "Terraform has no outputs yet: deploy the infrastructure first (yarn deploy infra)."
    for spec in $(dk_c outputs_files 'env/${APP_ENV:-prod}.env'); do
      eval "spec=\"$spec\""
      file=${spec%%[:!]*} only="" except=""
      [[ "$spec" == *:* ]] && only=${spec#*:}
      [[ "$spec" == *'!'* ]] && except=${spec#*!}
      printf '%s\n' "$values" | node "$DK_ROOT/bin/env-write.mjs" "$ROOT/$file" "${only//,/ }" "${except//!/ }" ||
        die "Writing $file failed."
    done
  fi
  rm -rf "$(dirname "$json")"
}
