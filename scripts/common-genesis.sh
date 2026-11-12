#!/usr/bin/env bash
set -Eeuo pipefail

# Print failing command with file and line number on error
trap 'rc=$?; echo "Error ($rc) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# Shared genesis/bootstrap for the ACME chain
# - Initializes home, imports keys, adds genesis accounts, patches genesis,
#   generates/collects gentx, and validates genesis.

echo "Starting common genesis setup"

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$SCRIPT_DIR/env-setup.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found in PATH" >&2
  exit 1
fi

# Log binary and version for diagnostics
echo "Using BIN_PATH: $BIN_PATH"
"$BIN_PATH" version || true

CONFIG_JSON="$REPO_ROOT/contrib/config.json"

VAL0_KEY=$(jq -r '.validator_wallet.name' "$CONFIG_JSON")
VAL0_MNEMONIC=$(jq -r '.validator_wallet.mnemonic' "$CONFIG_JSON")
VAL0_ADDRESS=$(jq -r '.validator_wallet.address' "$CONFIG_JSON")

NEWLINE=$'\n'


# Initialize home and moniker
"$BIN_PATH" init "$MONIKER" --home "$CHAIN_DIR" --chain-id $CHAIN_ID --default-denom $DENOM

# Import validator key
printf "%s\n" "$VAL0_MNEMONIC" | "$BIN_PATH" --home "$CHAIN_DIR" keys add "$VAL0_KEY" --keyring-backend $KEYRING_BACKEND --recover

# Amounts
coins_validator="10000000000000000000$DENOM"
coins_user="10000000000000000000$DENOM"
GENTX_AMOUNT="${GENTX_AMOUNT:-1000000000000000000}"

validator_addr="$VAL0_ADDRESS"
if [ -z "$validator_addr" ] || [ "$validator_addr" = "null" ]; then
  validator_addr=$("$BIN_PATH" --home "$CHAIN_DIR" keys show "$VAL0_KEY" -a --keyring-backend $KEYRING_BACKEND)
fi
"$BIN_PATH" --home "$CHAIN_DIR" genesis add-genesis-account "$validator_addr" "$coins_validator"

# Import admin wallet keys and add genesis accounts from config.json
while IFS=$'\t' read -r wallet_name wallet_address wallet_mnemonic; do
  printf "%s\n" "$wallet_mnemonic" | "$BIN_PATH" --home "$CHAIN_DIR" keys add "$wallet_name" --keyring-backend $KEYRING_BACKEND --recover
  echo "Adding admin genesis account for ${wallet_name}: $wallet_address"
  "$BIN_PATH" --home "$CHAIN_DIR" genesis add-genesis-account "$wallet_address" "$coins_user"
done < <(jq -r '.admin_wallets[] | [ .name, .address, .mnemonic ] | @tsv' "$CONFIG_JSON")

# Add user accounts (address-only) from config.json
while IFS=$'\t' read -r name addr; do
  echo "Adding genesis account for ${name:-wallet}: $addr"
  "$BIN_PATH" --home "$CHAIN_DIR" genesis add-genesis-account "$addr" "$coins_user"
done < <(jq -r '.user_accounts[] | [(.name // "wallet"), .address] | @tsv' "$CONFIG_JSON")

# Patch genesis: bond denom and denom metadata
DENOM_METADATA_PATH="$REPO_ROOT/contrib/denom_metadata.json"
GENESIS_PATH="$CHAIN_DIR/config/genesis.json"
TMP_GENESIS="$CHAIN_DIR/config/tmp_genesis.json"

jq --arg denom "$DENOM" --argjson metadata "$(cat "$DENOM_METADATA_PATH")" \
  '.app_state.staking.params.bond_denom = $denom | .app_state.bank.denom_metadata = $metadata' \
  "$GENESIS_PATH" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS_PATH"

# Patch genesis: set IFT module authority to denom_admin
DENOM_ADMIN_ADDR=$(jq -r '.admin_wallets[] | select(.name=="denom_admin") | .address' "$CONFIG_JSON")
jq --arg authority "$DENOM_ADMIN_ADDR" \
  '.app_state.ift.params.authority = $authority' \
  "$GENESIS_PATH" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS_PATH"

# Patch genesis: voting period
sed -i -e 's/"voting_period": "172800s"/"voting_period": "60s"/g' "$GENESIS_PATH"
sed -i -e 's/"expedited_voting_period": "86400s"/"expedited_voting_period": "59s"/g' "$GENESIS_PATH"

# Patch genesis: block size
sed -i -e 's/"max_block_utilization": "30000000"/"max_block_utilization": "500000000"/g' "$GENESIS_PATH"

# Patch genesis: fee denom
sed -i -e 's/"stake"/"$DENOM"/g' "$GENESIS_PATH"

# gentx, collect, validate
"$BIN_PATH" --home "$CHAIN_DIR" genesis gentx "$VAL0_KEY" "${GENTX_AMOUNT}${DENOM}" --keyring-backend $KEYRING_BACKEND --chain-id $CHAIN_ID
"$BIN_PATH" --home "$CHAIN_DIR" genesis collect-gentxs

# Post-gentx validation check: ensure genutil.gen_txs contains at least one tx
if [ "$(jq '.app_state.genutil.gen_txs | length' "$GENESIS_PATH")" -lt 1 ]; then
  echo "ERROR: No gen_txs found in genesis after collect-gentxs. Inspecting gentx dir..." >&2
  ls -lah "$CHAIN_DIR/config/gentx" || true
  echo "First gentx file (if any):" >&2
  first_gentx=$(ls -1 "$CHAIN_DIR/config/gentx" 2>/dev/null | head -n1 || true)
  if [ -n "$first_gentx" ]; then
    cat "$CHAIN_DIR/config/gentx/$first_gentx" || true
  fi
  exit 1
fi

"$BIN_PATH" --home "$CHAIN_DIR" genesis validate

echo "Genesis bootstrap complete at $CHAIN_DIR"

echo "Setting common config options"
# Reduce blocktime to 1 seconds
sed -i -e 's/timeout_commit = "5s"/timeout_commit = "1s"/g' "$CFG_TOML"
sed -i -e 's/minimum-gas-prices = ""/minimum-gas-prices = "0.0025uacme"/' "$APP_TOML"
