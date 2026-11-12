# ACME Chain Architecture

This document describes the high-level architecture of ACME Chain, including its IBC integrations, RPC endpoints, and local operation instructions.

## Architecture Overview

```
        ┌──────────────────────────────────────────────────────────────────┐
        │                        Client Applications                       │
        └──────────────────────────────┬───────────────────────────────────┘
                                       │
                    ┌──────────────────┴─────────────────┐
                    │                                    │
            ┌───────▼────────┐                   ┌───────▼────────┐
            │   REST API     │                   │     gRPC       │
            │  (Port 1317)   │                   │  (Port 9090)   │
            └────────────────┘                   └────────────────┘
                    │                                    │
                    └──────────────────┬─────────────────┘
                                       │
        ┌──────────────────────────────┼───────────────────────────────────┐
        │                      ACME Chain Node                             │
        ├──────────────────────────────┬───────────────────────────────────┤
        │  TokenFactory Module         │         IBC Stack                 │
        │  ┌─────────────────────┐     │   ┌──────────────────────────┐    │
        │  │ • Create Denoms     │     │   │   Light Clients          │    │
        │  │ • Mint/Burn         │     │   │   ┌────────────────────┐ │    │
        │  │ • Bridging          │     │   │   │ 07-tendermint      │ │    │
        │  └─────────────────────┘     │   │   │ 08-wasm (with VM)  │ │    │
        │                              │   │   └────────────────────┘ │    │
        │  Standard Cosmos Modules     │   │                          │    │
        │  ┌─────────────────────┐     │   │   IBC Applications       │    │
        │  │ • Auth/Bank         │     │   │   ┌────────────────────┐ │    │
        │  │ • Staking/Slashing  │     │   │   │ ICS-20 Transfer    │ │    │
        │  │ • Gov/Upgrade       │     │   │   │ ICS-20 Transfer v2 │ │    │
        │  │ • Distribution      │     │   │   │ ICS-27 GMP         │ │    │
        │  └─────────────────────┘     │   │   └────────────────────┘ │    │
        │                              │   └──────────────────────────┘    │
        ├──────────────────────────────────────────────────────────────────┤
        │                    Cosmos SDK Base App                           │
        ├──────────────────────────────────────────────────────────────────┤
        │                     CometBFT Consensus                           │
        │                      (Port 26657)                                │
        └──────────────────────────────┬───────────────────────────────────┘
                                       │
                      ┌────────────────┴─────────────────┐
                      │    Cross-Chain Network           │
                      │   (Other IBC Chains)             │
                      └──────────────────────────────────┘
```

## IBC Integrations

ACME Chain is built on the Cosmos SDK and integrates IBC core and apps. The following IBC components are wired in the application:

### Core Routing
- IBC Keeper with both IBC v1 and IBC v2 router
- IBC v1 applications/ports: ICS-20 transfer
- RouterV2 routes: ICS-20 transfer v2, ICS-27 GMP

### Light Clients
- **07-tendermint light client**: Standard Tendermint consensus light client
- **08-wasm light client**: WASM-based light client with embedded VM and custom query plugin that allows `/cosmos.base.tendermint.v1beta1.Service/ABCIQuery` via Stargate

### IBC Applications
- **ICS-20 Token Transfer**: Cross-chain token transfers
  - Legacy transfer module registered on legacy router
  - Transfer v2 module registered on RouterV2 under standard transfer port
- **ICS-27 GMP (General Message Passing)**: Cross-chain message passing
  - Registered on RouterV2 under ICS-27 GMP port

### Custom Modules
- **TokenFactory Module**: Denom creation, minting, burning, and bridging
  - Not an IBC app module itself, but integrates with the GMP IBC application to send cross-chain contract calls (currently used for mint/burn transfers, but can easily be extended to perform admin controls on remote contracts)


## Operation

See the instructions in the repo readme for how to build and run locally.
