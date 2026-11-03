#!/usr/bin/env bash
# Publish a built static site to S3 behind CloudFront, for an app's CI (`yarn
# deploykit publish-site ...`): the same sync a deploy's site target does
# (lib/site.sh), without the deploy around it.
#
#   publish-site.sh --out <dir> --bucket <name> [--distribution <id>]
#                   [--immutable <dir>] [--keep "<pattern> ..."] [--build "<command>"]
#
# --build runs first, from the app's root. --immutable defaults to
# _next/static. Values are literal (CI passes its env: --bucket "$WEB_BUCKET").
set -euo pipefail

DK_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd)"
ROOT="${DK_APP_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
die() { printf '\e[1;31m%s\e[0m\n' "$*" >&2; exit 1; }
step() { printf '\e[1m==> %s\e[0m\n' "$2"; }
spinner_label() { :; }
# shellcheck source=../lib/site.sh
source "$DK_ROOT/lib/site.sh"

out="" bucket="" distribution="" immutable="_next/static" keep="" build=""
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || die "publish-site: $1 needs a value."
  case "$1" in
    --out) out=$2 ;;
    --bucket) bucket=$2 ;;
    --distribution) distribution=$2 ;;
    --immutable) immutable=$2 ;;
    --keep) keep=$2 ;;
    --build) build=$2 ;;
    *) die "publish-site: unknown option $1" ;;
  esac
  shift 2
done
[[ -n "$out" && -n "$bucket" ]] || die "usage: publish-site.sh --out <dir> --bucket <name> [--distribution <id>] [--immutable <dir>] [--keep \"<pattern> ...\"] [--build \"<command>\"]"
[[ "$out" == /* ]] || out="$ROOT/$out"
if [[ -n "$build" ]]; then
  (cd "$ROOT" && bash -c "$build") || die "The build failed ($build)."
fi
# --keep's patterns are split, never globbed against the working directory.
read -ra keeps <<<"$keep"
dk_site_sync "$out" "$bucket" "$distribution" "$immutable" ${keeps[@]+"${keeps[@]}"}
echo "✓ Published to s3://$bucket"
