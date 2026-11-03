# shellcheck shell=bash
# Terraform's secret variables from the macOS login keychain, exported as
# TF_VAR_<name> inside the plan's thread only (no Lint check sees them; CI's
# come from its environment's secrets). The app names them:
#
#   dk_config tf_secrets "apns_key_id apns_signing_key ..." [tf_secrets_service freebox-tf]
#
# Items are generic passwords with the service (default <slug>-tf) and the
# variable's name as the account, stored base64-encoded so multi-line keys
# round-trip byte for byte (`security find-generic-password -w` prints a
# multi-line value as hex). Nothing here prints a value.
#
#   yarn deploy secrets status                    which items exist (names only)
#   yarn deploy secrets store <variable> <file>   one-time setup: a file's exact bytes
#   yarn deploy secrets run <command> [...]       a command with them loaded
#
# Fallback: with no keychain items (or no `security`, e.g. on Linux), nothing
# is exported and Terraform reads <infra_dir>/variables.auto.tfvars. A
# variable already set in the environment (CI) is left alone. Terraform ranks
# *.auto.tfvars above TF_VAR_*, so while that file exists it wins: a warning
# says so when both exist.

dk_tf_secrets_service() { dk_c tf_secrets_service "$APP_SLUG-tf"; }
dk_tf_secrets_tfvars() { printf '%s' "$ROOT/$(dk_c infra_dir infrastructure)/variables.auto.tfvars"; }

# dk_tf_secrets_load: TF_VAR_<name> for every keychain item found. Returns 0
# even when none exist (the tfvars fallback).
dk_tf_secrets_load() {
  local name encoded value env loaded=0 service tfvars count=0
  local -a missing=() names=()
  [[ -n "$(dk_c tf_secrets)" ]] || return 0
  command -v security >/dev/null 2>&1 || return 0
  service="$(dk_tf_secrets_service)"
  tfvars="$(dk_tf_secrets_tfvars)"
  read -ra names <<<"$(dk_c tf_secrets)"
  for name in ${names[@]+"${names[@]}"}; do
    count=$((count + 1))
    env="TF_VAR_${name}"
    [[ -z "${!env:-}" ]] || continue
    if ! encoded="$(security find-generic-password -s "$service" -a "$name" -w 2>/dev/null)"; then
      missing+=("$name")
      continue
    fi
    # The x keeps a trailing newline that $(...) would strip; the decode's
    # own status decides (pipefail), not the printf's.
    if ! value="$(set -o pipefail; printf '%s' "$encoded" | base64 -D 2>/dev/null && printf x)"; then
      warn "Keychain item $service/$name isn't base64; store it with: yarn deploy secrets store $name <file>"
      missing+=("$name")
      continue
    fi
    export "$env=${value%x}"
    loaded=$((loaded + 1))
  done
  ((loaded > 0)) || return 0
  if ((${#missing[@]} > 0)) && [[ ! -f "$tfvars" ]]; then
    warn "The keychain holds $loaded of $count Terraform secrets; missing: ${missing[*]}"
  fi
  if [[ -f "$tfvars" ]]; then
    warn "Both the keychain and ${tfvars#"$ROOT"/} hold Terraform secrets; Terraform uses the tfvars file. Delete it once the keychain items are right."
  fi
  return 0
}

# dk_tf_secrets_command status | store <variable> <file> | run <command...>
dk_tf_secrets_command() {
  local cmd=${1:-} service name file known=0 v
  [[ -n "$(dk_c tf_secrets)" ]] || die "This app keeps no Terraform secrets in the keychain (dk_config tf_secrets)."
  service="$(dk_tf_secrets_service)"
  case "$cmd" in
    run)
      shift
      (($# > 0)) || die "usage: yarn deploy secrets run <command> [args...]"
      dk_tf_secrets_load
      exec "$@"
      ;;
    store)
      name=${2:-} file=${3:-}
      for v in $(dk_c tf_secrets); do [[ "$v" == "$name" ]] && known=1; done
      ((known)) && [[ -n "$file" ]] || die "usage: yarn deploy secrets store <variable> <file>   (variable: $(dk_c tf_secrets))"
      [[ -f "$file" ]] || die "$file: no such file"
      command -v security >/dev/null 2>&1 || die "security (macOS) not found"
      # -U replaces an existing item. The value is on security's argv for the
      # moment it runs (`security -i` truncates long lines, and the prompt of
      # a bare -w can't take a 3 KB paste).
      security add-generic-password -U -s "$service" -a "$name" \
        -l "$APP_SLUG Terraform: $name" -w "$(base64 -i "$file")"
      echo "Stored $service/$name ($(wc -c <"$file" | tr -d ' ') bytes)."
      ;;
    status)
      if ! command -v security >/dev/null 2>&1; then
        echo "security (macOS) not found: the tfvars file is used"
        return 0
      fi
      for name in $(dk_c tf_secrets); do
        if security find-generic-password -s "$service" -a "$name" >/dev/null 2>&1; then
          echo "keychain  $name"
        else
          echo "missing   $name"
        fi
      done
      [[ ! -f "$(dk_tf_secrets_tfvars)" ]] ||
        echo "$(dk_c infra_dir infrastructure)/variables.auto.tfvars exists (Terraform prefers it over the keychain)"
      ;;
    *) die "usage: yarn deploy secrets status | store <variable> <file> | run <command...>" ;;
  esac
}
