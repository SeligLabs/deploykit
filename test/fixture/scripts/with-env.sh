#!/usr/bin/env bash
# The fixture's env loader: env/.env under the shell's values.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=(.*)$ ]] || continue
  key="${line%%=*}"; value="${BASH_REMATCH[1]}"
  [[ -n "$value" && -z "${!key+x}" ]] && export "$key=$value"
done <"$ROOT/env/.env"
exec "$@"
