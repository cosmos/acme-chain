#!/usr/bin/env bash
set -Eeuo pipefail

# Print failing command with file and line number on error
trap 'rc=$?; echo "Error ($rc) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# Resolve repository root relative to this file
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Core identifiers and paths
BIN="${BIN:-acmed}"

# Chain configuration
CHAIN_DIR="${CHAIN_DIR:-$HOME/.acme}"
CHAIN_ID="${CHAIN_ID:-acme-1}"
KEYRING_BACKEND="${KEYRING_BACKEND:-test}"
MONIKER="${MONIKER:-n0}"
DENOM="${DENOM:-uacme}"
MIN_GAS_PRICES="${MIN_GAS_PRICES:-0.05uacme}"
GAS_ADJUSTMENT="${GAS_ADJUSTMENT:-2}"

APP_TOML="$CHAIN_DIR/config/app.toml"
CFG_TOML="$CHAIN_DIR/config/config.toml"

# Non-interactive mode flag (-y/--yes sets this to 1)
AUTO_YES="${AUTO_YES:-0}"

# Resolve the binary path; if already set, use that, otherwise prefer /root/go/bin then PATH fallback

if [ -z "${BIN_PATH:-}" ]; then
  DEFAULT_BIN_PATH="/root/go/bin/$BIN"
  if [ -x "$DEFAULT_BIN_PATH" ]; then
    BIN_PATH="$DEFAULT_BIN_PATH"
  elif command -v "$BIN" >/dev/null 2>&1; then
    BIN_PATH="$(command -v "$BIN")"
  else
    BIN_PATH="$BIN"
  fi
fi

export REPO_ROOT BIN \
  CHAIN_DIR CHAIN_ID KEYRING_BACKEND MONIKER DENOM MIN_GAS_PRICES \
  AUTO_YES BIN_PATH APP_TOML CFG_TOML

