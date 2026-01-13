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
    function merge(uint256 marketId, uint256 amount, address to) external;
    function getNoId(uint256 marketId) external pure returns (uint256);
}

/// @notice PMHookRouter vault interface
interface IPMHookRouter {
    function depositToVault(uint256 marketId, bool isYes, uint256 shares, address receiver)
        external
        returns (uint256 vaultShares);

    function buyWithBootstrap(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 totalSharesOut, bytes4[] memory sources);

    function sellWithBootstrap(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external returns (uint256 totalCollateralOut, bytes4[] memory sources);
}

/// @title MasterRouter - Complete Abstraction Layer
/// @notice Pooled orderbook + vault integration for prediction markets
/// @dev Combines simple pooled orderbook with PMHookRouter vault abstractions
contract MasterRouter {
    address constant ETH = address(0);
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IPMHookRouter constant PM_HOOK_ROUTER =
        IPMHookRouter(0x000000000050D5716568008f83854D67c7ab3D22);

    uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268;
    uint256 constant BPS_DENOM = 10000;

    bytes4 constant ERR_VALIDATION = 0x077a9c33;
    bytes4 constant ERR_STATE = 0xd06e7808;
    bytes4 constant ERR_TRANSFER = 0x2929f974;
    bytes4 constant ERR_REENTRANCY = 0xab143c06;
    bytes4 constant ERR_LIQUIDITY = 0x4dae90b0;
    bytes4 constant ERR_TIMING = 0x3703bac9;
    bytes4 constant ERR_OVERFLOW = 0xc4c2c1b0;

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

    /// @notice Pooled liquidity at a specific price point
    struct PricePool {
        uint112 totalShares;
        uint112 sharesFilled;
        uint112 sharesWithdrawn;
        uint96 totalCollateralEarned;
    }

    // Pool ID => Pool data
    mapping(bytes32 => PricePool) public pools;

    // Pool ID => User => User's shares
    mapping(bytes32 => mapping(address => uint112)) public userPoolShares;

    // Pool ID => User => User's withdrawn shares
    mapping(bytes32 => mapping(address => uint112)) public userWithdrawnShares;

    // Pool ID => User => User's claimed collateral
    mapping(bytes32 => mapping(address => uint96)) public userClaimedCollateral;

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

    function getUserPosition(uint256 marketId, bool isYes, uint256 priceInBps, address user)
        external
        view
        returns (
            uint112 userShares,
            uint112 userUnfilledShares,
            uint256 userEarnedCollateral,
            uint96 userClaimedAmount
        )
    {
        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        PricePool storage pool = pools[poolId];

        userShares = userPoolShares[poolId][user];
        if (userShares == 0) return (0, 0, 0, 0);

        uint112 unfilledShares = pool.totalShares - pool.sharesFilled;
        uint256 userMaxUnfilled = (uint256(userShares) * unfilledShares) / pool.totalShares;
        uint112 userWithdrawn = userWithdrawnShares[poolId][user];

        userUnfilledShares =
            userWithdrawn >= userMaxUnfilled ? 0 : uint112(userMaxUnfilled - userWithdrawn);

        userEarnedCollateral = (uint256(userShares) * pool.totalCollateralEarned) / pool.totalShares;

        userClaimedAmount = userClaimedCollateral[poolId][user];
    }

    /// @notice Mint shares and pool one side at a specific price
    function mintAndPool(
        uint256 marketId,
        uint256 collateralIn,
        bool keepYes,
        uint256 priceInBps,
        address to
    ) external payable nonReentrant returns (bytes32 poolId) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1);
        if (priceInBps == 0 || priceInBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);
        if (collateralIn > type(uint112).max) _revert(ERR_OVERFLOW, 0);

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

        uint256 keepId = keepYes ? marketId : PAMM.getNoId(marketId);
        PAMM.transfer(to, keepId, collateralIn);

        bool poolIsYes = !keepYes;
        poolId = getPoolId(marketId, poolIsYes, priceInBps);

        PricePool storage pool = pools[poolId];
        unchecked {
            pool.totalShares += uint112(collateralIn);
            userPoolShares[poolId][to] += uint112(collateralIn);
        }

        emit MintAndPool(marketId, msg.sender, poolId, collateralIn, keepYes, priceInBps);
    }

    /// @notice Fill shares from a pool
    function fillFromPool(
        uint256 marketId,
        bool isYes,
        uint256 priceInBps,
        uint256 sharesWanted,
        address to
    ) external payable nonReentrant returns (uint256 sharesBought, uint256 collateralPaid) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (sharesWanted == 0) _revert(ERR_VALIDATION, 1);
        if (sharesWanted > type(uint112).max) _revert(ERR_OVERFLOW, 0);

        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        PricePool storage pool = pools[poolId];

        uint112 availableShares = pool.totalShares - pool.sharesFilled - pool.sharesWithdrawn;
        if (sharesWanted > availableShares) _revert(ERR_LIQUIDITY, 0);

        sharesBought = sharesWanted;
        collateralPaid = (sharesWanted * priceInBps) / BPS_DENOM;
        if (collateralPaid == 0) _revert(ERR_VALIDATION, 5);
        if (collateralPaid > type(uint96).max) _revert(ERR_OVERFLOW, 1);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value != collateralPaid) _revert(ERR_VALIDATION, 3);
        } else {
            if (msg.value != 0) _revert(ERR_VALIDATION, 4);
            _safeTransferFrom(collateral, msg.sender, address(this), collateralPaid);
        }

        uint256 tokenId = isYes ? marketId : PAMM.getNoId(marketId);
        PAMM.transfer(to, tokenId, sharesBought);

        unchecked {
            pool.sharesFilled += uint112(sharesBought);
            pool.totalCollateralEarned += uint96(collateralPaid);
        }

        emit PoolFilled(poolId, msg.sender, sharesBought, collateralPaid);
    }

    /// @notice Claim collateral proceeds from pool fills
    function claimProceeds(uint256 marketId, bool isYes, uint256 priceInBps, address to)
        external
        nonReentrant
        returns (uint256 collateralClaimed)
    {
        if (to == address(0)) to = msg.sender;

        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        PricePool storage pool = pools[poolId];

        uint112 userShares = userPoolShares[poolId][msg.sender];
        if (userShares == 0) return 0;
        if (pool.totalCollateralEarned == 0) return 0;

        uint256 userTotalEarned =
            (uint256(userShares) * pool.totalCollateralEarned) / pool.totalShares;
        uint96 alreadyClaimed = userClaimedCollateral[poolId][msg.sender];

        if (userTotalEarned <= alreadyClaimed) return 0;

        unchecked {
            collateralClaimed = userTotalEarned - alreadyClaimed;
        }

        userClaimedCollateral[poolId][msg.sender] = uint96(userTotalEarned);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            _safeTransferETH(to, collateralClaimed);
        } else {
            _safeTransfer(collateral, to, collateralClaimed);
        }

        emit ProceedsClaimed(poolId, msg.sender, collateralClaimed);
    }

    /// @notice Withdraw unfilled shares from pool
    function withdrawFromPool(
        uint256 marketId,
        bool isYes,
        uint256 priceInBps,
        uint256 sharesToWithdraw,
        address to
    ) external nonReentrant returns (uint256 sharesWithdrawn) {
        if (to == address(0)) to = msg.sender;

        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        PricePool storage pool = pools[poolId];

        uint112 userShares = userPoolShares[poolId][msg.sender];
        if (userShares == 0) _revert(ERR_VALIDATION, 6);

        uint112 unfilledShares = pool.totalShares - pool.sharesFilled;
        uint256 userMaxUnfilled = (uint256(userShares) * unfilledShares) / pool.totalShares;
        uint112 userWithdrawn = userWithdrawnShares[poolId][msg.sender];
        uint112 userUnfilledShares =
            userWithdrawn >= userMaxUnfilled ? 0 : uint112(userMaxUnfilled - userWithdrawn);

        if (userUnfilledShares == 0) _revert(ERR_VALIDATION, 7);

        if (sharesToWithdraw == 0) {
            sharesToWithdraw = userUnfilledShares;
        } else if (sharesToWithdraw > userUnfilledShares) {
            _revert(ERR_VALIDATION, 8);
        }

        sharesWithdrawn = sharesToWithdraw;

        unchecked {
            userWithdrawnShares[poolId][msg.sender] += uint112(sharesWithdrawn);
            pool.sharesWithdrawn += uint112(sharesWithdrawn);
        }

        uint256 tokenId = isYes ? marketId : PAMM.getNoId(marketId);
        PAMM.transfer(to, tokenId, sharesWithdrawn);

        emit SharesWithdrawn(poolId, msg.sender, sharesWithdrawn);
    }

    /*//////////////////////////////////////////////////////////////
                    VAULT INTEGRATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint shares and deposit one side to PMHookRouter vault
    function mintAndVault(uint256 marketId, uint256 collateralIn, bool keepYes, address to)
        external
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

        uint256 keepId = keepYes ? marketId : PAMM.getNoId(marketId);
        sharesKept = collateralIn;
        PAMM.transfer(to, keepId, sharesKept);

        vaultShares = PM_HOOK_ROUTER.depositToVault(marketId, !keepYes, collateralIn, to);

        emit MintAndVault(marketId, msg.sender, collateralIn, keepYes, sharesKept, vaultShares);
    }

    /// @notice Buy shares with integrated routing (pool → vault OTC → AMM → mint)
    /// @param poolPriceInBps Optional: Try pooled orderbook at this price first (0 = skip pool)
    /// @param feeOrHook Fee tier or hook address for PMHookRouter
    function buy(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 poolPriceInBps, // NEW: try pool at this price first
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 totalSharesOut, bytes4[] memory sources) {
        if (to == address(0)) to = msg.sender;
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value != collateralIn) _revert(ERR_VALIDATION, 3);
        } else {
            if (msg.value != 0) _revert(ERR_VALIDATION, 4);
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
        }

        // Step 1: Try pooled orderbook first (if price specified)
        bool filledFromPool = false;
        if (poolPriceInBps > 0 && poolPriceInBps < BPS_DENOM) {
            bytes32 poolId = getPoolId(marketId, buyYes, poolPriceInBps);
            PricePool storage pool = pools[poolId];

            uint112 availableShares = pool.totalShares - pool.sharesFilled - pool.sharesWithdrawn;

            // Calculate max shares we can buy with our collateral at this price
            uint256 maxSharesAtPrice = (collateralIn * BPS_DENOM) / poolPriceInBps;
            uint256 sharesToBuy =
                maxSharesAtPrice < availableShares ? maxSharesAtPrice : availableShares;

            if (sharesToBuy > 0) {
                uint256 collateralNeeded = (sharesToBuy * poolPriceInBps) / BPS_DENOM;
                if (sharesToBuy > type(uint112).max) _revert(ERR_OVERFLOW, 0);
                if (collateralNeeded > type(uint96).max) _revert(ERR_OVERFLOW, 1);

                // Fill from pool
                uint256 tokenId = buyYes ? marketId : PAMM.getNoId(marketId);
                PAMM.transfer(to, tokenId, sharesToBuy);

                // Update pool accounting
                unchecked {
                    pool.sharesFilled += uint112(sharesToBuy);
                    pool.totalCollateralEarned += uint96(collateralNeeded);
                }

                emit PoolFilled(poolId, msg.sender, sharesToBuy, collateralNeeded);

                totalSharesOut = sharesToBuy;
                filledFromPool = true;

                // If fully satisfied, return
                if (collateralNeeded >= collateralIn) {
                    sources = new bytes4[](1);
                    sources[0] = bytes4(keccak256("POOL"));
                    return (totalSharesOut, sources);
                }

                // Otherwise, continue with remaining collateral
                collateralIn -= collateralNeeded;
            }
        }

        // Step 2: Route remaining through PMHookRouter (vault OTC → AMM → mint)
        if (collateralIn > 0) {
            if (collateral != ETH) {
                _ensureApproval(collateral, address(PM_HOOK_ROUTER));
            }

            (uint256 additionalShares, bytes4[] memory pmSources) = PM_HOOK_ROUTER.buyWithBootstrap{
                value: collateral == ETH ? collateralIn : 0
            }(
                marketId,
                buyYes,
                collateralIn,
                minSharesOut > totalSharesOut ? minSharesOut - totalSharesOut : 0,
                feeOrHook,
                to,
                deadline
            );

            totalSharesOut += additionalShares;

            // Combine sources
            if (filledFromPool) {
                sources = new bytes4[](pmSources.length + 1);
                sources[0] = bytes4(keccak256("POOL"));
                for (uint256 i = 0; i < pmSources.length; i++) {
                    sources[i + 1] = pmSources[i];
                }
            } else {
                sources = pmSources;
            }
        }

        if (totalSharesOut < minSharesOut) _revert(ERR_VALIDATION, 9);
    }

    /// @notice Sell shares for immediate liquidity (vault OTC → AMM → merge)
    /// @dev For limit orders, use addToPool() instead to list at specific price
    function sell(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 totalCollateralOut, bytes4[] memory sources) {
        if (to == address(0)) to = msg.sender;
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);

        uint256 tokenId = sellYes ? marketId : PAMM.getNoId(marketId);

        PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);

        (totalCollateralOut, sources) = PM_HOOK_ROUTER.sellWithBootstrap(
            marketId, sellYes, sharesIn, minCollateralOut, feeOrHook, to, deadline
        );
    }

    /*//////////////////////////////////////////////////////////////
                        MULTICALL & PERMIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute multiple calls in a single transaction
    /// @param data Array of encoded function calls
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
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

    /// @notice Standard ERC-2612 permit (use in multicall before operations)
    /// @param token The token with permit support (USDC, USDT, etc.)
    /// @param owner The token owner who signed the permit
    /// @param value Amount to approve
    /// @param deadline Permit deadline
    /// @param v Signature v
    /// @param r Signature r
    /// @param s Signature s
    function permit(
        address token,
        address owner,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        assembly ("memory-safe") {
            let m := mload(0x40)
            // permit(address,address,uint256,uint256,uint8,bytes32,bytes32)
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

            // Check return value (some tokens return bool)
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

    /// @notice DAI-style permit (use in multicall before operations)
    /// @param token The DAI-like token with permit support
    /// @param owner The token owner who signed the permit
    /// @param nonce Owner's current nonce
    /// @param deadline Permit deadline (0 = no expiry)
    /// @param allowed True to approve max, false to revoke
    /// @param v Signature v
    /// @param r Signature r
    /// @param s Signature s
    function permitDAI(
        address token,
        address owner,
        uint256 nonce,
        uint256 deadline,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        assembly ("memory-safe") {
            let m := mload(0x40)
            // permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32)
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

            // Check return value (some tokens return bool)
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
                        HELPER FUNCTIONS
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
