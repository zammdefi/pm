// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title GasPM
/// @notice Gas price prediction markets with integrated base fee oracle.
/// @dev Tracks cumulative base fee, historical max/min. Anyone can update(); rewards optional.
///      Creates prediction markets via Resolver: directional, range, breakout, peak, trough,
///      volatility, stability, spot, comparison. Window variants track metrics since market creation.
contract GasPM {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address public constant PAMM = 0x0000000000F8bA51d6e987660D3e455ac2c4BE9d;
    address payable public constant RESOLVER = payable(0x0000000000b0ba1b2bb3AF96FbB893d835970ec4);

    // Resolver comparison operators
    uint8 internal constant OP_LTE = 2;
    uint8 internal constant OP_GTE = 3;
    uint8 internal constant OP_EQ = 4;

    // Market type identifiers (for MarketCreated event op field)
    // Directional markets emit op directly (2=LTE, 3=GTE)
    uint8 internal constant MARKET_TYPE_RANGE = 4;
    uint8 internal constant MARKET_TYPE_BREAKOUT = 5;
    uint8 internal constant MARKET_TYPE_PEAK = 6;
    uint8 internal constant MARKET_TYPE_TROUGH = 7;
    uint8 internal constant MARKET_TYPE_VOLATILITY = 8;
    uint8 internal constant MARKET_TYPE_STABILITY = 9;
    uint8 internal constant MARKET_TYPE_SPOT = 10;
    uint8 internal constant MARKET_TYPE_COMPARISON = 11;

    /*//////////////////////////////////////////////////////////////
                              TWAP STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public cumulativeBaseFee;
    uint256 public lastBaseFee;
    uint64 public lastUpdateTime;
    uint64 public startTime;
    uint128 public maxBaseFee;
    uint128 public minBaseFee;

    /*//////////////////////////////////////////////////////////////
                            REWARD STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    uint256 public rewardAmount;
    uint256 public cooldown;

    /*//////////////////////////////////////////////////////////////
                            MARKET STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256[] internal _markets;
    mapping(uint256 => bool) public isOurMarket;
    bool public publicCreation;

    /// @dev Snapshot of cumulative state at market creation (for window markets).
    struct Snapshot {
        uint192 cumulative;
        uint64 timestamp;
    }
    mapping(uint256 => Snapshot) public marketSnapshots;

    /// @dev Per-market max/min tracking for window volatility/stability markets.
    ///      Updated via pokeWindowVolatility() to track spread during the market window.
    struct WindowSpread {
        uint128 windowMax;
        uint128 windowMin;
    }
    mapping(uint256 => WindowSpread) public windowSpreads;

    /// @dev Starting TWAP for comparison markets.
    mapping(uint256 => uint256) public comparisonStartValue;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct SeedParams {
        uint256 collateralIn;
        uint256 feeOrHook;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 minLiquidity;
        address lpRecipient;
        uint256 deadline;
    }

    struct SwapParams {
        uint256 collateralForSwap;
        uint256 minOut;
        bool yesForNo; // true = buyNo (swap yes for no), false = buyYes (swap no for yes)
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Updated(
        uint256 baseFee, uint256 cumulativeBaseFee, address indexed updater, uint256 reward
    );
    event MarketCreated(
        uint256 indexed marketId,
        uint256 threshold,
        uint256 threshold2,
        uint64 close,
        bool canClose,
        uint8 op
    );
    event RewardConfigured(uint256 rewardAmount, uint256 cooldown);
    event PublicCreationSet(bool enabled);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidOp();
    error InvalidClose();
    error Unauthorized();
    error AlreadyExceeded();
    error InvalidCooldown();
    error InvalidThreshold();
    error InvalidETHAmount();
    error ResolverCallFailed();
    error AlreadyBelowThreshold();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier canCreate() {
        if (!publicCreation && msg.sender != owner) revert Unauthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the oracle with current base fee.
    /// @dev Owner is set to tx.origin (not msg.sender) to support factory deployment
    ///      patterns where the original deployer should retain ownership.
    constructor() payable {
        owner = tx.origin;
        startTime = uint64(block.timestamp);
        lastUpdateTime = uint64(block.timestamp);
        lastBaseFee = block.basefee;
        maxBaseFee = uint128(block.basefee);
        minBaseFee = uint128(block.basefee);
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                             TWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Record current base fee. Pays reward if funded and cooldown passed.
    function update() public {
        uint256 elapsed = block.timestamp - lastUpdateTime;
        if (elapsed == 0) return;

        uint256 basefee = block.basefee;

        cumulativeBaseFee += lastBaseFee * elapsed;
        lastBaseFee = basefee;
        lastUpdateTime = uint64(block.timestamp);

        // Track peak/trough
        if (basefee > maxBaseFee) maxBaseFee = uint128(basefee);
        if (basefee < minBaseFee) minBaseFee = uint128(basefee);

        uint256 reward;
        if (rewardAmount > 0 && elapsed >= cooldown && address(this).balance >= rewardAmount) {
            reward = rewardAmount;
            _safeTransferETH(msg.sender, reward);
        }

        emit Updated(basefee, cumulativeBaseFee, msg.sender, reward);
    }

    /// @notice TWAP since deployment in wei.
    function baseFeeAverage() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastUpdateTime;
        uint256 cumulative = cumulativeBaseFee + lastBaseFee * elapsed;
        uint256 totalTime = block.timestamp - startTime;
        if (totalTime == 0) return block.basefee;
        return cumulative / totalTime;
    }

    /// @notice TWAP since deployment in gwei.
    function baseFeeAverageGwei() public view returns (uint256) {
        return baseFeeAverage() / 1 gwei;
    }

    /// @notice Current spot base fee in wei.
    function baseFeeCurrent() public view returns (uint256) {
        return block.basefee;
    }

    /// @notice Current spot base fee in gwei.
    function baseFeeCurrentGwei() public view returns (uint256) {
        return block.basefee / 1 gwei;
    }

    /// @notice Seconds since oracle started.
    function trackingDuration() public view returns (uint256) {
        return block.timestamp - startTime;
    }

    /// @notice Returns 1 if TWAP is within [lower, upper], 0 otherwise.
    /// @param lower Lower bound in wei (inclusive)
    /// @param upper Upper bound in wei (inclusive)
    function baseFeeInRange(uint256 lower, uint256 upper) public view returns (uint256) {
        uint256 avg = baseFeeAverage();
        return (avg >= lower && avg <= upper) ? 1 : 0;
    }

    /// @notice Returns 1 if TWAP is outside (lower, upper), 0 otherwise.
    /// @param lower Lower bound in wei
    /// @param upper Upper bound in wei
    function baseFeeOutOfRange(uint256 lower, uint256 upper) public view returns (uint256) {
        uint256 avg = baseFeeAverage();
        return (avg < lower || avg > upper) ? 1 : 0;
    }

    /// @notice Highest base fee recorded since deployment (wei). Updated via update().
    function baseFeeMax() public view returns (uint256) {
        return maxBaseFee;
    }

    /// @notice Lowest base fee recorded since deployment (wei). Updated via update().
    function baseFeeMin() public view returns (uint256) {
        return minBaseFee;
    }

    /// @notice Spread between highest and lowest base fee since deployment (wei).
    function baseFeeSpread() public view returns (uint256) {
        return maxBaseFee - minBaseFee;
    }

    /// @notice TWAP since a specific market was created.
    /// @param marketId The market ID to get the window average for
    function baseFeeAverageSince(uint256 marketId) public view returns (uint256) {
        Snapshot memory snap = marketSnapshots[marketId];
        if (snap.timestamp == 0) return baseFeeAverage();

        uint256 elapsed = block.timestamp - lastUpdateTime;
        uint256 currentCumulative = cumulativeBaseFee + lastBaseFee * elapsed;

        uint256 duration = block.timestamp - snap.timestamp;
        if (duration == 0) return block.basefee;

        return (currentCumulative - snap.cumulative) / duration;
    }

    /// @notice Returns 1 if window TWAP is within [lower, upper], 0 otherwise.
    /// @param marketId The market ID for the window
    /// @param lower Lower bound in wei (inclusive)
    /// @param upper Upper bound in wei (inclusive)
    function baseFeeInRangeSince(uint256 marketId, uint256 lower, uint256 upper)
        public
        view
        returns (uint256)
    {
        uint256 avg = baseFeeAverageSince(marketId);
        return (avg >= lower && avg <= upper) ? 1 : 0;
    }

    /// @notice Returns 1 if window TWAP is outside (lower, upper), 0 otherwise.
    /// @param marketId The market ID for the window
    /// @param lower Lower bound in wei
    /// @param upper Upper bound in wei
    function baseFeeOutOfRangeSince(uint256 marketId, uint256 lower, uint256 upper)
        public
        view
        returns (uint256)
    {
        uint256 avg = baseFeeAverageSince(marketId);
        return (avg < lower || avg > upper) ? 1 : 0;
    }

    /// @notice Absolute spread (max - min) during the market window.
    /// @dev Call pokeWindowVolatility() regularly to keep tracking accurate.
    /// @param marketId The market ID to get the window spread for
    function baseFeeSpreadSince(uint256 marketId) public view returns (uint256) {
        WindowSpread memory ws = windowSpreads[marketId];
        if (ws.windowMax == 0 && ws.windowMin == 0) return baseFeeSpread();
        // Include current basefee in spread calculation for accuracy without requiring poke
        uint256 currentMax = block.basefee > ws.windowMax ? block.basefee : ws.windowMax;
        uint256 currentMin = block.basefee < ws.windowMin ? block.basefee : ws.windowMin;
        return currentMax - currentMin;
    }

    /// @notice Returns 1 if current TWAP > starting TWAP, 0 otherwise.
    /// @param marketId The comparison market ID
    function baseFeeHigherThanStart(uint256 marketId) public view returns (uint256) {
        uint256 startValue = comparisonStartValue[marketId];
        if (startValue == 0) return 0;
        return baseFeeAverage() > startValue ? 1 : 0;
    }

    /// @notice Update a window volatility market's max/min to include current basefee.
    /// @dev Call this periodically to ensure baseFeeSpreadSince() captures all extremes.
    ///      The view function includes current basefee, but poke persists historical extremes.
    /// @param marketId The market ID to update
    function pokeWindowVolatility(uint256 marketId) public {
        WindowSpread storage ws = windowSpreads[marketId];
        if (ws.windowMax == 0 && ws.windowMin == 0) return; // Not a window volatility market
        uint128 current = uint128(block.basefee);
        if (current > ws.windowMax) ws.windowMax = current;
        if (current < ws.windowMin) ws.windowMin = current;
    }

    /// @notice Batch update multiple window volatility markets.
    /// @param marketIds Array of market IDs to update
    function pokeWindowVolatilityBatch(uint256[] calldata marketIds) public {
        uint128 current = uint128(block.basefee);
        for (uint256 i; i < marketIds.length; ++i) {
            WindowSpread storage ws = windowSpreads[marketIds[i]];
            if (ws.windowMax == 0 && ws.windowMin == 0) continue;
            if (current > ws.windowMax) ws.windowMax = current;
            if (current < ws.windowMin) ws.windowMin = current;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          MARKET CREATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Create directional TWAP market: "Will avg gas be <=/>= X?"
    /// @param threshold Target in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when condition met
    /// @param op 2=LTE, 3=GTE
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createMarket(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint8 op,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();
        if (op != OP_LTE && op != OP_GTE) revert InvalidOp();

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeedSimple(string,address,address,bytes4,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                _buildObservable(threshold, op),
                collateral,
                address(this),
                this.baseFeeAverage.selector,
                op,
                threshold,
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, op);
    }

    /// @notice Create directional market + seed LP + take initial position.
    /// @dev yesForNo=false buys YES (raises YES price), yesForNo=true buys NO.
    /// @param threshold Target in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when condition met
    /// @param op 2=LTE, 3=GTE
    /// @param seed Liquidity parameters
    /// @param swap Position parameters
    function createMarketAndBuy(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint8 op,
        SeedParams calldata seed,
        SwapParams calldata swap
    ) public payable canCreate returns (uint256 marketId, uint256 swapOut) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();
        if (op != OP_LTE && op != OP_GTE) revert InvalidOp();

        uint256 ethValue = _handleCollateral(collateral, seed.collateralIn + swap.collateralForSwap);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketSeedAndBuy(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256),(uint256,uint256,bool))",
                _buildObservable(threshold, op),
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeAverage, ()),
                op,
                threshold,
                close,
                canClose,
                seed,
                swap
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,, swapOut) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256));

        _registerMarket(marketId);

        emit MarketCreated(marketId, threshold, 0, close, canClose, op);
    }

    /// @notice Create range market: "Will avg gas be between X and Y?"
    /// @param lower Lower bound in wei (inclusive)
    /// @param upper Upper bound in wei (inclusive)
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when in range
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createRangeMarket(
        uint256 lower,
        uint256 upper,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (lower == 0 || upper == 0) revert InvalidThreshold();
        if (lower >= upper) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        string memory observable = _buildRangeObservable(lower, upper);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeed(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeInRange, (lower, upper)),
                OP_EQ,
                uint256(1), // threshold = 1 (true)
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, lower, upper, close, canClose, MARKET_TYPE_RANGE);
    }

    /// @notice Create range market + seed LP + take initial position.
    /// @param lower Lower bound in wei (inclusive)
    /// @param upper Upper bound in wei (inclusive)
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when in range
    /// @param seed Liquidity parameters
    /// @param swap Position parameters
    function createRangeMarketAndBuy(
        uint256 lower,
        uint256 upper,
        address collateral,
        uint64 close,
        bool canClose,
        SeedParams calldata seed,
        SwapParams calldata swap
    ) public payable canCreate returns (uint256 marketId, uint256 swapOut) {
        if (lower == 0 || upper == 0) revert InvalidThreshold();
        if (lower >= upper) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        string memory observable = _buildRangeObservable(lower, upper);
        uint256 ethValue = _handleCollateral(collateral, seed.collateralIn + swap.collateralForSwap);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketSeedAndBuy(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256),(uint256,uint256,bool))",
                observable,
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeInRange, (lower, upper)),
                OP_EQ,
                uint256(1),
                close,
                canClose,
                seed,
                swap
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,, swapOut) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, lower, upper, close, canClose, MARKET_TYPE_RANGE);
    }

    /// @notice Create breakout market: "Will avg gas leave the X-Y range?"
    /// @param lower Lower bound in wei
    /// @param upper Upper bound in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when out of range
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createBreakoutMarket(
        uint256 lower,
        uint256 upper,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (lower == 0 || upper == 0) revert InvalidThreshold();
        if (lower >= upper) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        string memory observable = _buildBreakoutObservable(lower, upper);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeed(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeOutOfRange, (lower, upper)),
                OP_EQ,
                uint256(1),
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, lower, upper, close, canClose, MARKET_TYPE_BREAKOUT);
    }

    /// @notice Create peak market: "Will gas spike to X?" (lifetime high)
    /// @param threshold Target peak in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when threshold reached
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createPeakMarket(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        string memory observable = _buildPeakObservable(threshold);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeedSimple(string,address,address,bytes4,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                this.baseFeeMax.selector,
                OP_GTE,
                threshold,
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, MARKET_TYPE_PEAK);
    }

    /// @notice Create trough market: "Will gas dip to X?" (lifetime low)
    /// @param threshold Target trough in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when threshold reached
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createTroughMarket(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        string memory observable = _buildTroughObservable(threshold);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeedSimple(string,address,address,bytes4,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                this.baseFeeMin.selector,
                OP_LTE,
                threshold,
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, MARKET_TYPE_TROUGH);
    }

    /// @notice Create volatility market: "Will gas swing by X?" (lifetime spread)
    /// @param threshold Target spread in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when spread reached
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createVolatilityMarket(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        string memory observable = _buildVolatilityObservable(threshold);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeedSimple(string,address,address,bytes4,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                this.baseFeeSpread.selector,
                OP_GTE,
                threshold,
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, MARKET_TYPE_VOLATILITY);
    }

    /// @notice Create stability market: "Will gas stay calm?" (spread < threshold)
    /// @param threshold Max spread in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose Generally false; YES wins only if spread stays low at close
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createStabilityMarket(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        string memory observable = _buildStabilityObservable(threshold);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeedSimple(string,address,address,bytes4,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                this.baseFeeSpread.selector,
                OP_LTE,
                threshold,
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, MARKET_TYPE_STABILITY);
    }

    /// @notice Create spot market: "Will gas be >= X at resolution?" (instant, not TWAP)
    /// @dev More manipulation-susceptible than TWAP. Best for extreme thresholds.
    /// @param threshold Target spot price in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when threshold reached
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createSpotMarket(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        string memory observable = _buildSpotObservable(threshold);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeedSimple(string,address,address,bytes4,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                this.baseFeeCurrent.selector,
                OP_GTE,
                threshold,
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, MARKET_TYPE_SPOT);
    }

    /// @notice Create comparison market: "Will TWAP be higher at close than now?"
    /// @dev Snapshots current TWAP. YES wins if TWAP increases by close.
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createComparisonMarket(
        address collateral,
        uint64 close,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (close <= block.timestamp) revert InvalidClose();

        uint256 startTwap = baseFeeAverage();
        string memory observable = _buildComparisonObservable(startTwap);

        marketId = _computeMarketId(observable, collateral, OP_GTE, 1, close, false);
        comparisonStartValue[marketId] = startTwap;

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeed(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeHigherThanStart, (marketId)),
                OP_GTE,
                1,
                close,
                false,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();

        _registerMarket(marketId);
        emit MarketCreated(marketId, startTwap, 0, close, false, MARKET_TYPE_COMPARISON);
    }

    /*//////////////////////////////////////////////////////////////
                        WINDOW MARKET CREATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Create window market: "Will avg gas DURING THIS MARKET be <=/>= X?"
    /// @param threshold Target in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when condition met
    /// @param op 2=LTE, 3=GTE
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createWindowMarket(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint8 op,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();
        if (op != OP_LTE && op != OP_GTE) revert InvalidOp();

        string memory observable = _buildWindowObservable(threshold, op);
        marketId = _computeMarketId(observable, collateral, op, threshold, close, canClose);
        _snapshotForMarket(marketId);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeed(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeAverageSince, (marketId)),
                op,
                threshold,
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, op);
    }

    /// @notice Create window market + seed LP + take initial position.
    /// @param threshold Target in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when condition met
    /// @param op 2=LTE, 3=GTE
    /// @param seed Liquidity parameters
    /// @param swap Position parameters
    function createWindowMarketAndBuy(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint8 op,
        SeedParams calldata seed,
        SwapParams calldata swap
    ) public payable canCreate returns (uint256 marketId, uint256 swapOut) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();
        if (op != OP_LTE && op != OP_GTE) revert InvalidOp();

        string memory observable = _buildWindowObservable(threshold, op);
        marketId = _computeMarketId(observable, collateral, op, threshold, close, canClose);
        _snapshotForMarket(marketId);

        uint256 ethValue = _handleCollateral(collateral, seed.collateralIn + swap.collateralForSwap);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketSeedAndBuy(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256),(uint256,uint256,bool))",
                observable,
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeAverageSince, (marketId)),
                op,
                threshold,
                close,
                canClose,
                seed,
                swap
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (,,,, swapOut) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, op);
    }

    /// @notice Create window range market: "Will avg gas DURING THIS MARKET stay between X-Y?"
    /// @param lower Lower bound in wei (inclusive)
    /// @param upper Upper bound in wei (inclusive)
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when in range
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createWindowRangeMarket(
        uint256 lower,
        uint256 upper,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (lower == 0 || upper == 0) revert InvalidThreshold();
        if (lower >= upper) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        string memory observable = _buildWindowRangeObservable(lower, upper);
        marketId = _computeMarketId(observable, collateral, OP_EQ, 1, close, canClose);
        _snapshotForMarket(marketId);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeed(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeInRangeSince, (marketId, lower, upper)),
                OP_EQ,
                uint256(1),
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();

        _registerMarket(marketId);
        emit MarketCreated(marketId, lower, upper, close, canClose, MARKET_TYPE_RANGE);
    }

    /// @notice Create window range market + seed LP + take initial position.
    /// @param lower Lower bound in wei (inclusive)
    /// @param upper Upper bound in wei (inclusive)
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when in range
    /// @param seed Liquidity parameters
    /// @param swap Position parameters
    function createWindowRangeMarketAndBuy(
        uint256 lower,
        uint256 upper,
        address collateral,
        uint64 close,
        bool canClose,
        SeedParams calldata seed,
        SwapParams calldata swap
    ) public payable canCreate returns (uint256 marketId, uint256 swapOut) {
        if (lower == 0 || upper == 0) revert InvalidThreshold();
        if (lower >= upper) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        string memory observable = _buildWindowRangeObservable(lower, upper);
        marketId = _computeMarketId(observable, collateral, OP_EQ, 1, close, canClose);
        _snapshotForMarket(marketId);

        uint256 ethValue = _handleCollateral(collateral, seed.collateralIn + swap.collateralForSwap);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketSeedAndBuy(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256),(uint256,uint256,bool))",
                observable,
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeInRangeSince, (marketId, lower, upper)),
                OP_EQ,
                uint256(1),
                close,
                canClose,
                seed,
                swap
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (,,,, swapOut) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, lower, upper, close, canClose, MARKET_TYPE_RANGE);
    }

    /// @notice Create window breakout market: "Will avg gas DURING THIS MARKET leave X-Y range?"
    /// @param lower Lower bound in wei
    /// @param upper Upper bound in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when out of range
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createWindowBreakoutMarket(
        uint256 lower,
        uint256 upper,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (lower == 0 || upper == 0) revert InvalidThreshold();
        if (lower >= upper) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        string memory observable = _buildWindowBreakoutObservable(lower, upper);
        marketId = _computeMarketId(observable, collateral, OP_EQ, 1, close, canClose);
        _snapshotForMarket(marketId);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeed(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeOutOfRangeSince, (marketId, lower, upper)),
                OP_EQ,
                uint256(1),
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();

        _registerMarket(marketId);
        emit MarketCreated(marketId, lower, upper, close, canClose, MARKET_TYPE_BREAKOUT);
    }

    /// @notice Create window peak market: "Will gas spike to X DURING THIS MARKET?"
    /// @dev Reverts if threshold already exceeded (maxBaseFee >= threshold).
    /// @param threshold Target peak in wei (must be > current maxBaseFee)
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when threshold reached
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createWindowPeakMarket(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        update();
        if (maxBaseFee >= threshold) revert AlreadyExceeded();

        string memory observable = _buildWindowPeakObservable(threshold);
        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeedSimple(string,address,address,bytes4,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                this.baseFeeMax.selector,
                OP_GTE,
                threshold,
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, MARKET_TYPE_PEAK);
    }

    /// @notice Create window trough market: "Will gas dip to X DURING THIS MARKET?"
    /// @dev Reverts if threshold already reached (minBaseFee <= threshold).
    /// @param threshold Target trough in wei (must be < current minBaseFee)
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when threshold reached
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createWindowTroughMarket(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        update();
        if (minBaseFee <= threshold) revert AlreadyBelowThreshold();

        string memory observable = _buildWindowTroughObservable(threshold);
        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeedSimple(string,address,address,bytes4,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                this.baseFeeMin.selector,
                OP_LTE,
                threshold,
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();
        (marketId,,,) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, MARKET_TYPE_TROUGH);
    }

    /// @notice Create window volatility market: "Will gas spread exceed X DURING THIS MARKET?"
    /// @dev Tracks absolute spread (max - min) during the market window.
    ///      Call pokeWindowVolatility() periodically to capture extremes between blocks.
    /// @param threshold Target spread in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose If true, resolves early when spread reached
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createWindowVolatilityMarket(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        update();
        string memory observable = _buildWindowVolatilityObservable(threshold);
        marketId = _computeMarketId(observable, collateral, OP_GTE, threshold, close, canClose);
        uint128 current = uint128(block.basefee);
        windowSpreads[marketId] = WindowSpread(current, current);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeed(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeSpreadSince, (marketId)),
                OP_GTE,
                threshold,
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, MARKET_TYPE_VOLATILITY);
    }

    /// @notice Create window stability market: "Will gas spread stay below X DURING THIS MARKET?"
    /// @dev YES wins if absolute spread (max - min) stays below threshold.
    ///      Call pokeWindowVolatility() periodically to capture extremes between blocks.
    /// @param threshold Max spread in wei
    /// @param collateral Token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param canClose Generally false; YES wins only if spread stays low at close
    /// @param collateralIn Liquidity seed amount
    /// @param feeOrHook Pool fee tier
    /// @param minLiquidity Min LP tokens
    /// @param lpRecipient LP token recipient
    function createWindowStabilityMarket(
        uint256 threshold,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address lpRecipient
    ) public payable canCreate returns (uint256 marketId) {
        if (threshold == 0) revert InvalidThreshold();
        if (close <= block.timestamp) revert InvalidClose();

        update();
        string memory observable = _buildWindowStabilityObservable(threshold);
        marketId = _computeMarketId(observable, collateral, OP_LTE, threshold, close, canClose);
        uint128 current = uint128(block.basefee);
        windowSpreads[marketId] = WindowSpread(current, current);

        uint256 ethValue = _handleCollateral(collateral, collateralIn);

        (bool ok, bytes memory ret) = RESOLVER.call{value: ethValue}(
            abi.encodeWithSignature(
                "createNumericMarketAndSeed(string,address,address,bytes,uint8,uint256,uint64,bool,(uint256,uint256,uint256,uint256,uint256,address,uint256))",
                observable,
                collateral,
                address(this),
                abi.encodeCall(this.baseFeeSpreadSince, (marketId)),
                OP_LTE,
                threshold,
                close,
                canClose,
                SeedParams(collateralIn, feeOrHook, 0, 0, minLiquidity, lpRecipient, 0)
            )
        );
        if (!ok || ret.length == 0) revert ResolverCallFailed();

        _registerMarket(marketId);
        emit MarketCreated(marketId, threshold, 0, close, canClose, MARKET_TYPE_STABILITY);
    }

    /*//////////////////////////////////////////////////////////////
                            MARKET VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of markets created through this oracle.
    function marketCount() public view returns (uint256) {
        return _markets.length;
    }

    /// @notice Get market IDs with pagination.
    function getMarkets(uint256 start, uint256 count) public view returns (uint256[] memory ids) {
        uint256 len = _markets.length;
        if (start >= len) return new uint256[](0);

        uint256 end = start + count;
        if (end > len) end = len;

        ids = new uint256[](end - start);
        for (uint256 i = start; i < end; ++i) {
            ids[i - start] = _markets[i];
        }
    }

    struct MarketInfo {
        uint256 marketId;
        uint64 close;
        bool resolved;
        bool outcome;
        uint256 currentValue;
        bool conditionMet;
        bool ready;
    }

    /// @notice Get detailed info for markets created through this oracle.
    function getMarketInfos(uint256 start, uint256 count)
        public
        view
        returns (MarketInfo[] memory infos)
    {
        uint256[] memory ids = getMarkets(start, count);
        infos = new MarketInfo[](ids.length);

        for (uint256 i; i < ids.length; ++i) {
            uint256 mid = ids[i];

            (bool ok1, bytes memory data1) =
                PAMM.staticcall(abi.encodeWithSignature("getMarket(uint256)", mid));

            (bool ok2, bytes memory data2) =
                RESOLVER.staticcall(abi.encodeWithSignature("preview(uint256)", mid));

            if (ok1 && ok2) {
                (,,, bool resolved, bool outcome,, uint64 close,,,,) = abi.decode(
                    data1,
                    (
                        address,
                        address,
                        uint8,
                        bool,
                        bool,
                        bool,
                        uint64,
                        uint256,
                        uint256,
                        uint256,
                        string
                    )
                );
                (uint256 value, bool condTrue, bool ready) =
                    abi.decode(data2, (uint256, bool, bool));

                infos[i] = MarketInfo({
                    marketId: mid,
                    close: close,
                    resolved: resolved,
                    outcome: outcome,
                    currentValue: value,
                    conditionMet: condTrue,
                    ready: ready
                });
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                           OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure reward per update.
    function setReward(uint256 _rewardAmount, uint256 _cooldown) public onlyOwner {
        if (_rewardAmount > 0 && _cooldown == 0) revert InvalidCooldown();
        rewardAmount = _rewardAmount;
        cooldown = _cooldown;
        emit RewardConfigured(_rewardAmount, _cooldown);
    }

    /// @notice Enable/disable public market creation.
    function setPublicCreation(bool enabled) public onlyOwner {
        publicCreation = enabled;
        emit PublicCreationSet(enabled);
    }

    /// @notice Withdraw funds.
    function withdraw(address to, uint256 amount) public onlyOwner {
        _safeTransferETH(to, amount == 0 ? address(this).balance : amount);
    }

    /// @notice Transfer ownership (ERC-173).
    function transferOwnership(address newOwner) public onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                              UTILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Batch multiple calls in one transaction.
    /// @dev Non-payable to prevent msg.value reuse attacks. Use AndBuy helpers for ETH.
    function multicall(bytes[] calldata data) public returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i != data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }

    /// @notice EIP-2612 permit for gasless approvals.
    function permit(
        address token,
        address owner_,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        assembly ("memory-safe") {
            // token.permit(owner_, address(this), value, deadline, v, r, s)
            let m := mload(0x40)
            mstore(m, 0xd505accf00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner_)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), value)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), v)
            mstore(add(m, 0xa4), r)
            mstore(add(m, 0xc4), s)
            if iszero(call(gas(), token, 0, m, 0xe4, 0x00, 0x00)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    /// @notice DAI-style permit for gasless approvals.
    function permitDAI(
        address token,
        address owner_,
        uint256 nonce,
        uint256 deadline,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        assembly ("memory-safe") {
            // token.permit(owner_, address(this), nonce, deadline, allowed, v, r, s)
            let m := mload(0x40)
            mstore(m, 0x8fcbaf0c00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner_)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), nonce)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), allowed)
            mstore(add(m, 0xa4), v)
            mstore(add(m, 0xc4), r)
            mstore(add(m, 0xe4), s)
            if iszero(call(gas(), token, 0, m, 0x104, 0x00, 0x00)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Validates msg.value for ETH or transfers ERC20. Returns ETH to forward.
    function _handleCollateral(address collateral, uint256 amount)
        internal
        returns (uint256 ethValue)
    {
        if (collateral == address(0)) {
            if (msg.value != amount) revert InvalidETHAmount();
            ethValue = amount;
        } else {
            if (msg.value != 0) revert InvalidETHAmount();
            _safeTransferFrom(collateral, msg.sender, address(this), amount);
            _ensureApproval(collateral, RESOLVER);
        }
    }

    /// @dev Adds market to _markets array and isOurMarket mapping.
    function _registerMarket(uint256 marketId) internal {
        _markets.push(marketId);
        isOurMarket[marketId] = true;
    }

    /// @dev Transfers ETH, reverts on failure.
    function _safeTransferETH(address to, uint256 amount) internal {
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
                revert(0x1c, 0x04)
            }
        }
    }

    function _toString(uint256 value) internal pure returns (string memory result) {
        assembly ("memory-safe") {
            result := add(mload(0x40), 0x80)
            mstore(0x40, add(result, 0x20))
            mstore(result, 0)
            let end := result
            let w := not(0)
            for { let temp := value } 1 {} {
                result := add(result, w)
                mstore8(result, add(48, mod(temp, 10)))
                temp := div(temp, 10)
                if iszero(temp) { break }
            }
            let n := sub(end, result)
            result := sub(result, 0x20)
            mstore(result, n)
        }
    }

    /// @dev Formats wei as gwei string with up to 3 decimals. E.g., 50e9 => "50".
    function _toGweiString(uint256 wei_) internal pure returns (string memory) {
        uint256 gwei_ = wei_ / 1 gwei;
        uint256 remainder = (wei_ % 1 gwei) / 1e6;

        if (remainder == 0) {
            return _toString(gwei_);
        }

        uint256 decimals = remainder;
        uint256 places = 3;
        while (decimals % 10 == 0 && places > 0) {
            decimals /= 10;
            places--;
        }

        bytes memory decStr;
        if (places == 3) {
            if (remainder < 10) decStr = abi.encodePacked("00", _toString(remainder));
            else if (remainder < 100) decStr = abi.encodePacked("0", _toString(remainder));
            else decStr = bytes(_toString(remainder));
        } else if (places == 2) {
            if (decimals < 10) decStr = abi.encodePacked("0", _toString(decimals));
            else decStr = bytes(_toString(decimals));
        } else {
            decStr = bytes(_toString(decimals));
        }

        return string(abi.encodePacked(_toString(gwei_), ".", decStr));
    }

    /// @dev USDT-compatible transferFrom.
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x60, amount)
            mstore(0x40, to)
            mstore(0x2c, shl(96, from))
            mstore(0x0c, 0x23b872dd000000000000000000000000)
            let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, 0x7939f424) // TransferFromFailed()
                    revert(0x1c, 0x04)
                }
            }
            mstore(0x60, 0)
            mstore(0x40, m)
        }
    }

    /// @dev USDT-compatible approval. Sets max if allowance < uint128.max.
    function _ensureApproval(address token, address spender) internal {
        assembly ("memory-safe") {
            mstore(0x00, 0xdd62ed3e000000000000000000000000)
            mstore(0x14, address())
            mstore(0x34, spender)
            let success := staticcall(gas(), token, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(success, gt(mload(0x00), 0xffffffffffffffffffffffffffffffff))) {
                mstore(0x14, spender)
                mstore(0x34, not(0))
                mstore(0x00, 0x095ea7b3000000000000000000000000)
                success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
                if iszero(and(eq(mload(0x00), 1), success)) {
                    if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                        mstore(0x00, 0x3e3f8f73) // ApproveFailed()
                        revert(0x1c, 0x04)
                    }
                }
            }
            mstore(0x34, 0)
        }
    }

    /// @dev Snapshot cumulative state for window market.
    function _snapshotForMarket(uint256 marketId) internal {
        uint256 elapsed = block.timestamp - lastUpdateTime;
        uint256 currentCumulative = cumulativeBaseFee + lastBaseFee * elapsed;
        marketSnapshots[marketId] = Snapshot(uint192(currentCumulative), uint64(block.timestamp));
    }

    /// @dev Pre-compute marketId to match Resolver/PAMM derivation.
    function _computeMarketId(
        string memory observable,
        address collateral,
        uint8 op,
        uint256 threshold,
        uint64 close,
        bool canClose
    ) internal pure returns (uint256) {
        string memory opSym = op == OP_LTE ? "<=" : (op == OP_GTE ? ">=" : "==");
        string memory description = canClose
            ? string(
                abi.encodePacked(
                    observable,
                    " ",
                    opSym,
                    " ",
                    _toString(threshold),
                    " by ",
                    _toString(uint256(close)),
                    " Unix time. Note: market may close early once condition is met."
                )
            )
            : string(
                abi.encodePacked(
                    observable,
                    " ",
                    opSym,
                    " ",
                    _toString(threshold),
                    " by ",
                    _toString(uint256(close)),
                    " Unix time."
                )
            );
        return
            uint256(keccak256(abi.encodePacked("PMARKET:YES", description, RESOLVER, collateral)));
    }

    /*//////////////////////////////////////////////////////////////
                         OBSERVABLE BUILDERS
    //////////////////////////////////////////////////////////////*/

    function _buildObservable(uint256 threshold, uint8 op) internal pure returns (string memory) {
        string memory cmp = op == OP_LTE ? "<=" : ">=";
        return string(
            abi.encodePacked("Avg Ethereum base fee ", cmp, " ", _toGweiString(threshold), " gwei")
        );
    }

    function _buildRangeObservable(uint256 lower, uint256 upper)
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                "Avg Ethereum base fee between ",
                _toGweiString(lower),
                "-",
                _toGweiString(upper),
                " gwei"
            )
        );
    }

    function _buildBreakoutObservable(uint256 lower, uint256 upper)
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                "Avg Ethereum base fee outside ",
                _toGweiString(lower),
                "-",
                _toGweiString(upper),
                " gwei"
            )
        );
    }

    function _buildPeakObservable(uint256 threshold) internal pure returns (string memory) {
        return
            string(
                abi.encodePacked("Ethereum base fee spikes to ", _toGweiString(threshold), " gwei")
            );
    }

    function _buildTroughObservable(uint256 threshold) internal pure returns (string memory) {
        return
            string(
                abi.encodePacked("Ethereum base fee dips to ", _toGweiString(threshold), " gwei")
            );
    }

    function _buildWindowObservable(uint256 threshold, uint8 op)
        internal
        pure
        returns (string memory)
    {
        string memory cmp = op == OP_LTE ? "<=" : ">=";
        return string(
            abi.encodePacked("Avg gas during market ", cmp, " ", _toGweiString(threshold), " gwei")
        );
    }

    function _buildWindowRangeObservable(uint256 lower, uint256 upper)
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                "Avg gas during market between ",
                _toGweiString(lower),
                "-",
                _toGweiString(upper),
                " gwei"
            )
        );
    }

    function _buildWindowBreakoutObservable(uint256 lower, uint256 upper)
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                "Avg gas during market outside ",
                _toGweiString(lower),
                "-",
                _toGweiString(upper),
                " gwei"
            )
        );
    }

    function _buildWindowPeakObservable(uint256 threshold) internal pure returns (string memory) {
        return
            string(
                abi.encodePacked("Gas spikes to ", _toGweiString(threshold), " gwei during market")
            );
    }

    function _buildWindowTroughObservable(uint256 threshold) internal pure returns (string memory) {
        return
            string(
                abi.encodePacked("Gas dips to ", _toGweiString(threshold), " gwei during market")
            );
    }

    function _buildVolatilityObservable(uint256 threshold) internal pure returns (string memory) {
        return
            string(abi.encodePacked("Ethereum base fee swings ", _toGweiString(threshold), " gwei"));
    }

    function _buildStabilityObservable(uint256 threshold) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "Ethereum base fee stays within ", _toGweiString(threshold), " gwei spread"
            )
        );
    }

    function _buildWindowVolatilityObservable(uint256 threshold)
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked("Gas spread exceeds ", _toGweiString(threshold), " gwei during market")
        );
    }

    function _buildWindowStabilityObservable(uint256 threshold)
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                "Gas spread stays below ", _toGweiString(threshold), " gwei during market"
            )
        );
    }

    function _buildSpotObservable(uint256 threshold) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "Ethereum base fee spot price reaches ", _toGweiString(threshold), " gwei"
            )
        );
    }

    function _buildComparisonObservable(uint256 startTwap) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "Ethereum base fee TWAP higher than ", _toGweiString(startTwap), " gwei start"
            )
        );
    }
}
