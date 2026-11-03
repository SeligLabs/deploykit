#!/usr/bin/env bash
# deploykit's scenarios: the fixture app (test/fixture: Web, Mobile, TV and
# Desktop targets) deployed with stub tools (test/stubs: aws, terraform,
# bundle/fastlane, yarn, keytool, gh) on PATH, in a fresh copy per scenario
# with a local git origin, the cache in scratch, the plain output (no UI).
#
#   bash test/run.sh [<scenario> ...]     all of them by default
#
# Runs on macOS's bash 3.2 and on Linux.
set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/deploykit-test.XXXXXX")"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$SCRATCH"' EXIT
PASSED=0
FAILED=()
# A run that hangs fails after 4 minutes where timeout exists (coreutils; a
# Mac without it runs unbounded).
TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT="timeout 240"; elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT="gtimeout 240"; fi
# An identity for every commit the scenarios make (the fixture's, the
# deploy's bump), so a CI runner with none can run them.
export GIT_AUTHOR_NAME=deploykit-test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=deploykit-test GIT_COMMITTER_EMAIL=test@example.invalid

# fresh: a new copy of the fixture as a git repo with an origin; sets APP.
fresh() {
  APP="$SCRATCH/app-$1"
  rm -rf "$APP" "$SCRATCH/origin-$1.git"
  cp -R "$KIT/test/fixture" "$APP"
  git init -q --bare -b main "$SCRATCH/origin-$1.git"
  (
    cd "$APP" &&
      git init -q -b main &&
      printf 'apps/*/build/\napps/*/android/\napps/*/out/\n' >.gitignore &&
      git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture &&
      git remote add origin "$SCRATCH/origin-$1.git" && git push -q origin main
  )
  printf '%s\n' "mobile ios apps/mobile/build/deploy/fixture.ipa" "mobile android apps/mobile/android/app-release.aab" \
    "tv tvos apps/tv/build/deploy/fixture-tv.ipa" "tv android apps/tv/android/app-release.aab" >"$SCRATCH/artifacts"
  : >"$SCRATCH/stub.log"
  # The stub Terraform's state: no outputs until an apply.
  rm -f "$SCRATCH/tf-applied"
}

# deploy <input> <command...>: the app's deploy, its output in OUT, status RC.
deploy() {
  local input=$1
  shift
  printf '%b' "$input" >"$SCRATCH/input"
  (cd "$APP" && env -u AWS_PROFILE -u DEPLOY_UI -u DEPLOY_WORK -u DEPLOY_ENV_LOADED \
    PATH="$KIT/test/stubs:$PATH" DEPLOYKIT_DEV="$KIT" STUB_LOG="$SCRATCH/stub.log" STUB_ARTIFACTS="$SCRATCH/artifacts" \
    XDG_CACHE_HOME="$SCRATCH/cache" TMPDIR="$SCRATCH" DEPLOY_TUI=0 $TIMEOUT bash scripts/deploy/deploy.sh "$@") \
    <"$SCRATCH/input" >"$SCRATCH/out.raw" 2>&1
  RC=$?
  OUT="$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$SCRATCH/out.raw")"
}

fail() {
  echo "    ✗ $*"
  CASE_OK=0
}
expect_rc() { [[ "$RC" == "$1" ]] || fail "exit $RC, want $1"; }
expect_out() { grep -qF -- "$1" <<<"$OUT" || fail "output lacks: $1"; }
expect_no_out() { ! grep -qF -- "$1" <<<"$OUT" || fail "output has: $1"; }
expect_log() { grep -qE -- "$1" "$SCRATCH/stub.log" || fail "stub log lacks: $1"; }
expect_no_log() { ! grep -qE -- "$1" "$SCRATCH/stub.log" || fail "stub log has: $1"; }
uploads() { grep -c '^UPLOAD' "$SCRATCH/stub.log" | tr -d ' '; }
build_now() { node -p "require('$APP/package.json').build"; }
no_leftovers() {
  sleep 1
  if pgrep -f "$APP/" >/dev/null 2>&1; then fail "processes left running: $(pgrep -fl "$APP/" | head -3)"; fi
  [[ ! -d "$SCRATCH/fixture-deploy.lock" ]] || fail "the deploy lock is still held"
}
# line_of <regex> <file>: the first matching line's number (0: none).
line_of() { grep -nE -- "$1" "$2" | head -n 1 | cut -d: -f1 | grep . || echo 0; }

# The checklist's rows: 1 API + Infra, 2 Web, 3 app, 4 www, 5 Mobile, 6 iOS,
# 7 Android, 8 TV, 9 tvOS, 10 AndroidTV, 11 Desktop, 12 macOS, 13 Release.
# The version list: 1 Current, 2 Build, ... Then breaking (n), then Start
# (1 Start, 2 Edit the note first, 3 Cancel).
ALL="\n2\nn\n1\n"

case_full() {
  fresh full
  deploy "$ALL"
  expect_rc 0
  expect_out "Deployed 1.0.0 (11)."
  expect_out "iOS: TestFlight 1.0.0 (11)."
  expect_out "AndroidTV: the Play internal track 1.0.0 (1000011)."
  expect_out "app: published to https://app.example.com."
  expect_out "macOS: DMG 1.0.0 (11)."
  expect_out "Fire TV: upload the APK by hand."
  # Terraform's outputs, read live after the apply (a map output, one
  # variable per key).
  expect_out "(tables users-t tags-t)"
  expect_log "terraform output -json"
  [[ "$(uploads)" == 4 ]] || fail "$(uploads) store uploads, want 4"
  expect_log "s3 sync .*s3://www-fixture --delete .*--exclude \.well-known/\*"
  expect_log "s3 sync .*_next/static s3://web-fixture/_next/static"
  expect_log "cloudfront create-invalidation --distribution-id E123"
  # A first deploy: the lanes that need outputs start after the apply, and
  # nothing is uploaded before it.
  (($(line_of 'terraform apply' "$SCRATCH/stub.log") < $(line_of '^UPLOAD' "$SCRATCH/stub.log"))) || fail "an upload came before the apply"
  expect_log "terraform plan .*\(TF_VAR_push_key=secret-value\)"
  # --watch and --tests: each scheme on its own simulator, before the archive.
  expect_log "xcodebuild test .*-scheme FixtureWatch -destination id=WATCH-UDID"
  expect_log "xcodebuild test .*-scheme FixtureWidgets -destination id=IPHONE-UDID"
  (($(line_of 'scheme FixtureWatch' "$SCRATCH/stub.log") < $(line_of 'fastlane ios build' "$SCRATCH/stub.log"))) || fail "the watch tests came after the archive"
  git -C "$SCRATCH/origin-full.git" rev-parse -q --verify refs/tags/v1.0.0+11 >/dev/null || fail "no tag v1.0.0+11 on origin"
  # lint_lock: the Mac app's export (holding the web lock) and Lint's checks
  # never overlap.
  local taken released lint_start lint_end
  taken=$(line_of 'LOCK web taken' "$SCRATCH/stub.log") released=$(line_of 'LOCK web released' "$SCRATCH/stub.log")
  lint_start=$(line_of 'LINT start' "$SCRATCH/stub.log") lint_end=$(line_of 'LINT end' "$SCRATCH/stub.log")
  ((taken > 0 && lint_start > 0)) || fail "no export or no Lint in the stub log"
  ((released < lint_start || lint_end < taken)) || fail "the export ran while Lint held the web lock"
  # The kit's bump: package.json and each native file, in the bump commit
  # (a pbxproj's other version left alone).
  git -C "$APP" show --stat HEAD~0 >/dev/null
  grep -q '<string>1.0.0</string>' "$APP/native/Info.plist" && grep -q '<string>11</string>' "$APP/native/Info.plist" || fail "Info.plist wasn't bumped to 11"
  grep -q 'CURRENT_PROJECT_VERSION = 11;' "$APP/native/project.pbxproj" && grep -q 'MARKETING_VERSION = 9.9.9;' "$APP/native/project.pbxproj" || fail "project.pbxproj wasn't bumped (or its other version was)"
  grep -q 'versionCode 11' "$APP/native/build.gradle" || fail "build.gradle wasn't bumped"
  git -C "$APP" log -1 --name-only --format= origin/main | grep -q 'native/build.gradle' || fail "the bump commit lacks the native files"
  # No log holds the environment (a bare export in Prepare printed it all).
  ! grep -rlq 'declare -x' "$APP/apps" "$SCRATCH/cache" 2>/dev/null || fail "a log holds the environment: $(grep -rl 'declare -x' "$APP/apps" "$SCRATCH/cache" | head -n 1)"
  no_leftovers
}

case_outputs_ready() {
  fresh ready
  echo "API_URL=https://api.example.invalid" >>"$APP/env/.env"
  git -C "$APP" commit -qam outputs && git -C "$APP" push -q origin main
  deploy "$ALL"
  expect_rc 0
  # Outputs known: the lanes start in Preflight, before Lint.
  (($(grep -n 'iOS in the background' <<<"$OUT" | head -1 | cut -d: -f1) < $(grep -n '━━ Lint' <<<"$OUT" | head -1 | cut -d: -f1))) ||
    fail "the iOS lane didn't start before Lint"
  expect_out "Deployed 1.0.0 (11)."
}

case_failed_lint() {
  fresh lint
  local head
  head="$(git -C "$APP" rev-parse HEAD)"
  STUB_LINT_FAIL=js-test deploy "$ALL"
  expect_rc 1
  expect_out "Lint failed. Nothing was deployed."
  expect_out "Took back the bump"
  [[ "$(git -C "$APP" rev-parse HEAD)" == "$head" ]] || fail "the bump wasn't taken back"
  [[ "$(uploads)" == 0 ]] || fail "uploads after a failed Lint"
  expect_no_log "terraform apply"
  no_leftovers
}

case_cancel() {
  fresh cancel
  local head
  echo "API_URL=https://api.example.invalid" >>"$APP/env/.env"
  git -C "$APP" commit -qam outputs && git -C "$APP" push -q origin main
  head="$(git -C "$APP" rev-parse HEAD)"
  STUB_BUILD_SECONDS=20 deploy "\n2\nn\n3\n"
  expect_rc 1
  expect_out "Cancelled. Nothing was changed."
  [[ "$(git -C "$APP" rev-parse HEAD)" == "$head" ]] || fail "the bump wasn't taken back"
  [[ "$(uploads)" == 0 ]] || fail "uploads after Cancel"
  no_leftovers
}

case_target_fails() {
  fresh fails
  STUB_FAIL=android-mobile deploy "$ALL"
  expect_rc 1
  expect_out "Failed: Android. The other targets carried on; Release didn't run."
  expect_log "^UPLOAD ios mobile"
  expect_log "^UPLOAD tvos tv"
  expect_log "^UPLOAD android tv"
  git -C "$SCRATCH/origin-fails.git" rev-parse -q --verify refs/tags/v1.0.0+11 >/dev/null && fail "tagged though a target failed"
  no_leftovers
}

case_unticked_group() {
  fresh group-off
  deploy "5\n2\nn\n1\n"
  expect_rc 0
  expect_out "iOS: not selected."
  expect_out "Android: not selected."
  expect_no_log "^UPLOAD (ios|android) mobile"
  expect_log "^UPLOAD tvos tv"
}

# Only sites ticked: nothing ships a version, so none is asked (the input
# goes straight from the checklist to Start).
case_sites_only() {
  fresh sites-only
  deploy "5 8 11 13\n1\n"
  expect_rc 0
  expect_no_out "Version for this deploy"
  expect_out "app: published to https://app.example.com."
  [[ "$(uploads)" == 0 ]] || fail "$(uploads) uploads, want none"
  [[ "$(build_now)" == 10 ]] || fail "the build moved to $(build_now)"
}

case_group_command() {
  fresh mobile
  echo "API_URL=https://api.example.invalid" >>"$APP/env/.env"
  git -C "$APP" commit -qam outputs && git -C "$APP" push -q origin main
  deploy "1\n" mobile
  expect_rc 0
  expect_out "iOS: TestFlight 1.0.0 (10)."
  expect_out "Android: the Play internal track 1.0.0 (10)."
  [[ "$(uploads)" == 2 ]] || fail "$(uploads) uploads, want 2"
  [[ "$(build_now)" == 10 ]] || fail "a group command changed the version"
  expect_no_log "terraform (plan|apply)"
  : >"$SCRATCH/stub.log"
  deploy "1\n" tv:tvos
  expect_rc 0
  expect_out "tvOS: TestFlight 1.0.0 (10)."
  [[ "$(uploads)" == 1 ]] || fail "$(uploads) uploads, want 1"
}

case_first_deploy_target_command() {
  fresh needs-outputs
  deploy "1\n" mobile:ios
  expect_rc 1
  expect_out "iOS needs Infra's outputs"
}

case_infra() {
  fresh infra
  deploy "y\n" infra
  expect_rc 0
  expect_out "Applied: 0 to create, 1 to update"
  expect_out "synced"
  expect_log "terraform apply"
  expect_log "yarn workspace @fixture/api build"
  # dk_config tf_init_args and tf_plan_args, with the stage expanded.
  expect_log "terraform init -input=false -reconfigure -backend-config=key=prod.tfstate"
  expect_log "terraform plan .*-var=stage=prod"
}

case_reuse() {
  fresh reuse
  echo "API_URL=https://api.example.invalid" >>"$APP/env/.env"
  git -C "$APP" commit -qam outputs && git -C "$APP" push -q origin main
  deploy "1\n" mobile:ios
  expect_rc 0
  : >"$SCRATCH/stub.log"
  deploy "1\n" mobile:ios
  expect_rc 0
  grep -qF "Reusing the build of 1.0.0 (10)" "$APP/apps/mobile/build/deploy-ios.log" || fail "the lane didn't reuse the archive"
  expect_no_log "fastlane ios build"
  expect_log "^UPLOAD ios mobile"
}

case_already_uploaded() {
  fresh uploaded
  echo "API_URL=https://api.example.invalid" >>"$APP/env/.env"
  git -C "$APP" commit -qam outputs && git -C "$APP" push -q origin main
  STUB_CHECK_STATE=uploaded deploy "1\n" mobile
  expect_rc 0
  expect_out "iOS: 1.0.0 (10) was already on TestFlight."
  [[ "$(uploads)" == 0 ]] || fail "uploaded a build the store had"
}

case_settings() {
  fresh settings
  APPLE_TEAM_ID=FROMENV deploy "" settings
  expect_rc 0
  expect_out "APPLE_TEAM_ID"
  grep -E 'APPLE_TEAM_ID +FROMENV +env' <<<"$OUT" >/dev/null || fail "APPLE_TEAM_ID isn't from env"
  grep -E 'ANDROID_UPLOAD_KEYSTORE_PASSWORD +•' <<<"$OUT" >/dev/null || fail "a password isn't masked"
  grep -E 'ANDROID_UPLOAD_KEY_ALIAS +upload +default' <<<"$OUT" >/dev/null || fail "the alias default"
  sed -i.bak '/^PLAY_JSON_KEY_PATH=/d' "$APP/env/release.env"
  deploy "" settings
  expect_rc 1
  expect_out "1 missing."
  PLAY_SERVICE_ACCOUNT_JSON=env/play.json DK_TEST_ALIAS=1 deploy "" settings
  expect_rc 0
  expect_out "alias PLAY_SERVICE_ACCOUNT_JSON"
  # A file with both: the new name wins over the old one, and the warning
  # about an old name comes once a run.
  mv "$APP/env/release.env.bak" "$APP/env/release.env"
  echo "PLAY_SERVICE_ACCOUNT_JSON=env/old.json" >>"$APP/env/release.env"
  deploy "" settings
  expect_rc 0
  grep -E 'PLAY_JSON_KEY_PATH +env/play.json +env/release.env' <<<"$OUT" >/dev/null || fail "the old name beat the new one in the file"
  sed -i.bak '/^PLAY_JSON_KEY_PATH=/d' "$APP/env/release.env"
  deploy "" settings
  [[ "$(grep -c 'is the old name of PLAY_JSON_KEY_PATH' <<<"$OUT")" == 1 ]] || fail "the old-name warning came $(grep -c 'is the old name' <<<"$OUT") times"
}

case_demo() {
  fresh demo
  local head
  head="$(git -C "$APP" rev-parse HEAD)"
  DEMO_SPEED=20 deploy "\n1\n" demo
  expect_rc 0
  expect_out "(a demo: nothing was published)"
  expect_out "AndroidTV: 1.0.0 (11) (a demo"
  [[ "$(git -C "$APP" rev-parse HEAD)" == "$head" ]] || fail "the demo committed"
  expect_no_log "terraform|^UPLOAD|fastlane|s3 sync"
  # The app's lane logs (its last real build's) are left alone.
  [[ -z "$(find "$APP/apps" -name 'deploy-*.log' 2>/dev/null)" ]] || fail "the demo wrote $(find "$APP/apps" -name 'deploy-*.log' | head -n 1)"
  no_leftovers
}

# ios_lane_log: the iOS lane's log, where its failures are.
ios_lane_log() { cat "$APP/apps/mobile/build/deploy-ios.log" 2>/dev/null; }
expect_ios_log() { grep -qF -- "$1" <<<"$(ios_lane_log)" || fail "the iOS lane's log lacks: $1"; }

# A target command with the outputs in place: just the iOS lane.
ios_ready() {
  fresh "$1"
  echo "API_URL=https://api.example.invalid" >>"$APP/env/.env"
  git -C "$APP" commit -qam outputs && git -C "$APP" push -q origin main
}

case_watch_missing() {
  ios_ready watch-missing
  STUB_NO_WATCH=1 deploy "1\n" mobile:ios
  expect_rc 1
  expect_ios_log "The archive has no watch app"
  [[ "$(uploads)" == 0 ]] || fail "uploaded an archive without its watch app"
}

case_watch_version() {
  ios_ready watch-version
  STUB_WATCH_BUILD=1 deploy "1\n" mobile:ios
  expect_rc 1
  expect_ios_log "The watch app's W.appex is 1.0.0 (1), not 1.0.0 (10)."
  [[ "$(uploads)" == 0 ]] || fail "uploaded a mismatched watch extension"
}

case_xctest_fails() {
  ios_ready xctest-fails
  STUB_XCTEST_FAIL=FixtureWatch deploy "1\n" mobile:ios
  expect_rc 1
  expect_ios_log "The FixtureWatch tests failed. Nothing was archived."
  expect_no_log "fastlane ios build"
}

case_no_simulators() {
  ios_ready no-sims
  STUB_NO_SIMS=1 deploy "1\n" mobile:ios
  expect_rc 0
  expect_ios_log "FixtureWatch tests skipped: no watchOS simulator"
  expect_ios_log "FixtureWidgets tests skipped: no iOS simulator"
  expect_log "^UPLOAD ios mobile"
}

# The SSO token must outlive the deploy: under AWS_SESSION_MIN_SECONDS left
# counts as expired (without a terminal, ensure then says to log in).
case_sso_margin() {
  local home="$SCRATCH/sso-home" cache
  mkdir -p "$home/.aws/sso/cache"
  cache="$home/.aws/sso/cache/$(printf '%s' deploy-sso | shasum | cut -c1-40).json"
  sso_ensure() {
    OUT="$(env HOME="$home" PATH="$KIT/test/stubs:$PATH" STUB_LOG="$SCRATCH/stub.log" STUB_SSO_SESSION=deploy-sso \
      AWS_PROFILE=stub bash "$KIT/bin/aws-session.sh" ensure 2>&1 </dev/null)"
    RC=$?
  }
  printf '{"expiresAt":"%s"}' "$(date -u -r $(($(date +%s) + 630)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$(($(date +%s) + 630)) +%Y-%m-%dT%H:%M:%SZ)" >"$cache"
  sso_ensure
  [[ "$RC" != 0 ]] || fail "a token with 10 minutes left passed"
  expect_out "expires in 10 min (under 30)"
  printf '{"expiresAt":"%s"}' "$(date -u -r $(($(date +%s) + 7200)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$(($(date +%s) + 7200)) +%Y-%m-%dT%H:%M:%SZ)" >"$cache"
  sso_ensure
  expect_rc 0
}

# --tv: an Android TV bundle without leanback stops before the upload.
case_tv_leanback() {
  fresh leanback
  echo "API_URL=https://api.example.invalid" >>"$APP/env/.env"
  git -C "$APP" commit -qam outputs && git -C "$APP" push -q origin main
  STUB_NO_LEANBACK=1 deploy "1\n" tv:androidtv
  expect_rc 1
  grep -qF "doesn't declare android.software.leanback" "$APP/apps/tv/build/deploy-androidtv.log" || fail "no leanback message in the lane's log"
  [[ "$(uploads)" == 0 ]] || fail "uploaded a TV bundle without leanback"
}

# yarn deploy bump: the version by hand, the native files too, no commit.
case_bump() {
  fresh bump
  deploy "" bump set 2.0.0 20 --breaking
  expect_rc 0
  [[ "$(node -p "const p=require('$APP/package.json'); p.version+' '+p.build+' '+p.minBuild")" == "2.0.0 20 20" ]] || fail "package.json isn't 2.0.0 (20), minBuild 20"
  grep -q 'versionName "2.0.0"' "$APP/native/build.gradle" || fail "build.gradle isn't 2.0.0"
  grep -q 'MARKETING_VERSION = 2.0.0;' "$APP/native/project.pbxproj" || fail "project.pbxproj isn't 2.0.0"
  [[ "$(git -C "$APP" rev-list --count HEAD)" == 1 ]] || fail "bump committed"
  deploy "" bump set 3.0.0 5
  expect_rc 1
  expect_out "Build must be above 20"
}

# deploykit publish-site (an app's CI): the site driver's sync, no deploy.
case_publish_site() {
  fresh publish
  : >"$SCRATCH/stub.log"
  OUT="$(cd "$APP" && PATH="$KIT/test/stubs:$PATH" STUB_LOG="$SCRATCH/stub.log" bash "$KIT/bin/deploykit" publish-site \
    --build "mkdir -p apps/www/out/_next/static && echo www >apps/www/out/index.html" --out apps/www/out \
    --bucket www-ci --distribution ECI --keep ".well-known/*" 2>&1)"
  RC=$?
  expect_rc 0
  expect_out "Published to s3://www-ci"
  expect_log "s3 sync .*_next/static s3://www-ci/_next/static --cache-control public,max-age=31536000,immutable"
  expect_log "s3 sync .*apps/www/out s3://www-ci --delete --exclude _next/static/\* --exclude \.well-known/\*"
  expect_log "cloudfront create-invalidation --distribution-id ECI"
}

# A stale value in an env file loses to the state's: the build embeds the live one.
case_outputs_live() {
  fresh outputs-live
  echo "API_URL=https://stale.example.invalid" >>"$APP/env/.env"
  git -C "$APP" commit -qam stale && git -C "$APP" push -q origin main
  STUB_OUTPUTS=1 deploy "1\n" mobile:ios
  expect_rc 0
  unzip -p "$APP/apps/mobile/build/deploy/fixture.ipa" Payload/App.app/config | grep -qx 'https://api.example.invalid' ||
    fail "the build embeds $(unzip -p "$APP/apps/mobile/build/deploy/fixture.ipa" Payload/App.app/config), not the state's API_URL"
}

# yarn deploy env-sync: the live outputs into env/.env, in place.
case_env_sync() {
  fresh env-sync
  STUB_OUTPUTS=1 deploy "" env-sync
  expect_rc 0
  expect_out "✓ env/.env ← terraform outputs (3 values"
  grep -qx 'API_URL=https://api.example.invalid' "$APP/env/.env" || fail "env/.env has no API_URL"
  grep -qx 'ITEM_TAGS_TABLE=tags-t' "$APP/env/.env" || fail "env/.env has no ITEM_TAGS_TABLE"
  grep -qx 'WEB_BUCKET=web-fixture' "$APP/env/.env" || fail "env-sync lost a line it doesn't own"
  deploy "" env-sync
  expect_rc 1
  expect_out "Terraform has no outputs yet"
}

case_usage() {
  fresh usage
  deploy "" nosuch
  expect_rc 2
  expect_out "mobile[:ios|android]"
}

SCENARIOS=(full outputs_ready failed_lint cancel target_fails unticked_group group_command
  sites_only first_deploy_target_command infra reuse already_uploaded watch_missing watch_version xctest_fails
  no_simulators tv_leanback bump publish_site outputs_live env_sync sso_margin settings demo usage)
[[ $# -gt 0 ]] && SCENARIOS=("$@")
for s in "${SCENARIOS[@]}"; do
  CASE_OK=1
  echo "▶ $s"
  "case_$s"
  if ((CASE_OK)); then
    PASSED=$((PASSED + 1))
  else
    FAILED+=("$s")
    printf '%s\n' "$OUT" | tail -n 40 | sed 's/^/    │ /'
  fi
done
echo
echo "$PASSED passed, ${#FAILED[@]} failed${FAILED[*]:+: ${FAILED[*]}}"
((${#FAILED[@]} == 0))
