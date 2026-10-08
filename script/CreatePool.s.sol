// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BellswapScript} from "./lib/BellswapScript.sol";
import {PoolPrice} from "./lib/PoolPrice.sol";
import {PoolSeeder} from "./lib/PoolSeeder.sol";
import {IBellswapHook} from "../src/hook/IBellswapHook.sol";
import {IBellMarket} from "../src/mint/interfaces/IBellMarket.sol";
import {IBellMarketFactory} from "../src/mint/interfaces/IBellMarketFactory.sol";
import {IBellMarketFactoryV2} from "../src/mint/interfaces/IBellMarketFactoryV2.sol";
import {IAggregatorV3} from "../src/reference/l1/IAggregatorV3.sol";

/// @title CreatePool
/// @notice The synthetic pool of one Bellswap market (SPEC 11.1; step T9 of 10.1, T9c of docs/DEPLOY.md section 4):
/// `BellswapHook.createSyntheticPool(market, tickSpacing, sqrtPriceX96)` on the child chain, with the start price
/// checked against the market's reference view (its `referenceFeed()`, the hook's anchor) before anything is sent;
/// then, on test and local chains only and when asked, the T9c liquidity and one swap through PoolSeeder
/// (script/lib/PoolSeeder.sol): a full-range position bound to the signer with on-chain max amounts, and one
/// exact-input USDG swap with an on-chain minimum output, both paid by and paid out to the signer.
///
/// Dry run by default. Without --broadcast the script executes every call pranked as the signer (--sender,
/// --private-key or the single wallet), so forge saves no transaction and a later `forge script --resume` of the dry
/// run has nothing to send. With --broadcast the script refuses unless BELLSWAP_CREATE_POOL_BROADCAST equals this
/// chain's id (for example 46630), and on chain 1 or 4663 it also needs BELLSWAP_MAINNET_CONFIRMED (SPEC 10.3 G0).
/// `forge script --resume` never runs this code (forge resumes the saved sequence as is), so script/run.sh refuses
/// --resume for this script: re-run it with --broadcast instead. A re-run skips the pool and the signer's seed when
/// they exist and finds PoolSeeder at its CREATE2 address even when `poolSeeder` never reached the config; the swap
/// is sent again on every run with BELLSWAP_POOL_SWAP_USDG set.
///
/// Environment (names only):
///   BELLSWAP_POOL_MARKET            the BellMarket or BellMarketV2 (required); it must be listed by
///                                   stacks.<S>.marketFactory, stacks.<S>.stressMarketFactory,
///                                   stacks.<S>.marketFactoryV2 or stacks.<S>.marketFactoryV3
///   BELLSWAP_POOL_TICK_SPACING      tick spacing, [1, 32767], default 60
///   BELLSWAP_POOL_PRICE18           start price, USDG per synthetic times 1e18; default 0 = the reference itself;
///                                   refused if more than the hook's init band (10 percent) from the reference
///   BELLSWAP_POOL_SEED_USDG         USDG (raw units, 6 decimals) of the full-range seed; the synthetic side follows
///                                   from the pool price; default 0 = no liquidity; skipped when the signer's seed
///                                   position already holds liquidity; refused on mainnet (SPEC 2)
///   BELLSWAP_POOL_SWAP_USDG         USDG (raw units) exact input of one swap buying the synthetic; default 0 = no
///                                   swap; every run with it set swaps once; refused on mainnet
///   BELLSWAP_POOL_SLIPPAGE_BPS      bound of the seed amounts (max = quote plus this) and of the swap output (min =
///                                   quote at the pool price and the quoted fee minus this); default 100, max 1,000
///   BELLSWAP_CREATE_POOL_BROADCAST  must equal the chain id for a --broadcast run
/// Config keys read: hook, mockUsdgHook (the hook whose USDG() is the market's USDG), stacks.<S>.marketFactory,
/// stacks.<S>.stressMarketFactory, stacks.<S>.marketFactoryV2, poolSeeder. Keys written (run.sh, broadcast only):
/// pools.<market> = PoolId (also by a re-run that finds the pool and has nothing to send, so a lost config write is
/// repaired, after checking that the hook recorded it as the market's synthetic pool; that run needs the same
/// BELLSWAP_CREATE_POOL_BROADCAST and, on mainnet, BELLSWAP_MAINNET_CONFIRMED as a sending run), and
/// poolSeeder when the config lacks it and this run used it. Without `poolSeeder` in the config, PoolSeeder is the
/// contract at its CREATE2 proxy address (salt `bellswap.v1.PoolSeeder`, argument the hook's PoolManager), deployed
/// there when that address has no code, so a run whose config write was lost (run.sh writes only after a successful
/// --broadcast run) is followed by a re-run that uses the same seeder and sees the signer's seed position.
contract CreatePool is BellswapScript {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal constant BROADCAST_ENV = "BELLSWAP_CREATE_POOL_BROADCAST";
    string internal constant MARKET_ENV = "BELLSWAP_POOL_MARKET";
    string internal constant SPACING_ENV = "BELLSWAP_POOL_TICK_SPACING";
    string internal constant PRICE_ENV = "BELLSWAP_POOL_PRICE18";
    string internal constant SEED_ENV = "BELLSWAP_POOL_SEED_USDG";
    string internal constant SWAP_ENV = "BELLSWAP_POOL_SWAP_USDG";
    string internal constant SLIPPAGE_ENV = "BELLSWAP_POOL_SLIPPAGE_BPS";
    int24 internal constant DEFAULT_TICK_SPACING = 60;
    uint256 internal constant DEFAULT_SLIPPAGE_BPS = 100;
    uint256 internal constant MAX_SLIPPAGE_BPS = 1_000;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;

    error BroadcastNotEnabled(string env, string expected);

    /// @notice Everything the script checks and sends, computed read-only.
    struct Plan {
        address market;
        address hook;
        address usdg;
        address referenceView; // market.referenceFeed(), the hook's anchor feed
        PoolKey key;
        PoolId id;
        uint8 synthDecimals;
        uint8 usdgDecimals;
        uint256 reference18; // USDG per synthetic times 1e18, as the hook reads the view
        uint256 referenceAge; // seconds since the view's updatedAt
        uint256 staleAfter; // canonical staleAfter; an older reference makes the hook refuse (FeedUnusable)
        uint256 start18; // requested start price
        uint160 sqrtPriceX96;
        uint256 impliedX18; // the start price as the hook reads sqrtPriceX96 back
        uint256 gapBps; // |implied - reference| in bps of the reference
        uint256 bandBps; // max(canonical bandBps, INIT_BAND_FLOOR_BPS) = 1,000
        bool exists; // the hook already recorded this PoolId
    }

    /// @notice The optional T9c liquidity and swap, test and local chains only.
    struct Seed {
        uint256 seedUsdg; // USDG (raw) of the full-range seed; 0 = none
        uint256 swapUsdg; // USDG (raw) exact input of one swap buying the synthetic; 0 = none
        uint256 slippageBps;
        address seeder; // PoolSeeder from config (poolSeeder), else zero: the one at its CREATE2 address
    }

    /// @notice The seed position at the current pool price.
    struct SeedQuote {
        int24 tickLower; // full range, aligned to the tick spacing
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0; // needed at the current price, rounded up
        uint256 amount1;
        uint256 max0; // on-chain bound: amount plus slippage
        uint256 max1;
    }

    /// @notice What one run did.
    struct Result {
        bool created;
        bool seeded;
        bool swapped;
        bool seederDeployed;
        address seeder;
        uint256 paid0;
        uint256 paid1;
        uint256 swapOut;
    }

    function run() external {
        _loadConfig();
        _requireChildChain();
        address market = vm.envAddress(MARKET_ENV);
        _requireListed(market);
        Plan memory p = _plan(_hookFor(market), market, _tickSpacing(), vm.envOr(PRICE_ENV, uint256(0)));
        Seed memory sd = _seedConfig(
            p,
            vm.envOr(SEED_ENV, uint256(0)),
            vm.envOr(SWAP_ENV, uint256(0)),
            vm.envOr(SLIPPAGE_ENV, DEFAULT_SLIPPAGE_BPS),
            _addr(".poolSeeder")
        );
        _log(p);
        bool broadcasting = _isBroadcastRun();
        if (_gateOrRepair(market, p, sd, broadcasting, vm.envOr(BROADCAST_ENV, string("")))) return;

        address signer = _beginSend(broadcasting);
        Result memory r = _execute(p, sd, signer);
        _endSend(broadcasting);

        console.log(_poolsLine(market, p.id));
        if (r.seeder != address(0) && r.seeder != sd.seeder) {
            console.log(string.concat("BELLSWAP_SET poolSeeder ", vm.toString(r.seeder)));
        }
        if (!broadcasting) {
            console.log("CreatePool: dry run, nothing was sent and nothing was saved (no --broadcast).");
        }
    }

    /// @notice The broadcast guard and the G0 gate, then the existing-pool repair. Returns true when the pool exists and
    /// there is nothing to send: it has then printed pools.<market>. The guard and the gate come first, so a --broadcast
    /// run, whose BELLSWAP_SET lines run.sh writes into the config, refuses the repair without them as it refuses a send.
    function _gateOrRepair(address market, Plan memory p, Seed memory sd, bool broadcasting, string memory guard)
        internal
        view
        returns (bool repaired)
    {
        _checkBroadcastGuard(broadcasting, guard);
        _gate(_description(p, sd));
        if (p.exists && sd.seedUsdg == 0 && sd.swapUsdg == 0) {
            // The pool may be someone else's (createSyntheticPool is permissionless): adopt it into the address book
            // only when the hook recorded it as this market's synthetic pool on the market's reference view. Regime and
            // price are not required here: they change over time and do not decide whose pool it is.
            _checkPoolInfo(p);
            console.log("CreatePool: the pool already exists; nothing to send.");
            // A re-run after the pool was created but before run.sh wrote the config (a failed post-broadcast check,
            // a lost write) repairs pools.<market>: run.sh writes the lines of every successful --broadcast run.
            console.log(_poolsLine(market, p.id));
            return true;
        }
    }

    /// @notice The config line for pools.<market> = PoolId.
    function _poolsLine(address market, PoolId id) internal pure returns (string memory) {
        return string.concat("BELLSWAP_SET pools.", vm.toString(market), " ", vm.toString(PoolId.unwrap(id)));
    }

    /// @notice The sending part, between _beginSend and _endSend: create the pool if missing, then the optional seed
    /// and swap, each checked after the call.
    function _execute(Plan memory p, Seed memory sd, address signer) internal returns (Result memory r) {
        if (!p.exists) {
            (PoolId id,) = IBellswapHook(p.hook).createSyntheticPool(p.market, p.key.tickSpacing, p.sqrtPriceX96);
            _postflight(p, id, signer);
            r.created = true;
            console.log("CreatePool: pool created");
        } else {
            _checkPool(p);
            console.log("CreatePool: the pool already exists; creation skipped");
        }
        if (sd.seedUsdg == 0 && sd.swapUsdg == 0) return r;
        r.seeder = sd.seeder;
        if (r.seeder == address(0)) {
            IPoolManager pm = IBellswapHook(p.hook).POOL_MANAGER();
            (r.seeder, r.seederDeployed) =
                _create2(_salt("PoolSeeder"), abi.encodePacked(type(PoolSeeder).creationCode, abi.encode(pm)));
            if (PoolSeeder(r.seeder).MANAGER() != pm) revert Postflight("PoolSeeder MANAGER");
            if (r.seederDeployed) console.log("CreatePool: PoolSeeder deployed", r.seeder);
            else console.log("CreatePool: PoolSeeder found at its CREATE2 address (not in the config)", r.seeder);
        }
        if (sd.seedUsdg > 0) (r.seeded, r.paid0, r.paid1) = _seed(p, sd, r.seeder, signer);
        if (sd.swapUsdg > 0) {
            r.swapOut = _swapOnce(p, sd, r.seeder, signer);
            r.swapped = true;
        }
    }

    // ------------------------------------------------------------------ checks

    /// @notice Refuses a --broadcast run unless `guard` equals this chain's id (a dry run passes).
    function _checkBroadcastGuard(bool broadcasting, string memory guard) internal view {
        if (!broadcasting) return;
        string memory want = vm.toString(block.chainid);
        if (keccak256(bytes(guard)) != keccak256(bytes(want))) {
            console.log(string.concat("CreatePool: --broadcast refused; set ", BROADCAST_ENV, "=", want, " to send."));
            revert BroadcastNotEnabled(BROADCAST_ENV, want);
        }
    }

    /// @notice The read-only plan: reference, start price, sqrtPriceX96, key and every refusal the hook would give,
    /// raised here with a readable reason before a transaction exists.
    function _plan(address hook, address market, int24 tickSpacing, uint256 start18)
        internal
        view
        returns (Plan memory p)
    {
        if (hook.code.length == 0) revert Preflight("hook has no code");
        if (market.code.length == 0) revert Preflight("market has no code");
        if (tickSpacing < TickMath.MIN_TICK_SPACING || tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert Preflight("tickSpacing outside [1, 32767]");
        }
        IBellswapHook h = IBellswapHook(hook);
        p.market = market;
        p.hook = hook;
        p.usdg = h.USDG();
        if (IBellMarket(market).USDG() != p.usdg) revert Preflight("the market's USDG is not the hook's USDG");
        p.referenceView = IBellMarket(market).referenceFeed();
        if (p.referenceView.code.length == 0) revert Preflight("reference view has no code");
        bool synthIs0 = market < p.usdg;
        IBellswapHook.PoolConfig memory cfg = h.canonicalConfig(p.referenceView, synthIs0);

        (p.reference18, p.referenceAge) = _reference(p.referenceView);
        p.staleAfter = cfg.staleAfter;
        if (p.referenceAge > p.staleAfter) revert Preflight("reference older than staleAfter: the hook refuses it");

        uint256 floor = h.INIT_BAND_FLOOR_BPS();
        p.bandBps = cfg.bandBps > floor ? cfg.bandBps : floor;
        p.start18 = start18 == 0 ? p.reference18 : start18;
        if (PoolPrice.gapBps(p.start18, p.reference18) > p.bandBps) {
            revert Preflight("start price more than the init band (10 percent) from the reference");
        }

        p.synthDecimals = IERC20Metadata(market).decimals();
        p.usdgDecimals = IERC20Metadata(p.usdg).decimals();
        p.sqrtPriceX96 = PoolPrice.sqrtPriceX96(synthIs0, p.synthDecimals, p.usdgDecimals, p.start18);
        if (p.sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || p.sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert Preflight("sqrtPriceX96 outside the v4 range");
        }
        p.impliedX18 = PoolPrice.priceX18(p.sqrtPriceX96, synthIs0, p.synthDecimals, p.usdgDecimals);
        p.gapBps = PoolPrice.gapBps(p.impliedX18, p.reference18);
        if (p.gapBps > p.bandBps) revert Preflight("rounded start price outside the init band");

        p.key = PoolKey({
            currency0: Currency.wrap(synthIs0 ? market : p.usdg),
            currency1: Currency.wrap(synthIs0 ? p.usdg : market),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
        p.id = p.key.toId();
        p.exists = h.poolInfo(p.id).creator != address(0);
    }

    /// @dev The view read the way the hook reads it (BellswapHook._readFeed, src/hook/BellswapHook.sol:498-511).
    function _reference(address view_) internal view returns (uint256 usd18, uint256 age) {
        uint8 dec = IAggregatorV3(view_).decimals();
        if (dec < 6 || dec > 18) revert Preflight("reference decimals outside [6, 18]");
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(view_).latestRoundData();
        if (answer <= 0) revert Preflight("reference answer <= 0");
        // forge-lint: disable-next-line(block-timestamp)
        if (updatedAt > block.timestamp) revert Preflight("reference updatedAt in the future");
        // forge-lint: disable-next-line(unsafe-typecast)
        usd18 = uint256(answer) * 10 ** (18 - dec);
        age = block.timestamp - updatedAt;
    }

    function _postflight(Plan memory p, PoolId id, address creator) internal view {
        if (PoolId.unwrap(id) != PoolId.unwrap(p.id)) revert Postflight("pool id");
        if (IBellswapHook(p.hook).poolInfo(id).creator != creator) revert Postflight("pool creator");
        _checkPool(p);
    }

    /// @notice The pool is the market's synthetic pool on its reference, Fresh, within the band of the reference.
    function _checkPool(Plan memory p) internal view {
        _checkPoolInfo(p);
        (, uint256 gap,, IBellswapHook.Regime regime) = IBellswapHook(p.hook).quoteFee(p.key, true);
        if (regime != IBellswapHook.Regime.Fresh) revert Postflight("regime is not Fresh");
        if (gap > p.bandBps) revert Postflight("pool price outside the init band");
    }

    /// @notice The hook recorded the PoolId as a synthetic pool anchored on the market's reference view.
    function _checkPoolInfo(Plan memory p) internal view {
        IBellswapHook.PoolInfo memory info = IBellswapHook(p.hook).poolInfo(p.id);
        if (!info.synthetic || info.cfg.feed != p.referenceView) revert Postflight("pool info");
    }

    // ------------------------------------------------------------------ seed and swap (T9c)

    /// @notice The seed and swap request, refused where the operator must not seed (mainnet, SPEC 2) and with a
    /// configured PoolSeeder that does not belong to the hook's PoolManager.
    function _seedConfig(Plan memory p, uint256 seedUsdg, uint256 swapUsdg, uint256 slippageBps, address seeder)
        internal
        view
        returns (Seed memory sd)
    {
        sd = Seed(seedUsdg, swapUsdg, slippageBps, seeder);
        if (seedUsdg == 0 && swapUsdg == 0) return sd;
        if (_isMainnet()) revert Preflight("no liquidity seeding or swap by the operator on mainnet (SPEC 2)");
        if (slippageBps > MAX_SLIPPAGE_BPS) revert Preflight("BELLSWAP_POOL_SLIPPAGE_BPS above 1,000");
        if (seeder == address(0)) _requireCreate2Proxy();
        if (seeder != address(0)) {
            if (seeder.code.length == 0) revert Preflight("poolSeeder has no code");
            if (PoolSeeder(seeder).MANAGER() != IBellswapHook(p.hook).POOL_MANAGER()) {
                revert Preflight("poolSeeder belongs to another PoolManager");
            }
        }
    }

    /// @notice The full-range position worth `sd.seedUsdg` USDG on its USDG side at the current pool price.
    function _seedQuote(Plan memory p, Seed memory sd) internal view returns (SeedQuote memory q) {
        IPoolManager pm = IBellswapHook(p.hook).POOL_MANAGER();
        (uint160 sqrtP,,,) = pm.getSlot0(p.id);
        q.tickLower = TickMath.minUsableTick(p.key.tickSpacing);
        q.tickUpper = TickMath.maxUsableTick(p.key.tickSpacing);
        uint160 sa = TickMath.getSqrtPriceAtTick(q.tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(q.tickUpper);
        if (sqrtP <= sa || sqrtP >= sb) revert Preflight("pool price outside the full range");
        uint256 l = Currency.unwrap(p.key.currency0) == p.usdg
            ? FullMath.mulDiv(FullMath.mulDiv(sd.seedUsdg, sqrtP, FixedPoint96.Q96), sb, sb - sqrtP)
            : FullMath.mulDiv(sd.seedUsdg, FixedPoint96.Q96, sqrtP - sa);
        if (l == 0) revert Preflight("BELLSWAP_POOL_SEED_USDG too small: zero liquidity");
        if (l > Pool.tickSpacingToMaxLiquidityPerTick(p.key.tickSpacing)) {
            revert Preflight("BELLSWAP_POOL_SEED_USDG above the max liquidity per tick");
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        q.liquidity = uint128(l); // below the max liquidity per tick, a uint128
        q.amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sb, q.liquidity, true);
        q.amount1 = SqrtPriceMath.getAmount1Delta(sa, sqrtP, q.liquidity, true);
        q.max0 = q.amount0 + q.amount0 * sd.slippageBps / BPS + 1;
        q.max1 = q.amount1 + q.amount1 * sd.slippageBps / BPS + 1;
    }

    /// @notice Adds the signer's full-range seed through PoolSeeder, unless the signer's seed position already holds
    /// liquidity (a re-run). Approves exactly the on-chain maxima; checks position, pool liquidity and paid amounts.
    function _seed(Plan memory p, Seed memory sd, address seeder, address signer)
        internal
        returns (bool seeded, uint256 paid0, uint256 paid1)
    {
        SeedQuote memory q = _seedQuote(p, sd);
        bytes32 pos = Position.calculatePositionKey(seeder, q.tickLower, q.tickUpper, PoolSeeder(seeder).saltOf(signer));
        IPoolManager pm = IBellswapHook(p.hook).POOL_MANAGER();
        if (pm.getPositionLiquidity(p.id, pos) > 0) {
            console.log("CreatePool: the signer's seed position already holds liquidity; seeding skipped");
            return (false, 0, 0);
        }
        uint256[3] memory before = _seedBefore(p, pm, signer, q);

        IERC20(Currency.unwrap(p.key.currency0)).approve(seeder, q.max0);
        IERC20(Currency.unwrap(p.key.currency1)).approve(seeder, q.max1);
        (paid0, paid1) = PoolSeeder(seeder).addLiquidity(p.key, q.tickLower, q.tickUpper, q.liquidity, q.max0, q.max1);

        _seedPostflight(p, pm, pos, q, signer, before, paid0, paid1);
        console.log("CreatePool: seeded liquidity", uint256(q.liquidity));
        console.log("  paid currency0", paid0, "max", q.max0);
        console.log("  paid currency1", paid1, "max", q.max1);
        seeded = true;
    }

    /// @dev The signer's balances of both currencies (checked against the quote) and the pool liquidity.
    function _seedBefore(Plan memory p, IPoolManager pm, address signer, SeedQuote memory q)
        internal
        view
        returns (uint256[3] memory before)
    {
        IERC20 t0 = IERC20(Currency.unwrap(p.key.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(p.key.currency1));
        _requireBalance(t0, signer, q.amount0);
        _requireBalance(t1, signer, q.amount1);
        before = [t0.balanceOf(signer), t1.balanceOf(signer), uint256(pm.getLiquidity(p.id))];
    }

    function _seedPostflight(
        Plan memory p,
        IPoolManager pm,
        bytes32 pos,
        SeedQuote memory q,
        address signer,
        uint256[3] memory before,
        uint256 paid0,
        uint256 paid1
    ) internal view {
        if (pm.getPositionLiquidity(p.id, pos) != q.liquidity) {
            revert Postflight("seed position liquidity");
        }
        if (pm.getLiquidity(p.id) != before[2] + q.liquidity) revert Postflight("pool liquidity after the seed");
        if (
            before[0] - IERC20(Currency.unwrap(p.key.currency0)).balanceOf(signer) != paid0
                || before[1] - IERC20(Currency.unwrap(p.key.currency1)).balanceOf(signer) != paid1
        ) revert Postflight("seed paid amounts");
        if (paid0 == 0 || paid1 == 0 || paid0 > q.max0 || paid1 > q.max1) revert Postflight("seed amounts");
    }

    /// @notice One exact-input swap of `sd.swapUsdg` USDG for the synthetic, from and to the signer, with an
    /// on-chain minimum output (pool price, quoted fee, minus the slippage bound); checks the balances, the
    /// charged fee (PoolManager Swap event) against the quote, and that the synthetic's pool price did not fall.
    function _swapOnce(Plan memory p, Seed memory sd, address seeder, address signer) internal returns (uint256 out) {
        bool zeroForOne = Currency.unwrap(p.key.currency0) == p.usdg; // USDG in, synthetic out
        (uint24 fee, uint256 px, uint256 minOut) = _swapQuote(p, sd, zeroForOne);
        _requireBalance(IERC20(p.usdg), signer, sd.swapUsdg);
        uint256[2] memory before = [IERC20(p.usdg).balanceOf(signer), IERC20(p.market).balanceOf(signer)];

        IERC20(p.usdg).approve(seeder, sd.swapUsdg);
        vm.recordLogs();
        out = PoolSeeder(seeder).swapExactIn(p.key, zeroForOne, sd.swapUsdg, minOut, signer);
        uint24 charged = _chargedFee(vm.getRecordedLogs(), address(IBellswapHook(p.hook).POOL_MANAGER()), p.id);

        if (before[0] - IERC20(p.usdg).balanceOf(signer) != sd.swapUsdg) revert Postflight("swap input");
        if (IERC20(p.market).balanceOf(signer) - before[1] != out || out < minOut) revert Postflight("swap output");
        if (charged != fee) revert Postflight("charged fee differs from the quoted fee");
        if (_poolPrice18(p) < px) revert Postflight("synthetic pool price fell on a buy");
        console.log("CreatePool: swapped USDG in", sd.swapUsdg);
        console.log("  synthetic out", out, "min", minOut);
        console.log("  fee pips", uint256(charged));
    }

    /// @dev The hook's fee for the swap, the pool price (USDG per synthetic times 1e18) and the minimum output: the
    /// input at the pool price after the quoted fee, minus the slippage bound.
    function _swapQuote(Plan memory p, Seed memory sd, bool zeroForOne)
        internal
        view
        returns (uint24 fee, uint256 px, uint256 minOut)
    {
        IBellswapHook.Regime regime;
        (fee,,, regime) = IBellswapHook(p.hook).quoteFee(p.key, zeroForOne);
        if (regime != IBellswapHook.Regime.Fresh) revert Preflight("pool not Fresh: the swap would pay maxFee");
        if (IBellswapHook(p.hook).POOL_MANAGER().getLiquidity(p.id) == 0) {
            revert Preflight("the pool has no liquidity: set BELLSWAP_POOL_SEED_USDG");
        }
        px = _poolPrice18(p);
        uint256 expected =
            FullMath.mulDiv(sd.swapUsdg, 10 ** (18 + uint256(p.synthDecimals)), px * 10 ** p.usdgDecimals);
        minOut = expected * (PIPS - fee) / PIPS * (BPS - sd.slippageBps) / BPS;
        if (minOut == 0) revert Preflight("BELLSWAP_POOL_SWAP_USDG too small: zero minimum output");
    }

    /// @dev The pool price as USDG per synthetic times 1e18.
    function _poolPrice18(Plan memory p) internal view returns (uint256) {
        (uint160 sqrtP,,,) = IBellswapHook(p.hook).POOL_MANAGER().getSlot0(p.id);
        return PoolPrice.priceX18(sqrtP, Currency.unwrap(p.key.currency0) == p.market, p.synthDecimals, p.usdgDecimals);
    }

    function _requireBalance(IERC20 token, address who, uint256 amount) internal view {
        uint256 bal = token.balanceOf(who);
        if (bal < amount) {
            revert Preflight(string.concat(
                    "signer holds ",
                    vm.toString(bal),
                    " of ",
                    vm.toString(address(token)),
                    ", needs ",
                    vm.toString(amount),
                    " (synthetics: open a position on the market and mint first)"
                ));
        }
    }

    /// @dev The fee of the one PoolManager Swap event of pool `id` in `logs`.
    function _chargedFee(Vm.Log[] memory logs, address manager, PoolId id) internal pure returns (uint24 fee) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (
                l.emitter != manager || l.topics.length < 2 || l.topics[0] != IPoolManager.Swap.selector
                    || l.topics[1] != PoolId.unwrap(id)
            ) continue;
            (,,,,, fee) = abi.decode(l.data, (int128, int128, uint160, uint128, int24, uint24));
            ++n;
        }
        if (n != 1) revert Postflight("one Swap event of the pool");
    }

    // ------------------------------------------------------------------ config

    /// @notice The market is listed by one of this stack's factories: marketFactory, stressMarketFactory,
    /// marketFactoryV2 (BellMarketFactoryV2) or marketFactoryV3 (BellMarketFactoryV3, M1 step S1, which implements
    /// IBellMarketFactoryV2); isMarket has the same selector in both factory interfaces. On mainnet an address book with
    /// marketFactoryV3 set is refused before any read unless BELLSWAP_V3_MAINNET_CHAIN=4663 on 4663 (DESIGN.md decision
    /// 12, lifted by the founder on 2026-10-07); chain 1 is refused.
    function _requireListed(address market) internal view {
        address f = _addr(_stackKey("marketFactory"));
        address stress = _addr(_stackKey("stressMarketFactory"));
        address v2 = _addr(_stackKey("marketFactoryV2"));
        address v3 = _addr(_stackKey("marketFactoryV3"));
        if (v3 != address(0) && !_v3Allowed()) {
            revert Preflight("the V3 market factory on 4663 needs BELLSWAP_V3_MAINNET_CHAIN=4663 (DESIGN.md decision 12)");
        }
        bool listed = (f != address(0) && IBellMarketFactory(f).isMarket(market))
            || (stress != address(0) && IBellMarketFactory(stress).isMarket(market))
            || (v2 != address(0) && IBellMarketFactoryV2(v2).isMarket(market))
            || (v3 != address(0) && IBellMarketFactoryV2(v3).isMarket(market));
        if (!listed) revert Preflight("market is not listed by this stack's market factories");
    }

    /// @dev The configured hook whose USDG is the market's USDG: `hook`, else `mockUsdgHook` (T8b stress markets).
    function _hookFor(address market) internal view returns (address) {
        address usdg = IBellMarket(market).USDG();
        address hook = _addr(".hook");
        if (hook.code.length > 0 && IBellswapHook(hook).USDG() == usdg) return hook;
        address mockHook = _addr(".mockUsdgHook");
        if (mockHook.code.length > 0 && IBellswapHook(mockHook).USDG() == usdg) return mockHook;
        revert Preflight("no configured hook quotes the market's USDG");
    }

    function _tickSpacing() internal view returns (int24) {
        int256 s = vm.envOr(SPACING_ENV, int256(DEFAULT_TICK_SPACING));
        if (s < TickMath.MIN_TICK_SPACING || s > TickMath.MAX_TICK_SPACING) {
            revert Preflight("BELLSWAP_POOL_TICK_SPACING outside [1, 32767]");
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(s);
    }

    // ------------------------------------------------------------------ output

    function _description(Plan memory p, Seed memory sd) internal view returns (string memory) {
        string memory seed = sd.seedUsdg == 0 && sd.swapUsdg == 0
            ? ""
            : string.concat(
                "; seed USDG ",
                vm.toString(sd.seedUsdg),
                ", swap USDG ",
                vm.toString(sd.swapUsdg),
                ", slippage bps ",
                vm.toString(sd.slippageBps)
            );
        return string.concat(
            "CreatePool ",
            _chainName(),
            ": hook ",
            vm.toString(p.hook),
            " createSyntheticPool(market ",
            vm.toString(p.market),
            ", tickSpacing ",
            vm.toString(int256(p.key.tickSpacing)),
            ", sqrtPriceX96 ",
            vm.toString(uint256(p.sqrtPriceX96)),
            ")",
            seed
        );
    }

    function _log(Plan memory p) internal pure {
        console.log("market        ", p.market);
        console.log("hook          ", p.hook);
        console.log("reference view", p.referenceView);
        console.log("reference18   ", p.reference18);
        console.log("reference age ", p.referenceAge, "staleAfter", p.staleAfter);
        console.log("start18       ", p.start18);
        console.log("sqrtPriceX96  ", uint256(p.sqrtPriceX96));
        console.log("implied18     ", p.impliedX18);
        console.log("gap bps       ", p.gapBps, "band bps", p.bandBps);
        console.log("currency0     ", Currency.unwrap(p.key.currency0));
        console.log("currency1     ", Currency.unwrap(p.key.currency1));
        console.log("poolId        ", vm.toString(PoolId.unwrap(p.id)));
    }
}
