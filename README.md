# TartSwap Public Contracts

Source code of the TartSwap protocol contracts, published for public verification.

## Transparency Notes

- Contract addresses are published for public verification.
- Users can inspect balances, transactions, read methods and write methods through BscScan.
- Private keys, deployment secrets, admin environment variables and backend service keys are never stored in this public repository.
- Official contract verification should be checked directly on BscScan.

## Repository Layout

| Directory | Contents |
|---|---|
| `contracts/dex/` | DEX core: swap router, fee distributor, fee converter, staking vault, LP farm, reward auto allocator |
| `contracts/dex/tartswap-v2/` | TartSwap V2 AMM: factory, pair, router, LP ERC20, interfaces and libraries |
| `contracts/games/` | Fast Games: parimutuel round arena, game fee splitter, testnet pUSDT faucet |
| `contracts/governance/` | Weekly buyback vote, stake adapter, buyback distributor |
| `contracts/interfaces/` | Shared interfaces |

## DEX Contracts — BNB Smart Chain Mainnet (Chain ID 56)

| Contract | Address | Purpose |
|---|---|---|
| Protocol Owner Safe (2/3 multisig) | [`0x91772cEc686C619b9a09ecAD4Ed1863d7DE62fBE`](https://bscscan.com/address/0x91772cEc686C619b9a09ecAD4Ed1863d7DE62fBE) | Protocol owner / admin multisig |
| Ecosystem Token | [`0xeb2B7d5691878627eff20492cA7c9a71228d931D`](https://bscscan.com/address/0xeb2B7d5691878627eff20492cA7c9a71228d931D) | Crepe |
| Tart Router V2 | [`0xBd9Ab53ebfb53F4436c829E881B5e560868D840F`](https://bscscan.com/address/0xBd9Ab53ebfb53F4436c829E881B5e560868D840F) | Swap routing and protocol fee collection (`TartSwapRouterV2.sol`) |
| Fee Distributor V2 | [`0xdf0aC48105BbC66EBe2976b03097A87Bb80744c1`](https://bscscan.com/address/0xdf0aC48105BbC66EBe2976b03097A87Bb80744c1) | Protocol fee distribution (`TartFeeDistributor.sol`) |
| Fee Converter V2 | [`0xDeA32774f6d8d2170192275C23Aec2f3bc1492Bd`](https://bscscan.com/address/0xDeA32774f6d8d2170192275C23Aec2f3bc1492Bd) | Fee conversion contract (`TartFeeConverterV2.sol`) |
| Tart Staking Vault | [`0x20940d3573F1629F6c5226C2DDa2e9a28b364B33`](https://bscscan.com/address/0x20940d3573F1629F6c5226C2DDa2e9a28b364B33) | Staking vault (`TartStakingVault.sol`) |
| LP Farm V3 | [`0x4f6Eb30a521E5F5FDE2BD433cDc805962902F316`](https://bscscan.com/address/0x4f6Eb30a521E5F5FDE2BD433cDc805962902F316) | LP farming contract (`TartLPFarmV3.sol`) |
| Reward Auto Allocator | [`0x7465fF319E6B8Df81ccdE90479D989DA5E7f83Eb`](https://bscscan.com/address/0x7465fF319E6B8Df81ccdE90479D989DA5E7f83Eb) | Reward allocation automation (`TartRewardAutoAllocator.sol`) |
| Reward Vault | [`0x1f4Dbc1c8556E5B1200d3cef250c87658AcAb760`](https://bscscan.com/address/0x1f4Dbc1c8556E5B1200d3cef250c87658AcAb760) | Reward custody / vault |
| Fee Collector | [`0xfa261c02b023b8a01F4Fc25Cca658757ddA48521`](https://bscscan.com/address/0xfa261c02b023b8a01F4Fc25Cca658757ddA48521) | Protocol fee receiver |
| Token Registry | [`0xE216adfA6C8eCD094f17dF9cdf3ce0b476925538`](https://bscscan.com/address/0xE216adfA6C8eCD094f17dF9cdf3ce0b476925538) | Token registry |
| Farm Registry | [`0x7c125816207AECfa2011eA28c71A6B2BB0D43f23`](https://bscscan.com/address/0x7c125816207AECfa2011eA28c71A6B2BB0D43f23) | Farm registry |

## Games & Governance — BNB Smart Chain Testnet (Chain ID 97)

Live on BSC Testnet today; mainnet deployment follows after audit.

| Contract | Address | Purpose |
|---|---|---|
| FastRoundArena | [`0x46ae0d1eE576dfC2679F24eb2c70abC21a7C98f9`](https://testnet.bscscan.com/address/0x46ae0d1eE576dfC2679F24eb2c70abC21a7C98f9) | Parimutuel fast-round games (`FastRoundArena.sol`) |
| Game Fee Splitter | [`0x22D710dc241958727140ec336136930132f3BC40`](https://testnet.bscscan.com/address/0x22D710dc241958727140ec336136930132f3BC40) | Arena fee sink: treasury / buyback split (`GameFeeSplitter.sol`) |
| WeeklyBuybackVote | [`0xb2281B548C7f40b7A2EeDd34f171293B6Da11706`](https://testnet.bscscan.com/address/0xb2281B548C7f40b7A2EeDd34f171293B6Da11706) | Weekly buyback governance vote (`WeeklyBuybackVote.sol`) |
| BuybackDistributor | [`0xC9c25196c24653D30b5432fcb84F1b72D38adecd`](https://testnet.bscscan.com/address/0xC9c25196c24653D30b5432fcb84F1b72D38adecd) | Buyback execution and distribution (`BuybackDistributor.sol`) |
| Test USDT (pUSDT) | [`0xc69F045446e96D0a275b72486eEA773d087532d4`](https://testnet.bscscan.com/address/0xc69F045446e96D0a275b72486eEA773d087532d4) | Testnet collateral token |
| pUSDT Faucet | [`0xbD0D20A344D1e66d5e1107AE050a78e7D07569bE`](https://testnet.bscscan.com/address/0xbD0D20A344D1e66d5e1107AE050a78e7D07569bE) | Testnet token faucet (`PredictionTestUSDTFaucet.sol`) |

## External / Utility Contracts (Mainnet)

| Contract | Address | Purpose |
|---|---|---|
| PancakeSwap V2 Router | [`0x10ED43C718714eb63d5aA57B78B54704E256024E`](https://bscscan.com/address/0x10ED43C718714eb63d5aA57B78B54704E256024E) | External DEX router |
| WBNB | [`0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`](https://bscscan.com/address/0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) | Wrapped BNB |
| USDT | [`0x55d398326f99059fF775485246999027B3197955`](https://bscscan.com/address/0x55d398326f99059fF775485246999027B3197955) | Tether USD |
| USDC | [`0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d`](https://bscscan.com/address/0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d) | USD Coin |

## Treasury / Reserve

| Wallet | Address | Purpose |
|---|---|---|
| Treasury Wallet | [`0x043Ee47649A5C46Af488B499E48362803806d339`](https://bscscan.com/address/0x043Ee47649A5C46Af488B499E48362803806d339) | Treasury operations |
| Reserve Wallet | [`0x64BC8aC9F92a2526AA2AEb7c19005368955d9945`](https://bscscan.com/address/0x64BC8aC9F92a2526AA2AEb7c19005368955d9945) | Reserve operations |

## Security

Found a vulnerability? Please report it privately per our [Security Policy](SECURITY.md) — do not open a public issue. Private keys, deployment secrets and backend service keys are never stored in this repository.

