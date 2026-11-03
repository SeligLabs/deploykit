# shellcheck shell=bash disable=SC2034 # globals the engine reads
# yarn deploy demo: this app's own groups, targets and checks through the real
# engine, checklist, tracker and deploy UI, touching nothing. Every function
# that would reach git, AWS, Terraform, a store or a build is replaced here,
# and the app's hooks are dropped. Its step times go to a scratch cache, so
# they never skew the estimates. DEMO_SPEED=4 runs it four times as fast.

DK_DEMO=1

dk_nap() { sleep "$(awk "BEGIN { print $1 / ${DEMO_SPEED:-1} }")"; }

dk_demo_setup() {
  local id fn
  export XDG_CACHE_HOME="${TMPDIR:-/tmp}/$APP_SLUG-demo-cache"
  export DEPLOY_SKIP_GIT_CHECK=1
  for fn in infra_preflight_hook infra_check_hook infra_build_hook infra_secrets_hook infra_init_hook \
    after_apply_hook reload_env_hook summary_hook outputs_ready settings_source_hook; do
    unset -f "$fn" 2>/dev/null || true
  done
  for id in ${DK_TARGET_IDS[@]+"${DK_TARGET_IDS[@]}"}; do
    # The lanes' logs into the scratch cache too: the app's own (its last
    # real build's) stay as they are.
    printf -v "DKT_${id}_log" '%s' "$XDG_CACHE_HOME/$APP_SLUG/lanes/deploy-$id.log"
    for fn in preflight check after_prepare before_build after_build verify before_publish after_publish summary; do
      unset -f "${id}_$fn" 2>/dev/null || true
    done
  done
}

preflight_git() { step Git "Git: deploying origin/main (demo)"; echo "HEAD $(git -C "$ROOT" rev-parse --short HEAD) (a demo: nothing is checked or pushed)."; dk_nap 1; }
preflight_tools() { step Tools "Tools"; echo "Found: $*"; dk_nap 0.5; }
preflight_aws() { step AWS "AWS session (demo)"; dk_nap 1; }

dk_checks() {
  local id
  step Checks "Target setup and store checks"
  for id in $(dk_targets_on); do
    spinner_label "asking about $(dk_t "$id" name)"
    echo "$(dk_t "$id" name): ready (demo)."
    dk_nap 0.7
  done
  return 0
}

version_choose() {
  version_read
  BUMP=build NEXT_VERSION=$VERSION NEXT_BUILD=$((BUILD + 1)) RELEASED=0 BREAKING=0
  echo "Version: $VERSION ($NEXT_BUILD), a build bump (the demo asks nothing here)."
}
version_step() {
  step Version "Bump (build) and commit, local until Release"
  echo "a1b2c3d chore(release): v$NEXT_VERSION+$NEXT_BUILD [skip ci] (demo: not committed)"
  BUMP_COMMIT=""
  dk_nap 0.5
}
version_read() {
  VERSION="$(node -p "require('$ROOT/package.json').version")"
  BUILD="$(node -p "require('$ROOT/package.json').build ?? 1")"
  [[ -z "${NEXT_BUILD:-}" ]] || BUILD=$NEXT_BUILD
  TAG="v$VERSION+$BUILD"
}
notes_default() {
  NOTES_FILE="$WORK/whats-new.txt"
  NOTES_SOURCE=generated
  printf '%s\n' "A demo build: nothing was uploaded." >"$NOTES_FILE"
}
version_undo() { :; }
dk_reload_env() { :; }

dk_demo_count() {
  local n=$1 label=$2 line=$3 i
  progress_total "$n" "$label"
  for ((i = 1; i <= n; i++)); do
    # shellcheck disable=SC2059 # the line is a printf format
    printf "$line\n" "$i"
    progress_set "$i"
    dk_nap 0.03
  done
}

plan_step() {
  ((DO_INFRA)) || {
    step_mark Plan s
    return 0
  }
  step Plan "Build the API and plan the infrastructure"
  thread_run api-build "API build" dk_demo_count 40 "functions built" "built: function-%d"
  thread_run plan "Terraform plan" dk_demo_count 120 "resources refreshed" "aws_lambda_function.fn[%d]: Refreshing state..."
  INFRA_STATUS=2
  printf '%s\n' "0 24 0 0 20" "0 to create, 24 to update, 0 to replace, 0 to destroy (20 Lambda functions)" >"$WORK/tfplan-summary"
  printf '\e[1m==> %s\e[0m\n' "$(sed -n 2p "$WORK/tfplan-summary")"
}

infra_apply_thread() {
  step Apply "terraform apply"
  thread_run apply "Terraform apply" dk_demo_count 24 "resources" "aws_lambda_function.fn[%d]: Modifications complete"
  INFRA_RESULT="0 to create, 24 to update, 0 to replace, 0 to destroy (demo)"
  step Sync "Sync outputs"
  dk_nap 0.5
}

lint_stage() {
  local name done_checks=0
  local -a checks
  stage Lint
  read -r -a checks <<<"$(lint_steps)"
  progress_total "${#checks[@]}" "checks"
  for name in ${checks[@]+"${checks[@]}"}; do
    step_mark "$name" r
    thread_begin "lint-$name" "$name" "$WORK/lint/$name.log"
    mkdir -p "$WORK/lint"
    echo "$name: checking (demo)" >>"$WORK/lint/$name.log"
    dk_nap 0.6
    thread_end "lint-$name" d
    step_mark "$name" d
    done_checks=$((done_checks + 1))
    progress_set "$done_checks"
    printf '  \e[32m✓\e[0m %s\n' "$name"
  done
}

release_stage() {
  stage Release
  step Push "Push main"; dk_nap 1
  step Tag "Tag $TAG"; dk_nap 1
  step GitHub "GitHub release"; dk_nap 1
  RELEASE_RESULT="released $TAG (demo)"
}

# dk_lane_run <id>: each of the target's steps with pretend output; the real
# gate.
dk_lane_run() {
  local id=$1 s steps
  steps="$(dk_target_steps "$id")"
  for s in $steps; do
    if [[ "$s" == Gate ]]; then
      dk_gate || return 0
      continue
    fi
    step "$s" "$s $(dk_t "$id" name) (demo)"
    case "$s" in
      Build | Archive | Bundle | Package) dk_demo_count 60 "build steps" "▸ Compiling $(dk_t "$id" name)Module%d" ;;
      *) for i in 1 2 3; do echo "$s: part $i of 3"; dk_nap 0.6; done ;;
    esac
  done
  dk_result "$id" "$VERSION ($BUILD) (a demo: nothing was published)"
}
