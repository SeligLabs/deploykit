# shellcheck shell=bash
# deploykit: the shared deploy engine. An app's scripts/deploy/deploy.sh
# sources this, declares its groups, targets, config and hooks, and calls
# dk_main "$@" (CONTRACT.md):
#
#   DK="${DEPLOYKIT_DEV:-$(dirname "$0")/../../node_modules/@seliglabs/deploykit}"
#   source "$DK/deploykit.sh"
#   dk_config api 1 ...
#   dk_group mobile "Mobile"
#   dk_target mobile ios --driver fastlane ...
#   dk_main "$@"
#
# DEPLOYKIT_DEV=../deploykit points an app at a working copy of the kit.
# Runs on macOS's bash 3.2.

set -euo pipefail

DK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DK_API=1
DK_VERSION="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$DK_ROOT/package.json" | head -n 1)"
# The app's deploy.sh, which dk_main runs again under the env loader and the
# deploy UI, and the app's root (its git checkout).
DK_CALLER="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)/$(basename "${BASH_SOURCE[1]}")"
ROOT="$(git -C "$(dirname "$DK_CALLER")" rev-parse --show-toplevel)"

# shellcheck source=lib/env.sh
source "$DK_ROOT/lib/env.sh"
# shellcheck source=lib/tracker.sh
source "$DK_ROOT/lib/tracker.sh"
# shellcheck source=lib/prompt.sh
source "$DK_ROOT/lib/prompt.sh"
# shellcheck source=lib/secrets.sh
source "$DK_ROOT/lib/secrets.sh"
# shellcheck source=lib/site.sh
source "$DK_ROOT/lib/site.sh"
# shellcheck source=lib/outputs.sh
source "$DK_ROOT/lib/outputs.sh"
# shellcheck source=lib/settings.sh
source "$DK_ROOT/lib/settings.sh"
# shellcheck source=lib/targets.sh
source "$DK_ROOT/lib/targets.sh"
# shellcheck source=lib/engine.sh
source "$DK_ROOT/lib/engine.sh"
# shellcheck source=stages/preflight.sh
source "$DK_ROOT/stages/preflight.sh"
# shellcheck source=stages/version.sh
source "$DK_ROOT/stages/version.sh"
# shellcheck source=stages/notes.sh
source "$DK_ROOT/stages/notes.sh"
# shellcheck source=stages/lint.sh
source "$DK_ROOT/stages/lint.sh"
# shellcheck source=stages/infra.sh
source "$DK_ROOT/stages/infra.sh"
# shellcheck source=stages/release.sh
source "$DK_ROOT/stages/release.sh"
# shellcheck source=drivers/site.sh
source "$DK_ROOT/drivers/site.sh"
# shellcheck source=drivers/fastlane.sh
source "$DK_ROOT/drivers/fastlane.sh"
# shellcheck source=drivers/fn.sh
source "$DK_ROOT/drivers/fn.sh"
