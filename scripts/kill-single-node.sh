#!/bin/bash
set -Eeuo pipefail

# Print failing command with file and line number on error
trap 'rc=$?; echo "Error ($rc) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$SCRIPT_DIR/env-setup.sh"

# Kill any process that is running the acmed binary
pkill -9 $BIN