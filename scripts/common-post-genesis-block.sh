#!/usr/bin/env bash
set -Eeuo pipefail

# Print failing command with file and line number on error
trap 'rc=$?; echo "Error ($rc) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# Post-genesis actions to run after the node is up and producing blocks.
# - Waits for RPC and first block
# - Creates tokenfactory denom "udeposit" using the denom_admin from config.json
# - Mints 100000 udeposit to denom_admin (idempotent)

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$SCRIPT_DIR/env-setup.sh"

CHAIN_HOME="${CHAIN_HOME:-$CHAIN_DIR}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found in PATH" >&2
  exit 1
fi

RPC_URL="${RPC_URL:-http://127.0.0.1:26657/status}"
DENOM_TO_CREATE="udeposit"

CONFIG_JSON="$REPO_ROOT/contrib/config.json"

# Extract denom_admin details from config.json
DENOM_ADMIN_NAME=$(jq -r '.admin_wallets[] | select(.name=="denom_admin") | .name' "$CONFIG_JSON")
DENOM_ADMIN_ADDR=$(jq -r '.admin_wallets[] | select(.name=="denom_admin") | .address' "$CONFIG_JSON")

if [ -z "${DENOM_ADMIN_NAME:-}" ] || [ "$DENOM_ADMIN_NAME" = "null" ]; then
  echo "denom_admin entry not found in $CONFIG_JSON" >&2
  exit 1
fi

if [ -z "${DENOM_ADMIN_ADDR:-}" ] || [ "$DENOM_ADMIN_ADDR" = "null" ]; then
  # Fallback to keyring lookup if address missing in file
  DENOM_ADMIN_ADDR=$("$BIN_PATH" --home "$CHAIN_HOME" keys show "$DENOM_ADMIN_NAME" -a --keyring-backend "$KEYRING_BACKEND")
fi

echo "Waiting for RPC at $RPC_URL ..."
for i in $(seq 1 60); do
  if curl -sf "$RPC_URL" >/dev/null; then
    break
  fi
  sleep 1
done

STATUS_JSON=$(curl -sf "$RPC_URL")
if [ -z "$STATUS_JSON" ]; then
  echo "RPC not reachable at $RPC_URL" >&2
  exit 1
fi

echo "Waiting for first block..."
for i in $(seq 1 120); do
  height=$(echo "$STATUS_JSON" | jq -r '.result.sync_info.latest_block_height' 2>/dev/null || echo "0")
  if [ "${height:-0}" -ge 1 ]; then
    break
  fi
  sleep 1
  STATUS_JSON=$(curl -sf "$RPC_URL" || echo "")
done

# Idempotency: check if the denom already exists for the creator
echo "Creating denom $DENOM_TO_CREATE using --from $DENOM_ADMIN_NAME ..."
"$BIN_PATH" --home "$CHAIN_HOME" tx tokenfactory create-denom "$DENOM_TO_CREATE" \
  --from "$DENOM_ADMIN_NAME" \
  --keyring-backend "$KEYRING_BACKEND" \
  --chain-id "$CHAIN_ID" \
  --yes \
  --gas auto \
  --gas-adjustment "$GAS_ADJUSTMENT" \
  --gas-prices "$MIN_GAS_PRICES"

 echo "Created denom $DENOM_TO_CREATE. Verifying..."
 sleep 2
 "$BIN_PATH" --home "$CHAIN_HOME" query tokenfactory denoms-by-creator "$DENOM_ADMIN_ADDR"

# Mint 1000000000000 udeposit to denom_admin
echo "Minting $DENOM_ADMIN_ADDR using --from $DENOM_ADMIN_NAME ..."
"$BIN_PATH" tx tokenfactory mint "$DENOM_ADMIN_ADDR" 1000000000000"$DENOM_TO_CREATE" \
  --home "$CHAIN_HOME" \
  --from "$DENOM_ADMIN_NAME" \
  --keyring-backend "$KEYRING_BACKEND" \
  --chain-id "$CHAIN_ID" \
  --yes \
  --gas auto \
  --gas-adjustment "$GAS_ADJUSTMENT" \
  --gas-prices "$MIN_GAS_PRICES"
sleep 2

# Distribute udeposit to user accounts
USER_ACCOUNTS=$(jq -r '.user_accounts[] | .address' "$CONFIG_JSON")
for USER_ACCOUNT in $USER_ACCOUNTS; do
  "$BIN_PATH" tx bank send "$DENOM_ADMIN_NAME" "$USER_ACCOUNT" 10000000000"$DENOM_TO_CREATE" \
    --home "$CHAIN_HOME" \
    --from "$DENOM_ADMIN_NAME" \
    --keyring-backend "$KEYRING_BACKEND" \
    --chain-id "$CHAIN_ID" \
    --yes \
    --gas auto \
    --gas-adjustment "$GAS_ADJUSTMENT" \
    --gas-prices "$MIN_GAS_PRICES"
  sleep 2
done

# Optional: create attestation light clients and register IFT bridges for each
# counterparty chain configured under .counterparty_chains in config.json.
# With an empty .counterparty_chains object (the default), this is skipped.
COUNTERPARTY_CHAINS=$(jq -r '(.counterparty_chains // {}) | keys_unsorted[]' "$CONFIG_JSON")
if [ -z "$COUNTERPARTY_CHAINS" ]; then
  echo "No counterparty chains configured in $CONFIG_JSON; skipping IBC client and bridge setup."
  echo "Post-genesis actions complete."
  exit 0
fi

CLIENT_INDEX=0
for COUNTERPARTY in $COUNTERPARTY_CHAINS; do
  CLIENT_ID="attestations-$CLIENT_INDEX"
  CLIENT_INDEX=$((CLIENT_INDEX + 1))

  COUNTERPARTY_CLIENT_ID=$(jq -r --arg c "$COUNTERPARTY" '.counterparty_chains[$c].client_id // empty' "$CONFIG_JSON")
  REMOTE_CONTRACT_ADDRESS=$(jq -r --arg c "$COUNTERPARTY" '.counterparty_chains[$c].contract_address // empty' "$CONFIG_JSON")
  if [ -z "$COUNTERPARTY_CLIENT_ID" ] || [ -z "$REMOTE_CONTRACT_ADDRESS" ]; then
    echo "counterparty_chains.$COUNTERPARTY must define client_id and contract_address in $CONFIG_JSON" >&2
    exit 1
  fi

  echo "Generating attestation client state for $COUNTERPARTY..."
  "$SCRIPT_DIR/generate-client-states.sh" "$COUNTERPARTY"

  "$BIN_PATH" tx ibc client create "contrib/wasm/${COUNTERPARTY}_attestation_client_state.json" "contrib/wasm/${COUNTERPARTY}_attestation_consensus_state.json" \
    --home "$CHAIN_HOME" \
    --from "$DENOM_ADMIN_NAME" \
    --keyring-backend "$KEYRING_BACKEND" \
    --chain-id "$CHAIN_ID" \
    --yes \
    --gas auto \
    --gas-adjustment "$GAS_ADJUSTMENT" \
    --gas-prices "$MIN_GAS_PRICES"
  sleep 2

  "$BIN_PATH" tx ibc client add-counterparty "$CLIENT_ID" "$COUNTERPARTY_CLIENT_ID" "" \
    --from "$DENOM_ADMIN_NAME" \
    --home "$CHAIN_HOME" \
    --keyring-backend "$KEYRING_BACKEND" \
    --chain-id "$CHAIN_ID" \
    --yes \
    --gas auto \
    --gas-adjustment "$GAS_ADJUSTMENT" \
    --gas-prices "$MIN_GAS_PRICES"
  sleep 2

  "$BIN_PATH" tx ift register-bridge "$DENOM_TO_CREATE" "$CLIENT_ID" "$REMOTE_CONTRACT_ADDRESS" "evm" \
    --from "$DENOM_ADMIN_NAME" \
    --home "$CHAIN_HOME" \
    --keyring-backend "$KEYRING_BACKEND" \
    --chain-id "$CHAIN_ID" \
    --yes \
    --gas auto \
    --gas-adjustment "$GAS_ADJUSTMENT" \
    --gas-prices "$MIN_GAS_PRICES"
  sleep 2
done

echo "Post-genesis actions complete."
