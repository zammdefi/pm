// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice PAMM interface
interface IPAMM {
    function markets(uint256 marketId)
        external
        view
        returns (
            address resolver,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,
            address collateral,
            uint256 collateralLocked
        );

    function tradingOpen(uint256 marketId) external view returns (bool);
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool);
    function setOperator(address operator, bool approved) external returns (bool);
    function split(uint256 marketId, uint256 amount, address to) external payable;
}

/// @notice PMHookRouter vault interface
interface IPMHookRouter {
    function depositToVault(
        uint256 marketId,
        bool isYes,
        uint256 shares,
        address receiver,
        uint256 deadline
    ) external returns (uint256 vaultShares);

    function withdrawFromVault(
        uint256 marketId,
        bool isYes,
        uint256 vaultSharesToRedeem,
        address receiver,
        uint256 deadline
    ) external returns (uint256 sharesReturned, uint256 feesEarned);

    function harvestVaultFees(uint256 marketId, bool isYes) external returns (uint256 feesEarned);

    function provideLiquidity(
        uint256 marketId,
        uint256 collateralAmount,
        uint256 vaultYesShares,
        uint256 vaultNoShares,
        uint256 ammLPShares,
        uint256 minAmount0,
        uint256 minAmount1,
        address receiver,
        uint256 deadline
    )
        external
        payable
        returns (uint256 yesVaultSharesMinted, uint256 noVaultSharesMinted, uint256 ammLiquidity);

    function buyWithBootstrap(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        address to,
        uint256 deadline
    ) external payable returns (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted);

    function sellWithBootstrap(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        address to,
        uint256 deadline
    ) external returns (uint256 collateralOut, bytes4 source);

    // View functions
    function totalYesVaultShares(uint256 marketId) external view returns (uint256);
    function totalNoVaultShares(uint256 marketId) external view returns (uint256);
    function vaultPositions(uint256 marketId, address user)
        external
        view
        returns (
            uint112 yesVaultShares,
            uint112 noVaultShares,
            uint256 yesDebt,
            uint256 noDebt,
            uint64 lastDepositTime
        );
    function canonicalPoolId(uint256 marketId) external view returns (uint256);
    function canonicalFeeOrHook(uint256 marketId) external view returns (uint256);
    function accYesCollateralPerShare(uint256 marketId) external view returns (uint256);
    function accNoCollateralPerShare(uint256 marketId) external view returns (uint256);
}

/// @title MasterRouter - Complete Abstraction Layer (FIXED)
/// @notice Pooled orderbook + vault integration for prediction markets
/// @dev Fixed accumulator-based accounting to prevent late joiner theft
contract MasterRouter {
    address constant ETH = address(0);
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IPMHookRouter constant PM_HOOK_ROUTER =
        IPMHookRouter(0x0000000000BADa259Cb860c12ccD9500d9496B3e);

    uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268;
    uint256 constant BPS_DENOM = 10000;
    uint256 constant ACC = 1e18; // Accumulator precision

    bytes4 constant ERR_VALIDATION = 0x077a9c33;
    bytes4 constant ERR_STATE = 0xd06e7808;
    bytes4 constant ERR_TRANSFER = 0x2929f974;
    bytes4 constant ERR_REENTRANCY = 0xab143c06;
    bytes4 constant ERR_LIQUIDITY = 0x4dae90b0;
    bytes4 constant ERR_TIMING = 0x3703bac9;
    bytes4 constant ERR_OVERFLOW = 0xc4c2c1b0;
    bytes4 constant ERR_COMPUTATION = 0x05832717;

    /*//////////////////////////////////////////////////////////////
                        POOLED ORDERBOOK EVENTS
    //////////////////////////////////////////////////////////////*/

    event MintAndPool(
        uint256 indexed marketId,
        address indexed user,
        bytes32 indexed poolId,
        uint256 collateralIn,
        bool keepYes,
        uint256 priceInBps
    );

    event PoolFilled(
        bytes32 indexed poolId, address indexed taker, uint256 sharesFilled, uint256 collateralPaid
    );

    event ProceedsClaimed(bytes32 indexed poolId, address indexed user, uint256 collateralClaimed);

    event SharesWithdrawn(bytes32 indexed poolId, address indexed user, uint256 sharesWithdrawn);

    // Bid pool events (collateral pools buying shares)
    event BidPoolCreated(
        uint256 indexed marketId,
        address indexed user,
        bytes32 indexed bidPoolId,
        uint256 collateralIn,
        bool buyYes,
        uint256 priceInBps
    );

    event BidPoolFilled(
        bytes32 indexed bidPoolId,
        address indexed seller,
        uint256 sharesSold,
        uint256 collateralPaid
    );

    event BidCollateralClaimed(
        bytes32 indexed bidPoolId, address indexed user, uint256 sharesClaimed
    );

    event BidCollateralWithdrawn(
        bytes32 indexed bidPoolId, address indexed user, uint256 collateralWithdrawn
    );

    /*//////////////////////////////////////////////////////////////
                        VAULT INTEGRATION EVENTS
    //////////////////////////////////////////////////////////////*/

    event LiquidityProvided(
        uint256 indexed marketId,
        address indexed user,
        uint256 yesVaultShares,
        uint256 noVaultShares,
        uint256 ammLiquidity
    );

    event MintAndVault(
        uint256 indexed marketId,
        address indexed user,
        uint256 collateralIn,
        bool keepYes,
        uint256 sharesKept,
        uint256 vaultShares
    );

    /*//////////////////////////////////////////////////////////////
                    ACCUMULATOR-BASED POOL STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool state with accumulator accounting
    /// @dev Uses LP units (scaled) + reward debt pattern to prevent late joiner theft
    struct Pool {
        uint256 totalShares; // Remaining PM shares available to buy
        uint256 totalScaled; // Total LP units issued
        uint256 accCollPerScaled; // Cumulative collateral per LP unit (scaled by 1e18)
        uint256 collateralEarned; // Total collateral collected (optional tracking)
    }

    /// @notice User position in a pool
    struct UserPosition {
        uint256 scaled; // LP units owned
        uint256 collDebt; // Reward debt (scaled * accCollPerScaled at last update)
    }

    // Pool ID => Pool data (ASK pools - selling shares for collateral)
    mapping(bytes32 => Pool) public pools;

    // Pool ID => User => Position
    mapping(bytes32 => mapping(address => UserPosition)) public positions;

    /*//////////////////////////////////////////////////////////////
                    BID POOL STRUCTS (BUY-SIDE LIQUIDITY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Bid pool state - collateral pool buying shares
    /// @dev Mirror of Pool struct but collateral in, shares out
    struct BidPool {
        uint256 totalCollateral; // Remaining collateral available to spend
        uint256 totalScaled; // Total LP units issued
        uint256 accSharesPerScaled; // Cumulative shares per LP unit (scaled by 1e18)
        uint256 sharesAcquired; // Total shares bought (optional tracking)
    }

    /// @notice User position in a bid pool
    struct BidPosition {
        uint256 scaled; // LP units owned
        uint256 sharesDebt; // Reward debt (scaled * accSharesPerScaled at last update)
    }

    // Bid Pool ID => BidPool data
    mapping(bytes32 => BidPool) public bidPools;

    // Bid Pool ID => User => Position
    mapping(bytes32 => mapping(address => BidPosition)) public bidPositions;

    /*//////////////////////////////////////////////////////////////
                    PRICE BITMAP FOR BEST BID/ASK DISCOVERY
    //////////////////////////////////////////////////////////////*/

    /// @dev Bitmap tracking active price levels
    /// Key: keccak256(marketId, isYes, isAsk) => 40 uint256s covering prices 0-10239
    /// Each bit represents whether a pool exists at that price (1-9999 valid range)
    mapping(bytes32 => uint256[40]) internal priceBitmap;

    constructor() payable {
        PAMM.setOperator(address(PM_HOOK_ROUTER), true);
    }

    receive() external payable {}

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, ERR_REENTRANCY)
                revert(0x00, 0x04)
            }
            tstore(REENTRANCY_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(REENTRANCY_SLOT, 0)
        }
    }

    function _revert(bytes4 selector, uint8 code) internal pure {
        assembly ("memory-safe") {
            mstore(0x00, selector)
            mstore(0x04, code)
            revert(0x00, 0x24)
        }
    }

    /*//////////////////////////////////////////////////////////////
                    POOLED ORDERBOOK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getPoolId(uint256 marketId, bool isYes, uint256 priceInBps)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(marketId, isYes, priceInBps));
    }

    /// @dev Get NO token ID using PAMM's formula
    function _getNoId(uint256 marketId) internal pure returns (uint256 noId) {
        assembly ("memory-safe") {
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, marketId)
            noId := keccak256(0x00, 0x2a)
        }
    }

    function _getTokenId(uint256 marketId, bool isYes) internal pure returns (uint256) {
        return isYes ? marketId : _getNoId(marketId);
    }

    /// @notice Get user's position in a pool
    /// @dev Uses accumulator model: pending = (scaled * acc) / 1e18 - debt
    function getUserPosition(uint256 marketId, bool isYes, uint256 priceInBps, address user)
        public
        view
        returns (
            uint256 userScaled,
            uint256 userWithdrawableShares,
            uint256 userPendingCollateral,
            uint256 userCollateralDebt
        )
    {
        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage pool = pools[poolId];
        UserPosition storage pos = positions[poolId][user];

        userScaled = pos.scaled;
        if (userScaled == 0) return (0, 0, 0, 0);

        // Withdrawable shares = user's portion of remaining pool shares
        if (pool.totalScaled > 0) {
            userWithdrawableShares = mulDiv(pos.scaled, pool.totalShares, pool.totalScaled);
        }

        // Pending collateral = accumulated - debt
        uint256 accumulated = mulDiv(pos.scaled, pool.accCollPerScaled, ACC);
        userPendingCollateral = accumulated > pos.collDebt ? accumulated - pos.collDebt : 0;

        userCollateralDebt = pos.collDebt;
    }

    /// @notice Mint shares and pool one side at a specific price
    /// @dev Uses accumulator model to prevent late joiner theft
    function mintAndPool(
        uint256 marketId,
        uint256 collateralIn,
        bool keepYes,
        uint256 priceInBps,
        address to
    ) public payable nonReentrant returns (bytes32 poolId) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1);
        if (priceInBps == 0 || priceInBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value != collateralIn) _revert(ERR_VALIDATION, 3);
        } else {
            if (msg.value != 0) _revert(ERR_VALIDATION, 4);
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            _ensureApproval(collateral, address(PAMM));
        }

        PAMM.split{value: collateral == ETH ? collateralIn : 0}(
            marketId, collateralIn, address(this)
        );

        uint256 keepId = _getTokenId(marketId, keepYes);
        bool success = PAMM.transfer(to, keepId, collateralIn);
        if (!success) _revert(ERR_TRANSFER, 0);

        bool poolIsYes = !keepYes;
        poolId = getPoolId(marketId, poolIsYes, priceInBps);

        Pool storage pool = pools[poolId];
        bool wasEmpty = pool.totalShares == 0;

        _deposit(pool, positions[poolId][to], collateralIn);

        // Set bitmap if this is first deposit to this pool
        if (wasEmpty) {
            _setPriceBit(marketId, poolIsYes, true, priceInBps, true);
        }

        emit MintAndPool(marketId, msg.sender, poolId, collateralIn, keepYes, priceInBps);
    }

    /// @notice Internal: Deposit shares into pool (accumulator model)
    function _deposit(Pool storage p, UserPosition storage u, uint256 sharesIn) internal {
        uint256 mintScaled;
        if (p.totalScaled == 0) {
            // First depositor: 1:1 ratio
            mintScaled = sharesIn;
        } else if (p.totalShares == 0) {
            // Pool exhausted but LPs haven't withdrawn - no valid exchange rate
            _revert(ERR_STATE, 2);
        } else {
            // Buy in at current exchange rate
            // Round DOWN to favor existing LPs (safe direction)
            mintScaled = mulDiv(sharesIn, p.totalScaled, p.totalShares);
            if (mintScaled == 0) _revert(ERR_VALIDATION, 10); // Deposit too small
        }

        p.totalShares += sharesIn;
        p.totalScaled += mintScaled;

        u.scaled += mintScaled;
        // Add debt only for NEW units - preserves pending rewards from existing units
        u.collDebt += mulDiv(mintScaled, p.accCollPerScaled, ACC);
    }

    /// @notice Fill shares from a pool
    function fillFromPool(
        uint256 marketId,
        bool isYes,
        uint256 priceInBps,
        uint256 sharesWanted,
        address to
    ) public payable nonReentrant returns (uint256 sharesBought, uint256 collateralPaid) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (sharesWanted == 0) _revert(ERR_VALIDATION, 1);

        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage pool = pools[poolId];

        if (sharesWanted > pool.totalShares) _revert(ERR_LIQUIDITY, 0);

        sharesBought = sharesWanted;
        // Use CEILING division to protect sellers
        collateralPaid = ceilDiv(sharesWanted * priceInBps, BPS_DENOM);
        if (collateralPaid == 0) _revert(ERR_VALIDATION, 5);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value != collateralPaid) _revert(ERR_VALIDATION, 3);
        } else {
            if (msg.value != 0) _revert(ERR_VALIDATION, 4);
            _safeTransferFrom(collateral, msg.sender, address(this), collateralPaid);
        }

        _fill(pool, sharesBought, collateralPaid);

        // Clear bitmap if pool is now empty
        if (pool.totalShares == 0) {
            _setPriceBit(marketId, isYes, true, priceInBps, false);
        }

        uint256 tokenId = _getTokenId(marketId, isYes);
        bool success = PAMM.transfer(to, tokenId, sharesBought);
        if (!success) _revert(ERR_TRANSFER, 0);

        emit PoolFilled(poolId, msg.sender, sharesBought, collateralPaid);
    }

    /// @notice Internal: Fill from pool (accumulator model)
    function _fill(Pool storage p, uint256 sharesOut, uint256 collateralIn) internal {
        if (p.totalScaled == 0) _revert(ERR_STATE, 1); // Empty pool

        // Remove shares from pool
        p.totalShares -= sharesOut;

        // Distribute collateral to LP units (immutable snapshot)
        p.collateralEarned += collateralIn;
        p.accCollPerScaled += mulDiv(collateralIn, ACC, p.totalScaled);
    }

    /// @notice Claim collateral proceeds from pool fills
    function claimProceeds(uint256 marketId, bool isYes, uint256 priceInBps, address to)
        public
        nonReentrant
        returns (uint256 collateralClaimed)
    {
        if (to == address(0)) to = msg.sender;

        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage pool = pools[poolId];
        UserPosition storage pos = positions[poolId][msg.sender];

        collateralClaimed = _claim(pool, pos);

        if (collateralClaimed > 0) {
            address collateral;
            (,,,,, collateral,) = PAMM.markets(marketId);

            if (collateral == ETH) {
                _safeTransferETH(to, collateralClaimed);
            } else {
                _safeTransfer(collateral, to, collateralClaimed);
            }

            emit ProceedsClaimed(poolId, msg.sender, collateralClaimed);
        }
    }

    /// @notice Internal: Claim proceeds (accumulator model)
    function _claim(Pool storage p, UserPosition storage u) internal returns (uint256 claimable) {
        uint256 accumulated = mulDiv(u.scaled, p.accCollPerScaled, ACC);
        if (accumulated <= u.collDebt) return 0;

        claimable = accumulated - u.collDebt;
        u.collDebt = accumulated;
    }

    /// @notice Withdraw unfilled shares from pool
    function withdrawFromPool(
        uint256 marketId,
        bool isYes,
        uint256 priceInBps,
        uint256 sharesToWithdraw,
        address to
    ) public nonReentrant returns (uint256 sharesWithdrawn) {
        if (to == address(0)) to = msg.sender;

        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage pool = pools[poolId];
        UserPosition storage pos = positions[poolId][msg.sender];

        sharesWithdrawn = _withdraw(pool, pos, sharesToWithdraw);

        // Clear bitmap if pool is now empty
        if (pool.totalShares == 0) {
            _setPriceBit(marketId, isYes, true, priceInBps, false);
        }

        uint256 tokenId = _getTokenId(marketId, isYes);
        bool success = PAMM.transfer(to, tokenId, sharesWithdrawn);
        if (!success) _revert(ERR_TRANSFER, 0);

        emit SharesWithdrawn(poolId, msg.sender, sharesWithdrawn);
    }

    /// @notice Internal: Withdraw shares (accumulator model)
    function _withdraw(Pool storage p, UserPosition storage u, uint256 sharesWanted)
        internal
        returns (uint256 sharesOut)
    {
        // User's maximum withdrawable shares
        uint256 userMax = p.totalScaled > 0 ? mulDiv(u.scaled, p.totalShares, p.totalScaled) : 0;
        if (userMax == 0) _revert(ERR_VALIDATION, 6);

        sharesOut = (sharesWanted == 0) ? userMax : sharesWanted;
        if (sharesOut > userMax) _revert(ERR_VALIDATION, 8);

        // Burn corresponding LP units (round UP for safety)
        uint256 burnScaled = ceilDiv(sharesOut * p.totalScaled, p.totalShares);
        if (burnScaled > u.scaled) burnScaled = u.scaled; // Safety cap

        // Update pool
        p.totalShares -= sharesOut;
        p.totalScaled -= burnScaled;

        // Update user - subtract proportional debt to preserve pending
        uint256 debtToRemove = mulDiv(burnScaled, p.accCollPerScaled, ACC);
        u.scaled -= burnScaled;
        u.collDebt = u.collDebt > debtToRemove ? u.collDebt - debtToRemove : 0;
    }

    /*//////////////////////////////////////////////////////////////
                    VAULT INTEGRATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint shares and deposit one side to PMHookRouter vault
    function mintAndVault(uint256 marketId, uint256 collateralIn, bool keepYes, address to)
        public
        payable
        nonReentrant
        returns (uint256 sharesKept, uint256 vaultShares)
    {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value != collateralIn) _revert(ERR_VALIDATION, 3);
        } else {
            if (msg.value != 0) _revert(ERR_VALIDATION, 4);
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            _ensureApproval(collateral, address(PAMM));
        }

        PAMM.split{value: collateral == ETH ? collateralIn : 0}(
            marketId, collateralIn, address(this)
        );

        uint256 keepId = _getTokenId(marketId, keepYes);
        sharesKept = collateralIn;
        bool success = PAMM.transfer(to, keepId, sharesKept);
        if (!success) _revert(ERR_TRANSFER, 0);

        vaultShares =
            PM_HOOK_ROUTER.depositToVault(marketId, !keepYes, collateralIn, to, type(uint256).max);

        emit MintAndVault(marketId, msg.sender, collateralIn, keepYes, sharesKept, vaultShares);
    }

    /// @notice Buy shares with integrated routing (pool → vault OTC → AMM → mint)
    /// @param poolPriceInBps Optional: Try pooled orderbook at this price first (0 = skip pool)
    /// @param feeOrHook Deprecated parameter (PMHookRouter now uses canonical feeOrHook internally)
    function buy(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 poolPriceInBps,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public payable nonReentrant returns (uint256 totalSharesOut, bytes4[] memory sources) {
        if (to == address(0)) to = msg.sender;
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1);
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        // Track balance BEFORE operations for proper refund calculation
        uint256 balanceBefore = collateral == ETH ? address(this).balance - msg.value : 0;

        if (collateral == ETH) {
            if (msg.value != collateralIn) _revert(ERR_VALIDATION, 3);
        } else {
            if (msg.value != 0) _revert(ERR_VALIDATION, 4);
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
        }

        uint256 remainingCollateral = collateralIn;
        uint256 poolCollateralKept = 0;

        // Step 1: Try pooled orderbook first (if price specified)
        bool filledFromPool = false;
        if (poolPriceInBps > 0 && poolPriceInBps < BPS_DENOM) {
            bytes32 poolId = getPoolId(marketId, buyYes, poolPriceInBps);
            Pool storage pool = pools[poolId];

            if (pool.totalShares > 0) {
                // Calculate max shares we can buy with our collateral at this price
                uint256 maxSharesAtPrice = mulDiv(remainingCollateral, BPS_DENOM, poolPriceInBps);
                uint256 sharesToBuy =
                    maxSharesAtPrice < pool.totalShares ? maxSharesAtPrice : pool.totalShares;

                if (sharesToBuy > 0) {
                    uint256 collateralNeeded = ceilDiv(sharesToBuy * poolPriceInBps, BPS_DENOM);

                    // Fill from pool
                    _fill(pool, sharesToBuy, collateralNeeded);

                    // Clear bitmap if pool is now empty
                    if (pool.totalShares == 0) {
                        _setPriceBit(marketId, buyYes, true, poolPriceInBps, false);
                    }

                    uint256 tokenId = _getTokenId(marketId, buyYes);
                    bool success = PAMM.transfer(to, tokenId, sharesToBuy);
                    if (!success) _revert(ERR_TRANSFER, 0);

                    emit PoolFilled(poolId, msg.sender, sharesToBuy, collateralNeeded);

                    totalSharesOut = sharesToBuy;
                    filledFromPool = true;
                    poolCollateralKept = collateralNeeded;

                    // If fully satisfied, return early
                    if (collateralNeeded >= remainingCollateral) {
                        sources = new bytes4[](1);
                        sources[0] = bytes4(keccak256("POOL"));
                        return (totalSharesOut, sources);
                    }

                    // Otherwise, continue with remaining collateral
                    remainingCollateral -= collateralNeeded;
                }
            }
        }

        // Step 2: Route remaining through PMHookRouter (vault OTC → AMM → mint)
        if (remainingCollateral > 0) {
            if (collateral != ETH) {
                _ensureApproval(collateral, address(PM_HOOK_ROUTER));
            }

            (uint256 additionalShares, bytes4 pmSource,) = PM_HOOK_ROUTER.buyWithBootstrap{
                value: collateral == ETH ? remainingCollateral : 0
            }(
                marketId,
                buyYes,
                remainingCollateral,
                minSharesOut > totalSharesOut ? minSharesOut - totalSharesOut : 0,
                to,
                deadline
            );

            totalSharesOut += additionalShares;

            // Combine sources
            if (filledFromPool) {
                sources = new bytes4[](2);
                sources[0] = bytes4(keccak256("POOL"));
                sources[1] = pmSource;
            } else {
                sources = new bytes4[](1);
                sources[0] = pmSource;
            }
        }

        if (totalSharesOut < minSharesOut) _revert(ERR_VALIDATION, 9);

        // Refund any unused ETH using balance-based calculation
        if (collateral == ETH) {
            uint256 balanceAfter = address(this).balance;
            uint256 toRefund = balanceAfter > (balanceBefore + poolCollateralKept)
                ? balanceAfter - balanceBefore - poolCollateralKept
                : 0;

            if (toRefund > 0) {
                _safeTransferETH(msg.sender, toRefund);
            }
        }
    }

    /// @notice Sell shares with integrated routing (bid pool → vault OTC → AMM → merge)
    /// @param bidPoolPriceInBps Optional: Try bid pool at this price first (0 = skip pool)
    /// @param feeOrHook Deprecated parameter (PMHookRouter now uses canonical feeOrHook internally)
    function sell(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 bidPoolPriceInBps,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 totalCollateralOut, bytes4[] memory sources) {
        if (to == address(0)) to = msg.sender;
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);
        if (sharesIn == 0) _revert(ERR_VALIDATION, 1);

        uint256 tokenId = _getTokenId(marketId, sellYes);
        bool success = PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);
        if (!success) _revert(ERR_TRANSFER, 1);

        uint256 remainingShares = sharesIn;
        bool filledFromBidPool = false;

        // Step 1: Try bid pool first (if price specified)
        if (bidPoolPriceInBps > 0 && bidPoolPriceInBps < BPS_DENOM) {
            bytes32 bidPoolId = getBidPoolId(marketId, sellYes, bidPoolPriceInBps);
            BidPool storage bidPool = bidPools[bidPoolId];

            if (bidPool.totalCollateral > 0) {
                // Calculate max shares bid pool can buy at this price
                uint256 maxSharesAtPrice =
                    mulDiv(bidPool.totalCollateral, BPS_DENOM, bidPoolPriceInBps);
                uint256 sharesToSell =
                    maxSharesAtPrice < remainingShares ? maxSharesAtPrice : remainingShares;

                if (sharesToSell > 0) {
                    uint256 collateralToSpend = ceilDiv(sharesToSell * bidPoolPriceInBps, BPS_DENOM);
                    if (collateralToSpend > bidPool.totalCollateral) {
                        collateralToSpend = bidPool.totalCollateral;
                        sharesToSell = mulDiv(collateralToSpend, BPS_DENOM, bidPoolPriceInBps);
                    }

                    if (sharesToSell > 0 && collateralToSpend > 0) {
                        // Fill bid pool
                        _fillBidPool(bidPool, sharesToSell, collateralToSpend);

                        // Clear bitmap if bid pool is now empty
                        if (bidPool.totalCollateral == 0) {
                            _setPriceBit(marketId, sellYes, false, bidPoolPriceInBps, false);
                        }

                        // Transfer collateral to seller
                        address collateral;
                        (,,,,, collateral,) = PAMM.markets(marketId);
                        if (collateral == ETH) {
                            _safeTransferETH(to, collateralToSpend);
                        } else {
                            _safeTransfer(collateral, to, collateralToSpend);
                        }

                        emit BidPoolFilled(bidPoolId, msg.sender, sharesToSell, collateralToSpend);

                        totalCollateralOut = collateralToSpend;
                        filledFromBidPool = true;
                        remainingShares -= sharesToSell;

                        // If fully satisfied, return early
                        if (remainingShares == 0) {
                            sources = new bytes4[](1);
                            sources[0] = bytes4(keccak256("BIDPOOL"));
                            return (totalCollateralOut, sources);
                        }
                    }
                }
            }
        }

        // Step 2: Route remaining through PMHookRouter
        if (remainingShares > 0) {
            // Transfer remaining shares to PMHookRouter
            success = PAMM.transfer(address(PM_HOOK_ROUTER), tokenId, remainingShares);
            if (!success) _revert(ERR_TRANSFER, 0);

            bytes4 pmSource;
            uint256 pmCollateral;
            (pmCollateral, pmSource) = PM_HOOK_ROUTER.sellWithBootstrap(
                marketId,
                sellYes,
                remainingShares,
                minCollateralOut > totalCollateralOut ? minCollateralOut - totalCollateralOut : 0,
                to,
                deadline
            );

            totalCollateralOut += pmCollateral;

            if (filledFromBidPool) {
                sources = new bytes4[](2);
                sources[0] = bytes4(keccak256("BIDPOOL"));
                sources[1] = pmSource;
            } else {
                sources = new bytes4[](1);
                sources[0] = pmSource;
            }
        }

        if (totalCollateralOut < minCollateralOut) _revert(ERR_VALIDATION, 9);
    }

    /*//////////////////////////////////////////////////////////////
                    BID POOL FUNCTIONS (BUY-SIDE LIQUIDITY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Get bid pool ID for a market/side/price combination
    function getBidPoolId(uint256 marketId, bool buyYes, uint256 priceInBps)
        public
        pure
        returns (bytes32)
    {
        // Use different prefix to avoid collision with ask pools
        return keccak256(abi.encode("BID", marketId, buyYes, priceInBps));
    }

    /// @notice Get user's position in a bid pool
    function getBidPosition(uint256 marketId, bool buyYes, uint256 priceInBps, address user)
        public
        view
        returns (
            uint256 userScaled,
            uint256 userWithdrawableCollateral,
            uint256 userPendingShares,
            uint256 userSharesDebt
        )
    {
        bytes32 bidPoolId = getBidPoolId(marketId, buyYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];
        BidPosition storage pos = bidPositions[bidPoolId][user];

        userScaled = pos.scaled;
        if (userScaled == 0) return (0, 0, 0, 0);

        // Withdrawable collateral = user's portion of remaining pool collateral
        if (bidPool.totalScaled > 0) {
            userWithdrawableCollateral =
                mulDiv(pos.scaled, bidPool.totalCollateral, bidPool.totalScaled);
        }

        // Pending shares = accumulated - debt
        uint256 accumulated = mulDiv(pos.scaled, bidPool.accSharesPerScaled, ACC);
        userPendingShares = accumulated > pos.sharesDebt ? accumulated - pos.sharesDebt : 0;

        userSharesDebt = pos.sharesDebt;
    }

    /// @notice Create a bid pool - deposit collateral to buy shares at a specific price
    /// @param marketId Market to bid on
    /// @param collateralIn Collateral to deposit
    /// @param buyYes True to bid for YES shares, false for NO shares
    /// @param priceInBps Price willing to pay in basis points (1-9999)
    /// @param to Recipient of position (and eventually shares)
    function createBidPool(
        uint256 marketId,
        uint256 collateralIn,
        bool buyYes,
        uint256 priceInBps,
        address to
    ) public payable nonReentrant returns (bytes32 bidPoolId) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1);
        if (priceInBps == 0 || priceInBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value != collateralIn) _revert(ERR_VALIDATION, 3);
        } else {
            if (msg.value != 0) _revert(ERR_VALIDATION, 4);
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
        }

        bidPoolId = getBidPoolId(marketId, buyYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];
        bool wasEmpty = bidPool.totalCollateral == 0;

        _depositToBidPool(bidPool, bidPositions[bidPoolId][to], collateralIn);

        // Set bitmap if this is first deposit to this pool
        if (wasEmpty) {
            _setPriceBit(marketId, buyYes, false, priceInBps, true);
        }

        emit BidPoolCreated(marketId, msg.sender, bidPoolId, collateralIn, buyYes, priceInBps);
    }

    /// @notice Internal: Deposit collateral into bid pool
    function _depositToBidPool(BidPool storage p, BidPosition storage u, uint256 collateralIn)
        internal
    {
        uint256 mintScaled;
        if (p.totalScaled == 0) {
            mintScaled = collateralIn;
        } else if (p.totalCollateral == 0) {
            // Pool exhausted but LPs haven't withdrawn - no valid exchange rate
            _revert(ERR_STATE, 2);
        } else {
            mintScaled = mulDiv(collateralIn, p.totalScaled, p.totalCollateral);
            if (mintScaled == 0) _revert(ERR_VALIDATION, 10);
        }

        p.totalCollateral += collateralIn;
        p.totalScaled += mintScaled;

        u.scaled += mintScaled;
        // Add debt only for NEW units - preserves pending shares from existing units
        u.sharesDebt += mulDiv(mintScaled, p.accSharesPerScaled, ACC);
    }

    /// @notice Sell shares directly to a bid pool at the pool's price
    function sellToPool(
        uint256 marketId,
        bool isYes,
        uint256 priceInBps,
        uint256 sharesWanted,
        address to
    ) public nonReentrant returns (uint256 sharesSold, uint256 collateralReceived) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (sharesWanted == 0) _revert(ERR_VALIDATION, 1);

        bytes32 bidPoolId = getBidPoolId(marketId, isYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];

        // Calculate max shares pool can buy
        uint256 maxShares = mulDiv(bidPool.totalCollateral, BPS_DENOM, priceInBps);
        if (sharesWanted > maxShares) _revert(ERR_LIQUIDITY, 0);

        sharesSold = sharesWanted;
        collateralReceived = ceilDiv(sharesWanted * priceInBps, BPS_DENOM);
        if (collateralReceived > bidPool.totalCollateral) {
            collateralReceived = bidPool.totalCollateral;
            sharesSold = mulDiv(collateralReceived, BPS_DENOM, priceInBps);
        }
        if (collateralReceived == 0) _revert(ERR_VALIDATION, 5);

        // Take shares from seller
        uint256 tokenId = _getTokenId(marketId, isYes);
        bool success = PAMM.transferFrom(msg.sender, address(this), tokenId, sharesSold);
        if (!success) _revert(ERR_TRANSFER, 1);

        // Fill bid pool
        _fillBidPool(bidPool, sharesSold, collateralReceived);

        // Clear bitmap if bid pool is now empty
        if (bidPool.totalCollateral == 0) {
            _setPriceBit(marketId, isYes, false, priceInBps, false);
        }

        // Pay seller
        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);
        if (collateral == ETH) {
            _safeTransferETH(to, collateralReceived);
        } else {
            _safeTransfer(collateral, to, collateralReceived);
        }

        emit BidPoolFilled(bidPoolId, msg.sender, sharesSold, collateralReceived);
    }

    /// @notice Internal: Fill bid pool (spend collateral, receive shares)
    function _fillBidPool(BidPool storage p, uint256 sharesIn, uint256 collateralOut) internal {
        if (p.totalScaled == 0) _revert(ERR_STATE, 1);

        p.totalCollateral -= collateralOut;
        p.sharesAcquired += sharesIn;
        p.accSharesPerScaled += mulDiv(sharesIn, ACC, p.totalScaled);
    }

    /// @notice Claim shares from bid pool fills
    function claimBidShares(uint256 marketId, bool isYes, uint256 priceInBps, address to)
        public
        nonReentrant
        returns (uint256 sharesClaimed)
    {
        if (to == address(0)) to = msg.sender;

        bytes32 bidPoolId = getBidPoolId(marketId, isYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];
        BidPosition storage pos = bidPositions[bidPoolId][msg.sender];

        sharesClaimed = _claimBidShares(bidPool, pos);

        if (sharesClaimed > 0) {
            uint256 tokenId = _getTokenId(marketId, isYes);
            bool success = PAMM.transfer(to, tokenId, sharesClaimed);
            if (!success) _revert(ERR_TRANSFER, 0);

            emit BidCollateralClaimed(bidPoolId, msg.sender, sharesClaimed);
        }
    }

    /// @notice Internal: Claim shares from bid pool
    function _claimBidShares(BidPool storage p, BidPosition storage u)
        internal
        returns (uint256 claimable)
    {
        uint256 accumulated = mulDiv(u.scaled, p.accSharesPerScaled, ACC);
        if (accumulated <= u.sharesDebt) return 0;

        claimable = accumulated - u.sharesDebt;
        u.sharesDebt = accumulated;
    }

    /// @notice Withdraw unfilled collateral from bid pool
    function withdrawFromBidPool(
        uint256 marketId,
        bool isYes,
        uint256 priceInBps,
        uint256 collateralToWithdraw,
        address to
    ) public nonReentrant returns (uint256 collateralWithdrawn) {
        if (to == address(0)) to = msg.sender;

        bytes32 bidPoolId = getBidPoolId(marketId, isYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];
        BidPosition storage pos = bidPositions[bidPoolId][msg.sender];

        collateralWithdrawn = _withdrawFromBidPool(bidPool, pos, collateralToWithdraw);

        // Clear bitmap if bid pool is now empty
        if (bidPool.totalCollateral == 0) {
            _setPriceBit(marketId, isYes, false, priceInBps, false);
        }

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            _safeTransferETH(to, collateralWithdrawn);
        } else {
            _safeTransfer(collateral, to, collateralWithdrawn);
        }

        emit BidCollateralWithdrawn(bidPoolId, msg.sender, collateralWithdrawn);
    }

    /// @notice Internal: Withdraw from bid pool
    function _withdrawFromBidPool(
        BidPool storage p,
        BidPosition storage u,
        uint256 collateralWanted
    ) internal returns (uint256 collateralOut) {
        uint256 userMax = p.totalScaled > 0 ? mulDiv(u.scaled, p.totalCollateral, p.totalScaled) : 0;
        if (userMax == 0) _revert(ERR_VALIDATION, 6);

        collateralOut = (collateralWanted == 0) ? userMax : collateralWanted;
        if (collateralOut > userMax) _revert(ERR_VALIDATION, 8);

        uint256 burnScaled = ceilDiv(collateralOut * p.totalScaled, p.totalCollateral);
        if (burnScaled > u.scaled) burnScaled = u.scaled;

        p.totalCollateral -= collateralOut;
        p.totalScaled -= burnScaled;

        // Update user - subtract proportional debt to preserve pending
        uint256 debtToRemove = mulDiv(burnScaled, p.accSharesPerScaled, ACC);
        u.scaled -= burnScaled;
        u.sharesDebt = u.sharesDebt > debtToRemove ? u.sharesDebt - debtToRemove : 0;
    }

    /*//////////////////////////////////////////////////////////////
                    VAULT LIFECYCLE WRAPPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Provide liquidity to vault and/or AMM in one transaction
    /// @dev Splits collateral, deposits to vaults and AMM as specified
    function provideLiquidity(
        uint256 marketId,
        uint256 collateralAmount,
        uint256 vaultYesShares,
        uint256 vaultNoShares,
        uint256 ammLPShares,
        uint256 minAmount0,
        uint256 minAmount1,
        address to,
        uint256 deadline
    )
        public
        payable
        nonReentrant
        returns (uint256 yesVaultSharesMinted, uint256 noVaultSharesMinted, uint256 ammLiquidity)
    {
        if (to == address(0)) to = msg.sender;

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value != collateralAmount) _revert(ERR_VALIDATION, 3);
        } else {
            if (msg.value != 0) _revert(ERR_VALIDATION, 4);
            _safeTransferFrom(collateral, msg.sender, address(this), collateralAmount);
            _ensureApproval(collateral, address(PM_HOOK_ROUTER));
        }

        (yesVaultSharesMinted, noVaultSharesMinted, ammLiquidity) = PM_HOOK_ROUTER.provideLiquidity{
            value: collateral == ETH ? collateralAmount : 0
        }(
            marketId,
            collateralAmount,
            vaultYesShares,
            vaultNoShares,
            ammLPShares,
            minAmount0,
            minAmount1,
            to,
            deadline
        );

        emit LiquidityProvided(
            marketId, msg.sender, yesVaultSharesMinted, noVaultSharesMinted, ammLiquidity
        );
    }

    /*//////////////////////////////////////////////////////////////
                        MULTICALL & PERMIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute multiple calls in a single transaction
    function multicall(bytes[] calldata data) public payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i < data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }

    /// @notice Standard ERC-2612 permit
    function permit(
        address token,
        address owner,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xd505accf00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), value)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), v)
            mstore(add(m, 0xa4), r)
            mstore(add(m, 0xc4), s)

            let ok := call(gas(), token, 0, m, 0xe4, 0, 0)
            if iszero(ok) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }

            switch returndatasize()
            case 0 {} // No return data is fine
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) }
            }
            default { revert(0, 0) }

            mstore(0x40, add(m, 0x100))
        }
    }

    /// @notice DAI-style permit
    function permitDAI(
        address token,
        address owner,
        uint256 nonce,
        uint256 deadline,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x8fcbaf0c00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), nonce)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), allowed)
            mstore(add(m, 0xa4), v)
            mstore(add(m, 0xc4), r)
            mstore(add(m, 0xe4), s)

            let ok := call(gas(), token, 0, m, 0x104, 0, 0)
            if iszero(ok) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }

            switch returndatasize()
            case 0 {} // No return data is fine
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) }
            }
            default { revert(0, 0) }

            mstore(0x40, add(m, 0x120))
        }
    }

    /*//////////////////////////////////////////////////////////////
                        POOL DISCOVERABILITY (VIEW FUNCTIONS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Get ASK pool depths at multiple price levels for a market/side
    /// @param marketId The market ID
    /// @param isYes True for YES pools, false for NO pools
    /// @param pricesInBps Array of prices to query (in basis points)
    /// @return depths Array of available shares at each price level
    function getPoolDepths(uint256 marketId, bool isYes, uint256[] calldata pricesInBps)
        external
        view
        returns (uint256[] memory depths)
    {
        depths = new uint256[](pricesInBps.length);
        for (uint256 i; i < pricesInBps.length; ++i) {
            bytes32 poolId = getPoolId(marketId, isYes, pricesInBps[i]);
            depths[i] = pools[poolId].totalShares;
        }
    }

    /// @notice Get BID pool depths at multiple price levels for a market/side
    /// @param marketId The market ID
    /// @param buyYes True for YES bid pools, false for NO bid pools
    /// @param pricesInBps Array of prices to query (in basis points)
    /// @return depths Array of available collateral at each price level
    function getBidPoolDepths(uint256 marketId, bool buyYes, uint256[] calldata pricesInBps)
        external
        view
        returns (uint256[] memory depths)
    {
        depths = new uint256[](pricesInBps.length);
        for (uint256 i; i < pricesInBps.length; ++i) {
            bytes32 bidPoolId = getBidPoolId(marketId, buyYes, pricesInBps[i]);
            depths[i] = bidPools[bidPoolId].totalCollateral;
        }
    }

    /// @notice Get full orderbook view for a market side
    /// @dev Returns both ASK (shares for sale) and BID (collateral to buy) depths
    /// @param marketId The market ID
    /// @param isYes True for YES side, false for NO side
    /// @param pricesInBps Array of prices to query
    /// @return askDepths Shares available for sale at each price (ASK pools)
    /// @return bidDepths Collateral available to buy at each price (BID pools)
    function getOrderbook(uint256 marketId, bool isYes, uint256[] calldata pricesInBps)
        external
        view
        returns (uint256[] memory askDepths, uint256[] memory bidDepths)
    {
        askDepths = new uint256[](pricesInBps.length);
        bidDepths = new uint256[](pricesInBps.length);

        for (uint256 i; i < pricesInBps.length; ++i) {
            bytes32 askPoolId = getPoolId(marketId, isYes, pricesInBps[i]);
            bytes32 bidPoolId = getBidPoolId(marketId, isYes, pricesInBps[i]);

            askDepths[i] = pools[askPoolId].totalShares;
            bidDepths[i] = bidPools[bidPoolId].totalCollateral;
        }
    }

    /// @notice Get detailed pool info for a specific ASK pool
    /// @return totalShares Remaining shares available
    /// @return totalScaled Total LP units issued
    /// @return collateralEarned Total collateral collected from fills
    function getPoolInfo(uint256 marketId, bool isYes, uint256 priceInBps)
        external
        view
        returns (uint256 totalShares, uint256 totalScaled, uint256 collateralEarned)
    {
        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage pool = pools[poolId];
        return (pool.totalShares, pool.totalScaled, pool.collateralEarned);
    }

    /// @notice Get detailed bid pool info for a specific BID pool
    /// @return totalCollateral Remaining collateral available
    /// @return totalScaled Total LP units issued
    /// @return sharesAcquired Total shares bought from fills
    function getBidPoolInfo(uint256 marketId, bool buyYes, uint256 priceInBps)
        external
        view
        returns (uint256 totalCollateral, uint256 totalScaled, uint256 sharesAcquired)
    {
        bytes32 bidPoolId = getBidPoolId(marketId, buyYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];
        return (bidPool.totalCollateral, bidPool.totalScaled, bidPool.sharesAcquired);
    }

    /*//////////////////////////////////////////////////////////////
                        BEST BID/ASK DISCOVERY
    //////////////////////////////////////////////////////////////*/

    /// @notice Get best ASK price (lowest price with shares for sale)
    /// @param marketId The market ID
    /// @param isYes True for YES side, false for NO side
    /// @return price Best ask price in bps (0 if no asks)
    /// @return depth Shares available at best price
    function getBestAsk(uint256 marketId, bool isYes)
        external
        view
        returns (uint256 price, uint256 depth)
    {
        bytes32 key = _getBitmapKey(marketId, isYes, true);

        // Scan from low to high (find lowest price with liquidity)
        for (uint256 bucket; bucket < 40; ++bucket) {
            uint256 bits = priceBitmap[key][bucket];
            while (bits != 0) {
                uint256 bit = _lowestSetBit(bits);
                price = (bucket << 8) | bit;
                bytes32 poolId = getPoolId(marketId, isYes, price);
                depth = pools[poolId].totalShares;
                if (depth > 0) return (price, depth);
                bits &= bits - 1; // Clear this bit and continue
            }
        }
    }

    /// @notice Get best BID price (highest price with collateral to buy)
    /// @param marketId The market ID
    /// @param buyYes True for YES side, false for NO side
    /// @return price Best bid price in bps (0 if no bids)
    /// @return depth Collateral available at best price
    function getBestBid(uint256 marketId, bool buyYes)
        external
        view
        returns (uint256 price, uint256 depth)
    {
        bytes32 key = _getBitmapKey(marketId, buyYes, false);

        // Scan from high to low (find highest price with liquidity)
        for (uint256 i = 40; i > 0; --i) {
            uint256 bucket = i - 1;
            uint256 bits = priceBitmap[key][bucket];
            while (bits != 0) {
                uint256 bit = _highestSetBit(bits);
                price = (bucket << 8) | bit;
                bytes32 bidPoolId = getBidPoolId(marketId, buyYes, price);
                depth = bidPools[bidPoolId].totalCollateral;
                if (depth > 0) return (price, depth);
                bits &= ~(1 << bit); // Clear this bit and continue
            }
        }
    }

    /// @notice Get market spread (best bid and ask for a side)
    /// @return bestBidPrice Highest bid price (0 if none)
    /// @return bestBidDepth Collateral at best bid
    /// @return bestAskPrice Lowest ask price (0 if none)
    /// @return bestAskDepth Shares at best ask
    function getSpread(uint256 marketId, bool isYes)
        external
        view
        returns (
            uint256 bestBidPrice,
            uint256 bestBidDepth,
            uint256 bestAskPrice,
            uint256 bestAskDepth
        )
    {
        // Best bid (scan high to low)
        bytes32 bidKey = _getBitmapKey(marketId, isYes, false);
        bool foundBid;
        for (uint256 i = 40; i > 0 && !foundBid; --i) {
            uint256 bucket = i - 1;
            uint256 bits = priceBitmap[bidKey][bucket];
            while (bits != 0 && !foundBid) {
                uint256 bit = _highestSetBit(bits);
                uint256 price = (bucket << 8) | bit;
                bytes32 bidPoolId = getBidPoolId(marketId, isYes, price);
                uint256 depth = bidPools[bidPoolId].totalCollateral;
                if (depth > 0) {
                    bestBidPrice = price;
                    bestBidDepth = depth;
                    foundBid = true;
                }
                bits &= ~(1 << bit);
            }
        }

        // Best ask (scan low to high)
        bytes32 askKey = _getBitmapKey(marketId, isYes, true);
        bool foundAsk;
        for (uint256 bucket; bucket < 40 && !foundAsk; ++bucket) {
            uint256 bits = priceBitmap[askKey][bucket];
            while (bits != 0 && !foundAsk) {
                uint256 bit = _lowestSetBit(bits);
                uint256 price = (bucket << 8) | bit;
                bytes32 poolId = getPoolId(marketId, isYes, price);
                uint256 depth = pools[poolId].totalShares;
                if (depth > 0) {
                    bestAskPrice = price;
                    bestAskDepth = depth;
                    foundAsk = true;
                }
                bits &= bits - 1;
            }
        }
    }

    /// @notice Get all active price levels with depth (for orderbook UI)
    /// @dev Scans bitmap and returns non-zero price levels up to maxLevels (capped at 50)
    /// @param marketId The market ID
    /// @param isYes True for YES side, false for NO side
    /// @param maxLevels Maximum price levels per side (capped at 50)
    /// @return askPrices Active ask prices (ascending)
    /// @return askDepths Shares at each ask price
    /// @return bidPrices Active bid prices (descending)
    /// @return bidDepths Collateral at each bid price
    function getActiveLevels(uint256 marketId, bool isYes, uint256 maxLevels)
        external
        view
        returns (
            uint256[] memory askPrices,
            uint256[] memory askDepths,
            uint256[] memory bidPrices,
            uint256[] memory bidDepths
        )
    {
        // Cap to prevent excessive memory allocation
        if (maxLevels > 50) maxLevels = 50;

        // Allocate arrays (will resize via assembly)
        askPrices = new uint256[](maxLevels);
        askDepths = new uint256[](maxLevels);
        bidPrices = new uint256[](maxLevels);
        bidDepths = new uint256[](maxLevels);

        uint256 askCount;
        uint256 bidCount;

        // Scan asks (low to high)
        bytes32 askKey = _getBitmapKey(marketId, isYes, true);
        for (uint256 bucket; bucket < 40 && askCount < maxLevels; ++bucket) {
            uint256 bits = priceBitmap[askKey][bucket];
            while (bits != 0 && askCount < maxLevels) {
                uint256 bit = _lowestSetBit(bits);
                uint256 price = (bucket << 8) | bit;
                uint256 depth = pools[getPoolId(marketId, isYes, price)].totalShares;
                if (depth > 0) {
                    askPrices[askCount] = price;
                    askDepths[askCount] = depth;
                    ++askCount;
                }
                bits &= bits - 1; // Clear lowest bit
            }
        }

        // Scan bids (high to low)
        bytes32 bidKey = _getBitmapKey(marketId, isYes, false);
        for (uint256 i = 40; i > 0 && bidCount < maxLevels; --i) {
            uint256 bucket = i - 1;
            uint256 bits = priceBitmap[bidKey][bucket];
            while (bits != 0 && bidCount < maxLevels) {
                uint256 bit = _highestSetBit(bits);
                uint256 price = (bucket << 8) | bit;
                uint256 depth = bidPools[getBidPoolId(marketId, isYes, price)].totalCollateral;
                if (depth > 0) {
                    bidPrices[bidCount] = price;
                    bidDepths[bidCount] = depth;
                    ++bidCount;
                }
                bits &= ~(1 << bit); // Clear highest bit
            }
        }

        // Resize arrays to actual count
        assembly ("memory-safe") {
            mstore(askPrices, askCount)
            mstore(askDepths, askCount)
            mstore(bidPrices, bidCount)
            mstore(bidDepths, bidCount)
        }
    }

    /// @notice Get all active positions for a user on a market side (for "My Orders" UI)
    /// @dev Scans bitmap for active pools and checks user's position at each.
    ///      NOTE: Only finds positions at pools with active liquidity. For fully-depleted
    ///      pools where user has unclaimed proceeds, use getUserPosition() with specific price
    ///      or index MintAndPool/BidPoolCreated events for complete coverage.
    /// @param marketId The market ID
    /// @param isYes True for YES side, false for NO side
    /// @param user Address to check positions for
    /// @return askPrices Prices where user has ASK positions (selling shares)
    /// @return askShares Withdrawable shares at each ASK price
    /// @return askPendingColl Pending collateral earnings at each ASK price
    /// @return bidPrices Prices where user has BID positions (buying shares)
    /// @return bidCollateral Withdrawable collateral at each BID price
    /// @return bidPendingShares Pending shares at each BID price
    function getUserActivePositions(uint256 marketId, bool isYes, address user)
        external
        view
        returns (
            uint256[] memory askPrices,
            uint256[] memory askShares,
            uint256[] memory askPendingColl,
            uint256[] memory bidPrices,
            uint256[] memory bidCollateral,
            uint256[] memory bidPendingShares
        )
    {
        // Cap at 50 positions per side (same as getActiveLevels)
        uint256 maxPositions = 50;

        askPrices = new uint256[](maxPositions);
        askShares = new uint256[](maxPositions);
        askPendingColl = new uint256[](maxPositions);
        bidPrices = new uint256[](maxPositions);
        bidCollateral = new uint256[](maxPositions);
        bidPendingShares = new uint256[](maxPositions);

        uint256 askCount;
        uint256 bidCount;

        // Scan ASK pools (user selling shares)
        bytes32 askKey = _getBitmapKey(marketId, isYes, true);
        for (uint256 bucket; bucket < 40 && askCount < maxPositions; ++bucket) {
            uint256 bits = priceBitmap[askKey][bucket];
            while (bits != 0 && askCount < maxPositions) {
                uint256 bit = _lowestSetBit(bits);
                uint256 price = (bucket << 8) | bit;

                bytes32 poolId = getPoolId(marketId, isYes, price);
                UserPosition storage pos = positions[poolId][user];

                if (pos.scaled > 0) {
                    Pool storage pool = pools[poolId];

                    // Calculate withdrawable shares
                    uint256 withdrawable = pool.totalScaled > 0
                        ? mulDiv(pos.scaled, pool.totalShares, pool.totalScaled)
                        : 0;

                    // Calculate pending collateral
                    uint256 accumulated = mulDiv(pos.scaled, pool.accCollPerScaled, ACC);
                    uint256 pending = accumulated > pos.collDebt ? accumulated - pos.collDebt : 0;

                    askPrices[askCount] = price;
                    askShares[askCount] = withdrawable;
                    askPendingColl[askCount] = pending;
                    ++askCount;
                }

                bits &= bits - 1;
            }
        }

        // Scan BID pools (user buying shares)
        bytes32 bidKey = _getBitmapKey(marketId, isYes, false);
        for (uint256 bucket; bucket < 40 && bidCount < maxPositions; ++bucket) {
            uint256 bits = priceBitmap[bidKey][bucket];
            while (bits != 0 && bidCount < maxPositions) {
                uint256 bit = _lowestSetBit(bits);
                uint256 price = (bucket << 8) | bit;

                bytes32 bidPoolId = getBidPoolId(marketId, isYes, price);
                BidPosition storage pos = bidPositions[bidPoolId][user];

                if (pos.scaled > 0) {
                    BidPool storage bidPool = bidPools[bidPoolId];

                    // Calculate withdrawable collateral
                    uint256 withdrawable = bidPool.totalScaled > 0
                        ? mulDiv(pos.scaled, bidPool.totalCollateral, bidPool.totalScaled)
                        : 0;

                    // Calculate pending shares
                    uint256 accumulated = mulDiv(pos.scaled, bidPool.accSharesPerScaled, ACC);
                    uint256 pending =
                        accumulated > pos.sharesDebt ? accumulated - pos.sharesDebt : 0;

                    bidPrices[bidCount] = price;
                    bidCollateral[bidCount] = withdrawable;
                    bidPendingShares[bidCount] = pending;
                    ++bidCount;
                }

                bits &= bits - 1;
            }
        }

        // Resize arrays
        assembly ("memory-safe") {
            mstore(askPrices, askCount)
            mstore(askShares, askCount)
            mstore(askPendingColl, askCount)
            mstore(bidPrices, bidCount)
            mstore(bidCollateral, bidCount)
            mstore(bidPendingShares, bidCount)
        }
    }

    /// @notice Batch query user positions at specific prices (for complete coverage with event indexing)
    /// @dev Use with prices from indexed MintAndPool/BidPoolCreated events for depleted pools
    /// @param marketId The market ID
    /// @param isYes True for YES side, false for NO side
    /// @param user Address to check
    /// @param prices Array of prices to check (from event index)
    /// @return askShares Withdrawable shares at each price (0 if no position)
    /// @return askPending Pending collateral at each price
    /// @return bidCollateral Withdrawable collateral at each price (0 if no position)
    /// @return bidPending Pending shares at each price
    function getUserPositionsBatch(
        uint256 marketId,
        bool isYes,
        address user,
        uint256[] calldata prices
    )
        external
        view
        returns (
            uint256[] memory askShares,
            uint256[] memory askPending,
            uint256[] memory bidCollateral,
            uint256[] memory bidPending
        )
    {
        uint256 len = prices.length;
        askShares = new uint256[](len);
        askPending = new uint256[](len);
        bidCollateral = new uint256[](len);
        bidPending = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            uint256 price = prices[i];

            // Check ASK position
            bytes32 poolId = getPoolId(marketId, isYes, price);
            UserPosition storage askPos = positions[poolId][user];
            if (askPos.scaled > 0) {
                Pool storage pool = pools[poolId];
                askShares[i] = pool.totalScaled > 0
                    ? mulDiv(askPos.scaled, pool.totalShares, pool.totalScaled)
                    : 0;
                uint256 acc = mulDiv(askPos.scaled, pool.accCollPerScaled, ACC);
                askPending[i] = acc > askPos.collDebt ? acc - askPos.collDebt : 0;
            }

            // Check BID position
            bytes32 bidPoolId = getBidPoolId(marketId, isYes, price);
            BidPosition storage bidPos = bidPositions[bidPoolId][user];
            if (bidPos.scaled > 0) {
                BidPool storage bidPool = bidPools[bidPoolId];
                bidCollateral[i] = bidPool.totalScaled > 0
                    ? mulDiv(bidPos.scaled, bidPool.totalCollateral, bidPool.totalScaled)
                    : 0;
                uint256 acc = mulDiv(bidPos.scaled, bidPool.accSharesPerScaled, ACC);
                bidPending[i] = acc > bidPos.sharesDebt ? acc - bidPos.sharesDebt : 0;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          QUOTE / SIMULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Simulate buying shares from ASK pools (sellers)
    /// @param marketId Market to buy in
    /// @param isYes True for YES shares, false for NO shares
    /// @param collateralIn Amount of collateral to spend
    /// @return sharesOut Total shares that would be received
    /// @return avgPrice Weighted average fill price in bps
    /// @return levelsFilled Number of price levels touched
    function quoteBuyFromPools(uint256 marketId, bool isYes, uint256 collateralIn)
        external
        view
        returns (uint256 sharesOut, uint256 avgPrice, uint256 levelsFilled)
    {
        if (collateralIn == 0) return (0, 0, 0);

        bytes32 bitmapKey = _getBitmapKey(marketId, isYes, true);
        uint256 remaining = collateralIn;
        uint256 totalCollateralSpent;

        // Scan from lowest ask price upward
        for (uint256 bucket; bucket < 40 && remaining > 0; ++bucket) {
            uint256 word = priceBitmap[bitmapKey][bucket];
            while (word != 0 && remaining > 0) {
                uint256 bit = _lowestSetBit(word);
                uint256 price = (bucket << 8) | bit;
                word &= ~(1 << bit);

                if (price == 0 || price >= BPS_DENOM) continue;

                bytes32 poolId = getPoolId(marketId, isYes, price);
                Pool storage pool = pools[poolId];
                uint256 depth = pool.totalShares;
                if (depth == 0) continue;

                // Cost to fill entire pool at this price
                uint256 costToFill = mulDiv(depth, price, BPS_DENOM);

                if (remaining >= costToFill) {
                    // Fill entire pool
                    sharesOut += depth;
                    totalCollateralSpent += costToFill;
                    remaining -= costToFill;
                    ++levelsFilled;
                } else {
                    // Partial fill
                    uint256 sharesBought = mulDiv(remaining, BPS_DENOM, price);
                    sharesOut += sharesBought;
                    totalCollateralSpent += remaining;
                    remaining = 0;
                    ++levelsFilled;
                }
            }
        }

        if (sharesOut > 0) {
            avgPrice = mulDiv(totalCollateralSpent, BPS_DENOM, sharesOut);
        }
    }

    /// @notice Simulate selling shares to BID pools (buyers)
    /// @param marketId Market to sell in
    /// @param isYes True for YES shares, false for NO shares
    /// @param sharesIn Amount of shares to sell
    /// @return collateralOut Total collateral that would be received
    /// @return avgPrice Weighted average fill price in bps
    /// @return levelsFilled Number of price levels touched
    function quoteSellToPools(uint256 marketId, bool isYes, uint256 sharesIn)
        external
        view
        returns (uint256 collateralOut, uint256 avgPrice, uint256 levelsFilled)
    {
        if (sharesIn == 0) return (0, 0, 0);

        bytes32 bitmapKey = _getBitmapKey(marketId, isYes, false); // false = BID
        uint256 remaining = sharesIn;
        uint256 totalSharesSold;

        // Scan from highest bid price downward
        for (uint256 b; b < 40 && remaining > 0; ++b) {
            uint256 bucket = 39 - b;
            uint256 word = priceBitmap[bitmapKey][bucket];
            while (word != 0 && remaining > 0) {
                uint256 bit = _highestSetBit(word);
                uint256 price = (bucket << 8) | bit;
                word &= ~(1 << bit);

                if (price == 0 || price >= BPS_DENOM) continue;

                bytes32 bidPoolId = getBidPoolId(marketId, isYes, price);
                BidPool storage bidPool = bidPools[bidPoolId];
                uint256 collateralDepth = bidPool.totalCollateral;
                if (collateralDepth == 0) continue;

                // Max shares this pool can buy at its price
                uint256 maxShares = mulDiv(collateralDepth, BPS_DENOM, price);

                if (remaining >= maxShares) {
                    // Fill entire pool
                    collateralOut += collateralDepth;
                    totalSharesSold += maxShares;
                    remaining -= maxShares;
                    ++levelsFilled;
                } else {
                    // Partial fill
                    uint256 collateralReceived = mulDiv(remaining, price, BPS_DENOM);
                    collateralOut += collateralReceived;
                    totalSharesSold += remaining;
                    remaining = 0;
                    ++levelsFilled;
                }
            }
        }

        if (totalSharesSold > 0) {
            avgPrice = mulDiv(collateralOut, BPS_DENOM, totalSharesSold);
        }
    }

    /// @notice Get basic market information for display
    /// @param marketId Market to query
    /// @return collateral Token address (address(0) for ETH)
    /// @return closeTime Unix timestamp when market closes
    /// @return tradingOpen Whether trading is currently allowed
    /// @return resolved Whether market has been resolved
    function getMarketInfo(uint256 marketId)
        external
        view
        returns (address collateral, uint64 closeTime, bool tradingOpen, bool resolved)
    {
        (, resolved,,, closeTime, collateral,) = PAMM.markets(marketId);
        tradingOpen = PAMM.tradingOpen(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Compute bitmap key for a market/side/type
    function _getBitmapKey(uint256 marketId, bool isYes, bool isAsk)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(marketId, isYes, isAsk));
    }

    /// @dev Set or clear a price bit in the bitmap
    function _setPriceBit(uint256 marketId, bool isYes, bool isAsk, uint256 priceInBps, bool active)
        internal
    {
        bytes32 key = _getBitmapKey(marketId, isYes, isAsk);
        uint256 bucket = priceInBps >> 8;
        uint256 bit = priceInBps & 0xff;

        if (active) {
            priceBitmap[key][bucket] |= (1 << bit);
        } else {
            priceBitmap[key][bucket] &= ~(1 << bit);
        }
    }

    /// @dev Find position of lowest set bit (0-255)
    function _lowestSetBit(uint256 x) internal pure returns (uint256) {
        // Isolate lowest bit and find its position
        return _highestSetBit(x & (~x + 1));
    }

    /// @dev Find position of highest set bit (0-255)
    function _highestSetBit(uint256 x) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            if gt(x, 0xffffffffffffffffffffffffffffffff) {
                x := shr(128, x)
                r := 128
            }
            if gt(x, 0xffffffffffffffff) {
                x := shr(64, x)
                r := or(r, 64)
            }
            if gt(x, 0xffffffff) {
                x := shr(32, x)
                r := or(r, 32)
            }
            if gt(x, 0xffff) {
                x := shr(16, x)
                r := or(r, 16)
            }
            if gt(x, 0xff) {
                x := shr(8, x)
                r := or(r, 8)
            }
            if gt(x, 0xf) {
                x := shr(4, x)
                r := or(r, 4)
            }
            if gt(x, 0x3) {
                x := shr(2, x)
                r := or(r, 2)
            }
            if gt(x, 0x1) { r := or(r, 1) }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Multiply then divide with overflow check
    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            z := mul(x, y)
            if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                mstore(0x00, ERR_COMPUTATION)
                mstore(0x04, 0)
                revert(0x00, 0x24)
            }
            z := div(z, d)
        }
    }

    /// @dev Ceiling division: ceil(x/y) = (x + y - 1) / y
    function ceilDiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            if iszero(y) {
                mstore(0x00, ERR_COMPUTATION)
                mstore(0x04, 2)
                revert(0x00, 0x24)
            }
            z := div(add(x, sub(y, 1)), y)
        }
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER HELPERS
    //////////////////////////////////////////////////////////////*/

    function _safeTransfer(address token, address to, uint256 amount) internal {
        assembly ("memory-safe") {
            mstore(0x14, to)
            mstore(0x34, amount)
            mstore(0x00, 0xa9059cbb000000000000000000000000)
            let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, ERR_TRANSFER)
                    mstore(0x04, 0)
                    revert(0x00, 0x24)
                }
            }
            mstore(0x34, 0)
        }
    }

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
                    mstore(0x00, ERR_TRANSFER)
                    mstore(0x04, 1)
                    revert(0x00, 0x24)
                }
            }
            mstore(0x60, 0)
            mstore(0x40, m)
        }
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, ERR_TRANSFER)
                mstore(0x04, 2)
                revert(0x00, 0x24)
            }
        }
    }

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
                        mstore(0x00, 0x3e3f8f73)
                        revert(0x00, 0x04)
                    }
                }
            }
            mstore(0x34, 0)
        }
    }
}
