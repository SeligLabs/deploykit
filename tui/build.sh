#!/usr/bin/env bash
# Builds the deploy UI (this folder) once per change to its source, into
# ~/.cache/<APP_SLUG>/deploy-tui/, and prints the binary's path. The engine runs it
# before handing the terminal to the UI; any failure here means the deploy
# runs with its plain output instead, so it never stops a release.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v go >/dev/null 2>&1 || { echo "go isn't on PATH" >&2; exit 1; }

hash="$(cd "$here" && cat go.mod go.sum ./*.go | shasum | cut -c1-16)"
# APP_SLUG from the engine, else the app.slug of the package.json at the
# root of the checkout it runs in.
slug="${APP_SLUG:-$(node -p "require('$(git rev-parse --show-toplevel 2>/dev/null || pwd)/package.json').app.slug || 'app'" 2>/dev/null || echo app)}"
dir="${XDG_CACHE_HOME:-$HOME/.cache}/$slug/deploy-tui"
bin="$dir/deploy-tui-$hash"

if [[ ! -x "$bin" ]]; then
  mkdir -p "$dir"
  echo "Building the deploy UI (once per change to deploykit's tui/)…" >&2
  (cd "$here" && go build -trimpath -o "$bin.tmp" .) >&2
  mv -f "$bin.tmp" "$bin"
  # Earlier builds.
  find "$dir" -name 'deploy-tui-*' ! -name "$(basename "$bin")" -delete 2>/dev/null || true
fi
echo "$bin"
