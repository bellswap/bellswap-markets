# Bellswap markets audit scope

Unaudited. Prepared for an external review; scope frozen at the tags named below.

This is the short scope note for this repository. The full scope document, with the trust model, the deployed parameters, the known open findings, the prior internal reviews, dependencies, the complete test and coverage figures and the freeze, is `AUDIT-SCOPE.md` in https://github.com/bellswap/bellswap-contracts.

## Scope rows for this repository

Both deployed contracts are verified on Sourcify as an exact match (creation and runtime; solc 0.8.26, cancun, optimizer 800 runs, via-IR off), and their project source files are identical to the files here.

| Contract | Path | Chain | Address | Deployed (UTC date, block) | Sourcify exact match | Lines (total / code) |
|---|---|---|---|---|---|---|
| BellMarketFactoryV3 | `src/mint/BellMarketFactoryV3.sol` | Robinhood Chain (4663) | `0x5c4B9baf485D1B72f46Ef84889c33CBca99f3D1E` | 2026-10-07, block 82569133 | yes | 338 / 241 |
| BellMarketV2, market 100 Tanker (TANKR) | `src/mint/BellMarketV2.sol` | Robinhood Chain (4663) | `0x0B199dA32205A5986f8DBDbed1b9c9c86FD7B3f2` | 2026-10-07, block 82570621 | yes | 577 / 460 |
| BellMarketFactoryV2 (not deployed) | `src/mint/BellMarketFactoryV2.sol` | none | none | n/a | n/a | 323 / 239 |
| IBellMarketFactoryV2 | `src/mint/interfaces/IBellMarketFactoryV2.sol` | n/a | n/a | n/a | n/a | 144 / 73 |

These four files (1,382 total, 1,013 code lines) are the part of the scope that exists only here. Every other `src/` file in this repository is byte-identical to the file of the same path in bellswap-contracts and is counted there; the full scope is 28 files, 5,180 total and 3,629 code lines. Out of scope here: `src/mocks/`, `src/vendor/`, `src/Version.sol`, `script/` (including the TANKR deploy scripts) and `test/`.

TANKR reads the reference feed `0xA8Dd192FFcAcC451D104BEEB628190ab4D3aA6ad`, takes USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` as collateral, and trades in the hook pool `0x6728e02c29014a5f4703c4367f0638a35351dbc8a5e9a85de91829896da0641f`.

## Known issues that affect this repository

Open, disclosed and unfixed in the deployed code; each is listed with location, severity and a suggested fix in the full document, section 6. Full write-ups with reproduction tests are available to the reviewing firm on request at hi@bellswap.fun.

- mint-1 (P2): `BellMarketV2._globalCondition` (`src/mint/BellMarketV2.sol:556-560`), in the live TANKR market, has the same global settlement trigger expression as `BellMarket` (bsX0, bsX1), so it counts collateral that never reaches the holders' pool.
- mint-2, mint-3 and mint-4: BellMarketV2 has the same code as `BellMarket` at these points (`REFERENCE_VIEW` at `src/mint/BellMarketV2.sol:96`, `close` at :213, `open` at :146, `withdraw` at :175).
- reference-1, reference-2, reference-3, reference-5 and reference-7: TANKR reads the live ReferenceFeed and its GuardedFeedView, whose guard edge cases are unfixed.
- hook-1, hook-2, hook-5 and hook-6: the TANKR pool uses the deployed BellswapHook.
- The residual paths of the TANKR tier (full document, section 6.3): hold-end report, late delivery burst, stale stack, hold stack beyond liquidator inventory, and a global trigger that is not an insolvency backstop.
- The reference source's relayed `deviationBps` sets TANKR's mint price buffer and can close minting (full document, section 5).

## Tests

`test/mint/` here: 29 files, 20 `.t.sol`, 169 test functions, 2 invariant functions (`test/mint/invariant/MintInvariants.t.sol`), run as 8 invariant tests in four suites: MintInvariantsTest at 128 runs, and MintInvariantsV2Test (`test/mint/v2/MarketSuitesV2.t.sol`), MintInvariantsOnV3Test and MintInvariantsTL1Test (`test/mint/v3/MarketSuitesV3.t.sol:68`, :82), which run the same two invariants against BellMarketV2 at 256 runs. On 8 October 2026 at `ef1039e`, `forge test --summary --offline` (forge 1.7.1) ran 35 suites: 328 passed, 0 failed, 0 skipped, exit 0.

```
bash tools/install-deps.sh
forge build
forge test
FOUNDRY_PROFILE=invariant forge test --match-test '^invariant'
```

`[profile.invariant]` in this repository's `foundry.toml` only names its artifact and cache folders. Under it only MintInvariantsTest runs its inline 10,000 runs; MintInvariantsV2Test, MintInvariantsOnV3Test and MintInvariantsTL1Test, which test BellMarketV2, stay at 256 runs. The profile that runs every invariant suite at 10,000 runs is in the private repository (full document, section 7).

The full suite (177 Solidity files under `test/`, 1,577 test functions, 79 fuzzed, 4 invariant functions; 170 suites, 1,497 passed, 0 failed, 249 harness tests skipped) is in the private development repository at commit 37b342e, whose `src/` and `test/` files for this repository equal the files here.

## Coverage

Measured on 8 October 2026 with `forge coverage` (forge 1.7.1, unoptimized coverage build) at private commit 37b342e; the command and the full table are in the full document, section 8.

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| src/mint/BellMarketV2.sol | 100.00% (311/311) | 100.00% (399/399) | 100.00% (72/72) | 100.00% (39/39) |
| src/mint/BellMarketFactoryV2.sol | 97.89% (139/142) | 98.76% (239/242) | 95.24% (40/42) | 100.00% (20/20) |
| src/mint/BellMarketFactoryV3.sol | 96.50% (138/143) | 84.96% (209/246) | 16.28% (7/43) | 100.00% (20/20) |
| src/mint/MarketMath.sol | 100.00% (53/53) | 94.12% (80/85) | 70.00% (7/10) | 100.00% (9/9) |

Totals over the 14 in-scope files of both repositories: lines 99.15% (1740/1755), statements 97.74% (2337/2391), branches 87.98% (344/391), functions 99.32% (290/292). The low branch figure for BellMarketFactoryV3 comes from revert paths no V3 test reaches (full document, section 8).

## Prior review

BellMarketV2, BellMarketFactoryV2 and BellMarketFactoryV3 went through internal review rounds with large language models before deployment, run by the Bellswap team (full document, section 9). They are not an audit and not an independent review by a security firm.

## Freeze

Tag `audit-2026-10-14` on this repository points to exactly one commit: the commit that adds this note, a descendant of the commit tagged `tankr-mainnet-2026-10-07` (`ef1039e9877948457ca090347f67823b3fcbfee8`). Check: `git diff --name-only ef1039e9877948457ca090347f67823b3fcbfee8 audit-2026-10-14` lists only `AUDIT-SCOPE.md`, and `git rev-parse audit-2026-10-14:src` prints `6764f1b26786ca189cf898bb719c06c0d24315fa`. Source, tests, scripts, build configuration and dependency installer are therefore those of `ef1039e`. The matching tag in bellswap-contracts is in the full document, section 12.

Contact: hi@bellswap.fun
