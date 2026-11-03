# shellcheck shell=bash
# The fastlane driver: a store build (TestFlight, the Play internal track, App
# Store Connect for the Mac) through the app's Fastfile.
#
#   dk_target mobile ios --driver fastlane --platform ios --dir apps/mobile \
#     --artifact "apps/mobile/build/deploy/{slug}.ipa" --lock xcode --reuse \
#     --prepare "dk_expo_prebuild ios @repo/mobile" --waits-for outputs \
#     --embeds "API_URL COGNITO_USER_POOL_ID COGNITO_CLIENT_ID"
#
# The Fastfile contract (in --dir, the platform --platform: ios, tvos,
# android or mac), which every app's Fastfile keeps:
#   check_build [version:<v>] build:<b> out:<file>
#       writes "<state> <latest>" on the first line, the state one of new,
#       uploaded, behind or rejected; a rejected build's reasons follow, a
#       line each. Android takes no version (the version code is the build;
#       a Fastfile with an offset adds it itself).
#   build                    makes --artifact
#   upload ipa:|aab:|pkg:<artifact> changelog_file:<the store note>
# The settings it needs reach it as environment variables (CONTRACT.md,
# Settings), with FASTLANE_SKIP_UPDATE_CHECK and no stdin, so a lane that
# would prompt fails instead of hanging the deploy.
#
# Options:
#   --platform ios|tvos|android|mac   --dir <fastlane's directory>
#   --artifact <path>        what build makes ({slug} is the app's slug)
#   --prepare "<command>"    before the build, e.g. dk_expo_prebuild ios
#   --lock xcode|gradle      take turns with targets holding the same lock
#   --play                   Play's checks and uploads take turns (the play
#                            lock): each upload reads the track and keeps the
#                            other's release in it
#   --reuse                  keep the artifact by version, build, commit and
#                            env, and reuse it on a later run (an archive made
#                            now, uploaded later)
#   --embeds "<VAR ...>"     values the build must contain (the API URL a
#                            build made without the env loaded lacks)
#   --env "<VAR=value ...>"  for fastlane and --prepare (EXPO_TV=1)
#   --gemfile <path>         BUNDLE_GEMFILE, when not found from --dir
#   --version-offset <n>     shown and checked version code: the build plus n
#   --bundle-id <id>         default the app's bundle ID
#   --upload-key settings|none  Android: verify the bundle is signed with the
#                            ANDROID_UPLOAD_* key (default settings)
#   --tv                     android: a TV app; its manifest must declare
#                            android.software.leanback
#   --progress "<regex>"     a build line to count (▸ for Xcode, > Task : for
#                            Gradle by default)
#   --watch <scheme>         ios: the app carries an Apple Watch app. Before
#                            the archive, that scheme's XCTests run on the
#                            newest watchOS simulator; in the archive, the
#                            watch app (Payload/*.app/Watch/*.app) and its
#                            extensions must be there, at the app's version
#                            and build, the app with --watch-bundle-id
#                            (default <bundle id>.watchkitapp)
#   --tests "<scheme ...>"   more XCTest schemes before the archive, on the
#                            newest simulator of the target's platform
#                            (an iPhone, or an Apple TV)
#   --extensions "<X.appex ...>"  extensions the archive must carry in the
#                            app's PlugIns/, at its version and build, their
#                            bundle IDs under the app's
#   --xcode-project <path>   the project the tests build (default the first
#                            <dir>/ios/*.xcodeproj, as expo prebuild makes it)
#   The tests skip, with a warning, without Xcode or a simulator to run on
#   (add one in Xcode → Settings → Components); a failing test stops the
#   build before anything ships.
#
# Hooks (CONTRACT.md): <id>_after_prepare, <id>_before_build (inside the
# lock), <id>_after_build, <id>_verify <unzipped dir or app>, <id>_preflight.

DK_ASC_SETTINGS="APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_KEY_ISSUER_ID APPLE_TEAM_ID"
DK_PLAY_SETTINGS="PLAY_JSON_KEY_PATH"
DK_UPLOAD_KEY_SETTINGS="ANDROID_UPLOAD_KEYSTORE_PATH ANDROID_UPLOAD_KEYSTORE_PASSWORD ANDROID_UPLOAD_KEY_ALIAS ANDROID_UPLOAD_KEY_PASSWORD"

dk_fastlane_platform() { dk_t "$1" platform; }
dk_fastlane_apple() { [[ "$(dk_fastlane_platform "$1")" != android ]]; }

dk_fastlane_steps() {
  if dk_fastlane_has_tests "$1"; then
    echo "Check Prepare Tests Build Verify Gate Upload"
  else
    echo "Check Prepare Build Verify Gate Upload"
  fi
}

# dk_fastlane_has_tests <id>: XCTests run before this target's archive.
dk_fastlane_has_tests() {
  dk_fastlane_apple "$1" && [[ -n "$(dk_t "$1" watch)$(dk_t "$1" tests)" ]]
}

dk_fastlane_tools() {
  if dk_fastlane_apple "$1"; then echo "bundle xcodebuild unzip"; else echo "bundle java keytool unzip"; fi
}
dk_fastlane_needs_aws() { echo no; }
dk_fastlane_takes_note() { echo yes; }
dk_fastlane_reuses() { [[ "$(dk_t "$1" reuse)" == 1 ]] && echo yes || echo no; }

# dk_fastlane_store <id>: where it goes, for messages.
dk_fastlane_store() {
  case "$(dk_fastlane_platform "$1")" in
    android) echo "the Play internal track" ;;
    mac) echo "App Store Connect" ;;
    *) echo TestFlight ;;
  esac
}

# dk_fastlane_code <id>: the build number the store sees.
dk_fastlane_code() { echo $((BUILD + $(dk_t "$1" version_offset 0))); }

dk_fastlane_summary() {
  # Before the version is chosen (the checklist), just where it goes.
  if [[ -z "${VERSION:-}" ]]; then
    echo "build, upload to $(dk_fastlane_store "$1")"
  else
    echo "$APP_NAME $VERSION ($(dk_fastlane_code "$1")) to $(dk_fastlane_store "$1")"
  fi
}

dk_fastlane_settings() {
  local name
  if dk_fastlane_apple "$1"; then
    dk_setting_declare APP_STORE_CONNECT_API_KEY_ID "The App Store Connect API key's ID (App Store Connect → Users and Access → Integrations)."
    dk_setting_declare APP_STORE_CONNECT_API_KEY_ISSUER_ID "The App Store Connect API key's issuer ID."
    dk_setting_declare APP_STORE_CONNECT_API_KEY_PATH "The key's .p8 file." \
      "$HOME/.appstoreconnect/private_keys/AuthKey_$(dk_setting APP_STORE_CONNECT_API_KEY_ID).p8"
    # The team is a fact of the app, not of the machine: package.json
    # app.appleTeamId, which a setting still overrides.
    dk_setting_declare APPLE_TEAM_ID "The Apple Developer team that signs the app (developer.apple.com → Membership): package.json app.appleTeamId." \
      "$(app_field appleTeamId)"
  else
    dk_setting_declare PLAY_JSON_KEY_PATH "A Google Cloud service account's JSON key with release access in Play Console."
    if [[ "$(dk_t "$1" upload_key settings)" == settings ]]; then
      for name in $DK_UPLOAD_KEY_SETTINGS; do
        dk_setting_declare "$name" "The Play upload key Gradle signs with (keytool -genkeypair ...; CONTRACT.md)." \
          "$([[ $name == ANDROID_UPLOAD_KEY_ALIAS ]] && echo upload)"
      done
    fi
  fi
}

# dk_fastlane_names <id>: the settings fastlane reads for this target.
dk_fastlane_names() {
  if dk_fastlane_apple "$1"; then
    echo "$DK_ASC_SETTINGS APP_STORE_CONNECT_API_KEY_PATH"
  else
    echo "$DK_PLAY_SETTINGS $DK_UPLOAD_KEY_SETTINGS"
  fi
}

# dk_fastlane_run <id> <lane> [<arg> ...]: fastlane in the target's
# directory, with its settings and --env, no stdin.
dk_fastlane_run() {
  local id=$1 lane=$2 dir gemfile
  shift 2
  dir="$ROOT/$(dk_t "$id" dir .)"
  gemfile="$(dk_t "$id" gemfile)"
  (
    # shellcheck disable=SC2046 # the names are a word list
    dk_settings_export $(dk_fastlane_names "$id")
    [[ -z "$gemfile" ]] || export BUNDLE_GEMFILE="$ROOT/$gemfile"
    cd "$dir" || exit 1
    # shellcheck disable=SC2046 # --env is a list of VAR=value words
    env FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1 $(dk_t "$id" env) \
      bundle exec fastlane "$(dk_fastlane_platform "$id")" "$lane" "$@" </dev/null
  )
}

# dk_fastlane_artifact <id>
dk_fastlane_artifact() {
  local a
  a="$(dk_t "$1" artifact)"
  a="${a//\{slug\}/$APP_SLUG}"
  [[ "$a" == /* ]] || a="$ROOT/$a"
  printf '%s' "$a"
}

# dk_fastlane_preflight <id>: the store's keys, the gems, the signing key.
dk_fastlane_preflight() {
  local id=$1 key store dir
  [[ -n "$(dk_t "$id" artifact)" ]] || die "Target $id (--driver fastlane) has no --artifact."
  if dk_fastlane_apple "$id"; then
    # shellcheck disable=SC2086 # a word list
    dk_setting_require $DK_ASC_SETTINGS
    key="$(dk_setting_path APP_STORE_CONNECT_API_KEY_PATH)"
    [[ -f "$key" ]] || die "APP_STORE_CONNECT_API_KEY_PATH doesn't point to a file: '$key'"
  else
    # shellcheck disable=SC2086
    dk_setting_require $DK_PLAY_SETTINGS
    key="$(dk_setting_path PLAY_JSON_KEY_PATH)"
    [[ -f "$key" ]] || die "PLAY_JSON_KEY_PATH doesn't point to a file: '$key'"
    if [[ "$(dk_t "$id" upload_key settings)" == settings ]]; then
      # shellcheck disable=SC2086
      dk_setting_require $DK_UPLOAD_KEY_SETTINGS
      store="$(dk_setting_path ANDROID_UPLOAD_KEYSTORE_PATH)"
      [[ -f "$store" ]] || die "ANDROID_UPLOAD_KEYSTORE_PATH doesn't point to a file: '$store'"
      # Opened now: a wrong password or alias would otherwise fail minutes
      # into the Gradle build.
      [[ -n "$(dk_upload_key_sha256)" ]] ||
        die "The upload keystore doesn't open with ANDROID_UPLOAD_KEYSTORE_PASSWORD and alias '$(dk_setting ANDROID_UPLOAD_KEY_ALIAS)'."
    fi
    [[ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]] || die "ANDROID_HOME isn't set: Gradle needs the Android SDK."
    dk_gradle_stop_daemons
  fi
  dir="$ROOT/$(dk_t "$id" dir .)"
  local gemfile
  gemfile="$(dk_t "$id" gemfile)"
  (
    [[ -z "$gemfile" ]] || export BUNDLE_GEMFILE="$ROOT/$gemfile"
    cd "$dir" && bundle check >/dev/null
  ) || die "Ruby gems missing for $(dk_t "$id" name): run bundle install."
  echo "$(dk_t "$id" name): $(dk_fastlane_store "$id"), key $(basename "$key"), gems installed."
}

# dk_upload_key_sha256: the upload key's certificate SHA-256, as keytool
# prints it; empty when the keystore doesn't open.
dk_upload_key_sha256() {
  ANDROID_UPLOAD_KEYSTORE_PASSWORD="$(dk_setting ANDROID_UPLOAD_KEYSTORE_PASSWORD)" \
    keytool -list -v -keystore "$(dk_setting_path ANDROID_UPLOAD_KEYSTORE_PATH)" \
    -storepass:env ANDROID_UPLOAD_KEYSTORE_PASSWORD -alias "$(dk_setting ANDROID_UPLOAD_KEY_ALIAS)" 2>/dev/null |
    sed -n 's/^[[:space:]]*SHA256: //p' | head -n 1
}

# dk_gradle_stop_daemons: stop every Gradle daemon on the machine before the
# lanes build, once per run. Each build reuses any daemon with its JVM
# settings, and a daemon left by another shell can be broken for good (seen
# failing every exec of node while a fresh JVM built fine). Stopping loses
# nothing: the build cache is on disk. Through any wrapper on the machine:
# a generated project's gradlew may not exist yet.
dk_gradle_stop_daemons() {
  local gradle id
  [[ ! -f "$WORK/gradle-stopped" ]] || return 0
  touch "$WORK/gradle-stopped"
  for id in ${DK_TARGET_IDS[@]+"${DK_TARGET_IDS[@]}"}; do
    gradle="$ROOT/$(dk_t "$id" dir .)/android/gradlew"
    if [[ -x "$gradle" ]]; then
      (cd "$(dirname "$gradle")" && "$gradle" --stop >/dev/null 2>&1) || true
      return 0
    fi
  done
  for gradle in "$HOME"/.gradle/wrapper/dists/gradle-*/*/gradle-*/bin/gradle; do
    [[ -x "$gradle" ]] || continue
    (cd "$(dirname "$gradle")" && "$gradle" --stop >/dev/null 2>&1) || true
    return 0
  done
}

# dk_fastlane_check <id> <version> <build>: the store's answer: sets
# DK_CHECK_STATE (new or uploaded), or stops when the store is ahead of this
# build or rejected it.
dk_fastlane_check() {
  local id=$1 version=$2 build=$3 out="$WORK/$1-check" latest store code
  local -a args=("build:$build" "out:$out")
  dk_fastlane_apple "$id" && args=("version:$version" ${args[@]+"${args[@]}"})
  if [[ "$(dk_t "$id" play)" == 1 ]]; then
    with_lock play dk_fastlane_run "$id" check_build "${args[@]}"
  else
    dk_fastlane_run "$id" check_build "${args[@]}"
  fi
  [[ -s "$out" ]] || die "fastlane check_build wrote nothing to $out."
  read -r DK_CHECK_STATE latest <"$out"
  store="$(dk_fastlane_store "$id")"
  code=$((build + $(dk_t "$id" version_offset 0)))
  case "$DK_CHECK_STATE" in
    new | uploaded) ;;
    behind) die "$store already has $version ($latest), newer than build $code. Choose a higher build." ;;
    rejected)
      echo "$store rejected $version ($code):"
      tail -n +2 "$out" | sed 's/^/  /'
      die "Fix that, then choose a higher build: the store won't take build $code again."
      ;;
    *) die "Unexpected check_build result from $store: $DK_CHECK_STATE" ;;
  esac
}

# dk_fastlane_meta <id>: what an artifact is built from.
dk_fastlane_meta() {
  local id=$1 var values=""
  for var in $(dk_t "$id" embeds); do values+="${!var:-}|"; done
  jq -cn --arg v "$VERSION" --arg b "$BUILD" --arg c "$(git -C "$ROOT" rev-parse HEAD)" \
    --arg e "${APP_ENV:-}" --arg x "$values" \
    '{version: $v, build: $b, commit: $c, env: $e, embeds: $x}'
}

# dk_fastlane_matches <id>: the kept artifact is this version, build, commit
# and env, with these embedded values.
dk_fastlane_matches() {
  local a
  a="$(dk_fastlane_artifact "$1")"
  [[ -f "$a" && -f "$a.meta.json" ]] || return 1
  [[ "$(jq -c '{version, build, commit, env, embeds}' "$a.meta.json" 2>/dev/null)" == "$(dk_fastlane_meta "$1")" ]]
}

# dk_plist <key> <plist>: one value, through PlistBuddy, plutil or Python.
dk_plist() {
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Print $1" "$2" 2>/dev/null
  else
    python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[2],"rb")).get(sys.argv[1],""))' "$1" "$2" 2>/dev/null
  fi
}

# dk_plist_version <plist>: "<version> (<build>)".
dk_plist_version() { echo "$(dk_plist CFBundleShortVersionString "$1") ($(dk_plist CFBundleVersion "$1"))"; }

# dk_verify_embeds <id> <dir>: each --embeds value is somewhere in the build.
dk_verify_embeds() {
  local var
  for var in $(dk_t "$1" embeds); do
    [[ -n "${!var:-}" ]] || die "$var is empty: the build has nothing to check it against."
    command grep -rqaF "${!var}" "$2" ||
      die "$var's value isn't in the build: was it built with another env?"
  done
}

# dk_verify_bundle <dir> <what> [<bundle id> | <prefix>.*]: a bundle in the
# archive at the app's version and build, with that bundle ID or one under
# that prefix (App Store Connect flags an extension that isn't).
dk_verify_bundle() {
  local dir=$1 what=$2 want=${3:-} got
  [[ -n "$dir" && -d "$dir" ]] || die "The archive has no $what."
  if [[ -n "$want" ]]; then
    got="$(dk_plist CFBundleIdentifier "$dir/Info.plist")"
    if [[ "$want" == *'.*' ]]; then
      [[ "$got" == "${want%\*}"* ]] || die "The $what's bundle ID is $got, not under ${want%.\*}."
    else
      [[ "$got" == "$want" ]] || die "The $what's bundle ID is $got, not $want."
    fi
  fi
  got="$(dk_plist_version "$dir/Info.plist")"
  [[ "$got" == "$VERSION ($BUILD)" ]] || die "The $what is $got, not $VERSION ($BUILD)."
}

# dk_verify_watch <id> <app>: --watch's app and every extension in it. A
# mismatch fails App Store validation, or installs nothing on the watch.
dk_verify_watch() {
  local id=$1 app=$2 watch appex bundle
  [[ -n "$(dk_t "$id" watch)" ]] || return 0
  bundle="$(dk_t "$id" bundle_id "$APP_BUNDLE_ID")"
  watch="$(compgen -G "$app/Watch/*.app" | head -n 1 || true)"
  [[ -n "$watch" ]] || die "The archive has no watch app (Payload/*.app/Watch/*.app)."
  dk_verify_bundle "$watch" "watch app" "$(dk_t "$id" watch_bundle_id "$bundle.watchkitapp")"
  for appex in "$watch"/PlugIns/*.appex; do
    [[ -d "$appex" ]] || continue
    dk_verify_bundle "$appex" "watch app's ${appex##*/}" "$bundle.*"
  done
}

# dk_verify_extensions <id> <app>: each of --extensions in the app's PlugIns/.
dk_verify_extensions() {
  local id=$1 app=$2 name bundle
  bundle="$(dk_t "$id" bundle_id "$APP_BUNDLE_ID")"
  for name in $(dk_t "$id" extensions); do
    dk_verify_bundle "$app/PlugIns/$name" "extension $name" "$bundle.*"
  done
}

# dk_sim <runtime> [<name prefix>]: the UDID of an available simulator on the
# newest runtime (watchOS, iOS, tvOS), or nothing. By UDID: a destination by
# name matches one simulator per runtime.
dk_sim() {
  xcrun simctl list devices available -j 2>/dev/null | jq -r --arg rt "$1" --arg name "${2:-}" '
    [.devices | to_entries[]
      | select(.key | test($rt + "-[0-9]+-[0-9]+$"))
      | (.key | capture($rt + "-(?<maj>[0-9]+)-(?<min>[0-9]+)$")) as $v
      | .value[] | select(.isAvailable != false and (.name | startswith($name)))
      | {udid, maj: ($v.maj | tonumber), min: ($v.min | tonumber)}]
    | sort_by(.maj, .min) | last | .udid // empty' 2>/dev/null
}

# dk_xcode_project <id>: the project --tests and --watch build.
dk_xcode_project() {
  local p
  p="$(dk_t "$1" xcode_project)"
  if [[ -n "$p" ]]; then
    printf '%s' "$ROOT/$p"
  else
    compgen -G "$ROOT/$(dk_t "$1" dir .)/ios/*.xcodeproj" | grep -v "/Pods" | head -n 1 || true
  fi
}

# dk_xctest <id> <scheme> <udid>: one scheme's XCTests, ad-hoc signed (an
# unsigned build has no keychain). Its log is kept beside the target's.
dk_xctest() {
  local id=$1 scheme=$2 udid=$3 dir log project
  dir="$ROOT/$(dk_t "$id" dir .)/build"
  log="$dir/xctest-$scheme.log"
  project="$(dk_xcode_project "$id")"
  [[ -n "$project" ]] || die "No Xcode project for the $scheme tests: set --xcode-project."
  mkdir -p "$dir"
  spinner_label "testing $scheme on a simulator"
  if xcodebuild test -project "$project" -scheme "$scheme" -destination "id=$udid" \
    -derivedDataPath "$dir/xctest" CODE_SIGN_IDENTITY=- >"$log" 2>&1 </dev/null; then
    { grep -E 'Executed [0-9]+ tests?' "$log" || echo "passed"; } | tail -n 1 |
      sed -E "s/^[[:space:]]*/$scheme: /; s/ in [0-9.]+ .*//"
  else
    printf '\n\e[1;31m── %s tests (last 40 lines of %s)\e[0m\n' "$scheme" "$log"
    tail -n 40 "$log"
    die "The $scheme tests failed. Nothing was archived."
  fi
}

# dk_fastlane_tests <id>: Tests, inside the target's lock: --watch's scheme
# on a watch simulator, then --tests on the platform's.
dk_fastlane_tests() {
  local id=$1 scheme udid runtime=iOS device=iPhone
  step Tests "XCTests before the archive"
  if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
    warn "Tests skipped: Xcode isn't installed."
    return 0
  fi
  scheme="$(dk_t "$id" watch)"
  if [[ -n "$scheme" ]]; then
    udid="$(dk_sim watchOS)"
    if [[ -n "$udid" ]]; then
      dk_xctest "$id" "$scheme" "$udid"
    else
      warn "$scheme tests skipped: no watchOS simulator; add one in Xcode → Settings → Components."
    fi
  fi
  [[ "$(dk_fastlane_platform "$id")" == tvos ]] && runtime=tvOS device="Apple TV"
  for scheme in $(dk_t "$id" tests); do
    udid="$(dk_sim "$runtime" "$device")"
    if [[ -n "$udid" ]]; then
      dk_xctest "$id" "$scheme" "$udid"
    else
      warn "$scheme tests skipped: no $runtime simulator; add one in Xcode → Settings → Components."
    fi
  done
}

# dk_fastlane_verify <id>: the artifact is this app at this version and build,
# signed for its store, with the env's values inside; then the app's checks.
dk_fastlane_verify() {
  local id=$1 dir="$WORK/$1-verify" a app plist got want platform code
  a="$(dk_fastlane_artifact "$id")"
  [[ -f "$a" ]] || die "No $a to verify."
  platform="$(dk_fastlane_platform "$id")"
  code="$(dk_fastlane_code "$id")"
  rm -rf "$dir" && mkdir -p "$dir"
  case "$platform" in
    ios | tvos)
      unzip -q "$a" -d "$dir"
      app="$(compgen -G "$dir/Payload/*.app" | head -n 1 || true)"
      [[ -n "$app" ]] || die "The archive has no Payload/*.app."
      plist="$app/Info.plist"
      want=iphoneos
      [[ "$platform" == tvos ]] && want=appletvos
      got="$(dk_plist DTPlatformName "$plist")"
      [[ -z "$got" || "$got" == "$want" ]] || die "The archive is for $got, not $want."
      got="$(dk_plist CFBundleIdentifier "$plist")"
      want="$(dk_t "$id" bundle_id "$APP_BUNDLE_ID")"
      [[ "$got" == "$want" ]] || die "The archive's bundle ID is $got, not $want."
      got="$(dk_plist_version "$plist")"
      [[ "$got" == "$VERSION ($code)" ]] || die "The archive is $got, not $VERSION ($code)."
      dk_verify_embeds "$id" "$dir/Payload"
      dk_verify_watch "$id" "$app"
      dk_verify_extensions "$id" "$app"
      dk_hook "${id}_verify" "$app"
      ;;
    android)
      if [[ "$(dk_t "$id" upload_key settings)" == settings ]]; then
        want="$(dk_upload_key_sha256)"
        got="$(keytool -printcert -jarfile "$a" 2>/dev/null | sed -n 's/^[[:space:]]*SHA256: //p' | head -n 1)"
        [[ -n "$got" ]] || die "The bundle isn't signed."
        [[ "$got" == "$want" ]] ||
          die "The bundle is signed by $got, not the upload key ($want): debug-signed? Check ANDROID_UPLOAD_*."
      fi
      unzip -oq "$a" -d "$dir"
      dk_verify_embeds "$id" "$dir"
      # --tv: a TV app declares leanback, or Play offers it to phones.
      if [[ "$(dk_t "$id" tv)" == 1 ]]; then
        command grep -qaF android.software.leanback "$dir/base/manifest/AndroidManifest.xml" 2>/dev/null ||
          die "The TV bundle's manifest doesn't declare android.software.leanback: was it built as the TV app (EXPO_TV=1)?"
      fi
      dk_hook "${id}_verify" "$dir"
      ;;
    mac) dk_hook "${id}_verify" "$a" ;;
  esac
  echo "Checked: $(dk_t "$id" name) $VERSION ($code)${APP_ENV:+, built with APP_ENV=$APP_ENV}."
  rm -rf "$dir"
}

# dk_fastlane_compile <id>: Build, inside the target's lock.
dk_fastlane_compile() {
  local id=$1 cache total n a regex log="$WORK/$1-build.log"
  dk_fastlane_has_tests "$id" && dk_fastlane_tests "$id"
  dk_hook "${id}_before_build"
  a="$(dk_fastlane_artifact "$id")"
  step Build "Build $VERSION ($(dk_fastlane_code "$id"))"
  rm -f "$a" "$a.meta.json"
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/$APP_SLUG/$id-build-steps"
  total=0
  [[ -f "$cache" ]] && total="$(cat "$cache")"
  if dk_fastlane_apple "$id"; then regex='▸'; else regex='> Task :'; fi
  regex="$(dk_t "$id" progress "$regex")"
  if ((total > 0)); then progress_total "$total" "build steps (est.)"; else spinner_label "building (first run: no estimate)"; fi
  if ! dk_fastlane_run "$id" build 2>&1 | tee "$log" | count_lines "$regex"; then
    if ! dk_fastlane_apple "$id"; then
      echo "Gradle failed:" >&2
      dk_gradle_errors "$log" | sed 's/^/  /' >&2
    fi
    die "fastlane $(dk_fastlane_platform "$id") build failed (above)."
  fi
  get n n
  mkdir -p "$(dirname "$cache")" && echo "${n:-0}" >"$cache"
  [[ -f "$a" ]] || die "fastlane finished without $a."
  dk_hook "${id}_after_build"
}

# dk_gradle_errors <log>: what Gradle says went wrong, without fastlane's own
# stack trace (which is all the end of the log shows).
dk_gradle_errors() {
  perl -pe 's/\e\[[0-9;]*m//g; s/^\[[0-9:]+\]: \S+ //' "$1" |
    grep -E -A2 '^\* What went wrong:|error: ' |
    grep -v -E '^\* What went wrong:|^--$|^\* Try:|^> Run with' |
    awk '!seen[$0]++' | head -n 8
}

# dk_fastlane_skip_build_steps <id>: a reused artifact skips what made it.
dk_fastlane_skip_build_steps() {
  local s steps
  get steps steps
  for s in $steps; do
    case "$s" in Check | Verify | Gate | Upload) ;; *) step_mark "$s" s ;; esac
  done
}

dk_fastlane_build() {
  local id=$1 prepare lock store code a kv
  store="$(dk_fastlane_store "$id")"
  code="$(dk_fastlane_code "$id")"
  step Check "$store: is $VERSION ($code) new?"
  spinner_label "asking $store"
  dk_fastlane_check "$id" "$VERSION" "$BUILD"
  if [[ "$DK_CHECK_STATE" == uploaded ]]; then
    echo "$store already has $VERSION ($code). Not uploading it again."
    dk_result "$id" "$VERSION ($code) was already on $store"
    return 0
  fi
  if [[ "$(dk_t "$id" reuse)" == 1 ]] && dk_fastlane_matches "$id"; then
    dk_fastlane_skip_build_steps "$id"
    step Verify "Verify the kept build"
    echo "Reusing the build of $VERSION ($code) from this commit ($(jq -r '.created // "earlier"' "$(dk_fastlane_artifact "$id").meta.json"))."
    dk_fastlane_verify "$id"
    return 0
  fi
  prepare="$(dk_t "$id" prepare)"
  if [[ -n "$prepare" ]]; then
    step Prepare "$prepare"
    spinner_label "preparing the native project"
    # Not `export $(...)`: with no --env, a bare export prints every
    # variable, secrets included, into the lane's log.
    (
      for kv in $(dk_t "$id" env); do export "${kv?}"; done
      eval "$prepare"
    ) || die "Prepare failed: $prepare"
  else
    step_mark Prepare s
  fi
  dk_hook "${id}_after_prepare"
  lock="$(dk_t "$id" lock)"
  if [[ -n "$lock" ]]; then
    spinner_label "waiting for the other $lock build"
    with_lock "$lock" dk_fastlane_compile "$id"
  else
    dk_fastlane_compile "$id"
  fi
  step Verify "Verify the build"
  dk_fastlane_verify "$id"
  if [[ "$(dk_t "$id" reuse)" == 1 ]]; then
    a="$(dk_fastlane_artifact "$id")"
    dk_fastlane_meta "$id" | jq --arg t "$(date '+%Y-%m-%d %H:%M')" '. + {created: $t}' >"$a.meta.json"
  fi
}

dk_fastlane_publish() {
  local id=$1 key a store
  a="$(dk_fastlane_artifact "$id")"
  store="$(dk_fastlane_store "$id")"
  # Built before the apply: the outputs it embeds must still be the deployed
  # ones.
  if [[ "$(dk_t "$id" reuse)" == 1 ]]; then
    dk_fastlane_matches "$id" || die "The deployed outputs changed during Infra. Build again: yarn deploy $(dk_t "$id" group):$id"
  else
    dk_fastlane_verify "$id" >/dev/null
  fi
  case "$(dk_fastlane_platform "$id")" in
    android) key=aab ;;
    mac) key=pkg ;;
    *) key=ipa ;;
  esac
  step Upload "Upload to $store"
  spinner_label "uploading, then waiting for $store"
  if [[ "$(dk_t "$id" play)" == 1 ]]; then
    with_lock play dk_fastlane_run "$id" upload "$key:$a" "changelog_file:$NOTES_FILE"
  else
    dk_fastlane_run "$id" upload "$key:$a" "changelog_file:$NOTES_FILE"
  fi
  dk_result "$id" "$store $VERSION ($(dk_fastlane_code "$id"))"
}
