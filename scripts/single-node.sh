#!/usr/bin/env bash
set -Eeuo pipefail

# Print failing command with file and line number on error
trap 'rc=$?; echo "Error ($rc) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# USAGE:
# ./single-gen.sh <option of full path to acmed>

# Starts an ACME chain with only a single node. Best used with an acmed bin
# sitting in the same folder as the script, rather than using the one installed.
# Useful for upgrade testing, where two acmed versions can be placed in the
# folder to test.

# Without submitting any governance proposals, it seems acmed 1 and 2 releases
# can just start and continue off the same state back and forth without failing.
# e.g. run this with acmed1, stop acmed1, then run it with acmed2 to continue.

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BIN_PATH="${1:-$ROOT_DIR/build/acmed}"
CHAIN_DIR="$SCRIPT_DIR/node-data"

rm -rf $CHAIN_DIR

source "$SCRIPT_DIR/env-setup.sh"

echo "--- Root dir = $ROOT_DIR"
echo "--- Script dir = $SCRIPT_DIR"
echo "--- Bin path = $BIN_PATH"
echo "--- Chain dir = $CHAIN_DIR"
echo "--- Chain ID = $CHAIN_ID"
echo "--- Chain Dir = $CHAIN_DIR"
echo "--- Coin Denom = $DENOM"

if [ ! -f $BIN_PATH ]; then
  echo "$BIN_PATH does not exists. build it first with $ make build"
  exit 1
fi


echo "--- Bootstrapping genesis via common-genesis.sh..."
BIN_PATH="$BIN_PATH" CHAIN_ID="$CHAIN_ID" KEYRING_BACKEND="test" MONIKER="n0" DENOM="$DENOM" "$SCRIPT_DIR/common-genesis.sh"


LOG_FILE="$CHAIN_DIR/acme.log"


cmd=( $BIN_PATH start
  --home $CHAIN_DIR
  --api.enable true
  --grpc.address="0.0.0.0:9090"
  --api.enabled-unsafe-cors
  --grpc-web.enable=true
  --log_level info
)

echo "--- Starting in background"
"${cmd[@]}" > "$LOG_FILE" 2>&1 &


# Start the instance
echo "--- Starting node..."
echo
echo "Logs:"
echo "  * tail -f $LOG_FILE"
echo
echo "Env for easy access:"
echo "export H1='--home $CHAIN_DIR'"
echo
echo "Command Line Access:"
echo "  * $BIN_PATH --home $CHAIN_DIR status"


# Run common post-genesis actions (create udeposit denom)
CHAIN_DIR="$CHAIN_DIR" BIN_PATH="$BIN_PATH" bash "$SCRIPT_DIR/common-post-genesis-block.sh"

