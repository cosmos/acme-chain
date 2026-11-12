package keeper_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/cosmos/acme-chain/app"
	"github.com/cosmos/acme-chain/testutil"
	"github.com/cosmos/acme-chain/x/tokenfactory/types"
	dbm "github.com/cosmos/cosmos-db"
	"github.com/stretchr/testify/require"

	"cosmossdk.io/log"
	"cosmossdk.io/math"

	"github.com/cosmos/cosmos-sdk/baseapp"
	"github.com/cosmos/cosmos-sdk/runtime"
	simtestutil "github.com/cosmos/cosmos-sdk/testutil/sims"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/cosmos/cosmos-sdk/types/module"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	consensusparamkeeper "github.com/cosmos/cosmos-sdk/x/consensus/keeper"
	consensusparamtypes "github.com/cosmos/cosmos-sdk/x/consensus/types"

	cmtabcitypes "github.com/cometbft/cometbft/abci/types"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
)

const (
	// Addresses
	creatorAddrA   = "acme1nsh9vj9znccakn6xwlhlwx92acdt79yeyutjs7"
	creatorAddrB   = "acme1uu635yk0hz3cvrypnryrggltrjq7975j8yycqy"
	invalidAddress = "invalid"

	// Token denoms
	testDenom        = "testtoken"
	nonExistentDenom = "doesnotexist"
	invalidDenom     = "not-so-alphanumeric"
)

func setupIntegrationApp(tb testing.TB) (*app.App, sdk.Context) {
	tb.Helper()
	// Ensure bech32 prefixes match acme* test addresses
	testutil.SafeSetAddressPrefixes()

	db := dbm.NewMemDB()
	acmeapp := app.New(log.NewNopLogger(), db, nil, false, simtestutil.NewAppOptionsWithFlagHome(tb.TempDir()), baseapp.SetChainID("acme-chain-id"))
	acmeapp.SetInitChainer(func(ctx sdk.Context, _ *cmtabcitypes.RequestInitChain) (*cmtabcitypes.ResponseInitChain, error) {
		for _, mod := range acmeapp.ModuleManager.OrderInitGenesis {
			if m, ok := acmeapp.ModuleManager.Modules[mod].(module.HasGenesis); ok {
				m.InitGenesis(ctx, acmeapp.AppCodec(), m.DefaultGenesis(acmeapp.AppCodec()))
			}
		}

		return &cmtabcitypes.ResponseInitChain{}, nil
	})

	// set baseApp param store
	consensusParamsKeeper := consensusparamkeeper.NewKeeper(acmeapp.AppCodec(), runtime.NewKVStoreService(acmeapp.GetKey(consensusparamtypes.StoreKey)), authtypes.NewModuleAddress("gov").String(), runtime.EventService{})
	acmeapp.SetParamStore(consensusParamsKeeper.ParamsStore)

	if err := acmeapp.LoadLatestVersion(); err != nil {
		panic(fmt.Errorf("failed to load application version from store: %w", err))
	}

	_, err := acmeapp.InitChain(&cmtabcitypes.RequestInitChain{ChainId: acmeapp.ChainID(), ConsensusParams: simtestutil.DefaultConsensusParams})
	require.NoError(tb, err)

	// use deliver-state context backed by BaseApp finalizeBlockState
	ctx := acmeapp.NewContext(false)
	ctx = ctx.WithBlockHeader(cmtproto.Header{ChainID: acmeapp.ChainID(), Time: time.Now(), Height: 1})

	// Ensure module params exist (not strictly necessary if queries don’t touch them)
	require.NoError(tb, acmeapp.TokenFactoryKeeper.SetParams(ctx, types.DefaultParams()))

	return acmeapp, ctx
}

// TestKeeper_MintTo tests the MintTo function directly
func TestKeeper_MintTo(t *testing.T) {
	acmeapp, ctx := setupIntegrationApp(t)

	creator, err := sdk.AccAddressFromBech32(creatorAddrA)
	require.NoError(t, err)

	recipient, err := sdk.AccAddressFromBech32(creatorAddrB)
	require.NoError(t, err)

	// Create denom first
	err = acmeapp.TokenFactoryKeeper.CreateDenom(ctx, creatorAddrA, testDenom)
	require.NoError(t, err)

	t.Run("successful mint", func(t *testing.T) {
		amount := math.NewInt(1000000)
		err := acmeapp.TokenFactoryKeeper.MintTo(ctx, testDenom, amount, recipient)
		require.NoError(t, err)

		// Verify balance
		balance := acmeapp.BankKeeper.GetBalance(ctx, recipient, testDenom)
		require.True(t, balance.Amount.Equal(amount))
	})

	t.Run("mint more tokens", func(t *testing.T) {
		amount := math.NewInt(500000)
		err := acmeapp.TokenFactoryKeeper.MintTo(ctx, testDenom, amount, creator)
		require.NoError(t, err)

		// Verify balance
		balance := acmeapp.BankKeeper.GetBalance(ctx, creator, testDenom)
		require.True(t, balance.Amount.Equal(amount))
	})

	t.Run("invalid denom format", func(t *testing.T) {
		amount := math.NewInt(1000)
		err := acmeapp.TokenFactoryKeeper.MintTo(ctx, invalidDenom, amount, recipient)
		require.Error(t, err)
		require.ErrorIs(t, err, types.ErrInvalidDenom)
	})

	t.Run("empty denom", func(t *testing.T) {
		amount := math.NewInt(1000)
		err := acmeapp.TokenFactoryKeeper.MintTo(ctx, "", amount, recipient)
		require.Error(t, err)
	})
}

// TestKeeper_BurnFrom tests the BurnFrom function directly
func TestKeeper_BurnFrom(t *testing.T) {
	acmeapp, ctx := setupIntegrationApp(t)

	holder, err := sdk.AccAddressFromBech32(creatorAddrA)
	require.NoError(t, err)

	// Create denom and mint some tokens first
	err = acmeapp.TokenFactoryKeeper.CreateDenom(ctx, creatorAddrA, testDenom)
	require.NoError(t, err)

	mintAmount := math.NewInt(1000000)
	err = acmeapp.TokenFactoryKeeper.MintTo(ctx, testDenom, mintAmount, holder)
	require.NoError(t, err)

	t.Run("successful burn", func(t *testing.T) {
		burnAmount := math.NewInt(400000)
		err := acmeapp.TokenFactoryKeeper.BurnFrom(ctx, testDenom, burnAmount, holder)
		require.NoError(t, err)

		// Verify balance decreased
		balance := acmeapp.BankKeeper.GetBalance(ctx, holder, testDenom)
		expected := mintAmount.Sub(burnAmount)
		require.True(t, balance.Amount.Equal(expected))
	})

	t.Run("burn remaining balance", func(t *testing.T) {
		balance := acmeapp.BankKeeper.GetBalance(ctx, holder, testDenom)
		err := acmeapp.TokenFactoryKeeper.BurnFrom(ctx, testDenom, balance.Amount, holder)
		require.NoError(t, err)

		// Verify balance is zero
		newBalance := acmeapp.BankKeeper.GetBalance(ctx, holder, testDenom)
		require.True(t, newBalance.Amount.IsZero())
	})

	t.Run("insufficient balance", func(t *testing.T) {
		burnAmount := math.NewInt(1000)
		err := acmeapp.TokenFactoryKeeper.BurnFrom(ctx, testDenom, burnAmount, holder)
		require.Error(t, err)
	})

	t.Run("invalid denom format", func(t *testing.T) {
		burnAmount := math.NewInt(1000)
		err := acmeapp.TokenFactoryKeeper.BurnFrom(ctx, invalidDenom, burnAmount, holder)
		require.Error(t, err)
		require.ErrorIs(t, err, types.ErrInvalidDenom)
	})
}

// TestKeeper_HasDenom tests the HasDenom function
func TestKeeper_HasDenom(t *testing.T) {
	acmeapp, ctx := setupIntegrationApp(t)

	t.Run("denom does not exist", func(t *testing.T) {
		exists := acmeapp.TokenFactoryKeeper.HasDenom(ctx, testDenom)
		require.False(t, exists)
	})

	t.Run("denom exists after creation", func(t *testing.T) {
		err := acmeapp.TokenFactoryKeeper.CreateDenom(ctx, creatorAddrA, testDenom)
		require.NoError(t, err)

		exists := acmeapp.TokenFactoryKeeper.HasDenom(ctx, testDenom)
		require.True(t, exists)
	})

	t.Run("invalid denom format returns false", func(t *testing.T) {
		exists := acmeapp.TokenFactoryKeeper.HasDenom(ctx, invalidDenom)
		require.False(t, exists)
	})

	t.Run("empty denom returns false", func(t *testing.T) {
		exists := acmeapp.TokenFactoryKeeper.HasDenom(ctx, "")
		require.False(t, exists)
	})

	t.Run("non-existent valid denom returns false", func(t *testing.T) {
		exists := acmeapp.TokenFactoryKeeper.HasDenom(ctx, nonExistentDenom)
		require.False(t, exists)
	})
}
