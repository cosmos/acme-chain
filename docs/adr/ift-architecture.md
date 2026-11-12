# ADR: Interchain Fungible Token (IFT) - Cosmos SDK

## Changelog

- 2025-01-13: Initial ADR

## Status

Implemented

## Context

Blockchain developers and asset issuers on Cosmos SDK chains require fungible tokens that can be seamlessly transferred across multiple chains via mint and burn mechanisms. Unlike ICS-20, which is permissionless, IFT provides more control over token supply and behavior on each chain, aligning with regulatory or business requirements.

This document describes the Cosmos SDK implementation of the Interchain Fungible Token (IFT) standard. IFT enables cross-chain token transfers using IBC v2 with the ICS27-GMP protocol, providing a burn-and-mint bridging mechanism where tokens are burned on the source chain and minted on the destination chain.

## Architecture

### Outgoing Transfer (MsgIFTTransfer)

User initiates a cross-chain transfer. Tokens are burned locally and a packet is sent.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ACME CHAIN                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────┐      ┌────────────┐      ┌─────────────┐      ┌───────────┐   │
│  │   User   │─(1)─►│ IFT Module │─(2)─►│TokenFactory │      │ ICS27-GMP │   │
│  └──────────┘      └─────┬──────┘      │  BurnFrom   │      └─────▲─────┘   │
│                          │             └─────────────┘            │         │
│                          │                                        │         │
│                          └───────────────────(3)──────────────────┘         │
│                                        SendPacket                           │
│                                                                             │
│  (1) User submits MsgIFTTransfer                                            │
│  (2) IFT burns tokens from sender                                           │
│  (3) IFT sends cross-chain packet via GMP                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼ IBC Packet
                              COUNTERPARTY CHAIN
```

### Incoming Transfer (Packet received from remote chain)

Remote chain sent a packet. GMP receives it and executes MsgIFTMint.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ACME CHAIN                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────┐      ┌────────────┐      ┌─────────────┐      ┌──────────┐   │
│  │ ICS27-GMP │─(1)─►│ IFT Module │─(2)─►│TokenFactory │─(3)─►│   User   │   │
│  │  Receive  │      │ MsgIFTMint │      │   MintTo    │      │ (tokens) │   │
│  └───────────┘      └────────────┘      └─────────────┘      └──────────┘   │
│                                                                             │
│  (1) GMP receives packet and executes MsgIFTMint                            │
│  (2) IFT validates sender and mints tokens                                  │
│  (3) User receives tokens                                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                       ▲
                                       │ IBC Packet
                              COUNTERPARTY CHAIN
```

#### How GMP Calls the IFT Module

GMP doesn't directly import or call IFT. It uses Cosmos SDK's **MsgServiceRouter** - a central dispatcher that routes any `sdk.Msg` to its registered handler.

```
┌──────────────┐      ┌─────────────┐      ┌──────────────────┐      ┌────────────┐
│ IBC Packet   │─────►│     GMP     │─────►│ MsgServiceRouter │─────►│ IFT Module │
│   arrives    │      │   decodes   │      │     .Invoke()    │      │  IFTMint   │
└──────────────┘      └─────────────┘      └──────────────────┘      └────────────┘
                             │                      │
                             ▼                      ▼
                       MsgIFTMint            type URL lookup:
                                        "/acme.ift.MsgIFTMint"
```

GMP receives the router at initialization (`app.MsgServiceRouter()`), and IFT registers its handlers via `types.RegisterMsgServer()`. This decoupling allows any module to receive messages via GMP without GMP needing to import them.

### Acknowledgment Handling

After counterparty processes the packet, an acknowledgment is returned. The IBC Callbacks Middleware intercepts acks/timeouts and routes them to IFT (see [IBC Callbacks Middleware Integration](#ibc-callbacks-middleware-integration) for details).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ACME CHAIN                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  SUCCESS ACK                                                                │
│  ───────────                                                                │
│  ┌───────────┐      ┌────────────┐                                          │
│  │ Callbacks │─────►│ IFT Module │───► Clear pending transfer (done)        │
│  │ Middleware│      └────────────┘                                          │
│  └───────────┘                                                              │
│                                                                             │
│  ERROR ACK / TIMEOUT                                                        │
│  ───────────────────                                                        │
│  ┌───────────┐      ┌────────────┐      ┌─────────────┐      ┌──────────┐   │
│  │ Callbacks │─(1)─►│ IFT Module │─(2)─►│TokenFactory │─(3)─►│   User   │   │
│  │ Middleware│      │   Refund   │      │   MintTo    │      │ (refund) │   │
│  └───────────┘      └────────────┘      └─────────────┘      └──────────┘   │
│                                                                             │
│  (1) Callbacks middleware routes ack/timeout to IFT                         │
│  (2) IFT mints tokens back to original sender                               │
│  (3) User receives refund                                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Module Dependencies

### Required Modules

| Module           | Purpose                                    |
| ---------------- | ------------------------------------------ |
| **TokenFactory** | Mint and burn tokens for IFT denominations |
| **ICS27-GMP**    | Cross-chain message passing via IBC        |

### Keeper Interfaces

```go
// TokenFactoryKeeper - called by IFT for mint/burn operations
type TokenFactoryKeeper interface {
    MintTo(ctx context.Context, denom string, amount math.Int, to sdk.AccAddress) error
    BurnFrom(ctx context.Context, denom string, amount math.Int, from sdk.AccAddress) error
    HasDenom(ctx context.Context, denom string) bool
}

// GMPKeeper - called by IFT for account lookup
type GMPKeeper interface {
    GetAccount(ctx context.Context, address sdk.AccAddress) (*gmptypes.ICS27Account, error)
}

// IBCClientKeeper - called by IFT to validate client existence
type IBCClientKeeper interface {
    GetClientState(ctx sdk.Context, clientID string) (ibcexported.ClientState, bool)
}
```

## Data Structures

### IFTBridge

Represents a connection between a local token denomination and a counterparty IFT contract.

```protobuf
message IFTBridge {
  // The IBC client identifier on the local chain representing the counterparty chain
  string client_id = 1;
  // The address of the IFT contract on the counterparty chain
  string counterparty_ift_address = 2;
  // The identifier of the IFTSendCall constructor (e.g., "evm" or "cosmos")
  string ift_send_call_constructor = 3;
}
```

**Key Design Decision**: Bridges are keyed by `(denom, client_id)`, allowing a single denomination to have bridges to multiple counterparty chains.

### PendingTransfer

Tracks in-flight transfers for refund handling.

```protobuf
message PendingTransfer {
  string denom = 1;
  string client_id = 2;
  uint64 sequence = 3;
  string sender = 4;
  string amount = 5;
}
```

**Storage**: Uses dual indexing for efficient lookup:

- Primary: `(denom, client_id, sequence)` → PendingTransfer
- Secondary: `(client_id, sequence)` → denom (for callback lookup)

The secondary index is conflict-free because IBC sequences are unique per client.

### Params

Module configuration storing the authority address that can register/remove bridges.

```protobuf
message Params {
  string authority = 1;
}
```

## Messages

### MsgRegisterIFTBridge

Registers a new bridge for cross-chain transfers. Only callable by authority.

```protobuf
message MsgRegisterIFTBridge {
  string signer = 1;                    // Must be authority
  string denom = 2;                     // Token factory denom
  string client_id = 3;                 // IBC client ID
  string counterparty_ift_address = 4;  // Counterparty IFT address
  string ift_send_call_constructor = 5; // "evm" or "cosmos"
}
```

**Validations**:

- Signer must be authority
- Denom must exist in TokenFactory
- IBC client must exist
- Bridge must not already exist
- Constructor type must be valid
- Counterparty address format validated per constructor

### MsgRemoveIFTBridge

Removes an existing bridge. Only callable by authority.

```protobuf
message MsgRemoveIFTBridge {
  string signer = 1;
  string denom = 2;
  string client_id = 3;
}
```

**Validations**:

- Signer must be authority
- Bridge must exist
- No pending transfers for this bridge

### MsgIFTTransfer

Initiates a cross-chain token transfer.

```protobuf
message MsgIFTTransfer {
  string signer = 1;
  string denom = 2;
  string client_id = 3;
  string receiver = 4;
  string amount = 5;
  uint64 timeout_timestamp = 6;  // Unix seconds
}
```

**Flow**:

```
1. Validate inputs
2. Validate timeout > block time
3. Get bridge for (denom, client_id)
4. Validate receiver address format (via constructor)
5. Burn tokens from sender (TokenFactory.BurnFrom)
6. Construct mint call payload (via constructor)
7. Send GMP call (ICS27-GMP.SendCall)
8. Store pending transfer with sequence
9. Emit events (including GMP events for relayer)
```

### MsgIFTMint

Mints tokens in response to incoming cross-chain transfer. Only callable by ICS27-GMP accounts.

```protobuf
message MsgIFTMint {
  string signer = 1;   // ICS27-GMP account address
  string denom = 2;
  string receiver = 3;
  string amount = 4;
}
```

**Security Validations**:

```
1. Denom must exist in TokenFactory
2. Signer must be an ICS27-GMP account (reverse lookup via GMPKeeper)
3. Bridge must exist for (denom, account.client_id)
4. Account's sender must match bridge's counterparty_ift_address
5. Account must have no salt (prevents address spoofing)
```

## Constructors

Constructors define how mint call payloads are formatted for different target chains.

### Interface

```go
type Constructor interface {
    Type() string
    ValidateCounterpartyAddress(address string) error
    ValidateReceiverAddress(address string) error
    ConstructMintCall(cdc codec.BinaryCodec, receiver string, amount math.Int,
                      denom string, icaAddress string) ([]byte, error)
}
```

### EVM Constructor

For Ethereum/EVM-based counterparty chains.

```go
const ConstructorEVM = "evm"

// Payload format: ABI-encoded function call
// iftMint(address receiver, uint256 amount)
func (EVMConstructor) ConstructMintCall(...) ([]byte, error) {
    return abi.encode(IFT_MINT_SELECTOR, receiver, amount)
}
```

**Address Validation**:

- Must be valid hex with 0x prefix
- Must be 20 bytes (40 hex chars)
- Cannot be zero address

### Cosmos Constructor

For Cosmos SDK-based counterparty chains.

```go
const ConstructorCosmos = "cosmos"

// Payload format: Protobuf-encoded CosmosTx
func (CosmosTxConstructor) ConstructMintCall(...) ([]byte, error) {
    msg := &MsgIFTMint{
        Signer:   icaAddress,
        Denom:    denom,
        Receiver: receiver,
        Amount:   amount,
    }
    return gmptypes.SerializeCosmosTx(cdc, []proto.Message{msg})
}
```

**Address Validation**:

- Receiver must be valid bech32 address
- Counterparty address must be non-empty

## IBC Callbacks Middleware Integration

IFT uses the IBC Callbacks v2 middleware to receive packet acknowledgements and timeouts.

### How Callback Routing Works

IFT is registered as the **ContractKeeper** for GMP in app wiring. This means IFT receives callbacks for **all** GMP packets, not just its own. The callback handler must filter which packets to process.

```
SENDING A PACKET
────────────────

┌────────────┐                    ┌───────────┐
│ IFT Module │───── SendCall ────►│ ICS27-GMP │
└────────────┘                    └─────┬─────┘
                                        │
                                        ▼
                              Packet includes:
                              - payload (mint call)
                              - sender = IFT module address  ◄── Key!


RECEIVING AN ACK/TIMEOUT
────────────────────────

┌──────────┐      ┌───────────┐      ┌────────────┐
│ IBC Core │─────►│ Callbacks │─────►│ IFT Module │  (always)
└──────────┘      │ Middleware│      └─────┬──────┘
                  └───────────┘            │
                                           │
                  Middleware passes:       │
                  - contractAddress        │
                  - packetSenderAddress    │
                  (both derived from       │
                   packet's sender field)  │
                                           ▼
                              ┌─────────────────────────────────────┐
                              │ IFT validates:                      │
                              │   contractAddress == IFT module?    │
                              │   packetSenderAddress == IFT module?│
                              │                                     │
                              │   NO  → return nil (not our packet) │
                              │   YES → check pending transfer      │
                              └─────────────────────────────────────┘
```

**Key insight**: The callbacks middleware derives the callback recipient from the packet's sender field. IFT receives all GMP callbacks but only processes packets where IFT was the original sender.

### ContractKeeper Implementation

IFT implements `callbacktypes.ContractKeeper`:

```go
type ContractKeeper interface {
    IBCSendPacketCallback(...)                    // No-op for IFT
    IBCOnAcknowledgementPacketCallback(...)       // Handle ack
    IBCOnTimeoutPacketCallback(...)               // Handle timeout
    IBCReceivePacketCallback(...)                 // No-op for IFT
}
```

### GMP as Stateless Transport

GMP is a stateless transport - its `OnAcknowledgementPacket` and `OnTimeoutPacket` return `nil`. The IBC Callbacks Middleware intercepts acks/timeouts and routes them to the registered ContractKeeper (IFT) before GMP sees them.

**The limitation: One ContractKeeper per middleware instance**

The callbacks middleware only supports one ContractKeeper (see [App Wiring](#app-wiring)). IFT receives callbacks for ALL GMP packets and must filter to process only its own.

### Callback Filtering

IFT validates that the packet was sent by itself (checks `contractAddr`, `packetSender`, `version`, `sourcePort`). Non-IFT packets return `nil` to avoid interfering with other GMP applications.

### Acknowledgement Handling

```go
func (k Keeper) IBCOnAcknowledgementPacketCallback(ctx, packet, ack, ...) error {
    // 1. Check if this callback belongs to IFT
    if err := k.checkIsIFTCallback(...); err != nil {
        return nil  // Not our packet, let other apps handle it
    }

    // 2. Lookup pending transfer by (client_id, sequence)
    pending, found := k.GetPendingTransferByClientSequence(ctx, packet.SourceChannel, packet.Sequence)
    if !found {
        return nil  // Not an IFT transfer - ignore
    }

    // 3. Check if error ack (sentinel hash comparison)
    isErrorAck := bytes.Equal(ack, channeltypesv2.ErrorAcknowledgement[:])

    // 4. Handle based on ack type
    if isErrorAck {
        return k.RefundPendingTransfer(ctx, pending.Denom, pending.ClientId, pending.Sequence)
    }

    // 5. Success - remove pending transfer
    k.RemovePendingTransfer(ctx, pending.Denom, pending.ClientId, pending.Sequence)
    emit(IFTTransferCompleted)
    return nil
}
```

### Timeout Handling

```go
func (k Keeper) IBCOnTimeoutPacketCallback(ctx, packet, ...) error {
    // 1. Validate callback
    // 2. Lookup pending transfer
    // 3. Refund sender
    return k.RefundPendingTransfer(ctx, pending.Denom, pending.ClientId, pending.Sequence)
}
```

### Refund Logic

```go
func (k Keeper) RefundPendingTransfer(ctx, denom, clientID string, sequence uint64) error {
    pending := k.GetPendingTransfer(ctx, denom, clientID, sequence)
    sender := sdk.AccAddressFromBech32(pending.Sender)

    // Remove first (checks-effects-interactions)
    k.RemovePendingTransfer(ctx, denom, clientID, sequence)

    // Mint tokens back to sender
    k.tokenFactoryKeeper.MintTo(ctx, pending.Denom, pending.Amount, sender)

    emit(IFTTransferRefunded)
    return nil
}
```

## Event Propagation

### Critical: GMP Event Propagation

When IFT sends a transfer, it must propagate GMP events for the relayer:

```go
// In MsgIFTTransfer handler
res, err := handler(ctx, sendMsg)  // Execute GMP.SendCall

// CRITICAL: Propagate GMP events
ctx.EventManager().EmitEvents(res.GetEvents())
```

Without this, the relayer won't see the `send_packet` event.

### Event Flow

```
MsgIFTTransfer
    │
    ├─► IFT emits: ift_transfer_initiated
    │
    ▼
GMP.SendCall (via MsgRouter)
    │
    ├─► GMP emits: send_call, send_packet
    │
    ▼
IFT propagates GMP events
    │
    └─► Relayer detects send_packet event
```

### IFT Events

| Event                    | Attributes                                           | When                                 |
| ------------------------ | ---------------------------------------------------- | ------------------------------------ |
| `ift_bridge_registered`  | denom, client_id, counterparty_address, constructor  | Bridge registered                    |
| `ift_bridge_removed`     | denom, client_id                                     | Bridge removed                       |
| `ift_transfer_initiated` | denom, client_id, sequence, sender, receiver, amount | Transfer started                     |
| `ift_transfer_completed` | denom, client_id, sequence, sender, amount           | Success ack received                 |
| `ift_transfer_refunded`  | denom, client_id, sequence, sender, amount           | Error ack or timeout                 |
| `ift_mint_received`      | denom, client_id, receiver, amount                   | Tokens minted from incoming transfer |
| `ift_callback_failed`    | callback_type, client_id, sequence, error            | Callback validation failed           |

## Queries

| Query               | Parameters                 | Description                      |
| ------------------- | -------------------------- | -------------------------------- |
| `ICS27GMP`          | -                          | Returns ICS27-GMP module address |
| `IFTBridge`         | denom, client_id           | Get specific bridge              |
| `IFTBridges`        | -                          | List all bridges                 |
| `IFTBridgesByDenom` | denom                      | List bridges for a denom         |
| `PendingTransfer`   | denom, client_id, sequence | Get pending transfer             |
| `Params`            | -                          | Get module parameters            |

## State Layout

| Prefix | Key                              | Value                   |
| ------ | -------------------------------- | ----------------------- |
| `0`    | -                                | Params                  |
| `1`    | `{denom}/{client_id}`            | IFTBridge               |
| `2`    | `{denom}/{client_id}/{sequence}` | PendingTransfer         |
| `3`    | `{client_id}/{sequence}`         | denom (secondary index) |

## TokenFactory Integration

### Dual Access Model

TokenFactory provides two access paths:

```
┌──────────────────────────────────────────────────────────────────┐
│                      TokenFactory                                │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Admin Path (Messages)          Module Path (Keeper)            │
│   ─────────────────────          ───────────────────             │
│   MsgMint    → admin check       MintTo    → no admin check      │
│   MsgBurn    → admin check       BurnFrom  → no admin check      │
│                                                                  │
│   Used by: External users        Used by: IFT module             │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Why This Design?

1. **IFT doesn't need admin authority** - It uses keeper methods directly
2. **Denom admin retains control** - Can still mint/burn via messages
3. **Optional admin renounce** - Admin can renounce to make IFT the only minter

### Typical Setup

```
1. Admin creates denom via MsgCreateDenom
2. Authority registers IFT bridge for denom
3. Cross-chain transfers flow through IFT
4. (Optional) Admin renounces to lock down direct minting
```

## App Wiring

### In app.go

```go
// 1. Create IFT keeper
app.IFTKeeper = iftkeeper.NewKeeper(
    appCodec,
    runtime.NewKVStoreService(keys[ifttypes.StoreKey]),
    authtypes.NewModuleAddress(govtypes.ModuleName).String(),
    app.TokenFactoryKeeper,
    app.GMPKeeper,
    app.IBCKeeper.ClientKeeper,
    app.MsgServiceRouter(),
)

// 2. Register GMP with callbacks middleware
const maxCallbackGas = uint64(1_000_000)
cbGMPModule := ibccallbacksv2.NewIBCMiddleware(
    gmp.NewIBCModule(app.GMPKeeper),
    app.IBCKeeper.ChannelKeeperV2,
    &app.IFTKeeper,              // ContractKeeper implementation
    app.IBCKeeper.ChannelKeeperV2,
    maxCallbackGas,
)

// 3. Register route
ibcRouterV2.AddRoute(gmptypes.PortID, cbGMPModule)
```

## Key Design Choices

### 1. Separate IFT Module vs TokenFactory Extension

The spec allows IFT handlers to be implemented either in a separate module or within TokenFactory itself. We chose a **separate IFT module**.

**Why?**

- Clear separation of concerns: TokenFactory manages denom lifecycle, IFT handles bridging
- TokenFactory remains generic and reusable for non-IFT use cases
- Easier to audit and reason about bridge-specific logic
- Can upgrade IFT independently of TokenFactory

### 2. Dual Indexing for Pending Transfers

We store pending transfers with two indexes:

- Primary: `(denom, client_id, sequence)` → PendingTransfer
- Secondary: `(client_id, sequence)` → denom

**Why?**

- Callbacks only provide `(client_id, sequence)` - no denom
- Without secondary index, we'd need to iterate all denoms to find the transfer
- Trades storage for O(1) callback lookup

### 3. Protobuf for Cosmos Constructor Payloads

The Cosmos constructor uses protobuf-encoded `CosmosTx` rather than JSON (as shown in spec appendix).

**Why?**

- Matches GMP's native payload format
- More efficient encoding
- Type-safe serialization via `SerializeCosmosTx`

## Alternatives Considered

### 1. Implementing IFT within TokenFactory

**Approach**: Add IFT handlers directly to TokenFactory module.

**Rejected because**:

- Bloats TokenFactory with bridging concerns
- Makes TokenFactory dependent on GMP
- Harder to disable/upgrade bridging independently

### 2. GMP Handling Callbacks Internally

**Current situation**: GMP is a stateless transport. Its `OnAcknowledgementPacket` and `OnTimeoutPacket` handlers simply return `nil`:

```go
func (m IBCModule) OnAcknowledgementPacket(ctx, packet, ack, relayer) error {
    return nil  // GMP doesn't track state - nothing to do
}
```

GMP doesn't know what applications sent packets through it, so it can't route callbacks.

**Alternative approach**: GMP could maintain a registry of callback handlers:

```go
type GMPKeeper struct {
    callbackHandlers map[string]CallbackHandler  // sender address → handler
}

func (k GMPKeeper) RegisterCallbackHandler(sender string, handler CallbackHandler)

func (m IBCModule) OnAcknowledgementPacket(ctx, packet, ...) error {
    handler, found := k.callbackHandlers[packet.Sender]
    if found {
        return handler.OnAck(ctx, packet, ack)
    }
    return nil
}
```

**Rejected because**:

- Adds state and complexity to GMP (no longer stateless)
- Registration requires GMP to import handler interfaces
- IBC Callbacks middleware already provides this functionality
- Would duplicate existing infrastructure

### 3. Router ContractKeeper for Callback Dispatch

**Approach**: Instead of IFT being the ContractKeeper directly, create a router that dispatches callbacks to different handlers based on packet sender:

```go
type CallbackRouter struct {
    handlers map[string]callbacktypes.ContractKeeper  // sender address → keeper
}

func (r CallbackRouter) IBCOnAcknowledgementPacketCallback(ctx, packet, ack, packetSenderAddress, ...) error {
    handler, found := r.handlers[packetSenderAddress]
    if !found {
        return nil
    }
    return handler.IBCOnAcknowledgementPacketCallback(ctx, packet, ack, ...)
}
```

**Not implemented because**:

- Only IFT needs GMP callbacks currently - no other applications exist yet
- Adds infrastructure complexity for a single use case
- Filtering in IFT is simple and sufficient
- Can add router later if needed (backward compatible)

## Trade-offs

| Decision            | Benefit                                | Cost                               |
| ------------------- | -------------------------------------- | ---------------------------------- |
| Separate IFT module | Clean separation, independent upgrades | Additional module to maintain      |
| Dual indexing       | O(1) callback lookup                   | 2x storage for pending transfers   |
| Protobuf payloads   | Efficient, type-safe                   | Different from spec's JSON example |

## Security Assumptions

### 1. TokenFactory Keeper Access

Only IFT module has access to TokenFactory's `MintTo`/`BurnFrom` keeper methods. Other modules cannot arbitrarily mint IFT tokens.

**Enforcement**: Keeper is only passed to IFT at app initialization.

### 2. MsgServiceRouter Integrity

Messages routed via MsgServiceRouter execute with correct signer context. A compromised router could spoof signers.

**Enforcement**: Using standard Cosmos SDK infrastructure; well-audited.

### 3. Callback Address Derivation

IBC Callbacks middleware correctly derives `contractAddress` and `packetSenderAddress` from packet data. IFT trusts these values for filtering.

**Enforcement**: Validate multiple fields (address, version, port) to reduce attack surface.

### 4. Secondary Index Consistency

The secondary index `(client_id, sequence) → denom` must stay synchronized with primary storage. Inconsistency could cause refund failures.

**Enforcement**: Both indexes updated atomically in same transaction.

### 5. GMP Account Salt Validation

IFT validates that GMP accounts have empty salt to prevent address spoofing via salt manipulation.

**Enforcement**: Explicit `salt == ""` check in MsgIFTMint handler.

## Authorization Model

### Current State

IFT and TokenFactory use different authorization models:

| Module       | Model                | Who Controls                  |
| ------------ | -------------------- | ----------------------------- |
| TokenFactory | Per-denom admin      | Denom creator (can transfer)  |
| IFT          | Global authority     | Governance module             |

**TokenFactory**: Each denom has an admin who can mint/burn via messages. The admin can transfer control or renounce it. IFT bypasses admin checks using keeper methods directly.

**IFT**: A single governance address controls all bridge operations (register/remove). Transfers are permissionless (users burn their own tokens).

### Trade-offs

| Aspect               | Benefit                                    | Cost                                        |
| -------------------- | ------------------------------------------ | ------------------------------------------- |
| Global authority     | All bridges reviewed by governance         | Denom admin cannot manage their own bridges |
| Governance proposals | Security review before bridge changes      | Slower operational response                 |
| Single authority     | Simple implementation                      | Centralized control point                   |

### Alternative: Per-Denom Bridge Control

An alternative would let denom admins manage bridges for their tokens, with governance as fallback. This would align IFT authorization with TokenFactory but adds complexity and requires trusting individual admins.

**Status**: Not implemented. The current model is sufficient for initial deployment.

## Known Limitations

### 1. Single ContractKeeper Per Middleware Instance

IBC Callbacks middleware only supports one ContractKeeper per middleware stack. IFT is registered as the ContractKeeper for GMP, so it receives all GMP callbacks and must filter to process only its own packets.

**Future work**: If other GMP applications need callbacks, implement a Router ContractKeeper (see Alternatives Considered).

### 2. Callback Validation Returns Nil on Mismatch

When IFT receives a callback for a non-IFT packet, it returns `nil` rather than error. This means:

- No indication to middleware that callback wasn't handled
- Other applications can't receive the same callback

**Rationale**: Returning error would fail the entire IBC flow; returning nil is safe.

### 3. Query Pagination Not Implemented

The `IFTBridges` and `IFTBridgesByDenom` queries do not support pagination. They return all results in a single response.

**Impact**: May cause performance issues if many bridges are registered.

**Future work**: Add pagination support using `cosmos.base.query.v1beta1.PageRequest` if needed.
