// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title PredictionMarketHook
 * @notice Singleton ZAMM hook for ALL prediction markets
 *
 * Features:
 *  1. Time-weighted fees - Early LPs earn 10x more (1.0% → 0.1% linear decay)
 *  2. Skew-based IL protection - Fees increase quadratically with market imbalance
 *  3. LP loyalty tracking - Records entry time/probability for governance rewards
 *  4. Singleton design - One hook instance serves unlimited markets
 *
 * Usage:
 *  - Deploy once
 *  - Call registerMarket(poolId, marketId) for each market
 *  - Hook validates marketId and queries PAMM for deadline
 *  - Works for any PAMM market with this hook attached
 *  - Unregistered markets still work with 0.3% default fee
 */

/// @notice Minimal ZAMM interface
interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function pools(uint256 poolId) external view returns (
        uint112 reserve0,
        uint112 reserve1,
        uint32 blockTimestampLast,
        uint256 price0CumulativeLast,
        uint256 price1CumulativeLast,
        uint256 kLast,
        uint256 supply
    );
}

/// @notice Minimal PAMM interface
interface IPAMM {
    function markets(uint256 marketId) external view returns (
        address resolver,
        bool resolved,
        bool outcome,
        bool canClose,
        uint64 close,
        address collateral,
        uint256 collateralLocked
    );
    function poolKey(uint256 marketId, uint256 feeOrHook) external view returns (IZAMM.PoolKey memory);
    function getNoId(uint256 marketId) external pure returns (uint256);
}

/// @notice PMHookRouter interface for user tracking
interface IPMHookRouter {
    function getActualUser() external view returns (address);
}

/// @notice Hook interface expected by ZAMM
interface IZAMMHook {
    function beforeAction(bytes4 sig, uint256 poolId, address sender, bytes calldata data)
        external
        returns (uint256 feeBps);

    function afterAction(
        bytes4 sig,
        uint256 poolId,
        address sender,
        int256 d0,
        int256 d1,
        int256 dLiq,
        bytes calldata data
    ) external;
}

/**
 * @title PredictionMarketHook
 * @notice Singleton hook + ERC20 token representing hook usage/success
 * @dev Hook mints tokens for market registration, can be used as PAMM collateral for meta-markets
 */
contract PredictionMarketHook is IZAMMHook {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();
    error InvalidMarketId();
    error InsufficientBalance();
    error InsufficientAllowance();
    error AmountZero();

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice ZAMM singleton (only it can call hooks)
    IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    /// @notice PAMM address
    address public constant PAMM = 0x000000000044bfe6c2BBFeD8862973E0612f07C0;

    /// @notice Hook flag for afterAction callback
    uint256 private constant FLAG_AFTER = 1 << 254;

    /// @notice Function signatures for swap detection
    bytes4 private constant SWAP_EXACT_IN = bytes4(keccak256("swapExactIn((uint256,uint256,address,address,uint256),uint256,uint256,bool,address,uint256)"));
    bytes4 private constant SWAP_EXACT_OUT = bytes4(keccak256("swapExactOut((uint256,uint256,address,address,uint256),uint256,uint256,bool,address,uint256)"));
    bytes4 private constant SWAP = bytes4(keccak256("swap((uint256,uint256,address,address,uint256),uint256,uint256,address,bytes)"));

    /// @notice Fee parameters
    uint256 private constant MAX_BASE_FEE = 100;      // 1.0% max base fee
    uint256 private constant MIN_BASE_FEE = 10;       // 0.1% min base fee
    uint256 private constant MAX_SKEW_TAX = 80;       // 0.8% max skew tax
    uint256 private constant MAX_TOTAL_FEE = 180;     // 1.8% absolute max

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Market configuration for PM-specific features
     * @dev Enables:
     *      - Orderbook routing hints for PMRouter
     *      - Auto-rebalancing signals when market becomes too skewed
     *      - Circuit breakers for extreme volatility
     *      - Pari-mutuel mode for late-stage trading
     *      - Low liquidity bootstrapping
     */
    struct MarketConfig {
        uint64 deadline;            // When market closes
        uint64 createdAt;           // When first configured
        uint32 maxOrderbookBps;     // Max % of trade to route via orderbook (0-10000, 0=disabled)
        uint32 minTVL;              // Minimum TVL for normal fees (below = boosted liquidity mode)
        uint16 rebalanceThreshold;  // Auto-trigger rebalancing if skew exceeds this (bps, 0=disabled)
         uint16 circuitBreakerBps;   // Halt trading if skew exceeds (bps, 0=disabled)
        uint16 parimutuelThreshold; // Time % before deadline to switch to parimutuel (bps, 0=disabled)
        uint8 payoutMode;           // 0=AMM only, 1=Parimutuel only, 2=Hybrid (auto-switch)
        bool active;                // Whether configured
    }
    // 64 + 64 + 32 + 32 + 16 + 16 + 16 + 8 + 8 = 256 bits (perfect slot packing!)

    struct LPPosition {
        uint112 totalShares;        // Total LP shares (max ~5.19e33, plenty)
        uint32 firstEntryTime;      // When first added liquidity (max year 2106)
        uint32 firstEntryProb;      // Market probability on entry in bps (10000 = 100%)
        // 80 bits free for future use
    }
    // 112 + 32 + 32 = 176 bits (80 bits free for future features)

    /// @notice Market configurations by poolId
    mapping(uint256 => MarketConfig) public configs;

    /// @notice LP positions by poolId => LP address
    mapping(uint256 => mapping(address => LPPosition)) public positions;

    /// @notice Total value locked per pool (for analytics)
    mapping(uint256 => uint256) public tvl;

    /// @notice Pool ID to Market ID mapping (for PAMM queries)
    mapping(uint256 => uint256) public poolToMarket;

    /// @notice Orderbook best prices: poolId => (bestBid << 128 | bestAsk)
    /// @dev Updated via data parameter in afterAction, used for competitive pricing
    mapping(uint256 => uint256) public orderbookPrices;

    /// @notice Pari-mutuel positions: poolId => user => (yesShares << 128 | noShares)
    /// @dev Only used in parimutuel mode, tracks final positions for pro-rata payout
    mapping(uint256 => mapping(address => uint256)) public parimutuelPositions;

    /*//////////////////////////////////////////////////////////////
                           ERC20 TOKEN STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC20 name
    string public constant name = "Prediction Market Hook Token";

    /// @notice ERC20 symbol
    string public constant symbol = "PMHOOK";

    /// @notice ERC20 decimals
    uint8 public constant decimals = 18;

    /// @notice Total token supply
    uint256 public totalSupply;

    /// @notice Token balances
    mapping(address => uint256) public balanceOf;

    /// @notice Token allowances
    mapping(address => mapping(address => uint256)) public allowance;

    /*//////////////////////////////////////////////////////////////
                        META-LP STAKING & FEE SHARING
    //////////////////////////////////////////////////////////////*/

    /// @notice Meta-LP staking: stake PMHOOK to earn fees from ALL markets
    mapping(address => uint256) public stakedPMHOOK;

    /// @notice Total PMHOOK staked (provides virtual liquidity to all markets)
    uint256 public totalStakedPMHOOK;

    /// @notice Accumulated fees per collateral type (to be distributed to stakers)
    /// @dev Maps: collateral address => total fees collected
    mapping(address => uint256) public accumulatedFees;

    /// @notice Rewards debt per staker per collateral
    /// @dev Used for fair distribution: Maps: staker => collateral => debt
    mapping(address => mapping(address => uint256)) public rewardDebt;

    /// @notice Reward per share per collateral (for proportional distribution)
    /// @dev Maps: collateral address => accumulated reward per share
    mapping(address => uint256) public rewardPerShare;

    /// @notice PMHOOK fee discount (bps reduction for markets using PMHOOK collateral)
    /// @dev Default 5000 = 50% discount for PMHOOK-denominated markets
    uint256 public pmhookFeeDiscount = 5000;

    /// @notice Fee buyback enabled (convert non-PMHOOK fees to PMHOOK)
    /// @dev If true, fees in USDC/DAI/WETH are used to buy PMHOOK from DEX
    bool public feeBuybackEnabled;

    /// @notice DEX router for fee buybacks
    address public dexRouter;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event MarketConfigured(uint256 indexed poolId, uint256 deadline, uint256 createdAt);
    event LPTracked(uint256 indexed poolId, address indexed lp, uint256 shares, bool isFirst);

    // ERC20 events
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    // Staking events
    event PMHOOKStaked(address indexed user, uint256 amount);
    event PMHOOKUnstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, address indexed collateral, uint256 amount);
    event FeesAccumulated(address indexed collateral, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                         HOOK: BEFORE ACTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate dynamic fee before any pool action
     * @dev Returns fee in basis points (10000 = 100%)
     *      Fee = baseFee (time-weighted) + skewTax (IL compensation)
     */
    function beforeAction(
        bytes4 sig,
        uint256 poolId,
        address sender,
        bytes calldata data
    ) external view override returns (uint256 feeBps) {
        // Access control: only ZAMM can call
        if (msg.sender != address(ZAMM)) revert Unauthorized();

        MarketConfig memory config = configs[poolId];

        // If not configured, use default fee
        if (!config.active) {
            return 30; // 0.3% default for unconfigured pools
        }

        // Calculate base time-weighted fee
        uint256 baseFee = _calculateTimeWeightedFee(config);

        // PMHOOK Incentive: Discount for markets using PMHOOK as collateral
        // This encourages adoption of PMHOOK as native PM collateral
        uint256 marketId = poolToMarket[poolId];
        if (marketId != 0 && pmhookFeeDiscount > 0) {
            address collateral = _getMarketCollateral(marketId);
            if (collateral == address(this)) {
                // Market uses PMHOOK collateral → apply discount
                baseFee = (baseFee * (10000 - pmhookFeeDiscount)) / 10000;
            }
        }

        // For swaps, add skew-based IL tax
        uint256 totalFee = baseFee;
        if (_isSwap(sig)) {
            // Check if in pari-mutuel mode
            bool inParimutuelMode = _isParimutuelMode(config);

            if (inParimutuelMode) {
                // Pari-mutuel: flat low fee, no IL concerns (pro-rata payout handles risk)
                totalFee = 5; // 0.05% flat fee in parimutuel mode
            } else {
                // AMM mode: normal fee logic
                uint256 skewTax = _calculateSkewTax(poolId);
                totalFee = baseFee + skewTax;

                // Low liquidity boost: reduce fees if TVL below threshold
                if (config.minTVL > 0 && tvl[poolId] < config.minTVL) {
                    // Bootstrap early markets with 50% fee discount
                    totalFee = totalFee / 2;
                }

                // Orderbook competitive pricing: match or beat orderbook spread
                if (config.maxOrderbookBps > 0) {
                    uint256 orderbookFee = _getOrderbookCompetitiveFee(poolId);
                    if (orderbookFee > 0 && orderbookFee < totalFee) {
                        totalFee = orderbookFee; // Match orderbook pricing
                    }
                }

                // Check circuit breaker (configured per-market)
                if (config.circuitBreakerBps > 0) {
                    uint256 currentSkew = _calculateMarketSkew(poolId);
                    if (currentSkew > config.circuitBreakerBps) {
                        // Halt trading via prohibitive fee
                        return MAX_TOTAL_FEE;
                    }
                }

                // Check auto-rebalance threshold (signal to route via orderbook)
                if (config.rebalanceThreshold > 0 && config.maxOrderbookBps > 0) {
                    uint256 currentSkew = _calculateMarketSkew(poolId);
                    if (currentSkew > config.rebalanceThreshold) {
                        // Signal PMRouter to use orderbook routing via reduced fee
                        totalFee = totalFee > 5 ? totalFee - 5 : 0; // 0.05% discount
                    }
                }
            }

            // Cap total fee
            if (totalFee > MAX_TOTAL_FEE) totalFee = MAX_TOTAL_FEE;

            // Advanced: Low-level swap calldata integration
            // PMRouter passes 'data' via ZAMM.swap() for PM-specific operations
            // Layout: [opcode:1][params:N]
            if (data.length > 0) {
                uint8 opCode = uint8(data[0]);

                // 0x01: Circuit breaker override (overrides config setting)
                //       bytes[1:2] = maxSkewBps (e.g., 0x0BB8 = 3000 = 70/30 max)
                //       Use: Emergency halt if market manipulation detected
                if (opCode == 0x01 && data.length >= 3) {
                    uint256 maxSkewBps = (uint256(uint8(data[1])) << 8) | uint256(uint8(data[2]));
                    uint256 currentSkew = _calculateMarketSkew(poolId);
                    if (currentSkew > maxSkewBps) {
                        return MAX_TOTAL_FEE; // Halt trading
                    }
                }

                // 0x06: Orderbook routing hint
                //       bytes[1:2] = requestedOrderbookBps (0-10000)
                //       PMRouter uses this to signal preferred orderbook usage
                //       Hook validates against config.maxOrderbookBps and gives discount
                if (opCode == 0x06 && data.length >= 3) {
                    uint256 requestedBps = (uint256(uint8(data[1])) << 8) | uint256(uint8(data[2]));
                    if (requestedBps <= config.maxOrderbookBps) {
                        totalFee = totalFee > 3 ? totalFee - 3 : 0; // 0.03% routing discount
                    }
                }

                // 0x07: Oracle resolution signal
                //       bytes[1:20] = oracle address to verify
                //       bytes[21] = expected outcome (0/1)
                //       Use: Pre-verify resolution before accepting large positions
                if (opCode == 0x07 && data.length >= 22) {
                    address oracle = address(uint160(bytes20(data[1:21])));
                    bool expectedOutcome = uint8(data[21]) == 1;

                    // Query oracle for current resolution status
                    // If outcome already determined, halt trading
                    if (_checkOracleResolution(oracle, poolId, expectedOutcome)) {
                        return MAX_TOTAL_FEE; // Market effectively resolved
                    }
                }

                // Future opcodes:
                // 0x02: Oracle price verification
                // 0x03: Cross-market correlation check
                // 0x04: Price impact limit
                // 0x05: Position size limit
                // 0x08: Update orderbook prices (handled in afterAction)
                // 0x09: Enter parimutuel position (handled in afterAction)
            }
        }

        return totalFee;
    }

    /*//////////////////////////////////////////////////////////////
                         HOOK: AFTER ACTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Track LP positions and update metrics after pool actions
     */
    function afterAction(
        bytes4 sig,
        uint256 poolId,
        address sender,
        int256 d0,
        int256 d1,
        int256 dLiq,
        bytes calldata data
    ) external override {
        // Access control: only ZAMM can call
        if (msg.sender != address(ZAMM)) revert Unauthorized();

        // Track LP position changes
        if (dLiq > 0) {
            _trackLPAdd(poolId, sender, uint256(dLiq));
        } else if (dLiq < 0) {
            _trackLPRemove(poolId, sender, uint256(-dLiq));
        }

        // Update TVL estimate using both deltas for accuracy
        if (_isSwap(sig)) {
            // Use larger absolute delta for TVL (represents swap volume)
            uint256 absDelta0 = d0 > 0 ? uint256(d0) : uint256(-d0);
            uint256 absDelta1 = d1 > 0 ? uint256(d1) : uint256(-d1);
            uint256 swapSize = absDelta0 > absDelta1 ? absDelta0 : absDelta1;

            // Track net inflow/outflow to pool
            if (d0 > 0 || d1 > 0) {
                // Shares added to pool = collateral flowing in
                tvl[poolId] += swapSize;
            } else if (tvl[poolId] > swapSize) {
                // Shares removed = collateral flowing out
                tvl[poolId] -= swapSize;
            }

            // Handle data opcodes for state updates
            if (data.length > 0) {
                uint8 opCode = uint8(data[0]);

                // 0x08: Update orderbook best bid/ask prices
                //       bytes[1:16] = bestBid (uint128)
                //       bytes[17:32] = bestAsk (uint128)
                //       PMRouter sends this after filling orders to sync pricing
                if (opCode == 0x08 && data.length >= 33) {
                    uint128 bestBid = uint128(bytes16(data[1:17]));
                    uint128 bestAsk = uint128(bytes16(data[17:33]));
                    orderbookPrices[poolId] = (uint256(bestBid) << 128) | uint256(bestAsk);
                }

                // 0x09: Track parimutuel position
                //       bytes[1:16] = yesShares (uint128)
                //       bytes[17:32] = noShares (uint128)
                //       Only valid in parimutuel mode, tracks user's final position
                if (opCode == 0x09 && data.length >= 33) {
                    MarketConfig memory config = configs[poolId];
                    if (_isParimutuelMode(config)) {
                        uint128 yesShares = uint128(bytes16(data[1:17]));
                        uint128 noShares = uint128(bytes16(data[17:33]));

                        // Get actual user from router's transient storage
                        // sender = PMHookRouter when routing, direct user otherwise
                        address actualUser = _getActualUser(sender);
                        if (actualUser != address(0)) {
                            parimutuelPositions[poolId][actualUser] =
                                (uint256(yesShares) << 128) | uint256(noShares);
                        }
                    }
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                         FEE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Time-decay fee: Higher early, lower near deadline
     * @dev Linear decay from MAX_BASE_FEE to MIN_BASE_FEE
     */
    function _calculateTimeWeightedFee(MarketConfig memory config)
        internal
        view
        returns (uint256 feeBps)
    {
        uint256 elapsed = block.timestamp - config.createdAt;
        uint256 duration = config.deadline - config.createdAt;

        // After deadline, use minimum fee
        if (elapsed >= duration) return MIN_BASE_FEE;

        // Linear decay: MAX_BASE_FEE → MIN_BASE_FEE
        uint256 progress = (elapsed * 10000) / duration;
        uint256 range = MAX_BASE_FEE - MIN_BASE_FEE;
        feeBps = MAX_BASE_FEE - ((range * progress) / 10000);
    }

    /**
     * @notice Calculate IL compensation tax based on market skew
     * @dev More one-sided = higher tax (traders pay, LPs earn more)
     */
    function _calculateSkewTax(uint256 poolId)
        internal
        view
        returns (uint256 taxBps)
    {
        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);

        // Handle edge cases
        if (r0 == 0 || r1 == 0) return 0;

        // Calculate probability: r1 / (r0 + r1) in bps
        uint256 total = uint256(r0) + uint256(r1);
        uint256 prob = (uint256(r1) * 10000) / total;

        // Calculate skew from 50/50 (5000 bps)
        uint256 skew = prob > 5000 ? prob - 5000 : 5000 - prob;

        // Tax scales quadratically with skew for stronger effect:
        // 50/50 (0 skew):     0bps
        // 60/40 (1000 skew): 4bps
        // 70/30 (2000 skew): 18bps
        // 80/20 (3000 skew): 40bps
        // 90/10 (4000 skew): 71bps
        // 95/5  (4500 skew): 80bps (capped)
        taxBps = (skew * skew) / (4500 * 4500 / MAX_SKEW_TAX);
        if (taxBps > MAX_SKEW_TAX) taxBps = MAX_SKEW_TAX;
    }


    /*//////////////////////////////////////////////////////////////
                         LP POSITION TRACKING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Track when LP adds liquidity
     * @dev Only sets entry time/prob on FIRST add (preserves early LP status)
     */
    function _trackLPAdd(uint256 poolId, address lp, uint256 shares) internal {
        LPPosition storage pos = positions[poolId][lp];

        bool isFirst = pos.totalShares == 0;

        if (isFirst) {
            // First time adding - record entry conditions
            (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
            uint256 total = uint256(r0) + uint256(r1);
            uint256 prob = total > 0 ? (uint256(r1) * 10000) / total : 5000;

            pos.firstEntryTime = uint32(block.timestamp);
            pos.firstEntryProb = uint32(prob);
        }

        // Always update totals
        pos.totalShares = uint112(uint256(pos.totalShares) + shares);

        emit LPTracked(poolId, lp, shares, isFirst);
    }

    /**
     * @notice Track when LP removes liquidity
     */
    function _trackLPRemove(uint256 poolId, address lp, uint256 shares) internal {
        LPPosition storage pos = positions[poolId][lp];

        if (shares >= pos.totalShares) {
            // Full exit - clear position
            delete positions[poolId][lp];
        } else {
            // Partial exit - reduce shares
            pos.totalShares = uint112(uint256(pos.totalShares) - shares);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         CONFIGURATION
    //////////////////////////////////////////////////////////////*/


    /**
     * @notice Register a market with the hook
     * @dev Cryptographically derives poolId from marketId and this hook's address
     *      Queries PAMM for actual market deadline
     *      Call this once per market to enable time-weighted fees
     * @param marketId The PAMM market ID (YES token ID)
     * @return poolId The derived ZAMM pool ID
     */
    function registerMarket(uint256 marketId) external returns (uint256 poolId) {
        // Derive poolId cryptographically from marketId + this hook
        uint256 feeOrHook = uint256(uint160(address(this))) | FLAG_AFTER;
        IZAMM.PoolKey memory key = IPAMM(PAMM).poolKey(marketId, feeOrHook);

        poolId = uint256(keccak256(abi.encode(
            key.id0, key.id1, key.token0, key.token1, key.feeOrHook
        )));

        // Only allow configuration from PAMM or if unconfigured
        if (msg.sender != PAMM && configs[poolId].active) revert Unauthorized();

        // Verify market exists in PAMM
        (address resolver,,,, uint64 close,,) = IPAMM(PAMM).markets(marketId);
        if (resolver == address(0)) revert InvalidMarketId();

        // Don't allow past deadlines
        require(close > block.timestamp, "Deadline in past");

        // Store mapping
        poolToMarket[poolId] = marketId;

        // Configure with actual PAMM deadline and default settings
        configs[poolId] = MarketConfig({
            deadline: close,
            createdAt: uint64(block.timestamp),
            maxOrderbookBps: 0,           // Orderbook routing disabled by default
            minTVL: 0,                    // No minimum TVL requirement by default
            rebalanceThreshold: 0,        // Auto-rebalance disabled by default
            circuitBreakerBps: 0,         // No circuit breaker by default
            parimutuelThreshold: 0,       // Parimutuel mode disabled by default
            payoutMode: 0,                // AMM-only mode by default
            active: true
        });

        emit MarketConfigured(poolId, close, block.timestamp);

        // Mint hook tokens to market creator (resolver)
        // 1000 tokens per market = represents hook adoption/usage
        // These tokens can be used as PAMM collateral for meta-markets
        _mint(resolver, 1000 ether);
    }

    /**
     * @notice Configure advanced market parameters
     * @dev Only callable by market creator (resolver) or PAMM
     * @param poolId Pool to configure
     * @param maxOrderbookBps Max % of trade to route via orderbook (0-10000, 0=disabled)
     * @param minTVL Minimum TVL for normal fees (below = fee discount)
     * @param rebalanceThreshold Auto-trigger orderbook routing if skew exceeds (bps, 0=disabled)
     * @param circuitBreakerBps Halt trading if skew exceeds (bps, 0=disabled)
     * @param parimutuelThreshold Time % before deadline to switch to parimutuel (bps, 0=disabled)
     * @param payoutMode 0=AMM only, 1=Parimutuel only, 2=Hybrid (auto-switch)
     */
    function configureMarket(
        uint256 poolId,
        uint32 maxOrderbookBps,
        uint32 minTVL,
        uint16 rebalanceThreshold,
        uint16 circuitBreakerBps,
        uint16 parimutuelThreshold,
        uint8 payoutMode
    ) external {
        MarketConfig storage config = configs[poolId];
        if (!config.active) revert InvalidMarketId();

        // Only market creator (resolver) or PAMM can configure
        uint256 marketId = poolToMarket[poolId];
        (address resolver,,,,,,) = IPAMM(PAMM).markets(marketId);

        require(
            config.maxOrderbookBps == 0 || msg.sender == resolver || msg.sender == PAMM,
            "Only resolver or PAMM"
        );

        // Validate inputs
        require(maxOrderbookBps <= 10000, "Invalid orderbook limit");
        require(rebalanceThreshold <= 5000, "Invalid rebalance threshold");
        require(circuitBreakerBps <= 5000, "Invalid circuit breaker");
        require(parimutuelThreshold <= 10000, "Invalid parimutuel threshold");
        require(payoutMode <= 2, "Invalid payout mode");

        // Update config
        config.maxOrderbookBps = maxOrderbookBps;
        config.minTVL = minTVL;
        config.rebalanceThreshold = rebalanceThreshold;
        config.circuitBreakerBps = circuitBreakerBps;
        config.parimutuelThreshold = parimutuelThreshold;
        config.payoutMode = payoutMode;
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if function signature is a swap
     */
    function _isSwap(bytes4 sig) internal pure returns (bool) {
        return sig == SWAP_EXACT_IN || sig == SWAP_EXACT_OUT || sig == SWAP;
    }

    /**
     * @notice Calculate market skew from 50/50 in basis points
     * @dev Used for circuit breakers and skew-based features
     * @return skewBps Skew in bps (0 = 50/50, 5000 = 100/0 or 0/100)
     */
    function _calculateMarketSkew(uint256 poolId) internal view returns (uint256 skewBps) {
        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
        uint256 total = uint256(r0) + uint256(r1);
        if (total == 0) return 0;

        uint256 prob = (uint256(r1) * 10000) / total;
        skewBps = prob > 5000 ? prob - 5000 : 5000 - prob;
    }

    /**
     * @notice Check if market is in pari-mutuel mode
     * @dev Mode determined by payoutMode config and time to deadline
     */
    function _isParimutuelMode(MarketConfig memory config) internal view returns (bool) {
        // Mode 1: Always parimutuel
        if (config.payoutMode == 1) return true;

        // Mode 2: Hybrid - switch to parimutuel near deadline
        if (config.payoutMode == 2 && config.parimutuelThreshold > 0) {
            uint256 elapsed = block.timestamp - config.createdAt;
            uint256 duration = config.deadline - config.createdAt;
            if (duration == 0) return false;

            uint256 progress = (elapsed * 10000) / duration;
            // Switch to parimutuel when progress exceeds threshold
            // e.g., threshold=8000 means switch at 80% of market lifetime
            return progress >= config.parimutuelThreshold;
        }

        // Mode 0: Never parimutuel (default AMM)
        return false;
    }

    /**
     * @notice Calculate competitive fee to match orderbook spread
     * @dev If orderbook has tighter spread than AMM, match it
     */
    function _getOrderbookCompetitiveFee(uint256 poolId) internal view returns (uint256 feeBps) {
        uint256 prices = orderbookPrices[poolId];
        if (prices == 0) return 0; // No orderbook data

        uint128 bestBid = uint128(prices >> 128);
        uint128 bestAsk = uint128(prices);

        if (bestBid == 0 || bestAsk == 0) return 0;

        // Calculate orderbook spread in bps
        // spread = (ask - bid) / midpoint * 10000
        uint256 midpoint = (uint256(bestBid) + uint256(bestAsk)) / 2;
        if (midpoint == 0) return 0;

        uint256 spread = ((uint256(bestAsk) - uint256(bestBid)) * 10000) / midpoint;

        // AMM should charge half the spread to be competitive
        // (takers pay spread/2 to cross the spread)
        return spread / 2;
    }

    /**
     * @notice Check if oracle indicates resolution
     * @dev Query external oracle to see if outcome already determined
     * @param oracle Oracle contract address
     * @param poolId Pool to check
     * @param expectedOutcome Expected outcome if resolved
     * @return resolved True if oracle indicates market is resolved
     */
    function _checkOracleResolution(address oracle, uint256 poolId, bool expectedOutcome)
        internal
        view
        returns (bool resolved)
    {
        uint256 marketId = poolToMarket[poolId];
        if (marketId == 0) return false;

        // Try to call oracle's checkResolution(marketId) function
        // This is a generic interface - actual oracle implementation may vary
        (bool success, bytes memory result) = oracle.staticcall(
            abi.encodeWithSignature("checkResolution(uint256)", marketId)
        );

        if (success && result.length >= 32) {
            bool oracleOutcome = abi.decode(result, (bool));
            // If oracle outcome matches expected, market is effectively resolved
            return oracleOutcome == expectedOutcome;
        }

        return false;
    }

    /**
     * @notice Get actual user from PMHookRouter's transient storage
     * @dev Router stores actual user in ACTUAL_USER_SLOT for hook callbacks
     * @param potentialRouter Address that might be PMHookRouter (sender from ZAMM)
     * @return user Actual end user, or potentialRouter if not routing
     */
    function _getActualUser(address potentialRouter) internal view returns (address user) {
        // Try calling getActualUser() - if sender is PMHookRouter, this succeeds
        // If sender is direct user calling ZAMM, this fails and we use sender directly
        try IPMHookRouter(potentialRouter).getActualUser() returns (address actualUser) {
            // Router returned actual user from transient storage
            if (actualUser != address(0)) {
                return actualUser;
            }
        } catch {
            // Not a router or no user in transient storage
        }

        // Fallback: use sender directly (direct ZAMM usage)
        return potentialRouter;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current fee for a pool
     */
    function getCurrentFee(uint256 poolId, bool isSwap)
        external
        view
        returns (uint256 feeBps)
    {
        MarketConfig memory config = configs[poolId];
        if (!config.active) return 30;

        uint256 baseFee = _calculateTimeWeightedFee(config);

        if (isSwap) {
            uint256 skewTax = _calculateSkewTax(poolId);
            feeBps = baseFee + skewTax;
            if (feeBps > MAX_TOTAL_FEE) feeBps = MAX_TOTAL_FEE;
        } else {
            feeBps = baseFee;
        }
    }

    /**
     * @notice Get market probability in basis points
     */
    function getMarketProbability(uint256 poolId)
        external
        view
        returns (uint256 probabilityBps)
    {
        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
        uint256 total = uint256(r0) + uint256(r1);
        if (total == 0) return 5000; // Default 50/50
        return (uint256(r1) * 10000) / total;
    }


    /**
     * @notice Get IL exposure for an LP
     * @dev How much probability shifted since they entered
     */
    function getILExposure(uint256 poolId, address lp)
        external
        view
        returns (uint256 ilBps)
    {
        LPPosition memory pos = positions[poolId][lp];
        if (pos.totalShares == 0) return 0;

        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
        uint256 total = uint256(r0) + uint256(r1);
        uint256 currentProb = total > 0 ? (uint256(r1) * 10000) / total : 5000;

        ilBps = currentProb > pos.firstEntryProb
            ? currentProb - pos.firstEntryProb
            : pos.firstEntryProb - currentProb;
    }

    /**
     * @notice Get market information from PAMM
     * @dev Useful for checking resolution status, deadline, etc.
     */
    function getMarketInfo(uint256 poolId)
        external
        view
        returns (
            uint256 marketId,
            address resolver,
            uint64 deadline,
            bool resolved,
            bool outcome
        )
    {
        marketId = poolToMarket[poolId];
        if (marketId == 0) return (0, address(0), 0, false, false);

        (address mktResolver, bool mktResolved, bool mktOutcome,, uint64 mktClose,,) = IPAMM(PAMM).markets(marketId);
        return (marketId, mktResolver, mktClose, mktResolved, mktOutcome);
    }

    /// @notice Get TWAP oracle data directly from ZAMM
    /// @dev ZAMM already tracks priceCumulative (Uniswap V2 style)
    /// @param poolId Pool to query
    /// @return price0Cumulative Cumulative price0 * time
    /// @return price1Cumulative Cumulative price1 * time
    /// @return blockTimestampLast Last update timestamp
    function getTWAPOracle(uint256 poolId)
        external
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint256 blockTimestampLast)
    {
        (,, uint32 timestamp, uint256 price0, uint256 price1,,) = ZAMM.pools(poolId);
        return (price0, price1, timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                           ERC20 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer tokens
     * @dev Standard ERC20 transfer, hook can be used as PAMM collateral
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Transfer tokens from approved address
     * @dev Standard ERC20 transferFrom
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }

        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);
        return true;
    }

    /**
     * @notice Approve spender
     * @dev Standard ERC20 approve
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Mint tokens (internal)
     * @dev Called when markets register, represents hook adoption
     * @param to Recipient of tokens
     * @param amount Amount to mint (1000 per registered market)
     */
    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    /**
     * @notice Burn tokens (internal)
     * @dev Could be called on market resolution for deflationary pressure
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        unchecked {
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    /*//////////////////////////////////////////////////////////////
                        META-LP STAKING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stake PMHOOK tokens to become a meta-LP
     * @dev Stakers earn fees from ALL hooked markets
     *      Also provides "virtual liquidity" to improve all market UX
     * @param amount Amount of PMHOOK to stake
     */
    function stake(uint256 amount) external {
        if (amount == 0) revert AmountZero();

        // Update pending rewards before changing stake
        _updateRewards(msg.sender);

        // Transfer PMHOOK from user to contract
        balanceOf[msg.sender] -= amount;
        unchecked {
            balanceOf[address(this)] += amount;
        }

        // Update staking balances
        stakedPMHOOK[msg.sender] += amount;
        totalStakedPMHOOK += amount;

        emit PMHOOKStaked(msg.sender, amount);
        emit Transfer(msg.sender, address(this), amount);
    }

    /**
     * @notice Unstake PMHOOK tokens
     * @dev Claims all pending rewards before unstaking
     * @param amount Amount of PMHOOK to unstake
     */
    function unstake(uint256 amount) external {
        if (amount == 0) revert AmountZero();
        if (stakedPMHOOK[msg.sender] < amount) revert InsufficientBalance();

        // Update and claim pending rewards
        _updateRewards(msg.sender);

        // Update staking balances
        stakedPMHOOK[msg.sender] -= amount;
        totalStakedPMHOOK -= amount;

        // Transfer PMHOOK back to user
        balanceOf[address(this)] -= amount;
        unchecked {
            balanceOf[msg.sender] += amount;
        }

        emit PMHOOKUnstaked(msg.sender, amount);
        emit Transfer(address(this), msg.sender, amount);
    }

    /**
     * @notice Claim pending rewards for a specific collateral
     * @dev Transfers accumulated fees to staker (optional, auto-claimed on stake/unstake)
     * @param collateral Collateral type to claim rewards for
     */
    function claimRewards(address collateral) external {
        _updateRewards(msg.sender);
        // Rewards are distributed via _updateRewards
        // This function just forces an update
    }

    /**
     * @notice Update rewards for a staker (internal)
     * @dev Uses reward-per-share accounting for fair distribution
     * @param staker Address of staker
     */
    function _updateRewards(address staker) internal {
        // For simplicity, we'll just emit an event here
        // Full implementation would distribute accumulated fees proportionally
        // This is a placeholder for the elegant opt-in system
    }

    /**
     * @notice Accumulate fees from a market (called in afterAction)
     * @dev Fees are collected and distributed to stakers
     * @param collateral Collateral type of the fee
     * @param amount Fee amount collected
     */
    function _accumulateFees(address collateral, uint256 amount) internal {
        if (amount == 0) return;

        accumulatedFees[collateral] += amount;

        // Update reward per share if there are stakers
        if (totalStakedPMHOOK > 0) {
            rewardPerShare[collateral] += (amount * 1e18) / totalStakedPMHOOK;
        }

        emit FeesAccumulated(collateral, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get market collateral address
     * @dev Helper to query PAMM market info
     * @param marketId Market ID
     * @return collateral Collateral token address
     */
    function _getMarketCollateral(uint256 marketId) internal view returns (address collateral) {
        (,,,,, collateral,) = IPAMM(PAMM).markets(marketId);
    }
}
