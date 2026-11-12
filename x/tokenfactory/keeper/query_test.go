package keeper_test

import (
	"testing"

	"github.com/cosmos/acme-chain/x/tokenfactory/keeper"
	"github.com/cosmos/acme-chain/x/tokenfactory/types"
	"github.com/stretchr/testify/require"
)

func TestQuery_DenomAuthorityMetadata(t *testing.T) {
	acmeapp, ctx := setupIntegrationApp(t)
	ms := keeper.NewMsgServer(acmeapp.TokenFactoryKeeper)
	denom := testDenom

	_, err := ms.CreateDenom(ctx, types.NewMsgCreateDenom(creatorAddrA, denom))
	require.NoError(t, err)

	res, err := acmeapp.TokenFactoryKeeper.DenomAuthorityMetadata(ctx, &types.QueryDenomAuthorityMetadataRequest{Denom: denom})
	require.NoError(t, err)
	require.NotNil(t, res)
	require.Equal(t, creatorAddrA, res.AuthorityMetadata.Admin)

	res, err = acmeapp.TokenFactoryKeeper.DenomAuthorityMetadata(ctx, &types.QueryDenomAuthorityMetadataRequest{Denom: "udeposit"})
	require.Error(t, err)
	require.Nil(t, res)
}

func TestQuery_DenomsByCreator(t *testing.T) {
	acmeapp, ctx := setupIntegrationApp(t)
	ms := keeper.NewMsgServer(acmeapp.TokenFactoryKeeper)

	denomA1 := "denom_a1"
	denomA2 := "denom_a2"
	denomB1 := "denom_b1"

	_, err := ms.CreateDenom(ctx, types.NewMsgCreateDenom(creatorAddrA, denomA1))
	require.NoError(t, err)
	_, err = ms.CreateDenom(ctx, types.NewMsgCreateDenom(creatorAddrA, denomA2))
	require.NoError(t, err)
	_, err = ms.CreateDenom(ctx, types.NewMsgCreateDenom(creatorAddrB, denomB1))
	require.NoError(t, err)

	res, err := acmeapp.TokenFactoryKeeper.DenomsByCreator(ctx, &types.QueryDenomsByCreatorRequest{Creator: creatorAddrA})
	require.NoError(t, err)
	require.NotNil(t, res)
	require.Len(t, res.Denoms, 2)
	require.Contains(t, res.Denoms, denomA1)
	require.Contains(t, res.Denoms, denomA2)

	res, err = acmeapp.TokenFactoryKeeper.DenomsByCreator(ctx, &types.QueryDenomsByCreatorRequest{Creator: "acme1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"})
	require.NoError(t, err)
	require.Empty(t, res.Denoms)
}

func TestQueryParams(t *testing.T) {
	acmeapp, ctx := setupIntegrationApp(t)

	params := types.DefaultParams()
	require.NoError(t, acmeapp.TokenFactoryKeeper.SetParams(ctx, params))

	response, err := acmeapp.TokenFactoryKeeper.Params(ctx, &types.QueryParamsRequest{})
	require.NoError(t, err)
	require.Equal(t, params, response.Params)
}
