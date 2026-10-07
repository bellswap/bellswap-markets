# Bellswap markets

Unaudited. This repository holds the source of the Bellswap market contracts on Robinhood Chain. A market is a synthetic ERC-20 minted against USDG collateral at a reference price relayed from Ethereum. The repository contains the V2 market (`BellMarketV2`), the V2 factory that lists markets from a fixed label menu (`BellMarketFactoryV2`), and the V3 factory (`BellMarketFactoryV3`), which lowers the collateral bounds and adds the tier TL1, listed on testnet as the market Tanker (symbol TANKR).

## Where the live code is

https://github.com/bellswap/bellswap-contracts is the source of record for the Robinhood Chain mainnet deployment: the hook, the pool, the reference feed, the v1 market factory and its market bsX0. This repository adds the V2 market and the V2 and V3 factories, with their tests. Files that exist in both repositories (the v1 market and factory, `MarketMath.sol`, the reference feed) are byte-identical.

## Contents

| Path | What it is |
|---|---|
| `src/mint/BellMarketV2.sol` | The market: one isolated synthetic ERC-20 with its USDG positions (open, deposit, withdraw, mint, repay, close, liquidate) and its settlement path (arm, trigger, process, finalize, redeem). Both factories deploy this contract. |
| `src/mint/BellMarketFactoryV2.sol` | Permissionless, ownerless factory. The tier menu and the label menu are written once in the constructor. Each label (name, symbol, feed, tier, cap) lists at most one market, at id `FIRST_MARKET_ID + labelId`. |
| `src/mint/BellMarketFactoryV3.sol` | `BellMarketFactoryV2` with lower tier bounds and the full bonus rule. Same interface, same market code. |
| `src/mint/MarketMath.sol` | Value, collateral ratio, liquidation and settlement math. |
| `src/mint/interfaces/` | Market, factory and feed interfaces. |
| `src/reference/` | The reference feed the markets read (`ReferenceFeed`, `ReferenceFeedFactory`, `GuardedFeedView`), used by the V3 feed path tests. |
| `src/mint/BellMarket.sol`, `src/mint/BellMarketFactory.sol` | The v1 market and factory. The market test suites run against v1, V2 and V3. |
| `script/lib/LabelLint.sol` | Off-chain naming lint for label menus, run before deployment and before listing. |
| `script/lib/BellswapScript.sol` | Base of the deploy scripts. The V3 factory tests check its tier menu. |
| `src/mocks/`, `test/` | Test token, tests and test support. |
| `src/vendor/AddressAliasHelper.sol` | Unmodified Apache-2.0 code from OffchainLabs token-bridge-contracts. |

Deploy scripts are not included.

## Deployments

### Robinhood Chain testnet (chain 46630)

| Contract | Address |
|---|---|
| `BellMarketFactoryV3` | `0xBd524291552d279A34a71EB414fA58bB1C52f9ee` |
| Market 100, Tanker (TANKR), a `BellMarketV2` on tier TL1 | `0x41646A3865A175499b4E2be232FC67E0ba9636CB` |

Both contracts are verified on Sourcify (exact match) and on Blockscout:

- https://explorer.testnet.chain.robinhood.com/address/0xBd524291552d279A34a71EB414fA58bB1C52f9ee
- https://explorer.testnet.chain.robinhood.com/address/0x41646A3865A175499b4E2be232FC67E0ba9636CB

Every project source file in the two Sourcify records is byte-identical to the file of the same path here.

### Robinhood Chain mainnet

The market bsX0 runs on the v1 factory. Its addresses and source are in bellswap-contracts. The V3 factory is not deployed on mainnet yet.

## Build and test

Requires git and Foundry (built with forge 1.7.1).

```
bash tools/install-deps.sh
forge build
forge test
```

At import: 35 test suites, 328 tests, all passing. The gas snapshots in `test/mint/v2` and `test/mint/v3` check with, for example:

```
forge snapshot --match-path test/mint/v3/CreateMarketGas.t.sol --snap test/mint/v3/CreateMarketGas.snap --check
```

Compiler: solc 0.8.26, EVM version cancun, optimizer on with 800 runs, no via-IR. `foundry.toml` also defines the profiles `c4` and `invariant` only because inline test config in `test/mint/invariant/MintInvariants.t.sol` names them.

### Dependencies

`tools/install-deps.sh` clones each dependency into `lib/` (git-ignored, never vendored), checks out the pinned commit and fails if a HEAD differs from its pin.

| Name | Upstream | Version | Commit |
|---|---|---|---|
| forge-std | https://github.com/foundry-rs/forge-std | master after v1.16.2 | `886b4f8b63409ef474542de6394d25a9b5908ed3` |
| openzeppelin-contracts | https://github.com/OpenZeppelin/openzeppelin-contracts | v5.7.0 | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` |
| v4-core | https://github.com/Uniswap/v4-core | v4.0.0 | `e50237c43811bd9b526eff40f26772152a42daba` |

v4-core is fetched with its submodules so that `remappings.txt` matches the source repository. No file in this repository imports it.

## Tier TL1

TL1 is the lower-collateral tier of the V3 factory. The values below are read from the deployed testnet factory (`tier(0)`) and equal `script/lib/BellswapScript.sol`.

| Field | Value |
|---|---|
| Mint collateral ratio (`mintCrBps`) | 175 percent |
| Liquidation collateral ratio (`liqCrBps`) | 150 percent |
| Liquidation bonus (`bonusBps`) | 5 percent |
| Buffer floor (`bufferFloorBps`) | 10 percent |
| `mintMaxAge` | 129,600 s |
| `liqMaxAge` | 259,200 s |
| `settleStale` | 604,800 s |
| Settlement trigger on the global ratio (`settleGcrBps`) | 105 percent |
| Warm-up (`warmup`) | 600 s |

## Factory bounds

The factory constructor rejects any tier or label outside these bounds. No function changes a menu after deployment.

| Field | `BellMarketFactoryV3` | `BellMarketFactoryV2` |
|---|---|---|
| `mintCrBps` | at least 175 percent | at least 250 percent |
| `liqCrBps` | at least 150 percent, at most `mintCrBps` | same |
| `mintCrBps` minus `liqCrBps` | at least 25 points | at least 50 points |
| `bonusBps` | 5 to 20 percent, below `liqCrBps` minus 100 percent | same |
| Full bonus rule | `liqCrBps` at least (1 + bonus) times 140 percent | not checked |
| `bufferFloorBps` | 10 to 30 percent | same |
| `mintMaxAge` | at most 172,800 s | same |
| `liqMaxAge` | at most 345,600 s | same |
| `settleStale` | 604,800 to 2,592,000 s | same |
| `settleGcrBps` | at least 105 percent | same |
| `warmup` | at most 2,592,000 s | same |
| Label cap | 1,000 to 25,000 USD | same |
| Labels per factory | 1 to 32 | same |

TL1 meets the full bonus rule: 150 percent is above 1.05 times 140 percent (147 percent). Both factories also set `MIN_COLLATERAL` (smallest position collateral) to 100 USDG and `MIN_DEBT_VALUE` (smallest debt value at the confirmed price) to 50 USDG.

## Review process

Every change is reviewed by an independent model and verified by three further reviews before merge. There has been no external security review yet.

## Security

Report security issues to the bellswap organisation on GitHub: https://github.com/bellswap. There is no bug bounty.

## License

MIT, see `LICENSE`. `src/vendor/AddressAliasHelper.sol` is unmodified code from https://github.com/OffchainLabs/token-bridge-contracts (tag v1.2.5) under Apache-2.0; its licence text is in `src/vendor/licenses/`.

Not affiliated with any exchange or issuer.
