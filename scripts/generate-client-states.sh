#!/usr/bin/env bash
set -Eeuo pipefail

# Print failing command with file and line number on error
trap 'rc=$?; echo "Error ($rc) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

###############################################################################
# Expected formats (for reference)
#
# light_client_creation_states.json
# {
#   "client_state": {
#     "attestor_addresses": ["0x...", ...],
#     "min_required_sigs": 1,
#     "latest_height": 0,
#     "is_frozen": false
#   },
#   "consensus_state": {
#     "timestamp": 0
#   }
# }
#
# attestation_client_state.json
# {
#   "@type": "/ibc.lightclients.attestations.v1.ClientState",
#   "attestor_addresses": ["0x...", ...],
#   "min_required_sigs": 1,
#   "latest_height": "0",
#   "is_frozen": false
# }
#
# attestation_consensus_state.json
# {
#   "@type": "/ibc.lightclients.attestations.v1.ConsensusState",
#   "timestamp": "0"
# }
###############################################################################

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG_JSON=${CONFIG_JSON:-"$REPO_ROOT/contrib/config.json"}
WASM_DIR="$REPO_ROOT/contrib/wasm"


# Input: counterparty chain name (must match key under counterparty_chains in config)
if [ "${1:-}" = "" ]; then
  echo "Usage: $(basename "$0") <counterparty_chain_name>" >&2
  echo "Example: $(basename "$0") base" >&2
  exit 1
fi
CHAIN_NAME="$1"

CREATION_JSON="$WASM_DIR/${CHAIN_NAME}_light_client_creation_states.json"
CLIENT_JSON="$WASM_DIR/${CHAIN_NAME}_attestation_client_state.json"
CONS_JSON="$WASM_DIR/${CHAIN_NAME}_attestation_consensus_state.json"

# Read attestor addresses
ATTESTOR_CONFIG_JSON=$(jq --arg chain "$CHAIN_NAME" '.counterparty_chains[$chain].attestor_config' "$CONFIG_JSON")
ATTESTOR_ADDRESSES_JSON=$(echo "$ATTESTOR_CONFIG_JSON" | jq '.attestor_addresses')
MIN_REQUIRED_SIGS=$(echo "$ATTESTOR_CONFIG_JSON" | jq '.min_required_sigs')

if [ ! -f "$CONFIG_JSON" ]; then
  echo "Config not found: $CONFIG_JSON" >&2
  exit 1
fi

# Determine Ethereum RPC URL from chain-specific config
ETH_RPC=$(jq -r --arg chain "$CHAIN_NAME" '.counterparty_chains[$chain].rpc_address // empty' "$CONFIG_JSON")

if [ -z "$ETH_RPC" ] || [ "$ETH_RPC" = "null" ]; then
  echo "Error: Ethereum RPC address not found in $CONFIG_JSON under counterparty_chains.$CHAIN_NAME.rpc_address." >&2
  exit 1
fi

echo "Querying latest Ethereum block from: $ETH_RPC"
RESP=$(curl -sS -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest", false],"id":1}' \
  "$ETH_RPC")
if [ -z "$RESP" ]; then
  echo "Empty response from Ethereum RPC" >&2
  exit 1
fi
ERR_MSG=$(echo "$RESP" | jq -r '.error.message // empty')
if [ -n "$ERR_MSG" ]; then
  echo "Ethereum RPC error: $ERR_MSG" >&2
  echo "$RESP" >&2
  exit 1
fi
NUMBER_HEX=$(echo "$RESP" | jq -r '.result.number')
TS_HEX=$(echo "$RESP" | jq -r '.result.timestamp')
if [ -z "$NUMBER_HEX" ] || [ "$NUMBER_HEX" = "null" ] || [ -z "$TS_HEX" ] || [ "$TS_HEX" = "null" ]; then
  echo "Malformed block response: missing number/timestamp" >&2
  echo "$RESP" >&2
  exit 1
fi
BLOCK_NUMBER=$((16#${NUMBER_HEX#0x}))
BLOCK_TIMESTAMP=$((16#${TS_HEX#0x}))
BLOCK_TIMESTAMP_NS=$((BLOCK_TIMESTAMP * 1000000000))
echo "Latest block: height=$BLOCK_NUMBER timestamp=$BLOCK_TIMESTAMP"

# Build client_state JSON
CLIENT_STATE_JSON=$(jq -n \
  --argjson addrs "$ATTESTOR_ADDRESSES_JSON" \
  --argjson min_required_sigs "$MIN_REQUIRED_SIGS" \
  --argjson latest_height "$BLOCK_NUMBER" \
  '{attestor_addresses: $addrs, min_required_sigs: $min_required_sigs, latest_height: $latest_height, is_frozen: false}')

# Build consensus_state JSON
CONSENSUS_STATE_JSON=$(jq -n \
  --argjson timestamp "$BLOCK_TIMESTAMP_NS" \
  '{timestamp: $timestamp}')

# Write light_client_creation_states.json
mkdir -p "$WASM_DIR"
jq -n --argjson client_state "$CLIENT_STATE_JSON" --argjson consensus_state "$CONSENSUS_STATE_JSON" \
  '{client_state: $client_state, consensus_state: $consensus_state}' | jq '.' > "$CREATION_JSON"
echo "Wrote $CREATION_JSON"

# Prepare attestation_client_state.json
jq -n \
  --arg type "/ibc.lightclients.attestations.v1.ClientState" \
  --argjson addrs "$ATTESTOR_ADDRESSES_JSON" \
  --argjson min_required_sigs "$MIN_REQUIRED_SIGS" \
  --arg latest_height "${BLOCK_NUMBER}" \
  '{"@type": $type, attestor_addresses: $addrs, min_required_sigs: $min_required_sigs, latest_height: $latest_height, is_frozen: false}' \
  | jq '.' > "$CLIENT_JSON"
echo "Wrote $CLIENT_JSON"

# Prepare attestation_consensus_state.json
jq -n \
  --arg type "/ibc.lightclients.attestations.v1.ConsensusState" \
  --arg timestamp "${BLOCK_TIMESTAMP_NS}" \
  '{"@type": $type, timestamp: $timestamp}' \
  | jq '.' > "$CONS_JSON"
echo "Wrote $CONS_JSON"

echo "Done."
