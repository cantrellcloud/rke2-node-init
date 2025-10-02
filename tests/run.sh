#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
"$SCRIPT_DIR/vendor/bats-core/bin/bats" "$SCRIPT_DIR" "$@"
