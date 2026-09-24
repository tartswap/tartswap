# TartSwap — protocol contracts on BNB Chain

Source code of the TartSwap protocol contracts, published for public verification: the **TART** token and its
launch stack, the DEX (swap router, fee split, staking vaults, LP farms), the OTC desk, the games engine and
governance. Every mainnet contract below is source-verified on BscScan; this repository mirrors the verified
sources so they can be read, diffed and audited in one place.

- Website: https://tartswap.com · Token page: https://tartswap.com/token
- Whitepaper: https://tartswap.com/whitepaper.html · PDF: https://tartswap.com/tart-whitepaper.pdf
- X: https://x.com/TartProtocol · Telegram: https://t.me/TartSwap · Contact: contact@tartswap.com

## TART token

| | |
|---|---|
| Contract | [`0x7AB8d02CBb51Ff7223fDe700eAaa2a91Bf750314`](https://bscscan.com/token/0x7AB8d02CBb51Ff7223fDe700eAaa2a91Bf750314) — BEP-20 on BNB Smart Chain (chain id 56), source [`contracts/token/TartToken.sol`](contracts/token/TartToken.sol), [verified on BscScan](https://bscscan.com/address/0x7AB8d02CBb51Ff7223fDe700eAaa2a91Bf750314#code) |
| Name / symbol / decimals | TartSwap / TART / 9 |
| Supply | 10,000,000,000 TART, fixed — no mint function |
| Listing | PancakeSwap V2, 31 Aug 2026 19:00 UTC, after a contract-enforced whitelist presale (98.4 / 100 BNB, 246 wallets, no buyer vesting) |
| Pair | [`0x30000a407FabeBe29439F8E437050512fF6661bE`](https://bscscan.com/address/0x30000a407FabeBe29439F8E437050512fF6661bE) TART/WBNB · [DexScreener](https://dexscreener.com/bsc/0x30000a407fabebe29439f8e437050512ff6661be) |
| Tax | **0% buy / 0% sell** since 23 Sep 2026. The token's fee lanes were reduced to zero and **ownership was renounced** the same day ([tx](https://bscscan.com/tx/0xdc6594c9bb38febb9ce26a8fe850aa79880a3d57a93232aa4fd57dde81001301)); `owner()` is the zero address, so no fee, limit or exemption can ever be changed again. |
| Burned | 18.0% of supply sits at the dead address (11.21% burned at listing + buyback burns) — [holders](https://bscscan.com/token/0x7AB8d02CBb51Ff7223fDe700eAaa2a91Bf750314#balances) |
| Supply APIs | circulating https://tartswap.com/api/tart-circulating-supply · total https://tartswap.com/api/tart-total-supply (plain numbers, used by CoinMarketCap / CoinGecko) |
| Listings | CoinMarketCap (since 1 Sep 2026) · [DefiLlama](https://defillama.com/protocol/tartswap) (TVL + staking; volume/fees adapters in review) |

### Tokenomics

Allocation of the 10B supply, with the numbers as they were realized on chain at launch (the sale closed at
98.4 / 100 BNB on 2026-08-31; the ledger reconciles to the wei — see whitepaper §3 and §9):

| Allocation | Share | TART | Status |
|---|---|---|---|
| Presale (whitelist, fixed tickets) | 19.68% | 1,968,000,000 | Sold to 246 wallets, 100% unlocked at listing |
| Launch liquidity | 7.79% | 778,855,680 | Paired with 51% of the raise into the TART/WBNB pool; LP locked (below) |
| Launch burn | 11.21% | 1,121,144,320 | Unsold reserve burned to the dead address right after finalize ([tx](https://bscscan.com/tx/0x11d87972c67a53efec572922ab8be37686e4476558022a95ab10240526f54ebe), 2026-08-31 21:25 UTC) |
| Pre-listing payouts | 1.32% | 132,000,000 | Paid from the reserve to external wallets before listing; circulating |
| Rewards (farm + staking emissions) | 30% | 3,000,000,000 | Two ownerless emission lockers (1.8B farm, 1.2B staking); 180-day halving; released only against staked capital |
| Treasury | 15% | 1,500,000,000 | 1,372,310,000 locked at FlokiFi until **27 Feb 2027** (vault below); remainder funds operations |
| Team | 10% | 1,000,000,000 | Not time-locked — disclosed as such; held in the labelled team wallet below |
| Community airdrop (CREPE holders) | 5% | 500,000,000 | Held in the vested-airdrop escrow (Merkle roster of CREPE stakers and organic buyers); 25% at the first unlock, then 25% per month for 3 months |

Unlock path of the total supply (cumulative, % of 10B): listing 32.3% · month 3 40.8% · month 6 47.5% ·
year 1 55.0% · year 2 60.6% · year 3 62.0%. The 11.21% launch burn never circulates.

Fee model: the token itself charges nothing. Protocol revenue comes from the swap router (0.35% on routed
swaps, split by `TartFeeDistributor`), the staking vault's tiered deposit/early-exit fees, OTC and game fees.
Emissions are paced by `TartEmissionPacer` against real staked capital, so the reward rate can only fall,
never inflate beyond the lockers' halving curve.

Live figures (24 Sep 2026): ~5,900 holders · 1.28B TART (12.8% of supply) staked in the vault · ~$460K
pool liquidity · 77.7% of the LP locked or burned.

### TART contracts — BNB Smart Chain mainnet (chain id 56)

| Contract | Address | Source | Purpose |
|---|---|---|---|
| TART token | [`0x7AB8d02CBb51Ff7223fDe700eAaa2a91Bf750314`](https://bscscan.com/address/0x7AB8d02CBb51Ff7223fDe700eAaa2a91Bf750314#code) | [`contracts/token/TartToken.sol`](contracts/token/TartToken.sol) | BEP-20, fixed supply, fees at 0, ownership renounced |
| Presale (TartPad sale) | [`0x7FbE324eBA6FA8EDE908ada215bd30AB137278B8`](https://bscscan.com/address/0x7FbE324eBA6FA8EDE908ada215bd30AB137278B8#code) | verified on BscScan | Whitelist sale, finalize → LP → burn; closed 31 Aug 2026 |
| Buyback burner | [`0x7EFa5c25C1A18b020e1d15725EAd25bDd8B32308`](https://bscscan.com/address/0x7EFa5c25C1A18b020e1d15725EAd25bDd8B32308#code) | [`contracts/token/TartBuybackBurner.sol`](contracts/token/TartBuybackBurner.sol) | One-way buy-and-burn; anything sent here can only become burned TART |
| Community airdrop escrow | [`0x09d200E038b7064a1C8526Ad1f4bAA4acCdf3D01`](https://bscscan.com/address/0x09d200E038b7064a1C8526Ad1f4bAA4acCdf3D01#code) | [`contracts/token/TartVestedAirdrop.sol`](contracts/token/TartVestedAirdrop.sol) | Holds the 500M community airdrop; Merkle-proof claims, 25% per tranche |
| Staking vault | [`0x038C92ac8269c9A648BA06e434056706Bc7832cE`](https://bscscan.com/address/0x038C92ac8269c9A648BA06e434056706Bc7832cE#code) | [`contracts/dex/TartStakingVault.sol`](contracts/dex/TartStakingVault.sol) | Tiered TART staking (Flexible / 30 / 90 / 180 days) |
| Staking emission adapter | [`0x081E0E7eE77356780ACCC24Ec833B28E7358E771`](https://bscscan.com/address/0x081E0E7eE77356780ACCC24Ec833B28E7358E771#code) | [`contracts/token/TartVaultEmissionAdapter.sol`](contracts/token/TartVaultEmissionAdapter.sol) | Feeds locker releases into the vault's reward stream |
| Farm emission locker | [`0x2a9cC2df5F17d8f0553C41d43ea85C823CB0C3d8`](https://bscscan.com/address/0x2a9cC2df5F17d8f0553C41d43ea85C823CB0C3d8#code) | [`contracts/token/TartEmissionLocker.sol`](contracts/token/TartEmissionLocker.sol) | 1.8B TART, 180-day halving, no withdraw function |
| Staking emission locker | [`0x1113966aCD804959908a4003626b96497E2f6D01`](https://bscscan.com/address/0x1113966aCD804959908a4003626b96497E2f6D01#code) | [`contracts/token/TartEmissionLocker.sol`](contracts/token/TartEmissionLocker.sol) | 1.2B TART, same schedule |
| Farm emission pacer | [`0x0cB0aD473e7ff376e2C6a87550F3Ce6b91d68289`](https://bscscan.com/address/0x0cB0aD473e7ff376e2C6a87550F3Ce6b91d68289#code) | [`contracts/token/TartEmissionPacer.sol`](contracts/token/TartEmissionPacer.sol) | Permissionless sync that paces farm emissions to staked LP (APR target) |
| Staking emission sync | [`0x24d2eBEFa711A044221C725f1c627ee5f35D0c69`](https://bscscan.com/address/0x24d2eBEFa711A044221C725f1c627ee5f35D0c69#code) | [`contracts/token/TartEmissionSync.sol`](contracts/token/TartEmissionSync.sol) | Permissionless 6-hourly release from the staking locker |
| LP farm | [`0x4f6Eb30a521E5F5FDE2BD433cDc805962902F316`](https://bscscan.com/address/0x4f6Eb30a521E5F5FDE2BD433cDc805962902F316#code) | [`contracts/dex/TartLPFarmV3.sol`](contracts/dex/TartLPFarmV3.sol) | TART/WBNB LP staking is pool id 6 |
| OTC desk v1 | [`0x22E6B727286c02C5251682b1A1a65FdE71296Add`](https://bscscan.com/address/0x22E6B727286c02C5251682b1A1a65FdE71296Add#code) | [`contracts/otc/TartSwapOTC.sol`](contracts/otc/TartSwapOTC.sol) | Escrowed peer-to-peer offers, fixed price |
| OTC desk v2 (market-linked) | [`0xaB9dBE8903b4D89dc34Ea2C325B991A3183a4924`](https://testnet.bscscan.com/address/0xaB9dBE8903b4D89dc34Ea2C325B991A3183a4924#code) (BSC **testnet**) | [`contracts/otc/TartSwapOTCv2.sol`](contracts/otc/TartSwapOTCv2.sol) | Offers priced as a discount to the live pool spot; mainnet deployment pending |
| Partner staking vault | [`0xbc8f650EB1991C8AA5309f2b0d8693aF2Ec90dF6`](https://bscscan.com/address/0xbc8f650EB1991C8AA5309f2b0d8693aF2Ec90dF6#code) | [`contracts/dex/TartPartnerStakingVault.sol`](contracts/dex/TartPartnerStakingVault.sol) | Stake a partner token, earn TART (first pool: launch pending) |
| Market-making wallet (disclosed) | [`0x5F693Edc8E968E53A279138AF248D0C94C4009d7`](https://bscscan.com/address/0x5F693Edc8E968E53A279138AF248D0C94C4009d7) | — | The protocol's own labelled market maker on the TART/WBNB pool; trades only against the pool |

### Allocation wallets and locks

| Wallet / lock | Address | What it holds |
|---|---|---|
| LP lock (FlokiFi vault) | [`0x4478ab01d2b266f0bfe3236568cc4af7518e7e13`](https://bscscan.com/address/0x4478ab01d2b266f0bfe3236568cc4af7518e7e13) | 65.2% of TART/WBNB LP tokens, locked until **31 Aug 2027** ([lock page](https://locker.flokifi.com/view?type=1&tokenAddress=0x30000a407FabeBe29439F8E437050512fF6661bE&chainId=56)); a further 12.5% of the LP is burned at the zero address |
| Treasury lock (FlokiFi vault) | [`0x9e04c9387174da0db8753bd0f0908ba3f3536953`](https://bscscan.com/address/0x9e04c9387174da0db8753bd0f0908ba3f3536953) | 1,372,310,000 TART (13.7% of supply), locked until **27 Feb 2027** |
| Treasury wallet | [`0x594485986249FAD96E4f3bE8c68Ef2036f61beFE`](https://bscscan.com/address/0x594485986249FAD96E4f3bE8c68Ef2036f61beFE) | Treasury operations (the lock above was funded from here) |
| Team wallet | [`0x066E6547071Fa3ca88a21EDEF3B389C52212D307`](https://bscscan.com/address/0x066E6547071Fa3ca88a21EDEF3B389C52212D307) | Team allocation, not time-locked (disclosed) |
| Burn address | [`0x000000000000000000000000000000000000dEaD`](https://bscscan.com/token/0x7AB8d02CBb51Ff7223fDe700eAaa2a91Bf750314?a=0x000000000000000000000000000000000000dEaD) | 1.80B TART burned (18.0%) |
| Deployer / admin | [`0x6aB8Aca85a7f73876Cdc288686be24f67e2ee352`](https://bscscan.com/address/0x6aB8Aca85a7f73876Cdc288686be24f67e2ee352) | Deployed the TART stack; no longer has any power over the token (renounced) |

## Roadmap

Dates are UTC. ✅ shipped · 🔜 in progress / next · 📅 scheduled.

| When | Milestone |
|---|---|
| 2026 Q2 ✅ | Protocol on BNB Chain mainnet: swap router with on-chain fee split, staking vaults, LP farms, reward auto-allocator, escrowed OTC desk |
| 2026 Q3 ✅ | Fast Games parimutuel engine (rounds settled by keeper, winners split the pool) and the weekly buyback vote |
| 2026-08-29 → 31 ✅ | TART whitelist presale, listing on PancakeSwap, LP lock at FlokiFi, 1.12B launch burn — executed in one session after two full mainnet rehearsals |
| 2026-09 ✅ | CoinMarketCap (1 Sep) and DefiLlama (3 Sep) listings; vested community airdrop to 1,335 CREPE wallets; emission lockers streaming |
| 2026-09-23 ✅ | Token tax retired to 0% / 0% and ownership renounced |
| 2026-09-24 → 10-12 ✅ | Staking re-lock campaign for positions whose lock is ending; 30/90-day tiers weighted 2.5× / 3× |
| 2026 Q4 🔜 | OTC v2 (market-linked offers) to mainnet · DefiLlama volume/fees/revenue adapters and DEX-aggregator category · first partner staking pool · CEX listings (targets: MEXC, KCEX, XT) and Binance Alpha application · router fees routed into buyback |
| 2027-02-27 📅 | Treasury lock opens (disclosed in advance; use of funds to be published before that date) |
| 2027-08-31 📅 | LP lock expiry — renewal decision published before expiry |
| 2027 📅 | TART governance beyond the weekly buyback vote; multi-chain evaluation |

## Transparency notes

- Contract addresses are published for public verification; users can inspect balances, transactions, read and write methods through BscScan.
- Private keys, deployment secrets, admin environment variables and backend service keys are never stored in this public repository.
- Official contract verification should be checked directly on BscScan; this repository mirrors the verified sources.

## Repository layout

| Directory | Contents |
|---|---|
| `contracts/token/` | TART token, buyback burner, emission lockers / pacer / sync, vault emission adapter, vested airdrop |
| `contracts/otc/` | OTC desk v1 (fixed price) and v2 (market-linked) |
| `contracts/dex/` | DEX core: swap router, fee distributor, fee converter, staking vault, partner staking vault, LP farm, reward auto allocator |
| `contracts/dex/tartswap-v2/` | TartSwap V2 AMM: factory, pair, router, LP ERC20, interfaces and libraries |
| `contracts/games/` | Fast Games: parimutuel round arena, game fee splitter, testnet pUSDT faucet |
| `contracts/governance/` | Weekly buyback vote, stake adapter, buyback distributor |
| `contracts/interfaces/` | Shared interfaces |

## DEX contracts — BNB Smart Chain mainnet (chain id 56)

| Contract | Address | Purpose |
|---|---|---|
| Protocol Owner Safe (2/3 multisig) | [`0x91772cEc686C619b9a09ecAD4Ed1863d7DE62fBE`](https://bscscan.com/address/0x91772cEc686C619b9a09ecAD4Ed1863d7DE62fBE) | Protocol owner / admin multisig |
| Ecosystem token (TART) | [`0x7AB8d02CBb51Ff7223fDe700eAaa2a91Bf750314`](https://bscscan.com/address/0x7AB8d02CBb51Ff7223fDe700eAaa2a91Bf750314) | TART — protocol token, listed on PancakeSwap 2026-08-31 (`TartToken.sol`) |
| TART staking vault | [`0x038C92ac8269c9A648BA06e434056706Bc7832cE`](https://bscscan.com/address/0x038C92ac8269c9A648BA06e434056706Bc7832cE) | Tiered TART staking vault (`TartStakingVault.sol`) |
| TART emission lockers | [`0x2a9cC2df5F17d8f0553C41d43ea85C823CB0C3d8`](https://bscscan.com/address/0x2a9cC2df5F17d8f0553C41d43ea85C823CB0C3d8) · [`0x1113966aCD804959908a4003626b96497E2f6D01`](https://bscscan.com/address/0x1113966aCD804959908a4003626b96497E2f6D01) | Farm / staking emissions, 180-day halving (`TartEmissionLocker.sol`) |
| TART buyback burner | [`0x7EFa5c25C1A18b020e1d15725EAd25bDd8B32308`](https://bscscan.com/address/0x7EFa5c25C1A18b020e1d15725EAd25bDd8B32308) | One-way buyback-and-burn (`TartBuybackBurner.sol`) |
| Legacy ecosystem token (CREPE) | [`0xeb2B7d5691878627eff20492cA7c9a71228d931D`](https://bscscan.com/address/0xeb2B7d5691878627eff20492cA7c9a71228d931D) | CREPE — first reward token, still staked in its own vault |
| Tart Router V2 | [`0xBd9Ab53ebfb53F4436c829E881B5e560868D840F`](https://bscscan.com/address/0xBd9Ab53ebfb53F4436c829E881B5e560868D840F) | Swap routing and protocol fee collection, 0.35% (`TartSwapRouterV2.sol`) |
| Fee Distributor V2 | [`0xdf0aC48105BbC66EBe2976b03097A87Bb80744c1`](https://bscscan.com/address/0xdf0aC48105BbC66EBe2976b03097A87Bb80744c1) | Protocol fee distribution (`TartFeeDistributor.sol`) |
| Fee Converter V2 | [`0xDeA32774f6d8d2170192275C23Aec2f3bc1492Bd`](https://bscscan.com/address/0xDeA32774f6d8d2170192275C23Aec2f3bc1492Bd) | Fee conversion contract (`TartFeeConverterV2.sol`) |
| CREPE staking vault | [`0x20940d3573F1629F6c5226C2DDa2e9a28b364B33`](https://bscscan.com/address/0x20940d3573F1629F6c5226C2DDa2e9a28b364B33) | CREPE staking vault (`TartStakingVault.sol`) |
| LP Farm V3 | [`0x4f6Eb30a521E5F5FDE2BD433cDc805962902F316`](https://bscscan.com/address/0x4f6Eb30a521E5F5FDE2BD433cDc805962902F316) | LP farming contract (`TartLPFarmV3.sol`) |
| Reward Auto Allocator | [`0x7465fF319E6B8Df81ccdE90479D989DA5E7f83Eb`](https://bscscan.com/address/0x7465fF319E6B8Df81ccdE90479D989DA5E7f83Eb) | Reward allocation automation (`TartRewardAutoAllocator.sol`) |
| Reward Vault | [`0x1f4Dbc1c8556E5B1200d3cef250c87658AcAb760`](https://bscscan.com/address/0x1f4Dbc1c8556E5B1200d3cef250c87658AcAb760) | Reward custody / vault |
| Fee Collector | [`0xfa261c02b023b8a01F4Fc25Cca658757ddA48521`](https://bscscan.com/address/0xfa261c02b023b8a01F4Fc25Cca658757ddA48521) | Protocol fee receiver |
| Token Registry | [`0xE216adfA6C8eCD094f17dF9cdf3ce0b476925538`](https://bscscan.com/address/0xE216adfA6C8eCD094f17dF9cdf3ce0b476925538) | Token registry |
| Farm Registry | [`0x7c125816207AECfa2011eA28c71A6B2BB0D43f23`](https://bscscan.com/address/0x7c125816207AECfa2011eA28c71A6B2BB0D43f23) | Farm registry |

## Games & governance — BNB Smart Chain testnet (chain id 97)

| Contract | Address | Purpose |
|---|---|---|
| FastRoundArena | [`0x46ae0d1eE576dfC2679F24eb2c70abC21a7C98f9`](https://testnet.bscscan.com/address/0x46ae0d1eE576dfC2679F24eb2c70abC21a7C98f9) | Parimutuel fast-round games (`FastRoundArena.sol`) |
| Game Fee Splitter | [`0x22D710dc241958727140ec336136930132f3BC40`](https://testnet.bscscan.com/address/0x22D710dc241958727140ec336136930132f3BC40) | Arena fee sink: treasury / buyback split (`GameFeeSplitter.sol`) |
| WeeklyBuybackVote | [`0xb2281B548C7f40b7A2EeDd34f171293B6Da11706`](https://testnet.bscscan.com/address/0xb2281B548C7f40b7A2EeDd34f171293B6Da11706) | Weekly buyback governance vote (`WeeklyBuybackVote.sol`) |
| BuybackDistributor | [`0xC9c25196c24653D30b5432fcb84F1b72D38adecd`](https://testnet.bscscan.com/address/0xC9c25196c24653D30b5432fcb84F1b72D38adecd) | Buyback execution and distribution (`BuybackDistributor.sol`) |
| Test USDT (pUSDT) | [`0xc69F045446e96D0a275b72486eEA773d087532d4`](https://testnet.bscscan.com/address/0xc69F045446e96D0a275b72486eEA773d087532d4) | Testnet collateral token |
| pUSDT Faucet | [`0xbD0D20A344D1e66d5e1107AE050a78e7D07569bE`](https://testnet.bscscan.com/address/0xbD0D20A344D1e66d5e1107AE050a78e7D07569bE) | Testnet token faucet (`PredictionTestUSDTFaucet.sol`) |

## External / utility contracts (mainnet)

| Contract | Address | Purpose |
|---|---|---|
| PancakeSwap V2 Router | [`0x10ED43C718714eb63d5aA57B78B54704E256024E`](https://bscscan.com/address/0x10ED43C718714eb63d5aA57B78B54704E256024E) | External DEX router |
| WBNB | [`0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`](https://bscscan.com/address/0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c) | Wrapped BNB |
| USDT | [`0x55d398326f99059fF775485246999027B3197955`](https://bscscan.com/address/0x55d398326f99059fF775485246999027B3197955) | Tether USD |
| USDC | [`0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d`](https://bscscan.com/address/0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d) | USD Coin |

## Legacy treasury / reserve (CREPE era)

| Wallet | Address | Purpose |
|---|---|---|
| Treasury Wallet | [`0x043Ee47649A5C46Af488B499E48362803806d339`](https://bscscan.com/address/0x043Ee47649A5C46Af488B499E48362803806d339) | Treasury operations of the CREPE-era fee stack |
| Reserve Wallet | [`0x64BC8aC9F92a2526AA2AEb7c19005368955d9945`](https://bscscan.com/address/0x64BC8aC9F92a2526AA2AEb7c19005368955d9945) | Reserve operations of the CREPE-era fee stack |

## Security

Found a vulnerability? Please report it privately per our [Security Policy](SECURITY.md) — do not open a public issue. Private keys, deployment secrets and backend service keys are never stored in this repository.
