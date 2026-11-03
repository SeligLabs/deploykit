# shellcheck shell=bash disable=SC2034 # globals read by deploy.sh
# Version: which version and build this deploy ships. root package.json
# { version, build } is the source of truth (app.config.ts reads it, so no
# native file changes); the app's version command (dk_config version_cmd,
# e.g. node scripts/version.mjs) writes it. The release tag is
# v<version>+<build>, as in .github/workflows/ci.yml.
#
# BUMP (its values are listed at version_choose) is chosen up front;
# version_step applies it and commits locally, in Preflight, before the
# plan, Lint and the store builds, so they check and build what ships.
# Nothing is pushed until the Release stage, so a run that fails after Lint
# leaves an unpushed chore(release) commit and no tag: the next run offers to
# ship that pending version, or to drop it. A Cancel at Start or a failed Lint
# takes it back (version_undo), or the fix's commit would sit on top of it and
# Preflight would refuse it.

BUMP=none
# The commit this run's bump made, if it made one.
BUMP_COMMIT=""
# BREAKING (asked only with dk_config min_build yes): the release breaks
# older app builds, so the version command's --breaking sets package.json
# minBuild to the new build in the same commit; the app's API serves it, and
# older builds show Update required.
BREAKING=0

# version_read: VERSION, BUILD, TAG from package.json.
version_read() {
  VERSION="$(node -p "require('$ROOT/package.json').version")"
  BUILD="$(node -p "require('$ROOT/package.json').build")"
  TAG="v$VERSION+$BUILD"
}

# tag_exists <tag>: on origin, which is what the release is judged by.
tag_exists() {
  git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1
}

# next_version <bump>: the version a bump would give (build bumps keep it).
next_version() {
  local major minor patch
  IFS=. read -r major minor patch <<<"$VERSION"
  case "$1" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
    *) echo "$VERSION" ;;
  esac
}

# pending_bumps: how many unpushed chore(release) commits HEAD carries over
# origin/main; 0 when anything else is ahead, or when the git checks are off
# (DEPLOY_SKIP_GIT_CHECK), so a drop never resets real work.
pending_bumps() {
  [[ "${DEPLOY_SKIP_GIT_CHECK:-}" == 1 ]] && { echo 0; return 0; }
  local log
  log="$(git -C "$ROOT" log --format=%s origin/main..HEAD)"
  if [[ -z "$log" ]] || command grep -qv '^chore(release): ' <<<"$log"; then
    echo 0
  else
    command grep -c . <<<"$log"
  fi
}

# version_choose: ask which version to ship; sets BUMP, NEXT_VERSION,
# NEXT_BUILD, RELEASED (whether that tag already exists). BUMP is one of:
#   build|patch|minor|major  bump, commit, then tag in Release
#   custom                   the version and build typed in (version_custom),
#                            committed, then tagged in Release
#   none                     ship the current, untagged version and tag it
#   skip                     ship the current version; no tag or release
#   drop                     reset the unpushed bump commits, back to
#                            origin/main's version; no tag or release
# "" and "---" in labels are pick's separators; bumps has "" at the same
# places so PICKED indexes both.
version_choose() {
  version_read
  local released=0 nb=$((BUILD + 1)) pending base_version base_build
  local -a labels bumps
  tag_exists "$TAG" && released=1
  local -a bump_labels=("Build   → $VERSION ($nb)"
    "Patch   → $(next_version patch) ($nb)"
    "Minor   → $(next_version minor) ($nb)"
    "Major   → $(next_version major) ($nb)"
    "Custom  → type a version and build")

  echo
  if ((released)); then
    echo "Current: $VERSION ($BUILD), released as tag $TAG."
    labels=("${bump_labels[@]}" "" "Skip    — keep $VERSION ($BUILD): no bump, no tag or release")
    bumps=(build patch minor major custom "" skip)
  else
    pending="$(pending_bumps)"
    if ((pending > 0)); then
      base_version="$(git -C "$ROOT" show origin/main:package.json | node -p "JSON.parse(require('fs').readFileSync(0)).version")"
      base_build="$(git -C "$ROOT" show origin/main:package.json | node -p "JSON.parse(require('fs').readFileSync(0)).build")"
      echo "Current: $VERSION ($BUILD), pending: an earlier run's unpushed bump from $base_version ($base_build), not released yet."
      labels=("Pending → ship $VERSION ($BUILD), then tag it" --- "${bump_labels[@]}" ""
        "Skip    — drop the pending bump, back to $base_version ($base_build): no tag or release")
      bumps=(none "" build patch minor major custom "" drop)
    else
      echo "Current: $VERSION ($BUILD), not released yet (no tag $TAG)."
      labels=("Current → ship $VERSION ($BUILD), then tag it" --- "${bump_labels[@]}" ""
        "Skip    — ship $VERSION ($BUILD) untagged: no tag or release")
      bumps=(none "" build patch minor major custom "" skip)
    fi
  fi
  echo "Version for this deploy:"
  PROMPT_TITLE="Version for this deploy" pick 0 "${labels[@]}" || die "No version chosen."
  BUMP="${bumps[PICKED]}"
  case "$BUMP" in
    none | skip) NEXT_VERSION=$VERSION NEXT_BUILD=$BUILD RELEASED=$released ;;
    drop)
      NEXT_VERSION=$base_version NEXT_BUILD=$base_build RELEASED=0
      tag_exists "v$base_version+$base_build" && RELEASED=1
      ;;
    custom)
      version_custom
      RELEASED=0
      ;;
    *) NEXT_VERSION="$(next_version "$BUMP")" NEXT_BUILD=$nb RELEASED=0 ;;
  esac
  version_breaking
}

# version_breaking: for a new build, ask whether older builds must update;
# sets BREAKING. Only when API + Infra is ticked: minBuild reaches the API
# only with an apply, and an app-only release can't break older builds
# against an unchanged API.
version_breaking() {
  BREAKING=0
  [[ "$(dk_c min_build no)" == yes ]] || return 0
  ((${DO_INFRA:-1})) || return 0
  case "$BUMP" in none | skip | drop) return 0 ;; esac
  local min
  min="$(node -p "require('$ROOT/package.json').minBuild ?? 0")"
  echo "Yes sets minBuild to $NEXT_BUILD (now $min): older builds show Update required."
  if confirm "Is this release breaking for older builds?"; then BREAKING=1; fi
}

# version_ge <a> <b>: version a is b or later.
version_ge() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  if ((a1 != b1)); then ((a1 > b1)); elif ((a2 != b2)); then ((a2 > b2)); else ((a3 >= b3)); fi
}

# version_custom: ask for a version and build until they are usable; sets
# NEXT_VERSION and NEXT_BUILD. The version is three numbers, not below
# origin/main's; the build is above the current one, and the tag is new.
version_custom() {
  local v b floor
  floor="$(git -C "$ROOT" show origin/main:package.json 2>/dev/null |
    node -p "JSON.parse(require('fs').readFileSync(0)).version" 2>/dev/null)" || floor=$VERSION
  while :; do
    ask_line "Version" "$VERSION" || die "No version chosen."
    v=$ASK_ANSWER
    ask_line "Build" "$((BUILD + 1))" || die "No version chosen."
    b=$ASK_ANSWER
    if [[ ! "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "  The version is three numbers, like 1.2.3."
    elif ! version_ge "$v" "$floor"; then
      echo "  $v is below $floor, the version on origin/main."
    elif [[ ! "$b" =~ ^[0-9]+$ ]] || ((b <= BUILD)); then
      echo "  The build is a whole number above $BUILD."
    elif tag_exists "v$v+$b"; then
      echo "  Tag v$v+$b already exists."
    else
      NEXT_VERSION=$v NEXT_BUILD=$b
      return 0
    fi
  done
}

# version_step: Preflight's Version step: the bump committed, the pending
# one dropped, or the version kept.
version_step() {
  case "$BUMP" in
    none | skip)
      step Version "Version $VERSION ($BUILD), unchanged"
      return 0
      ;;
    drop)
      step Version "Drop the pending bump"
      # Preflight left only chore(release) commits ahead and a clean tree;
      # --keep refuses rather than lose anything else.
      git -C "$ROOT" reset --quiet --keep origin/main
      version_read
      [[ "$VERSION" == "$NEXT_VERSION" && "$BUILD" == "$NEXT_BUILD" ]] ||
        die "origin/main is $VERSION ($BUILD), expected $NEXT_VERSION ($NEXT_BUILD)."
      echo "Back to $VERSION ($BUILD), as on origin/main."
      return 0
      ;;
  esac
  step Version "Bump ($BUMP) and commit, local until Release"
  local -a flags=()
  ((BREAKING)) && flags=(--breaking)
  if [[ "$BUMP" == custom ]]; then
    dk_version_run set "$NEXT_VERSION" "$NEXT_BUILD" ${flags[@]+"${flags[@]}"}
  else
    dk_version_run "$BUMP" ${flags[@]+"${flags[@]}"}
  fi
  version_read
  [[ "$VERSION" == "$NEXT_VERSION" && "$BUILD" == "$NEXT_BUILD" ]] ||
    die "The version command gave $VERSION ($BUILD), expected $NEXT_VERSION ($NEXT_BUILD)."
  if ((BREAKING)) && [[ "$(node -p "require('$ROOT/package.json').minBuild")" != "$NEXT_BUILD" ]]; then
    die "The version command didn't set minBuild to $NEXT_BUILD."
  fi
  # [skip ci]: pushing this commit must not start the Actions deploy.
  # What the version command writes (dk_config version_files; iris's also
  # writes native files).
  # shellcheck disable=SC2046 # a file list
  git -C "$ROOT" add $(dk_c version_files package.json)
  git -C "$ROOT" commit --quiet -m "chore(release): $TAG [skip ci]"
  git -C "$ROOT" --no-pager log --oneline -1
  BUMP_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
}

# version_undo: take back this run's bump, and only that: HEAD must still be
# the commit version_step made. --keep refuses rather than lose anything.
version_undo() {
  [[ -n "$BUMP_COMMIT" && "$(git -C "$ROOT" rev-parse HEAD)" == "$BUMP_COMMIT" ]] || return 0
  if git -C "$ROOT" reset --quiet --keep HEAD~1; then
    echo "Took back the bump to $TAG: it stays unreleased."
  else
    warn "Couldn't take back the bump to $TAG: drop it at the next deploy's version question."
  fi
}

# dk_version_run <bump args>: the kit's version bump (bin/version.mjs, over
# package.json and dk_config version_files), or the app's own command when
# it names one (dk_config version_cmd).
dk_version_run() {
  if [[ -n "$(dk_c version_cmd)" ]]; then
    # shellcheck disable=SC2046 # the command is a command line, split on purpose
    $(dk_c version_cmd) "$@"
  else
    DK_APP_ROOT="$ROOT" node "$DK_ROOT/bin/version.mjs" "$@" --files "$(dk_c version_files package.json)"
  fi
}

# dk_bump_command <build|patch|minor|major> | set <x.y.z> [build] [--force]
# [--breaking]: yarn deploy bump, the version by hand (no commit; yarn deploy
# commits the bump it makes itself).
dk_bump_command() {
  (($# > 0)) || die "usage: yarn deploy bump <build|patch|minor|major> | bump set <x.y.z> [build] [--force] [--breaking]"
  dk_version_run "$@"
}
