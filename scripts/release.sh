#!/usr/bin/env bash
# Release deploykit: check, version, commit, tag, push, GitHub release.
#
#   bash scripts/release.sh                 the version in package.json, when it isn't tagged yet
#   bash scripts/release.sh patch|minor|major|<x.y.z>
#   bash scripts/release.sh --dry-run [...] every check and what would happen; changes nothing
#
# In order, stopping at the first problem:
#   1. on main, clean, level with origin/main
#   2. the version: package.json's untagged one, or the bump asked for
#   3. CHANGELOG.md has its entry: a "## <version>" or "## <version> (unreleased)"
#      heading, or "## Unreleased", which becomes "## <version> (<date>)"
#   4. the checks: gofmt, go vet and go test in tui/, shellcheck, test/run.sh
#   5. a commit "Release v<version>" (package.json and CHANGELOG.md), shown,
#      then one [y/n] before anything leaves the machine
#   6. tag v<version>, push main and the tag, a GitHub release with the
#      CHANGELOG entry as its notes
#
# A major release must also raise DK_API in deploykit.sh (CONTRACT.md): this
# stops if a major bump leaves it as it was. Runs on macOS's bash 3.2.

set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT"

die() { printf '\e[1;31m%s\e[0m\n' "$*" >&2; exit 1; }
say() { printf '\e[1m==> %s\e[0m\n' "$*"; }

DRY=0
if [[ "${1:-}" == --dry-run ]]; then
  DRY=1
  shift
fi
ASK="${1:-}"

# 1. Git.
say "Git"
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "Not on main."
[[ -z "$(git status --porcelain)" ]] || die "Uncommitted files: commit or stash them first."
git fetch --quiet --tags origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] ||
  die "main isn't level with origin/main: push or pull first."

# 2. The version.
current="$(node -p "require('./package.json').version")"
IFS=. read -r major minor patch <<<"$current"
case "$ASK" in
  "")
    git rev-parse -q --verify "refs/tags/v$current" >/dev/null &&
      die "v$current is already tagged: say patch, minor, major or a version."
    next=$current
    ;;
  patch) next="$major.$minor.$((patch + 1))" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  major) next="$((major + 1)).0.0" ;;
  *)
    [[ "$ASK" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Not a version: $ASK (patch, minor, major or x.y.z)."
    next=$ASK
    ;;
esac
git rev-parse -q --verify "refs/tags/v$next" >/dev/null && die "v$next is already tagged."
echo "Releasing v$next (package.json has $current)."
if [[ "${next%%.*}" != "$major" && "$current" != "$next" ]]; then
  api_now="$(sed -n 's/^DK_API=//p' deploykit.sh)"
  api_tagged="$(git show "v$current:deploykit.sh" 2>/dev/null | sed -n 's/^DK_API=//p')"
  [[ -z "$api_tagged" || "$api_now" != "$api_tagged" ]] ||
    die "A major release changes the contract: raise DK_API in deploykit.sh (now $api_now) and say how to move in CHANGELOG.md."
fi

# 3. The changelog entry.
say "CHANGELOG.md"
if grep -qE "^## $next( \(unreleased\))?$" CHANGELOG.md; then
  heading="$(grep -E "^## $next( \(unreleased\))?$" CHANGELOG.md | head -n 1)"
elif grep -qE '^## Unreleased$' CHANGELOG.md; then
  heading="## Unreleased"
else
  die "CHANGELOG.md has no entry for $next: add a '## Unreleased' (or '## $next') section with what changed."
fi
notes="$(awk -v h="$heading" '$0 == h {on = 1; next} on && /^## / {exit} on' CHANGELOG.md | sed -e '/./,$!d')"
[[ -n "${notes//[[:space:]]/}" ]] || die "The CHANGELOG entry for $next is empty."
printf '%s\n' "$notes" | sed 's/^/  │ /'

# 4. The checks.
say "Checks"
(
  cd tui
  test -z "$(gofmt -l .)" || {
    echo "Files need gofmt:"
    gofmt -l .
    exit 1
  }
  go vet ./...
  go test ./...
) || die "The deploy UI's checks failed."
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -S warning deploykit.sh lib/*.sh stages/*.sh drivers/*.sh bin/*.sh bin/deploykit scripts/*.sh test/run.sh test/stubs/* ||
    die "shellcheck failed."
else
  echo "shellcheck isn't installed: skipped here (CI runs it)."
fi
bash test/run.sh || die "The scenarios failed."

if ((DRY)); then
  say "Dry run: would commit 'Release v$next', tag v$next, push main and the tag, and create the GitHub release."
  exit 0
fi

# 5. The release commit, then the one question.
say "Commit"
node -e '
  const fs = require("fs");
  const p = JSON.parse(fs.readFileSync("package.json", "utf8"));
  p.version = process.argv[1];
  fs.writeFileSync("package.json", JSON.stringify(p, null, 2) + "\n");
' "$next"
today="$(date +%F)"
awk -v h="$heading" -v n="## $next ($today)" '$0 == h && !done {print n; done = 1; next} {print}' CHANGELOG.md >CHANGELOG.md.tmp
mv CHANGELOG.md.tmp CHANGELOG.md
git add package.json CHANGELOG.md
git commit -q -m "Release v$next"
git --no-pager log --oneline -1
echo
echo "Next: tag v$next, push main and the tag to origin ($(git remote get-url origin)), and create the GitHub release."
read -r -p "Push the release? [y/n] " answer || answer=n
case "$answer" in
  y | Y | yes | YES) ;;
  *)
    git reset -q --keep HEAD~1
    die "Not released. The release commit is taken back; nothing left the machine."
    ;;
esac

# 6. Out.
say "Tag, push, GitHub release"
git tag -a "v$next" -m "deploykit v$next"
git push -q origin main "refs/tags/v$next"
gh release create "v$next" --verify-tag --title "deploykit v$next" --notes "$notes"
echo
echo "Released v$next. In each app: \"@seliglabs/deploykit\": \"github:SeligLabs/deploykit#v$next\", then yarn install."
