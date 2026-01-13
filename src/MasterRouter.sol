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

    /*//////////////////////////////////////////////////////////////
                        VAULT INTEGRATION EVENTS
    //////////////////////////////////////////////////////////////*/

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

    // Pool ID => Pool data
    mapping(bytes32 => Pool) public pools;

    // Pool ID => User => Position
    mapping(bytes32 => mapping(address => UserPosition)) public positions;

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

        _deposit(pools[poolId], positions[poolId][to], collateralIn);

        emit MintAndPool(marketId, msg.sender, poolId, collateralIn, keepYes, priceInBps);
    }

    /// @notice Internal: Deposit shares into pool (accumulator model)
    function _deposit(Pool storage p, UserPosition storage u, uint256 sharesIn) internal {
        // Checkpoint user first
        _checkpoint(p, u);

        uint256 mintScaled;
        if (p.totalScaled == 0) {
            // First depositor: 1:1 ratio
            mintScaled = sharesIn;
        } else {
            // Buy in at current exchange rate
            // Round DOWN to favor existing LPs (safe direction)
            mintScaled = mulDiv(sharesIn, p.totalScaled, p.totalShares);
            if (mintScaled == 0) _revert(ERR_VALIDATION, 10); // Deposit too small
        }

        p.totalShares += sharesIn;
        p.totalScaled += mintScaled;

        u.scaled += mintScaled;
        // Set debt to current accumulator (no past rewards)
        u.collDebt = mulDiv(u.scaled, p.accCollPerScaled, ACC);
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
        _checkpoint(p, u);

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

        // Update user
        u.scaled -= burnScaled;
        u.collDebt = mulDiv(u.scaled, p.accCollPerScaled, ACC);
    }

    /// @notice Internal: Checkpoint user (update debt before balance changes)
    function _checkpoint(Pool storage p, UserPosition storage u) internal {
        // Update collDebt to current accumulator value
        // This ensures pending rewards are "locked in" before balance changes
        u.collDebt = mulDiv(u.scaled, p.accCollPerScaled, ACC);
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

    /// @notice Sell shares for immediate liquidity (vault OTC → AMM → merge)
    /// @dev For limit orders, use mintAndPool() instead to list at specific price
    /// @param feeOrHook Deprecated parameter (PMHookRouter now uses canonical feeOrHook internally)
    function sell(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 totalCollateralOut, bytes4[] memory sources) {
        if (to == address(0)) to = msg.sender;
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);

        uint256 tokenId = _getTokenId(marketId, sellYes);
        bool success = PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);
        if (!success) _revert(ERR_TRANSFER, 1);

        bytes4 source;
        (totalCollateralOut, source) = PM_HOOK_ROUTER.sellWithBootstrap(
            marketId, sellYes, sharesIn, minCollateralOut, to, deadline
        );

        // Wrap single source in array for consistent return type
        sources = new bytes4[](1);
        sources[0] = source;
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
                        MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Multiply then divide with overflow check (from PMHookRouter pattern)
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
