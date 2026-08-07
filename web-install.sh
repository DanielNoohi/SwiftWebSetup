#!/usr/bin/env bash
# Compatibility wrapper — prefer host-install.sh.
# Kept so existing docs/CI/one-liners that call web-install.sh keep working.
set -euo pipefail
_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${_ROOT}/host-install.sh" "$@"
