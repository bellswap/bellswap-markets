// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IBellMarket
/// @notice One isolated market: the synthetic ERC-20 and its self-collateralised USDG positions
/// (SPEC 4.8, section 8). The implementation is also IERC20Metadata and IReferenced.
interface IBellMarket {
    enum Phase {
        Live,
        Settling,
        Final
    }
    enum SettleReason {
        None,
        Stale,
        GlobalUndercollateralised,
        Discontinuity
    }
    enum MintBlock {
        None,
        Phase,
        Warmup,
        Pending,
        Age,
        BufferCap,
        Discontinuity
    }

    struct Position {
        address owner;
        uint128 collateral; // USDG, 6 decimals
        uint128 debt; // synthetic, 18 decimals
        uint128 excess; // USDG claimable after processing
        bool processed;
    }

    struct PriceView {
        uint256 confirmed18; // market price (8.2)
        uint256 mint18; // confirmed * (1 + buffer), rounded up; 0 when the buffer exceeds MAX_BUFFER_BPS
        uint64 observedAt;
        uint64 lagGraceUntil;
        bool pending; // a pending round or a promotion hold exists
        bool mintOk;
        bool liqOk;
        MintBlock mintBlock; // first failing mint condition; None when mintOk
    }

    error NotOwner();
    error WrongPhase(Phase phase);
    error WarmingUp();
    error PriceNotUsable();
    error BelowMintRatio();
    error CapExceeded();
    error BelowMinimum();
    error NotLiquidatable();
    error Slippage();
    error NoTrigger();
    error NotArmed();
    error AlreadyArmed(uint64 armedAt);
    error ArmDelayPending(uint64 triggerableAt);
    error Unprocessed(uint256 remaining);
    error NothingToClaim();

    event PositionOpened(uint256 indexed id, address indexed owner);
    event Deposited(uint256 indexed id, address indexed payer, uint256 amount);
    event Withdrawn(uint256 indexed id, address indexed to, uint256 amount, uint256 price18);
    event Minted(uint256 indexed id, address indexed to, uint256 amount, uint256 price18);
    event Repaid(uint256 indexed id, address indexed payer, uint256 amount);
    event Closed(uint256 indexed id, address indexed to, uint256 collateral);
    event Liquidated(
        uint256 indexed id,
        address indexed liquidator,
        uint256 repaid,
        uint256 seized,
        uint256 price18,
        bool full,
        uint256 badDebt
    );
    event SettlementArmed(uint64 armedAt, uint80 armedLatestRound, uint64 triggerableAt, address caller);
    event SettlementDisarmed(uint80 latestRound);
    event SettlementTriggered(SettleReason reason, uint256 price18, uint64 observedAt, uint256 supply, address caller);
    event PositionProcessed(uint256 indexed id, uint256 toPool, uint256 excess);
    event Finalized(uint256 pool, uint256 supplyAtTrigger);
    event Redeemed(address indexed holder, address indexed to, uint256 burned, uint256 paid);
    event ExcessClaimed(uint256 indexed id, address indexed to, uint256 amount);

    /// @notice The BellMarketFactory that deployed this market.
    function FACTORY() external view returns (address);
    /// @notice The collateral token.
    function USDG() external view returns (address);
    /// @notice ReferenceFeed, KIND 1.
    function FEED() external view returns (address);
    /// @notice GuardedFeedView(FEED, 0).
    function REFERENCE_VIEW() external view returns (address);
    /// @notice Sequential id in the factory.
    function MARKET_ID() external view returns (uint256);
    /// @notice Supply cap in synthetic units, fixed at creation.
    function SUPPLY_CAP() external view returns (uint256);
    /// @notice USDG units (6 decimals); checked at Pmint on every mint.
    function CAP_USD() external view returns (uint256);
    /// @notice FEED.discontinuityCount() at creation.
    function DISC_BASE() external view returns (uint256);
    /// @notice No minting before this time.
    function WARMUP_END() external view returns (uint64);
    /// @notice Tier mintCrBps.
    function MINT_CR_BPS() external view returns (uint32);
    /// @notice Tier liqCrBps.
    function LIQ_CR_BPS() external view returns (uint32);
    /// @notice Tier bonusBps.
    function BONUS_BPS() external view returns (uint32);
    /// @notice Tier bufferFloorBps.
    function BUFFER_FLOOR_BPS() external view returns (uint32);
    /// @notice Tier mintMaxAge.
    function MINT_MAX_AGE() external view returns (uint32);
    /// @notice Tier liqMaxAge.
    function LIQ_MAX_AGE() external view returns (uint32);
    /// @notice Tier settleStale.
    function SETTLE_STALE() external view returns (uint32);
    /// @notice Tier settleGcrBps.
    function SETTLE_GCR_BPS() external view returns (uint32);
    /// @notice Factory MIN_COLLATERAL.
    function MIN_COLLATERAL() external view returns (uint256);
    /// @notice Factory MIN_DEBT_VALUE.
    function MIN_DEBT_VALUE() external view returns (uint256);

    /// @notice == REFERENCE_VIEW (IReferenced).
    function referenceFeed() external view returns (address);
    /// @notice IReferenced settlement state.
    function settlementState() external view returns (uint8 phase, uint256 pool, uint256 supplyAtTrigger);

    /// @notice Opens a position owned by msg.sender; optional mint to `to`.
    function open(uint256 collateral, uint256 mintAmount, address to) external returns (uint256 id);
    /// @notice Anyone adds collateral; no price read.
    function deposit(uint256 id, uint256 amount) external;
    /// @notice Owner withdraws collateral; reads a price only if debt > 0.
    function withdraw(uint256 id, uint256 amount, address to) external;
    /// @notice Owner mints synthetic against the position.
    function mint(uint256 id, uint256 amount, address to) external;
    /// @notice Anyone burns own tokens against a position's debt; no price.
    function repay(uint256 id, uint256 amount) external;
    /// @notice Owner burns all debt from msg.sender and receives all collateral; no price.
    function close(uint256 id, address to) external;
    /// @notice Anyone liquidates a position below LIQ_CR (SPEC 8.5).
    function liquidate(uint256 id, uint256 maxRepay, uint256 minSeize, address to)
        external
        returns (uint256 repaid, uint256 seized);
    /// @notice Anyone, iff canArm() (SPEC 8.6).
    function armSettlement() external;
    /// @notice Anyone, iff canTrigger() (SPEC 8.6).
    function triggerSettlement() external;

    /// @notice Anyone, Settling: moves each position's claim into the pool.
    function processPositions(uint256[] calldata ids) external;
    /// @notice Anyone, Settling, iff remaining == 0.
    function finalize() external;
    /// @notice Final, no deadline: burns amount and pays mulDiv(amount, pool, supplyAtTrigger).
    function redeem(uint256 amount, address to) external returns (uint256 paid);
    /// @notice Owner claims the position's excess collateral in Settling or Final.
    function claimExcess(uint256 id, address to) external returns (uint256 amount);

    /// @notice Current phase.
    function phase() external view returns (Phase);
    /// @notice One position.
    function position(uint256 id) external view returns (Position memory);
    /// @notice Number of positions ever opened.
    function positionCount() external view returns (uint256);
    /// @notice Prices and gates of SPEC 8.2.
    function prices() external view returns (PriceView memory);
    /// @notice C * 1e4 / V(D, price18); type(uint256).max when V is 0.
    function crBps(uint256 id, uint256 price18) external view returns (uint256);
    /// @notice (0, 0, false) unless liquidatable (SPEC 8.5 step 0).
    function maxLiquidation(uint256 id) external view returns (uint256 repay, uint256 seize, bool full);
    /// @notice Whether triggerSettlement would succeed now, and for which reason.
    function canTrigger() external view returns (bool ok, SettleReason reason);
    /// @notice True iff the stale condition holds, no discontinuity after listing exists and no valid arm
    /// exists (a valid arm has FEED.latestRound() == armedLatestRound) (SPEC 8.6).
    function canArm() external view returns (bool ok);
    /// @notice Stored arm; armed is true only for a valid arm.
    function armState()
        external
        view
        returns (bool armed, uint64 armedAt, uint80 armedLatestRound, uint64 triggerableAt);
    /// @notice Market aggregates.
    function totals()
        external
        view
        returns (uint256 totalCollateral, uint256 totalDebt, uint256 unbackedSupply, uint256 openDebtPositions);
    /// @notice Settlement record.
    function settlement()
        external
        view
        returns (
            SettleReason reason,
            uint256 price18,
            uint256 supplyAtTrigger,
            uint256 pool,
            uint256 remaining,
            uint256 redeemedBurned,
            uint256 redeemedPaid
        );
    /// @notice USDG held by this contract.
    function assets() external view returns (uint256);
    /// @notice totalSupply * market price, USDG units.
    function liabilities() external view returns (uint256);
    /// @notice assets * 1e4 / liabilities.
    function coverageBps() external view returns (uint256);
}
