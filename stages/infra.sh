# shellcheck shell=bash disable=SC2034 # globals the engine reads
# API and Infra: build the app's API (its infra_build_hook), plan and apply
# Terraform in dk_config infra_dir, and hand the outputs on (its
# after_apply_hook, an env sync). The same steps as an app's CI plan and apply
# jobs, without their reviewers: read the plan.
#
# yarn deploy builds and plans in Preflight (plan_step), so the plan's summary
# is in front of you at Start, and applies after Lint with no further question
# (infra_apply_thread). yarn deploy infra runs it in the foreground and asks
# before the apply (infra_stage). The API build, the plan and the apply are
# threads (lib/tracker.sh): their own logs and, under the deploy UI, pages.
#
# Hooks (all optional; CONTRACT.md):
#   infra_build_hook     build the API's artifacts (in a thread)
#   infra_secrets_hook   export TF_VAR_* secrets; runs inside the plan's
#                        thread only, so no Lint check ever sees them
#   infra_init_hook      after terraform init (adopt a state bucket, ...)
#   infra_preflight_hook in Preflight, before the plan (create a state bucket)
#   infra_check_hook     after the plan, before Start; may stop the run
#                        (dk_plan_json gives the plan as JSON)
#   after_apply_hook     after the apply (sync outputs into env files)
# An app whose Terraform runs through a wrapper of its own redefines
# infra_init, infra_plan_run, infra_summarize or infra_apply_run.
#
# TF_ARGS go to the plan (yarn deploy infra -target=...). The saved plan holds
# every variable in plain text, secrets included, so it lives in $WORK and is
# deleted on exit.

INFRA_RESULT=""
INFRA_STATUS=""
INFRA=""
STATE_BUCKET=""
STATE_KEY=""
TF_PARALLELISM="${TF_PARALLELISM:-30}"

# dk_infra_setup: the config, read once the app has declared it.
dk_infra_setup() {
  [[ -n "$(dk_c infra_dir)" ]] || return 0
  INFRA="$ROOT/$(dk_c infra_dir)"
  STATE_BUCKET="$(dk_c state_bucket)"
  STATE_BUCKET="${STATE_BUCKET//\{slug\}/$APP_SLUG}"
  STATE_KEY="$(dk_c state_key prod.tfstate)"
  # Terraform's default -parallelism is 10; a version bump updates every
  # Lambda, so more at a time keeps a full apply short.
  TF_PARALLELISM="$(dk_c tf_parallelism "$TF_PARALLELISM")"
}

# aws_session_recheck: Preflight checked the AWS SSO session, but a deploy
# can run long, so the session can lapse before Terraform runs. An expired
# session opens `aws sso login`; a failed login stops here, before Terraform
# touches anything.
aws_session_recheck() {
  pause_ticker
  if ! check_session; then
    resume_ticker
    die "The AWS session (${AWS_PROFILE:-default credentials}) isn't valid: run aws sso login${AWS_PROFILE:+ --profile $AWS_PROFILE}, then the deploy again."
  fi
  resume_ticker
}

# run_tf <count_lines args> -- <terraform args>: terraform piped through
# count_lines. The reader ignores SIGINT, so terraform's own first-Ctrl-C
# shutdown runs (it finishes in-flight calls and unlocks); if it still exits
# holding a lock this run took, that lock is released here. Returns
# terraform's status.
run_tf() {
  local -a reader=()
  while [[ $1 != -- ]]; do
    reader+=("$1")
    shift
  done
  shift
  local since status
  since=$(date -u +%Y-%m-%dT%H:%M:%S)
  set +e
  terraform "$@" 2>&1 | {
    trap '' INT
    count_lines "${reader[@]}"
  }
  status=${PIPESTATUS[0]}
  set -e
  # A -lock=false plan took no lock, so any lock from this machine is
  # someone else's (a plan in another terminal): leave it.
  if ((status != 0 && status != 2)) && [[ " $* " != *" -lock=false "* ]]; then
    release_own_lock "$since"
  fi
  return "$status"
}

# release_own_lock <UTC start>: force-unlock the S3 state lock if this machine
# took it at or after <start>, i.e. this run's terraform left it behind.
# Anyone else's lock is left alone. Needs dk_config state_bucket.
release_own_lock() {
  local since=$1 lock id who created
  [[ -n "$STATE_BUCKET" ]] || return 0
  lock=$(aws s3 cp "s3://$STATE_BUCKET/$STATE_KEY.tflock" - 2>/dev/null) || return 0
  read -r id who created < <(jq -r '"\(.ID) \(.Who) \(.Created)"' <<<"$lock") || return 0
  [[ "$who" == "$(whoami)@$(hostname -s)"* && ! "$created" < "$since" ]] || return 0
  echo "==> Releasing the state lock this run left behind ($id)"
  terraform force-unlock -force "$id" >/dev/null 2>&1 || echo "    Couldn't: run terraform force-unlock $id"
}

# state_bucket_ensure: the backend bucket must exist in AWS_REGION before
# terraform init. On a first deploy it doesn't: create it (private,
# versioned), after asking. Once it exists it pins the region: an AWS_REGION
# changed since would plan a second copy of the stack, so stop instead. For an
# app's infra_preflight_hook.
state_bucket_ensure() {
  local region
  [[ -n "$STATE_BUCKET" ]] || die "state_bucket_ensure: dk_config state_bucket is empty."
  # Not head-bucket: it passes for a bucket in any region, and terraform init
  # then fails with a 301. A us-east-1 bucket's location reads back as None.
  if region=$(aws s3api get-bucket-location --bucket "$STATE_BUCKET" --query LocationConstraint --output text 2>/dev/null); then
    [[ "$region" == None ]] && region=us-east-1
    [[ "$region" == "$AWS_REGION" ]] && return 0
    echo "s3://$STATE_BUCKET is in $region, but AWS_REGION is $AWS_REGION." >&2
    echo "The stack lives where its state does: set AWS_REGION=$region. Moving it means rebuilding it, not this setting." >&2
    echo "If a first deploy created the bucket in the wrong region, it's empty: delete it, then deploy again." >&2
    echo "  aws s3api delete-bucket --bucket $STATE_BUCKET --region $region" >&2
    finish "Not applied: the state bucket is in $region, not $AWS_REGION." "1;31"
    exit 1
  fi
  pause_ticker
  echo
  echo "The Terraform state bucket s3://$STATE_BUCKET doesn't exist yet (a first deploy)."
  if ! confirm "Create it in $AWS_REGION?" "Stop the deploy?"; then
    resume_ticker
    finish "Not applied: no state bucket." 33
    exit 1
  fi
  resume_ticker
  local -a location=()
  # us-east-1 is the default location and rejects an explicit constraint.
  [[ "$AWS_REGION" == us-east-1 ]] || location=(--create-bucket-configuration "LocationConstraint=$AWS_REGION")
  aws s3api create-bucket --bucket "$STATE_BUCKET" ${location[@]+"${location[@]}"} >/dev/null
  aws s3api put-public-access-block --bucket "$STATE_BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
  echo "Created s3://$STATE_BUCKET in $AWS_REGION."
}

# state_bucket_adopt <address>: import the state bucket into the state it
# holds, once (Terraform can't create the bucket its own backend lives in).
# For an app's infra_init_hook, in infra_dir.
state_bucket_adopt() {
  local address=${1:-aws_s3_bucket.terraform_state}
  [[ -z "$(terraform state list "$address" 2>/dev/null)" ]] || return 0
  echo "==> Importing s3://$STATE_BUCKET into Terraform state"
  terraform import -input=false "$address" "$STATE_BUCKET" >/dev/null
}

# api_stage: yarn deploy infra's API stage. yarn deploy builds in plan_step.
api_stage() {
  stage API
  step Build "Building the API"
  if dk_has_hook infra_build_hook; then
    thread_run api-build "API build" infra_build_hook || die "The API build failed."
  else
    echo "No API build (infra_build_hook)."
  fi
}

# plan_summary <planfile>: a first line of counts ("<create> <update>
# <replace> <destroy> <lambdas>"), then the same in words, then what is
# replaced or destroyed, by address: those lose data or cause downtime.
plan_summary() {
  terraform -chdir="$INFRA" show -json "$1" | jq -r '
    [.resource_changes[]? | select(.mode == "managed")
      | {address, type, a: .change.actions}
      | .kind = (if .a == ["create"] then "create"
                 elif .a == ["update"] then "update"
                 elif .a == ["delete"] then "destroy"
                 elif ((.a | index("create")) != null and (.a | index("delete")) != null) then "replace"
                 else null end)
      | select(.kind != null)] as $c
    | ([$c[] | select(.kind == "create")] | length) as $create
    | ([$c[] | select(.kind == "update")] | length) as $update
    | ([$c[] | select(.kind == "replace")] | length) as $replace
    | ([$c[] | select(.kind == "destroy")] | length) as $destroy
    | ([$c[] | select(.type == "aws_lambda_function")] | length) as $lambdas
    | "\($create) \($update) \($replace) \($destroy) \($lambdas)",
      "\($create) to create, \($update) to update, \($replace) to replace, \($destroy) to destroy (\($lambdas) Lambda functions)",
      ($c[] | select(.kind == "replace") | "  replace  \(.address)"),
      ($c[] | select(.kind == "destroy") | "  destroy  \(.address)")'
}

# dk_plan_json: the plan as JSON, for an infra_check_hook (secrets included:
# it stays in $WORK).
dk_plan_json() {
  [[ -f "$WORK/tfplan.json" ]] || terraform -chdir="$INFRA" show -json "$WORK/tfplan" >"$WORK/tfplan.json"
  cat "$WORK/tfplan.json"
}

# infra_init: the secrets (infra_secrets_hook), terraform init, then the
# app's infra_init_hook. Runs inside the plan's thread.
infra_init() {
  cd "$INFRA"
  dk_hook infra_secrets_hook
  terraform init -input=false >/dev/null
  dk_hook infra_init_hook
  cd "$ROOT"
}

# infra_plan_run [<plan flag> ...]: the plan into $WORK/tfplan; its exit
# status (0 no changes, 2 changes) in $WORK/tfplan-status. Asks nothing.
# shellcheck disable=SC2120 # plan_step passes -lock=false
infra_plan_run() {
  local status=0
  cd "$INFRA"
  # Resources and data sources in state: roughly how many the plan refreshes.
  progress_total "$(terraform state list 2>/dev/null | wc -l | tr -d ' ')" "resources refreshed"
  run_tf ': (Refreshing state\.\.\.|Read complete after)' -- \
    plan -input=false -detailed-exitcode -parallelism="$TF_PARALLELISM" -out="$WORK/tfplan" \
    "$@" ${TF_ARGS[@]+"${TF_ARGS[@]}"} || status=$?
  ((status == 0 || status == 2)) || exit "$status"
  echo "$status" >"$WORK/tfplan-status"
  cd "$ROOT"
}

# infra_plan_lane [<plan flag> ...]: init and the plan as one thread. The
# secrets stay in the thread's subshell: Lint runs after it in the deploy's
# shell, and no check should see them (CI's don't). The saved plan carries
# what the apply needs.
infra_plan_lane() {
  infra_init
  infra_plan_run "$@"
}

# infra_summarize: from a finished plan: INFRA_STATUS (0 no changes, 2
# changes) and the summary in $WORK/tfplan-summary, printed.
infra_summarize() {
  INFRA_STATUS="$(cat "$WORK/tfplan-status")"
  if [[ "$INFRA_STATUS" == 0 ]]; then
    echo "No changes. Nothing to apply."
    return 0
  fi
  plan_summary "$WORK/tfplan" >"$WORK/tfplan-summary"
  printf '\e[1m==> %s\e[0m\n' "$(sed -n 2p "$WORK/tfplan-summary")"
  tail -n +3 "$WORK/tfplan-summary"
}

# plan_step: yarn deploy's API build and plan, in Preflight, so the plan is in
# front of you at Start. The target lanes build meanwhile.
plan_step() {
  if ((!DO_INFRA)); then
    step_mark Plan s
    return 0
  fi
  step Plan "Build the API and plan the infrastructure"
  local t0
  t0=$(date +%s)
  if dk_has_hook infra_build_hook; then
    thread_run api-build "API build" infra_build_hook || die "The API build failed."
  fi
  timing Preflight API $(($(date +%s) - t0))
  t0=$(date +%s)
  aws_session_recheck
  # No state lock: a Cancel or a failed Lint stops the run, and a terraform
  # stopped that way can leave one behind (run_tf). That is safe for a plan,
  # which changes nothing: the apply takes the lock, and refuses a plan the
  # state has moved on from.
  thread_run plan "Terraform plan" infra_plan_lane -lock=false || die "The Terraform plan failed."
  infra_summarize
  timing Preflight Terraform $(($(date +%s) - t0))
}

# infra_apply_run: Apply, from the summarized plan.
infra_apply_run() {
  local create update replace destroy lambdas changes
  read -r create update replace destroy lambdas <"$WORK/tfplan-summary"
  # One "complete" line per action: a replace is a delete and a create.
  changes=$((create + update + 2 * replace + destroy))
  cd "$INFRA"
  progress_total "$changes" "resources" "$lambdas" "lambdas"
  run_tf ': (Creation|Modifications|Destruction) complete' 'aws_lambda_function\.' -- \
    apply -input=false -parallelism="$TF_PARALLELISM" "$WORK/tfplan"
  cd "$ROOT"
}

# infra_apply_thread: Apply as a thread (the plan may be many minutes old, so
# the session is checked first), then Sync (after_apply_hook). With no
# changes, Sync alone.
infra_apply_thread() {
  if [[ "$INFRA_STATUS" == 0 ]]; then
    INFRA_RESULT="no changes"
    step_mark Apply s
  else
    aws_session_recheck
    step Apply "terraform apply"
    thread_run apply "Terraform apply" infra_apply_run || die "The Terraform apply failed."
    INFRA_RESULT="$(sed -n 2p "$WORK/tfplan-summary")"
  fi
  step Sync "Sync outputs"
  if dk_has_hook after_apply_hook; then after_apply_hook; else echo "Nothing to sync (after_apply_hook)."; fi
}

# infra_stage: yarn deploy infra's, in the foreground: Init, Plan, the
# summary, Confirm (its one question), Apply, Sync.
infra_stage() {
  stage Infra
  aws_session_recheck
  step Init "terraform init"
  step Plan "terraform plan"
  thread_run plan "Terraform plan" infra_plan_lane || die "The Terraform plan failed."
  infra_summarize
  dk_hook infra_check_hook
  if [[ "$INFRA_STATUS" != 0 ]]; then
    step Confirm "Confirm"
    spinner_label "waiting for an answer"
    pause_ticker
    echo
    if ! confirm "Apply this plan${STAGE:+ to $STAGE}?" "Stop the deploy without applying?"; then
      resume_ticker
      echo "Not applied."
      finish "Not applied. Nothing after Infra ran." 33
      exit 1
    fi
    resume_ticker
  else
    step_mark Confirm s
  fi
  infra_apply_thread
}
