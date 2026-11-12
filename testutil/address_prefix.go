package testutil

import (
	"sync"

	"github.com/cosmos/acme-chain/app/params"

	sdk "github.com/cosmos/cosmos-sdk/types"
)

var once sync.Once

func SafeSetAddressPrefixes() {
	once.Do(func() {
		cfg := sdk.GetConfig()
		cfg.SetBech32PrefixForAccount(params.AccountAddressPrefix, params.AccountPubKeyPrefix)
		cfg.SetBech32PrefixForValidator(params.ValidatorAddressPrefix, params.ValidatorPubKeyPrefix)
		cfg.SetBech32PrefixForConsensusNode(params.ConsNodeAddressPrefix, params.ConsNodePubKeyPrefix)
		cfg.Seal()
	})
}
