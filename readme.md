# acme-chain

[![Go Version](https://img.shields.io/badge/go-1.25-blue.svg)](https://golang.org/)
[![Lint](https://github.com/cosmos/acme-chain/workflows/Lint/badge.svg)](https://github.com/cosmos/acme-chain/actions/workflows/lint.yml)
[![Test](https://github.com/cosmos/acme-chain/workflows/Test/badge.svg)](https://github.com/cosmos/acme-chain/actions/workflows/test.yml)

**acme-chain** is a generic Cosmos SDK / CometBFT blockchain intended for CI and local development.
It wires in IBC (v1 and v2), ICS-20, ICS-27 GMP, the 08-wasm light client, and two custom modules:
`x/tokenfactory` and `x/ift` (interchain fungible token bridging).

| Item            | Value             |
|-----------------|-------------------|
| Binary          | `acmed`           |
| Default home    | `~/.acme`         |
| Chain ID        | `acme-1`          |
| Bech32 prefix   | `acme`            |
| Gas/bond denom  | `uacme`           |
| Example token   | `udeposit` (created via tokenfactory after genesis) |

> All keys and mnemonics in `contrib/config.json` are for local testing only. Never use them on a real network.

## Development setup

Requirements: Go 1.25+, `make`, `jq`, `curl`.

```bash
make build            # builds ./build/acmed
make test-unit        # runs unit tests
make single-node      # starts a local single-node chain in the background
make kill-single-node # stops it
```

`make single-node` initializes a fresh chain in `scripts/node-data`, funds the validator and test wallets from
`contrib/config.json` with `uacme`, then creates the `udeposit` tokenfactory denom and mints it to the `denom_admin` wallet.

### IBC counterparties (optional)

`contrib/config.json` has an empty `counterparty_chains` object by default. To have the post-genesis script create
attestation light clients and register IFT bridges, add entries of the form:

```json
"counterparty_chains": {
  "ethereum": {
    "rpc_address": "<EVM JSON-RPC URL>",
    "client_id": "<client id of this chain on the counterparty>",
    "contract_address": "<IFT contract address on the counterparty>",
    "attestor_config": { "attestor_addresses": ["0x..."], "min_required_sigs": 1 }
  }
}
```

To update wasm clients, modify the files in `contrib/wasm` and run `scripts/generate-client-states.sh <chain>`.

### Docker

```bash
make docker-build     # builds acme-chain:local
```

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
