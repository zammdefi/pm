// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function deposit(address token, uint256 id, uint256 amount) external payable;

    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    function pools(uint256 poolId)
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast,
            uint256 kLast,
            uint256 supply
        );

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    function recoverTransientBalance(address token, uint256 id, address to)
        external
        returns (uint256 amount);
}

interface IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);

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

    function getNoId(uint256 marketId) external pure returns (uint256);

    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);

    function setOperator(address operator, bool approved) external returns (bool);

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool);

    function split(uint256 marketId, uint256 amount, address to) external payable;
    function merge(uint256 marketId, uint256 amount, address to) external;

    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);

    function claim(uint256 marketId, address to) external returns (uint256 shares, uint256 payout);
}

interface IPMFeeHook {
    function registerMarket(uint256 marketId) external returns (uint256 poolId);
    function getCurrentFeeBps(uint256 poolId) external view returns (uint256);
    function getCloseWindow(uint256 marketId) external view returns (uint256);
}

/// @title PMHookRouter
/// @notice Prediction market router with vault market-making
/// @dev Execution: vault OTC => mint => AMM
///      LPs earn principal (seller-side) + 90% of scarcity-weighted spread (40-60% tilt).
///      Only markets created via bootstrapMarket() are supported.
/// @dev REQUIRES EIP-1153 (transient storage) - only deploy on chains with Cancun support
contract PMHookRouter {
    address constant ETH = address(0);

    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;

    // Error selectors
    bytes4 constant ERR_SHARES = 0x9325dafd;
    bytes4 constant ERR_VALIDATION = 0x077a9c33;
    bytes4 constant ERR_COMPUTATION = 0x05832717;
    bytes4 constant ERR_TIMING = 0x3703bac9;
    bytes4 constant ERR_STATE = 0xd06e7808;
    bytes4 constant ERR_TRANSFER = 0x2929f974;

    // pools(uint256) = 0xac4afa38 = bytes4(keccak256("pools(uint256)"))
    // markets(uint256) = 0xb1283e77 = bytes4(keccak256("markets(uint256)"))
    uint256 constant SELECTOR_POOLS_SHIFTED = 0xac4afa38 << 224;
    uint256 constant SELECTOR_MARKETS_SHIFTED = 0xb1283e77 << 224;

    // Transient storage slots (EIP-1153)
    uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268;

    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    function _guardEnter() internal {
        assembly ("memory-safe") {
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_SLOT, address())
        }
    }

    function _guardExit() internal {
        assembly ("memory-safe") {
            tstore(REENTRANCY_SLOT, 0)
        }
    }

    // ============ Helper Functions ============

    /// @dev Helper to derive pool ID from key
    function _derivePoolId(IZAMM.PoolKey memory k) internal pure returns (uint256 id) {
        assembly ("memory-safe") {
            // PoolKey: 5 × 32-byte words = 160 bytes (0xa0)
            id := keccak256(k, 0xa0)
        }
    }

    /// @dev Helper to check uint112 overflow
    function _checkU112Overflow(uint256 a, uint256 b) internal pure {
        if (a + b > MAX_UINT112) _revert(ERR_SHARES, 3); // SharesOverflow
    }

    /// @dev Generic revert helper - consolidated for bytecode savings
    function _revert(bytes4 selector, uint8 code) internal pure {
        assembly ("memory-safe") {
            mstore(0x00, selector)
            mstore(0x20, code)
            revert(0x1c, 0x24)
        }
    }

    /// @dev Low-level staticcall helper for uint256 returns (avoids try/catch overhead)
    function _staticUint(address target, bytes4 sel, uint256 arg)
        internal
        view
        returns (bool ok, uint256 out)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, sel)
            mstore(add(m, 0x04), arg)
            ok := staticcall(gas(), target, m, 0x24, m, 0x20)
            if and(ok, eq(returndatasize(), 0x20)) { out := mload(m) }
        }
    }

    /// @dev Low-level staticcall helper for ZAMM.pools (avoids try/catch overhead)
    function _staticPools(uint256 poolId)
        internal
        view
        returns (
            bool ok,
            uint112 r0,
            uint112 r1,
            uint32 blockTimestampLast,
            uint256 price0,
            uint256 price1
        )
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, SELECTOR_POOLS_SHIFTED)
            mstore(add(m, 0x04), poolId)
            ok := staticcall(gas(), 0x000000000000040470635EB91b7CE4D132D616eD, m, 0x24, m, 0xe0)
            if and(ok, eq(returndatasize(), 0xe0)) {
                r0 := mload(m)
                r1 := mload(add(m, 0x20))
                blockTimestampLast := mload(add(m, 0x40))
                price0 := mload(add(m, 0x60))
                price1 := mload(add(m, 0x80))
            }
        }
    }

    /// @dev Low-level staticcall helper for PAMM.markets (avoids tuple destructuring overhead)
    function _staticMarkets(uint256 marketId)
        internal
        view
        returns (bool resolved, bool outcome, bool canClose, uint64 close, address collateral)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, SELECTOR_MARKETS_SHIFTED)
            mstore(add(m, 0x04), marketId)
            // 7 return words = 0xe0 bytes
            if iszero(
                staticcall(gas(), 0x000000000044bfe6c2BBFeD8862973E0612f07C0, m, 0x24, m, 0xe0)
            ) {
                revert(0, 0)
            }
            // resolver @ 0x00 (unused)
            // resolved @ 0x20
            // outcome @ 0x40
            // canClose @ 0x60
            // close @ 0x80
            // collateral @ 0xa0
            // collateralLocked @ 0xc0 (unused)
            resolved := iszero(iszero(mload(add(m, 0x20))))
            outcome := iszero(iszero(mload(add(m, 0x40))))
            canClose := iszero(iszero(mload(add(m, 0x60))))
            close := mload(add(m, 0x80))
            collateral := mload(add(m, 0xa0))
        }
    }

    function _refundExcessETH(address collateral, uint256 amountUsed) internal {
        assembly ("memory-safe") {
            // Only refund if collateral == ETH (address(0)) and msg.value > amountUsed
            if and(iszero(collateral), gt(callvalue(), amountUsed)) {
                if iszero(
                    call(
                        gas(),
                        caller(),
                        sub(callvalue(), amountUsed),
                        codesize(),
                        0x00,
                        codesize(),
                        0x00
                    )
                ) {
                    mstore(0x00, 0x2929f974) // TransferError(2) = ETHTransferFailed
                    mstore(0x20, 2)
                    revert(0x1c, 0x24)
                }
            }
        }
    }

    function _validateETHAmount(address collateral, uint256 requiredAmount) internal view {
        if (collateral == ETH) {
            if (msg.value < requiredAmount) _revert(ERR_VALIDATION, 6); // InvalidETHAmount
        } else if (msg.value != 0) {
            _revert(ERR_VALIDATION, 6); // InvalidETHAmount
        }
    }

    /// @dev Helper to transfer collateral (handles ETH vs ERC20)
    function _transferCollateral(address collateral, address to, uint256 amount) internal {
        if (collateral == ETH) {
            safeTransferETH(to, amount);
        } else {
            safeTransfer(collateral, to, amount);
        }
    }

    /// @dev Helper to split shares via PAMM (handles ETH vs ERC20)
    function _splitShares(uint256 marketId, uint256 amount, address collateral) internal {
        if (collateral == ETH) {
            PAMM.split{value: amount}(marketId, amount, address(this));
        } else {
            ensureApproval(collateral, address(PAMM));
            PAMM.split(marketId, amount, address(this));
        }
    }

    /// @notice Calculate LP vs budget allocation based on imbalance
    /// @param preYes YES inventory
    /// @param preNo NO inventory
    /// @param buyYes Side being bought
    /// @param close Market close timestamp
    /// @param feeAmount Amount to split
    /// @return toLPs Amount allocated to LPs
    /// @return toRemaining Amount allocated to budget
    function _calculateFeeSplit(
        uint112 preYes,
        uint112 preNo,
        bool buyYes,
        uint64 close,
        uint256 feeAmount
    ) internal view returns (uint256 toLPs, uint256 toRemaining) {
        (, uint256 imbalanceBps) = _calculateDynamicSpread(preYes, preNo, buyYes, close);
        uint256 lpSplitBps =
            imbalanceBps > 7500 ? LP_FEE_SPLIT_BPS_IMBALANCED : LP_FEE_SPLIT_BPS_BALANCED;
        toLPs = mulDiv(feeAmount, lpSplitBps, 10_000);
        unchecked {
            toRemaining = feeAmount - toLPs;
        }
    }

    /// @notice Split fees between LPs and rebalance budget using pre-trade snapshot
    /// @param marketId Market ID
    /// @param feeAmount Total fees to distribute
    /// @param preYes Pre-merge YES inventory
    /// @param preNo Pre-merge NO inventory
    /// @param twap TWAP price in bps
    function _distributeFeesSplit(
        uint256 marketId,
        uint256 feeAmount,
        uint112 preYes,
        uint112 preNo,
        uint256 twap
    ) internal {
        // Dynamic budget split based on inventory imbalance
        uint64 close = _getClose(marketId);
        // Pass buyYes based on which side is scarce to ensure symmetric imbalance detection
        bool buyYes = preYes < preNo;
        (uint256 toLPs, uint256 toRebalance) =
            _calculateFeeSplit(preYes, preNo, buyYes, close, feeAmount);
        if (!_addVaultFeesSymmetricWithSnapshot(marketId, toLPs, preYes, preNo, twap)) {
            unchecked {
                rebalanceCollateralBudget[marketId] += toLPs + toRebalance;
                return;
            }
        }
        unchecked {
            rebalanceCollateralBudget[marketId] += toRebalance;
        }
    }

    /// @notice Split OTC proceeds into principal and spread
    /// @param marketId Market ID
    /// @param buyYes True for YES, false for NO
    /// @param sharesOut Shares sold by vault
    /// @param collateralUsed Total collateral paid
    /// @param pYes TWAP probability [1..9999]
    /// @param preYesInv YES inventory before trade
    /// @param preNoInv NO inventory before trade
    /// @return principal Fair value at TWAP
    /// @return spreadFee Spread above TWAP
    function _accountVaultOTCProceeds(
        uint256 marketId,
        bool buyYes,
        uint256 sharesOut,
        uint256 collateralUsed,
        uint256 pYes,
        uint112 preYesInv,
        uint112 preNoInv
    ) internal returns (uint256 principal, uint256 spreadFee) {
        if (pYes == 0) _revert(ERR_COMPUTATION, 3); // TWAPRequired
        if (pYes >= 10000) pYes = 9999;

        assembly ("memory-safe") {
            // Fair principal: buyYes ? pYes : (10000 - pYes)
            let fairBps := xor(pYes, mul(xor(pYes, sub(10000, pYes)), iszero(buyYes)))
            principal := div(add(mul(sharesOut, fairBps), 9999), 10000)
        }

        if (collateralUsed < principal) _revert(ERR_VALIDATION, 0); // Overflow
        unchecked {
            spreadFee = collateralUsed - principal;
        }

        // Principal to seller-side LPs
        uint256 sellerLP = buyYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];

        _addVaultFeesWithSnapshot(marketId, buyYes, principal, sellerLP);

        if (spreadFee == 0) return (principal, 0);

        // Dynamic budget split based on inventory imbalance
        uint64 close = _getClose(marketId);
        (uint256 toLPs, uint256 toBudget) =
            _calculateFeeSplit(preYesInv, preNoInv, buyYes, close, spreadFee);

        if (!_distributeOtcSpreadScarcityCapped(marketId, toLPs, preYesInv, preNoInv)) {
            unchecked {
                toBudget += toLPs;
            }
        }

        unchecked {
            rebalanceCollateralBudget[marketId] += toBudget;
        }

        return (principal, spreadFee);
    }

    function _depositToVaultSide(uint256 marketId, bool isYes, uint256 shares, address receiver)
        internal
        returns (uint256 vaultSharesMinted)
    {
        BootstrapVault storage vault = bootstrapVaults[marketId];
        uint256 totalVaultShares =
            isYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];
        uint256 totalAssets = isYes ? vault.yesShares : vault.noShares;

        // VaultDepleted: totalVaultShares != 0 && totalAssets == 0
        if (totalVaultShares != 0 && totalAssets == 0) _revert(ERR_STATE, 4);
        // OrphanedAssets: totalVaultShares == 0 && totalAssets != 0
        if (totalVaultShares == 0 && totalAssets != 0) _revert(ERR_STATE, 5);
        if (shares > MAX_UINT112) _revert(ERR_SHARES, 3); // SharesOverflow

        if ((totalVaultShares | totalAssets) == 0) {
            vaultSharesMinted = shares;
        } else {
            vaultSharesMinted = fullMulDiv(shares, totalVaultShares, totalAssets);
        }

        if (vaultSharesMinted == 0) _revert(ERR_SHARES, 1); // ZeroVaultShares
        if (vaultSharesMinted > MAX_UINT112) _revert(ERR_SHARES, 4); // VaultSharesOverflow

        UserVaultPosition storage position = vaultPositions[marketId][receiver];

        // Capture existing vault shares before updating (for weighted cooldown)
        uint256 existingVaultShares =
            uint256(position.yesVaultShares) + uint256(position.noVaultShares);

        if (isYes) {
            _checkU112Overflow(vault.yesShares, shares);
            _checkU112Overflow(position.yesVaultShares, vaultSharesMinted);

            unchecked {
                vault.yesShares += uint112(shares);
                totalYesVaultShares[marketId] += vaultSharesMinted;
                position.yesVaultShares += uint112(vaultSharesMinted);
                position.yesRewardDebt += mulDiv(
                    vaultSharesMinted, accYesCollateralPerShare[marketId], 1e18
                );
            }
        } else {
            _checkU112Overflow(vault.noShares, shares);
            _checkU112Overflow(position.noVaultShares, vaultSharesMinted);

            unchecked {
                vault.noShares += uint112(shares);
                totalNoVaultShares[marketId] += vaultSharesMinted;
                position.noVaultShares += uint112(vaultSharesMinted);
                position.noRewardDebt += mulDiv(
                    vaultSharesMinted, accNoCollateralPerShare[marketId], 1e18
                );
            }
        }

        // Weighted cooldown: prevents both griefing and bypass
        // Small deposits barely move timestamp; large deposits move it significantly
        if (existingVaultShares == 0) {
            // First deposit - set timestamp directly
            position.lastDepositTime = uint32(block.timestamp);
        } else {
            // Check if depositing in final window (last 12h before close)
            uint64 close = _getClose(marketId);
            bool inFinalWindow = block.timestamp > close || (close - block.timestamp) < 43200;

            if (inFinalWindow) {
                // Late deposit: force timestamp to now (ensures 24h cooldown)
                // NOTE: This prevents the weighted cooldown bypass but reintroduces
                // cheap griefing in the final 12h window. An attacker can deposit 1 share
                // to any receiver and lock them for 24h. This is acceptable because:
                // (1) Bypass prevention is more critical than griefing protection
                // (2) Users depositing near market close should expect lock until settlement
                // (3) Limited attack window and impact vs. added complexity of mitigations
                position.lastDepositTime = uint32(block.timestamp);
            } else {
                // Weighted average based on relative size of new deposit
                uint256 oldTime = position.lastDepositTime;
                uint256 newTotal = existingVaultShares + vaultSharesMinted;

                unchecked {
                    uint256 weightedTime =
                        (existingVaultShares * oldTime + vaultSharesMinted * block.timestamp)
                            / newTotal;
                    position.lastDepositTime = uint32(weightedTime);
                }
            }
        }
    }

    // ============ Bootstrap Vault Storage ============

    struct BootstrapVault {
        uint112 yesShares;
        uint112 noShares;
        uint32 lastActivity;
    }

    // poolId != 0 indicates registered market
    mapping(uint256 => uint256) public canonicalPoolId;
    mapping(uint256 => uint256) public canonicalFeeOrHook;
    mapping(uint256 => BootstrapVault) public bootstrapVaults;
    mapping(uint256 => uint256) public rebalanceCollateralBudget;

    // ============ TWAP Tracking ============
    // Two-observation sliding window (minimum 30min) using ZAMM pool cumulatives
    // Updates: permissionless after 30min, or opportunistic during trades
    // Reader uses obs0->obs1 if obs1 is recent, or obs1->current if obs1 is stale

    struct TWAPObservations {
        uint32 timestamp0; // Older checkpoint (4 bytes) \
        uint32 timestamp1; // Newer checkpoint (4 bytes)  |
        uint32 cachedTwapBps; // Cached TWAP value [0-10000] (4 bytes) |-- packed in slot 0
        uint32 cacheBlockNum; // Block number of cache (4 bytes)        |
        uint128 reservesAtObs1; // Pool reserves at timestamp1 (16 bytes)/
        uint256 cumulative0; // ZAMM's cumulative at timestamp0 (slot 1: 32 bytes)
        uint256 cumulative1; // ZAMM's cumulative at timestamp1 (slot 2: 32 bytes)
    }

    mapping(uint256 => TWAPObservations) public twapObservations;

    uint32 constant MIN_TWAP_UPDATE_INTERVAL = 30 minutes;

    // ============ Vault LP Accounting ============
    // ERC4626-style accounting with reward debt pattern
    // OTC principal -> seller-side LPs; spread -> 90% LPs, 10% budget

    struct UserVaultPosition {
        uint112 yesVaultShares; // 14 bytes  \
        uint112 noVaultShares; // 14 bytes   |-- packed in slot 0
        uint32 lastDepositTime; // 4 bytes   /
        uint256 yesRewardDebt; // 32 bytes -- slot 1
        uint256 noRewardDebt; // 32 bytes -- slot 2
    }

    mapping(uint256 => uint256) public totalYesVaultShares;
    mapping(uint256 => uint256) public totalNoVaultShares;
    mapping(uint256 => uint256) public accYesCollateralPerShare;
    mapping(uint256 => uint256) public accNoCollateralPerShare;
    mapping(uint256 => mapping(address => UserVaultPosition)) public vaultPositions;

    event VaultDeposit(
        uint256 indexed marketId,
        address indexed user,
        bool isYes,
        uint256 sharesDeposited,
        uint256 vaultSharesMinted
    );

    event VaultWithdraw(
        uint256 indexed marketId,
        address indexed user,
        bool isYes,
        uint256 vaultSharesBurned,
        uint256 sharesReturned,
        uint256 feesEarned
    );

    event VaultFeesHarvested(
        uint256 indexed marketId, address indexed user, bool isYes, uint256 feesEarned
    );

    event VaultOTCFill(
        uint256 indexed marketId,
        address indexed trader,
        address recipient,
        bool buyYes,
        uint256 collateralIn,
        uint256 sharesOut,
        uint256 effectivePriceBps,
        uint256 principal,
        uint256 spreadFee
    );

    event BudgetSettled(uint256 indexed marketId, uint256 budgetDistributed, uint256 sharesMerged);

    event VaultWinningSharesRedeemed(
        uint256 indexed marketId, bool outcome, uint256 sharesRedeemed, uint256 payoutToDAO
    );

    event MarketFinalized(
        uint256 indexed marketId,
        uint256 totalToDAO,
        uint256 sharesMerged,
        uint256 budgetDistributed
    );

    event Rebalanced(
        uint256 indexed marketId, uint256 collateralUsed, uint256 sharesAcquired, bool yesWasLower
    );

    // Economic Parameters
    uint256 constant MIN_ABSOLUTE_SPREAD_BPS = 20; // 0.2% minimum absolute spread
    uint256 constant MAX_SPREAD_BPS = 500; // 5% overall cap
    uint256 constant DEFAULT_FEE_BPS = 30; // 0.3% fallback AMM fee
    uint256 constant LP_FEE_SPLIT_BPS_BALANCED = 9000; // 90% to LPs when balanced
    uint256 constant LP_FEE_SPLIT_BPS_IMBALANCED = 7000; // 70% to LPs when imbalanced

    uint256 constant MAX_COLLATERAL_IN = type(uint256).max / 10_000;
    uint256 constant MAX_ACC_PER_SHARE = type(uint256).max / type(uint112).max;
    uint256 constant MAX_UINT112 = 0xffffffffffffffffffffffffffff;

    bytes4 constant SOURCE_OTC = bytes4("otc");
    bytes4 constant SOURCE_AMM = bytes4("amm");
    bytes4 constant SOURCE_MINT = bytes4("mint");
    bytes4 constant SOURCE_MULT = bytes4("mult");

    error ValidationError(uint8 code);
    // 0=Overflow, 1=AmountZero, 2=Slippage, 3=InsufficientOutput, 4=InsufficientShares,
    // 5=InsufficientVaultShares, 6=InvalidETHAmount, 7=InvalidCloseTime

    error TimingError(uint8 code);
    // 0=Expired, 1=TooSoon, 2=MarketClosed, 3=MarketNotClosed, 4=PoolNotReady

    error StateError(uint8 code);
    // 0=MarketResolved, 1=MarketNotResolved, 2=MarketNotRegistered, 3=MarketAlreadyRegistered,
    // 4=VaultDepleted, 5=OrphanedAssets, 6=CirculatingLPsExist

    error TransferError(uint8 code);
    // 0=TransferFailed, 1=TransferFromFailed, 2=ETHTransferFailed

    error ComputationError(uint8 code);
    // 0=MulDivFailed, 1=FullMulDivFailed, 2=TWAPCorrupt, 3=TWAPRequired, 4=TWAPInitFailed,
    // 5=SpotDeviantFromTWAP, 6=HookInvalidPoolId, 7=NonCanonicalPool

    error SharesError(uint8 code);
    // 0=ZeroShares, 1=ZeroVaultShares, 2=NoVaultShares, 3=SharesOverflow,
    // 4=VaultSharesOverflow, 5=SharesReturnedOverflow

    error Reentrancy();
    error ApproveFailed();
    error WithdrawalTooSoon(uint256 remainingSeconds);

    constructor() payable {
        PAMM.setOperator(address(ZAMM), true);
        PAMM.setOperator(address(PAMM), true);
    }

    receive() external payable {}

    // ============ Validation Helpers (Bytecode Optimization) ============

    /// @dev Revert if market is not registered
    function _requireRegistered(uint256 marketId) internal view {
        if (canonicalPoolId[marketId] == 0) _revert(ERR_STATE, 2); // MarketNotRegistered
    }

    /// @dev Revert if market is resolved or closed, return close time and collateral
    function _requireMarketOpen(uint256 marketId)
        internal
        view
        returns (uint64 close, address collateral)
    {
        _requireNotResolved(marketId);
        close = _getClose(marketId);
        collateral = _getCollateral(marketId);
        // Check if market exists (close == 0 indicates nonexistent market)
        if (close == 0) _revert(ERR_STATE, 2); // MarketNotRegistered
        if (block.timestamp >= close) _revert(ERR_TIMING, 2); // MarketClosed
    }

    /// @dev Revert if deadline expired
    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) _revert(ERR_TIMING, 0); // Expired
    }

    /// @dev Check withdrawal cooldown (shared by withdraw and harvest)
    /// @dev Enforced even after market close to prevent end-of-market fee sniping
    /// @dev Late deposits (within 12h of close) require 24h cooldown
    function _checkWithdrawalCooldown(uint256 marketId) internal view {
        uint256 depositTime = vaultPositions[marketId][msg.sender].lastDepositTime;
        if (depositTime != 0) {
            uint64 close = _getClose(marketId);
            assembly ("memory-safe") {
                let inFinalWindow := or(gt(depositTime, close), lt(sub(close, depositTime), 43200))
                let elapsed := sub(timestamp(), depositTime)
                let required := mul(21600, add(1, mul(3, inFinalWindow)))
                if lt(elapsed, required) {
                    mstore(0x00, 0xff56d9bd) // WithdrawalTooSoon(uint256)
                    mstore(0x20, sub(required, elapsed))
                    revert(0x1c, 0x24)
                }
            }
        }
    }

    /// @dev Get NO token ID matching PAMM's formula: keccak256("PMARKET:NO", marketId)
    function _getNoId(uint256 marketId) internal pure returns (uint256 noId) {
        assembly ("memory-safe") {
            // keccak256(abi.encodePacked("PMARKET:NO", marketId))
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, marketId)
            noId := keccak256(0x00, 0x2a)
        }
    }

    /// @dev Get collateral address for a market
    function _getCollateral(uint256 marketId) internal view returns (address collateral) {
        (,,,, collateral) = _staticMarkets(marketId);
    }

    /// @dev Get close time for a market
    function _getClose(uint256 marketId) internal view returns (uint64 close) {
        (,,, close,) = _staticMarkets(marketId);
    }

    /// @dev Get pool reserves
    function _getReserves(uint256 poolId) internal view returns (uint112 r0, uint112 r1) {
        (, r0, r1,,,) = _staticPools(poolId);
    }

    /// @dev Revert if market is resolved
    function _requireNotResolved(uint256 marketId) internal view {
        (bool resolved,,,,) = _staticMarkets(marketId);
        if (resolved) _revert(ERR_STATE, 0); // MarketResolved
    }

    /// @dev Revert if market is not resolved, return outcome
    function _requireResolved(uint256 marketId) internal view returns (bool outcome) {
        bool resolved;
        (resolved, outcome,,,) = _staticMarkets(marketId);
        if (!resolved) _revert(ERR_STATE, 1); // MarketNotResolved
    }

    /// @dev Revert if amount is zero
    function _requireNonZero(uint256 amount) internal pure {
        if (amount == 0) _revert(ERR_VALIDATION, 1); // AmountZero
    }

    /// @dev Check if market is in close window
    function _isInCloseWindow(uint256 marketId, uint64 close) internal view returns (bool) {
        uint256 closeWindow;
        uint256 feeOrHook = canonicalFeeOrHook[marketId];
        bool isHook = (feeOrHook & (FLAG_BEFORE | FLAG_AFTER)) != 0;
        if (isHook) {
            address hook = address(uint160(feeOrHook));
            (bool ok, uint256 window) = _staticUint(hook, 0x7c3a8f32, marketId); // getCloseWindow
            closeWindow = (ok && window > 0) ? window : 3600;
        } else {
            closeWindow = 3600; // 1 hour fallback for non-hooked markets
        }
        return block.timestamp < close && close - block.timestamp < closeWindow;
    }

    /// @dev Take collateral from user and approve PAMM
    function _takeCollateral(uint256 marketId, uint256 amount)
        internal
        returns (address collateral)
    {
        collateral = _getCollateral(marketId);
        _validateETHAmount(collateral, amount);
        if (collateral != ETH && amount != 0) {
            safeTransferFrom(collateral, msg.sender, address(this), amount);
            ensureApproval(collateral, address(PAMM));
        }
    }

    // ============ Multicall ============

    /// @notice Execute multiple calls in a single transaction
    function multicall(bytes[] calldata data) public returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i != data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            assembly ("memory-safe") {
                if iszero(ok) { revert(add(result, 0x20), mload(result)) }
            }
            results[i] = result;
        }
    }

    // ============ Permit ============

    /// @notice EIP-2612 permit for ERC20 tokens (use in multicall before operations)
    /// @param token The ERC20 token with permit support
    /// @param owner The token owner who signed the permit
    /// @param value Amount to approve to this contract
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

            // Check return value (some tokens return bool)
            switch returndatasize()
            case 0 {} // No return data is fine
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) } // Returned false
            }
            default { revert(0, 0) } // Unexpected return size

            mstore(0x40, add(m, 0x100)) // Update free memory pointer (32-byte aligned)
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

            // Check return value (some tokens return bool)
            switch returndatasize()
            case 0 {} // No return data is fine
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) } // Returned false
            }
            default { revert(0, 0) } // Unexpected return size

            mstore(0x40, add(m, 0x120)) // Update free memory pointer (32-byte aligned)
        }
    }

    // ============ Hook Integration ============

    function _buildKey(uint256 yesId, uint256 noId, uint256 feeOrHook)
        internal
        pure
        returns (IZAMM.PoolKey memory k, bool yesIsId0)
    {
        yesIsId0 = yesId < noId;
        address pamm = address(PAMM);
        k = IZAMM.PoolKey({
            id0: yesIsId0 ? yesId : noId,
            id1: yesIsId0 ? noId : yesId,
            token0: pamm,
            token1: pamm,
            feeOrHook: feeOrHook
        });
    }

    function _registerMarket(address hook, uint256 marketId)
        internal
        returns (uint256 poolId, uint256 feeOrHook)
    {
        if (canonicalPoolId[marketId] != 0) _revert(ERR_STATE, 3); // MarketAlreadyRegistered

        poolId = IPMFeeHook(hook).registerMarket(marketId);
        feeOrHook = uint256(uint160(hook)) | FLAG_BEFORE | FLAG_AFTER;

        (IZAMM.PoolKey memory k,) = _buildKey(marketId, _getNoId(marketId), feeOrHook);
        uint256 derivedPoolId = _derivePoolId(k);
        if (poolId != derivedPoolId) _revert(ERR_COMPUTATION, 6); // HookInvalidPoolId

        canonicalPoolId[marketId] = poolId;
        canonicalFeeOrHook[marketId] = feeOrHook;
    }

    /// @notice Bootstrap market with initial liquidity and optional trade
    /// @param collateralForLP Liquidity for 50/50 AMM pool
    /// @param collateralForBuy Optional initial trade
    function bootstrapMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose,
        address hook,
        uint256 collateralForLP,
        bool buyYes,
        uint256 collateralForBuy,
        uint256 minSharesOut,
        address to,
        uint256 deadline
    )
        public
        payable
        returns (uint256 marketId, uint256 poolId, uint256 lpShares, uint256 sharesOut)
    {
        _guardEnter();
        _checkDeadline(deadline);
        if (block.timestamp >= close) _revert(ERR_VALIDATION, 7); // InvalidCloseTime
        _requireNonZero(collateralForLP);

        if (to == address(0)) to = msg.sender;

        uint256 totalCollateral = collateralForLP + collateralForBuy;

        _validateETHAmount(collateral, totalCollateral);
        if (collateral != ETH && totalCollateral != 0) {
            safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
            ensureApproval(collateral, address(PAMM));
        }

        (marketId,) = PAMM.createMarket(description, resolver, collateral, close, canClose);

        (poolId,) = _registerMarket(hook, marketId);

        if (collateralForLP != 0) {
            _splitShares(marketId, collateralForLP, collateral);

            uint256 yesId = marketId;
            uint256 noId = _getNoId(marketId);

            ZAMM.deposit(address(PAMM), yesId, collateralForLP);
            ZAMM.deposit(address(PAMM), noId, collateralForLP);

            (IZAMM.PoolKey memory k,) =
                _buildKey(yesId, noId, uint256(uint160(hook)) | FLAG_BEFORE | FLAG_AFTER);

            (,, lpShares) =
                ZAMM.addLiquidity(k, collateralForLP, collateralForLP, 0, 0, to, deadline);

            ZAMM.recoverTransientBalance(address(PAMM), yesId, to);
            ZAMM.recoverTransientBalance(address(PAMM), noId, to);

            (uint256 initialCumulative, bool success) = _getCurrentCumulative(marketId);
            if (!success) _revert(ERR_COMPUTATION, 4); // TWAPInitFailed

            twapObservations[marketId] = TWAPObservations({
                timestamp0: uint32(block.timestamp),
                timestamp1: uint32(block.timestamp),
                cachedTwapBps: 0,
                cacheBlockNum: 0,
                reservesAtObs1: 0,
                cumulative0: initialCumulative,
                cumulative1: initialCumulative
            });
        }

        if (collateralForBuy != 0) {
            sharesOut = _bootstrapBuy(
                marketId, hook, collateral, buyYes, collateralForBuy, minSharesOut, to, deadline
            );
        }

        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    function _bootstrapBuy(
        uint256 marketId,
        address hook,
        address collateral,
        bool buyYes,
        uint256 collateralForBuy,
        uint256 minSharesOut,
        address to,
        uint256 deadline
    ) internal returns (uint256 sharesOut) {
        // Cache token IDs
        uint256 yesId = marketId;
        uint256 noId = _getNoId(marketId);

        _splitShares(marketId, collateralForBuy, collateral);

        uint256 swapTokenId = buyYes ? noId : yesId;
        uint256 desiredTokenId = buyYes ? yesId : noId;

        ZAMM.deposit(address(PAMM), swapTokenId, collateralForBuy);

        (IZAMM.PoolKey memory k, bool yesIsId0) =
            _buildKey(yesId, noId, uint256(uint160(hook)) | FLAG_BEFORE | FLAG_AFTER);
        bool zeroForOne = buyYes ? !yesIsId0 : yesIsId0;

        uint256 swappedShares =
            ZAMM.swapExactIn(k, collateralForBuy, 0, zeroForOne, address(this), deadline);

        sharesOut = collateralForBuy + swappedShares;
        if (sharesOut < minSharesOut) _revert(ERR_VALIDATION, 3); // InsufficientOutput
        PAMM.transfer(to, desiredTokenId, sharesOut);
    }

    /// @notice Buy shares via vault OTC => mint => AMM waterfall
    /// @param marketId Market ID
    /// @param buyYes True for YES, false for NO
    /// @param collateralIn Collateral to spend
    /// @param minSharesOut Minimum shares (all venues combined)
    /// @param to Recipient
    /// @param deadline Deadline
    /// @return sharesOut Total shares acquired
    /// @return source Venue used ("otc"/"mint"/"amm"/"mult")
    /// @return vaultSharesMinted Vault shares from mint path
    function buyWithBootstrap(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        address to,
        uint256 deadline
    ) public payable returns (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) {
        _guardEnter();
        (, address collateral) = _requireMarketOpen(marketId);
        if (block.timestamp > deadline) _revert(ERR_TIMING, 0); // Expired
        _requireNonZero(collateralIn);
        if (collateralIn > MAX_COLLATERAL_IN) _revert(ERR_VALIDATION, 0); // Overflow
        if (to == address(0)) to = msg.sender;

        _requireRegistered(marketId);
        uint256 feeOrHook = canonicalFeeOrHook[marketId];
        uint256 noId = _getNoId(marketId);
        // Take collateral from user (cached from _requireMarketOpen)
        _validateETHAmount(collateral, collateralIn);
        if (collateral != ETH && collateralIn != 0) {
            safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            ensureApproval(collateral, address(PAMM));
        }

        // Track remaining collateral and total output across venues
        uint256 remainingCollateral = collateralIn;
        uint256 totalSharesOut;
        uint8 venueCount; // Track how many venues were used

        BootstrapVault storage vault = bootstrapVaults[marketId];

        // Get quotes from both vault and AMM to determine best execution
        uint256 pYes = _getTWAPPrice(marketId);
        (uint256 vaultQuoteShares, uint256 vaultQuoteCollateral, bool vaultFillable) =
            _tryVaultOTCFill(marketId, buyYes, remainingCollateral, pYes);

        uint256 ammQuoteShares = _quoteAMMBuy(marketId, buyYes, remainingCollateral);

        // Determine venue priority based on best execution (total shares)
        // Compare: AMM-only vs (vault + AMM on remainder)
        // If vault is better: try vault first, then AMM, then mint
        // If AMM is better: try AMM first, then vault, then mint
        bool tryVaultFirst = false;
        if (vaultFillable && vaultQuoteShares > 0) {
            if (ammQuoteShares == 0) {
                // Only vault available
                tryVaultFirst = true;
            } else {
                // Quote AMM on remaining collateral after vault fill
                uint256 ammAfterVault = (vaultQuoteCollateral < remainingCollateral)
                    ? _quoteAMMBuy(marketId, buyYes, remainingCollateral - vaultQuoteCollateral)
                    : 0;

                // Compare total execution: vault+AMM vs AMM-only
                tryVaultFirst = (vaultQuoteShares + ammAfterVault >= ammQuoteShares);
            }
        }

        // VENUE 1: Vault OTC (if best execution or AMM not available)
        if (tryVaultFirst) {
            (uint256 otcShares, uint256 otcCollateralUsed, uint8 otcVenue) =
                _executeVaultOTCFill(marketId, buyYes, remainingCollateral, pYes, to, noId);
            if (otcVenue != 0) {
                unchecked {
                    totalSharesOut += otcShares;
                    remainingCollateral -= otcCollateralUsed;
                    venueCount += otcVenue;
                }
                source = SOURCE_OTC;
            }
        }

        // VENUE 2: AMM (before vault if AMM is better, or after vault if vault was first)
        // Guard: only attempt AMM if quote indicated liquidity is available
        if (remainingCollateral != 0 && !tryVaultFirst && ammQuoteShares != 0) {
            uint256 ammSharesOut = _executeAMMSwap(
                marketId,
                buyYes,
                remainingCollateral,
                minSharesOut,
                totalSharesOut,
                to,
                deadline,
                noId,
                feeOrHook
            );
            unchecked {
                totalSharesOut += ammSharesOut;
                ++venueCount;
                if (source == bytes4(0)) source = SOURCE_AMM;
                remainingCollateral = 0;
            }
        }

        // VENUE 3: Vault OTC (after AMM if AMM was first and left remainder - unlikely but possible)
        if (!tryVaultFirst && remainingCollateral != 0 && vaultFillable) {
            (uint256 otcShares, uint256 otcCollateralUsed, uint8 otcVenue) =
                _executeVaultOTCFill(marketId, buyYes, remainingCollateral, pYes, to, noId);
            if (otcVenue != 0) {
                unchecked {
                    totalSharesOut += otcShares;
                    remainingCollateral -= otcCollateralUsed;
                    venueCount += otcVenue;
                }
                if (source == bytes4(0)) source = SOURCE_OTC;
            }
        }

        // VENUE 4: AMM (remaining after vault, if vault went first)
        // Guard: only attempt AMM if quote indicated liquidity is available
        if (remainingCollateral != 0 && tryVaultFirst && ammQuoteShares != 0) {
            uint256 ammSharesOut = _executeAMMSwap(
                marketId,
                buyYes,
                remainingCollateral,
                minSharesOut,
                totalSharesOut,
                to,
                deadline,
                noId,
                feeOrHook
            );
            unchecked {
                totalSharesOut += ammSharesOut;
                ++venueCount;
                if (source == bytes4(0)) source = SOURCE_AMM;
                remainingCollateral = 0;
            }
        }

        // VENUE 5: Mint (fallback if no AMM liquidity or specific conditions met)
        bool mintCanSatisfyMin = (minSharesOut <= totalSharesOut + remainingCollateral);
        if (
            remainingCollateral != 0 && mintCanSatisfyMin
                && _shouldUseVaultMint(marketId, vault, buyYes)
        ) {
            uint256 oppositeVaultShares =
                !buyYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];
            uint256 oppositeAssets = !buyYes ? vault.yesShares : vault.noShares;

            if (oppositeVaultShares == 0 || oppositeAssets != 0) {
                _splitShares(marketId, remainingCollateral, collateral);

                PAMM.transfer(to, buyYes ? marketId : noId, remainingCollateral);

                unchecked {
                    uint256 vaultSharesCreated =
                        _depositToVaultSide(marketId, !buyYes, remainingCollateral, to);
                    vaultSharesMinted += vaultSharesCreated;
                    vault.lastActivity = uint32(block.timestamp);
                    emit VaultDeposit(
                        marketId, to, !buyYes, remainingCollateral, vaultSharesCreated
                    );
                    totalSharesOut += remainingCollateral;
                    remainingCollateral = 0;
                    ++venueCount;
                }
                if (source == bytes4(0)) source = SOURCE_MINT;
            }
        }

        if (totalSharesOut < minSharesOut) _revert(ERR_VALIDATION, 2); // Slippage

        if (venueCount > 1) source = SOURCE_MULT;

        if (remainingCollateral != 0) {
            _transferCollateral(collateral, msg.sender, remainingCollateral);
        }

        _refundExcessETH(collateral, collateralIn);

        _guardExit();
        return (totalSharesOut, source, vaultSharesMinted);
    }

    /// @notice Quote expected output for buyWithBootstrap
    /// @dev Returns total shares using best-execution routing: compares vault vs AMM efficiency
    /// @dev Venue order: best venue first, then remaining venues, then mint fallback
    /// @dev Best-effort estimate; AMM quotes use current fee which may change
    /// @param minSharesOut Minimum shares required
    /// @return totalSharesOut Total estimated shares across all venues
    /// @return usesVault Whether vault OTC or mint will be used
    /// @return source Primary source ("otc", "mint", "amm", or "mult" for hybrid)
    /// @return vaultSharesMinted Estimated vault shares if mint path used
    function quoteBootstrapBuy(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut
    )
        public
        view
        returns (uint256 totalSharesOut, bool usesVault, bytes4 source, uint256 vaultSharesMinted)
    {
        _requireRegistered(marketId);
        _requireNotResolved(marketId);

        // Check market not closed
        uint64 close = _getClose(marketId);
        if (block.timestamp >= close) _revert(ERR_TIMING, 2); // MarketClosed
        _requireNonZero(collateralIn);

        // Prevent overflow in _quoteAMMBuy
        if (collateralIn > MAX_COLLATERAL_IN) {
            return (0, false, bytes4(0), 0);
        }

        uint256 remainingCollateral = collateralIn;
        uint8 venueCount;

        // Get quotes from both vault and AMM to determine best execution
        uint256 pYes = _getTWAPPrice(marketId);
        (uint256 vaultQuoteShares, uint256 vaultQuoteCollateral, bool vaultFillable) =
            _tryVaultOTCFill(marketId, buyYes, remainingCollateral, pYes);

        uint256 ammQuoteShares = _quoteAMMBuy(marketId, buyYes, remainingCollateral);

        // Determine venue priority based on best execution
        bool tryVaultFirst = false;
        if (vaultFillable && vaultQuoteShares > 0) {
            if (ammQuoteShares == 0) {
                tryVaultFirst = true;
            } else {
                // Quote AMM on remaining collateral after vault fill
                uint256 ammAfterVault = (vaultQuoteCollateral < remainingCollateral)
                    ? _quoteAMMBuy(marketId, buyYes, remainingCollateral - vaultQuoteCollateral)
                    : 0;

                // Compare total execution: vault+AMM vs AMM-only
                tryVaultFirst = (vaultQuoteShares + ammAfterVault >= ammQuoteShares);
            }
        }

        // VENUE 1: Vault OTC (if best execution)
        if (tryVaultFirst && vaultFillable && vaultQuoteShares != 0) {
            totalSharesOut += vaultQuoteShares;
            remainingCollateral -= vaultQuoteCollateral;
            usesVault = true;
            source = SOURCE_OTC;
            ++venueCount;
        }

        // VENUE 2: AMM (if better than vault, or after vault)
        if (remainingCollateral != 0 && !tryVaultFirst && ammQuoteShares != 0) {
            totalSharesOut += ammQuoteShares;
            remainingCollateral = 0; // AMM consumes all
            if (source == bytes4(0)) source = SOURCE_AMM;
            ++venueCount;
        }

        // VENUE 3: Vault after AMM (if AMM went first and left remainder - rare)
        if (!tryVaultFirst && remainingCollateral != 0 && vaultFillable) {
            (uint256 otcShares, uint256 otcCollateralUsed,) =
                _tryVaultOTCFill(marketId, buyYes, remainingCollateral, pYes);
            if (otcShares != 0) {
                totalSharesOut += otcShares;
                remainingCollateral -= otcCollateralUsed;
                usesVault = true;
                if (source == bytes4(0)) source = SOURCE_OTC;
                ++venueCount;
            }
        }

        // VENUE 4: Mint (only if remaining collateral and can satisfy min)
        bool mintCanSatisfyMin = (minSharesOut <= totalSharesOut + remainingCollateral);
        if (
            remainingCollateral != 0 && mintCanSatisfyMin
                && _shouldUseVaultMint(marketId, bootstrapVaults[marketId], buyYes)
        ) {
            BootstrapVault memory vault = bootstrapVaults[marketId];
            uint256 totalVaultShares =
                buyYes ? totalNoVaultShares[marketId] : totalYesVaultShares[marketId];
            uint256 totalAssets = buyYes ? vault.noShares : vault.yesShares;

            // Zombie state: skip mint
            bool canMint = !(totalVaultShares != 0 && totalAssets == 0);

            if (canMint) {
                uint256 estimatedVaultShares = (totalVaultShares == 0 || totalAssets == 0)
                    ? remainingCollateral
                    : fullMulDiv(remainingCollateral, totalVaultShares, totalAssets);

                // Only mint if shares > 0
                if (estimatedVaultShares != 0) {
                    totalSharesOut += remainingCollateral;
                    vaultSharesMinted = estimatedVaultShares;
                    usesVault = true;
                    if (source == bytes4(0)) source = SOURCE_MINT;
                    remainingCollateral = 0;
                    ++venueCount;
                }
            }
        }

        // VENUE 5: AMM (remaining after vault, if vault went first)
        if (remainingCollateral != 0 && tryVaultFirst) {
            uint256 ammShares = _quoteAMMBuy(marketId, buyYes, remainingCollateral);
            if (ammShares != 0) {
                totalSharesOut += ammShares;
                remainingCollateral = 0;
                if (source == bytes4(0)) source = SOURCE_AMM;
                ++venueCount;
            }
        }

        // Set "mult" if multiple venues used
        if (venueCount > 1) source = SOURCE_MULT;
    }

    /// @return totalShares Shares from split + swap
    function _quoteAMMBuy(uint256 marketId, bool buyYes, uint256 collateralIn)
        internal
        view
        returns (uint256 totalShares)
    {
        uint256 poolId = canonicalPoolId[marketId];
        (uint112 r0, uint112 r1) = _getReserves(poolId);
        if (poolId == 0 || r0 == 0 || r1 == 0) return 0;

        uint256 feeBps = _getPoolFeeBps(canonicalFeeOrHook[marketId], poolId);
        uint256 noId = _getNoId(marketId);

        assembly ("memory-safe") {
            let zeroForOne := xor(lt(marketId, noId), buyYes)
            let amountInWithFee := mul(collateralIn, sub(10000, feeBps))
            let rIn := xor(r1, mul(xor(r1, r0), zeroForOne))
            let rOut := xor(r0, mul(xor(r0, r1), zeroForOne))
            let swapped := div(mul(amountInWithFee, rOut), add(mul(rIn, 10000), amountInWithFee))
            if lt(swapped, rOut) {
                totalShares := add(collateralIn, swapped)
            }
        }
    }

    // ============ Vault LP Functions ============

    function depositToVault(
        uint256 marketId,
        bool isYes,
        uint256 shares,
        address receiver,
        uint256 deadline
    ) public returns (uint256 vaultSharesMinted) {
        _guardEnter();
        _requireMarketOpen(marketId);
        _checkDeadline(deadline);
        _requireRegistered(marketId);
        if (shares == 0) _revert(ERR_SHARES, 0); // ZeroShares
        if (shares > MAX_UINT112) _revert(ERR_SHARES, 3); // SharesOverflow
        if (receiver == address(0)) receiver = msg.sender;

        PAMM.transferFrom(msg.sender, address(this), isYes ? marketId : _getNoId(marketId), shares);

        vaultSharesMinted = _depositToVaultSide(marketId, isYes, shares, receiver);

        bootstrapVaults[marketId].lastActivity = uint32(block.timestamp);

        emit VaultDeposit(marketId, receiver, isYes, shares, vaultSharesMinted);
        _guardExit();
    }

    /// @notice Withdraw vault shares and claim fees
    function withdrawFromVault(
        uint256 marketId,
        bool isYes,
        uint256 vaultSharesToRedeem,
        address receiver,
        uint256 deadline
    ) public returns (uint256 sharesReturned, uint256 feesEarned) {
        _guardEnter();
        _checkDeadline(deadline);
        _requireRegistered(marketId);
        _checkWithdrawalCooldown(marketId);

        if (vaultSharesToRedeem == 0) _revert(ERR_SHARES, 1); // ZeroVaultShares
        if (receiver == address(0)) receiver = msg.sender;

        UserVaultPosition storage position = vaultPositions[marketId][msg.sender];
        uint256 userVaultShares = isYes ? position.yesVaultShares : position.noVaultShares;
        if (userVaultShares < vaultSharesToRedeem) _revert(ERR_VALIDATION, 5); // InsufficientVaultShares

        BootstrapVault storage vault = bootstrapVaults[marketId];
        uint256 totalVaultShares =
            isYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];
        if (totalVaultShares == 0) _revert(ERR_SHARES, 2); // NoVaultShares

        uint256 totalShares = isYes ? vault.yesShares : vault.noShares;
        sharesReturned = mulDiv(vaultSharesToRedeem, totalShares, totalVaultShares);
        if (sharesReturned > MAX_UINT112) _revert(ERR_SHARES, 5); // SharesReturnedOverflow

        unchecked {
            uint256 accPerShare =
                isYes ? accYesCollateralPerShare[marketId] : accNoCollateralPerShare[marketId];
            uint256 debt = isYes ? position.yesRewardDebt : position.noRewardDebt;
            uint256 acc = mulDiv(userVaultShares, accPerShare, 1e18);
            feesEarned = acc > debt ? acc - debt : 0;
            uint256 newDebt = mulDiv(userVaultShares - vaultSharesToRedeem, accPerShare, 1e18);

            if (isYes) {
                vault.yesShares -= uint112(sharesReturned);
                position.yesVaultShares -= uint112(vaultSharesToRedeem);
                position.yesRewardDebt = newDebt;
                totalYesVaultShares[marketId] -= vaultSharesToRedeem;
            } else {
                vault.noShares -= uint112(sharesReturned);
                position.noVaultShares -= uint112(vaultSharesToRedeem);
                position.noRewardDebt = newDebt;
                totalNoVaultShares[marketId] -= vaultSharesToRedeem;
            }
        }

        if (sharesReturned != 0) {
            PAMM.transfer(receiver, isYes ? marketId : _getNoId(marketId), sharesReturned);
        }

        // Transfer fees if any earned
        if (feesEarned != 0) _transferCollateral(_getCollateral(marketId), receiver, feesEarned);

        emit VaultWithdraw(
            marketId, receiver, isYes, vaultSharesToRedeem, sharesReturned, feesEarned
        );
        _guardExit();
    }

    /// @notice Claim pending fees without withdrawing vault shares
    function harvestVaultFees(uint256 marketId, bool isYes) public returns (uint256 feesEarned) {
        _guardEnter();
        _requireRegistered(marketId);
        _checkWithdrawalCooldown(marketId);

        UserVaultPosition storage position = vaultPositions[marketId][msg.sender];
        uint256 userVaultShares;
        uint256 debt;
        assembly ("memory-safe") {
            // Load packed slot 0: yesVaultShares (bits 0-111) | noVaultShares (bits 112-223) | lastDepositTime (bits 224-255)
            let slot0 := sload(position.slot)

            // Extract vault shares based on isYes flag
            // if isYes: userVaultShares = slot0 & 0xffffffffffffffffffffffffffff (bits 0-111)
            // if !isYes: userVaultShares = (slot0 >> 112) & 0xffffffffffffffffffffffffffff (bits 112-223)
            userVaultShares := and(shr(mul(112, iszero(isYes)), slot0), MAX_UINT112)

            // Load debt from slot 1 (yesRewardDebt) or slot 2 (noRewardDebt)
            // if isYes: debt = sload(position.slot + 1)
            // if !isYes: debt = sload(position.slot + 2)
            let debtSlot := add(add(position.slot, 1), iszero(isYes))
            debt := sload(debtSlot)
        }

        uint256 accPerShare =
            isYes ? accYesCollateralPerShare[marketId] : accNoCollateralPerShare[marketId];
        uint256 acc = mulDiv(userVaultShares, accPerShare, 1e18);

        assembly ("memory-safe") {
            feesEarned := mul(gt(acc, debt), sub(acc, debt))
        }

        if (feesEarned != 0) {
            if (isYes) {
                position.yesRewardDebt = acc;
            } else {
                position.noRewardDebt = acc;
            }

            _transferCollateral(_getCollateral(marketId), msg.sender, feesEarned);

            emit VaultFeesHarvested(marketId, msg.sender, isYes, feesEarned);
        }
        _guardExit();
    }

    /// @notice Split collateral and provide liquidity to vaults and/or AMM
    /// @param marketId Market ID
    /// @param collateralAmount Collateral to split
    /// @param vaultYesShares YES shares to deposit to vault
    /// @param vaultNoShares NO shares to deposit to vault
    /// @param ammLPShares YES+NO shares to add to AMM
    /// @param minAmount0 Minimum YES to AMM
    /// @param minAmount1 Minimum NO to AMM
    /// @param receiver Recipient
    /// @param deadline Deadline
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
        public
        payable
        returns (uint256 yesVaultSharesMinted, uint256 noVaultSharesMinted, uint256 ammLiquidity)
    {
        _guardEnter();
        _requireMarketOpen(marketId);
        _checkDeadline(deadline);
        _requireRegistered(marketId);
        _requireNonZero(collateralAmount);
        if (receiver == address(0)) receiver = msg.sender;

        // Load canonical feeOrHook for this market
        uint256 feeOrHook = canonicalFeeOrHook[marketId];

        if (vaultYesShares > collateralAmount || vaultNoShares > collateralAmount) {
            _revert(ERR_VALIDATION, 4); // InsufficientShares
        }

        uint256 yesRemaining;
        uint256 noRemaining;
        unchecked {
            yesRemaining = collateralAmount - vaultYesShares;
            noRemaining = collateralAmount - vaultNoShares;
        }

        if (ammLPShares > yesRemaining || ammLPShares > noRemaining) {
            _revert(ERR_VALIDATION, 4); // InsufficientShares
        }

        // Take collateral and split into YES + NO shares
        address collateral = _takeCollateral(marketId, collateralAmount);
        _splitShares(marketId, collateralAmount, collateral);

        // Deposit YES shares to vault
        if (vaultYesShares != 0) {
            yesVaultSharesMinted = _depositToVaultSide(marketId, true, vaultYesShares, receiver);
            emit VaultDeposit(marketId, receiver, true, vaultYesShares, yesVaultSharesMinted);
        }

        // Deposit NO shares to vault
        if (vaultNoShares != 0) {
            noVaultSharesMinted = _depositToVaultSide(marketId, false, vaultNoShares, receiver);
            emit VaultDeposit(marketId, receiver, false, vaultNoShares, noVaultSharesMinted);
        }

        if ((vaultYesShares | vaultNoShares) != 0) {
            bootstrapVaults[marketId].lastActivity = uint32(block.timestamp);
        }

        // Add AMM liquidity
        uint256 yesId = marketId;
        uint256 noId = _getNoId(marketId);
        if (ammLPShares != 0) {
            ZAMM.deposit(address(PAMM), yesId, ammLPShares);
            ZAMM.deposit(address(PAMM), noId, ammLPShares);

            (IZAMM.PoolKey memory k,) = _buildKey(yesId, noId, feeOrHook);

            // Add liquidity with user-specified slippage protection
            (,, ammLiquidity) = ZAMM.addLiquidity(
                k, ammLPShares, ammLPShares, minAmount0, minAmount1, receiver, deadline
            );

            ZAMM.recoverTransientBalance(address(PAMM), yesId, receiver);
            ZAMM.recoverTransientBalance(address(PAMM), noId, receiver);
        }

        // Return leftover shares to receiver
        unchecked {
            uint256 leftoverYes = yesRemaining - ammLPShares;
            uint256 leftoverNo = noRemaining - ammLPShares;

            if (leftoverYes != 0) PAMM.transfer(receiver, yesId, leftoverYes);
            if (leftoverNo != 0) PAMM.transfer(receiver, noId, leftoverNo);
        }

        // Refund excess ETH
        _refundExcessETH(collateral, collateralAmount);
        _guardExit();
    }

    /// @notice Settle rebalance budget by distributing to LPs
    function settleRebalanceBudget(uint256 marketId)
        public
        returns (uint256 budgetDistributed, uint256 sharesMerged)
    {
        _guardEnter();
        _requireRegistered(marketId);
        // Check market close time or early resolution
        (bool resolved,,,,) = _staticMarkets(marketId);
        if (!resolved) {
            uint64 close = _getClose(marketId);
            if (block.timestamp < close) _revert(ERR_TIMING, 3); // MarketNotClosed
        }

        BootstrapVault storage vault = bootstrapVaults[marketId];

        // Capture pre-merge inventory for probability-weighted fee distribution
        uint112 preMergeYes = vault.yesShares;
        uint112 preMergeNo = vault.noShares;
        uint256 twapBps = _getTWAPPrice(marketId);

        // First, merge any balanced inventory to convert to collateral (only if not resolved)
        sharesMerged = vault.yesShares < vault.noShares ? vault.yesShares : vault.noShares;
        if (!resolved && sharesMerged != 0) {
            PAMM.merge(marketId, sharesMerged, address(this));
            unchecked {
                vault.yesShares -= uint112(sharesMerged); // Safe: sharesMerged = min(yes, no)
                vault.noShares -= uint112(sharesMerged); // Safe: sharesMerged = min(yes, no)
                // Add merged collateral to budget
                rebalanceCollateralBudget[marketId] += sharesMerged; // Safe: adding uint112 to uint256
            }
        }

        uint256 budgetToProcess = rebalanceCollateralBudget[marketId];
        rebalanceCollateralBudget[marketId] = 0;

        if (budgetToProcess != 0) {
            if (_addVaultFeesSymmetricWithSnapshot(
                    marketId, budgetToProcess, preMergeYes, preMergeNo, twapBps
                )) {
                budgetDistributed = budgetToProcess;
            } else {
                // No LPs to distribute to - reinvest into protocol vault depth
                unchecked {
                    rebalanceCollateralBudget[marketId] += budgetToProcess;
                }
                budgetDistributed = 0;
            }
        }

        emit BudgetSettled(marketId, budgetDistributed, sharesMerged);
        _guardExit();
    }

    /// @notice Redeem vault winning shares and send to DAO
    /// @dev Requires no user LPs exist
    /// @param marketId Market ID
    /// @return payout Collateral sent to DAO
    function redeemVaultWinningShares(uint256 marketId) public returns (uint256 payout) {
        _guardEnter();
        _requireRegistered(marketId);
        bool outcome = _requireResolved(marketId);

        uint256 totalYes = totalYesVaultShares[marketId];
        uint256 totalNo = totalNoVaultShares[marketId];

        // Only allow cleanup if no user LPs remain
        if ((totalYes | totalNo) != 0) _revert(ERR_STATE, 6); // CirculatingLPsExist

        BootstrapVault storage vault = bootstrapVaults[marketId];

        uint256 winningShares =
            PAMM.balanceOf(address(this), outcome ? marketId : _getNoId(marketId));
        if (winningShares != 0) (, payout) = PAMM.claim(marketId, DAO);

        vault.yesShares = 0;
        vault.noShares = 0;
        totalYesVaultShares[marketId] = 0;
        totalNoVaultShares[marketId] = 0;

        emit VaultWinningSharesRedeemed(marketId, outcome, winningShares, payout);
        _guardExit();
    }

    /// @notice Finalize market - extract all vault value to DAO
    /// @param marketId Market to finalize
    /// @return totalToDAO Collateral sent to DAO
    function finalizeMarket(uint256 marketId) public returns (uint256 totalToDAO) {
        _guardEnter();
        totalToDAO = _finalizeMarket(marketId);
        _guardExit();
    }

    function _finalizeMarket(uint256 marketId) internal returns (uint256 totalToDAO) {
        _requireRegistered(marketId);
        bool outcome = _requireResolved(marketId);
        address collateral = _getCollateral(marketId);

        // Cache vault share totals
        uint256 totalYes = totalYesVaultShares[marketId];
        uint256 totalNo = totalNoVaultShares[marketId];

        // Only finalize if no user LPs remain
        if ((totalYes | totalNo) != 0) return 0;

        BootstrapVault storage vault = bootstrapVaults[marketId];

        uint256 winningShares =
            PAMM.balanceOf(address(this), outcome ? marketId : _getNoId(marketId));
        if (winningShares != 0) {
            (, uint256 payout) = PAMM.claim(marketId, DAO);
            unchecked {
                totalToDAO += payout;
            }
        }

        vault.yesShares = 0;
        vault.noShares = 0;
        totalYesVaultShares[marketId] = 0;
        totalNoVaultShares[marketId] = 0;

        // Step 2: Distribute budget to LPs or send to DAO
        uint256 budget = rebalanceCollateralBudget[marketId];
        uint256 budgetDistributed;

        if (budget != 0) {
            rebalanceCollateralBudget[marketId] = 0;
            _transferCollateral(collateral, DAO, budget);
            budgetDistributed = budget;
            unchecked {
                totalToDAO += budget;
            }
        }

        emit MarketFinalized(marketId, totalToDAO, winningShares, budgetDistributed);
    }

    struct RebalanceValidation {
        uint256 twapBps;
        uint256 yesReserve;
        uint256 noReserve;
        bool yesIsId0;
    }

    /// @notice Validate TWAP and spot price for rebalancing
    function _validateRebalanceConditions(uint256 marketId, uint256 canonical)
        internal
        view
        returns (RebalanceValidation memory validation)
    {
        validation.twapBps = _getTWAPPrice(marketId);
        if (validation.twapBps == 0) _revert(ERR_COMPUTATION, 3); // TWAPRequired

        // Read spot reserves for deviation check (safety valve against manipulation)
        (uint112 r0, uint112 r1) = _getReserves(canonical);
        if (r0 == 0 || r1 == 0) _revert(ERR_TIMING, 4); // PoolNotReady

        uint256 noId = _getNoId(marketId);
        validation.yesIsId0 = marketId < noId;

        validation.yesReserve = validation.yesIsId0 ? uint256(r0) : uint256(r1);
        validation.noReserve = validation.yesIsId0 ? uint256(r1) : uint256(r0);

        uint256 spotYesBps;
        unchecked {
            spotYesBps =
                (validation.noReserve * 10_000) / (validation.yesReserve + validation.noReserve);
        }

        assembly ("memory-safe") {
            if iszero(spotYesBps) { spotYesBps := 1 }
            if iszero(lt(spotYesBps, 10000)) { spotYesBps := 9999 }
        }

        // Calculate deviation and check against max
        uint256 deviation;
        assembly ("memory-safe") {
            // Load twapBps from struct at offset 0
            let twapBps := mload(validation)

            // Calculate absolute difference: |spotYesBps - twapBps|
            let diff := sub(spotYesBps, twapBps)
            deviation := xor(
                diff,
                mul(xor(diff, sub(twapBps, spotYesBps)), sgt(twapBps, spotYesBps))
            )
        }
        if (deviation > 500) _revert(ERR_COMPUTATION, 5); // SpotDeviantFromTWAP
    }

    /// @notice Calculate minimum swap output for rebalance
    function _calculateRebalanceMinOut(
        uint256 collateralUsed,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256 minOut) {
        // ZAMM constant-product: amountOut = (amountIn * (1-fee) * reserveOut) / (reserveIn + amountIn * (1-fee))
        uint256 amountInWithFee;
        uint256 expectedSwapOut;
        unchecked {
            amountInWithFee = collateralUsed * (10_000 - feeBps);
            expectedSwapOut =
                mulDiv(amountInWithFee, reserveOut, (reserveIn * 10_000) + amountInWithFee);
        }

        if (expectedSwapOut == 0) return 0;

        assembly ("memory-safe") {
            // Apply tight slippage tolerance to swap output only
            minOut := div(mul(expectedSwapOut, sub(10000, 75)), 10000) // 0.75% slippage
            // Prevent truncation to 0 and subtract 1 for rounding tolerance
            switch minOut
            case 0 { minOut := 1 }
            default {
                if gt(minOut, 1) { minOut := sub(minOut, 1) }
            }
        }
    }

    /// @notice Get fee basis points for a pool
    function _getPoolFeeBps(uint256 feeOrHook, uint256 canonical)
        internal
        view
        returns (uint256 feeBps)
    {
        bool isHook = (feeOrHook & (FLAG_BEFORE | FLAG_AFTER)) != 0;
        if (isHook) {
            address hook = address(uint160(feeOrHook));
            (bool ok, uint256 fee) = _staticUint(hook, 0x9f3ce55a, canonical); // getCurrentFeeBps
            feeBps = (ok && fee < 10000) ? fee : DEFAULT_FEE_BPS;
        } else {
            feeBps = feeOrHook;
        }

        assembly ("memory-safe") {
            if iszero(lt(feeBps, 10000)) {
                feeBps := DEFAULT_FEE_BPS
            }
        }
    }

    /// @notice Rebalance vault using budget collateral
    function rebalanceBootstrapVault(uint256 marketId, uint256 deadline)
        public
        returns (uint256 collateralUsed)
    {
        _guardEnter();
        collateralUsed = _rebalanceBootstrapVault(marketId, deadline);
        _guardExit();
    }

    function _rebalanceBootstrapVault(uint256 marketId, uint256 deadline)
        internal
        returns (uint256 collateralUsed)
    {
        (uint64 close, address collateral) = _requireMarketOpen(marketId);
        _checkDeadline(deadline);

        // Opportunistically update TWAP (non-reverting, inlined)
        {
            TWAPObservations storage obs = twapObservations[marketId];
            if (
                obs.timestamp1 != 0 && uint256(obs.timestamp1) <= block.timestamp
                    && block.timestamp - uint256(obs.timestamp1) >= MIN_TWAP_UPDATE_INTERVAL
            ) {
                (uint256 currentCumulative, bool success) = _getCurrentCumulative(marketId);
                if (success && currentCumulative >= obs.cumulative1) {
                    _updateTWAPObservation(obs, marketId, currentCumulative);
                }
            }
        }
        if (_isInCloseWindow(marketId, close)) return 0;

        BootstrapVault storage vault = bootstrapVaults[marketId];

        uint256 canonical = canonicalPoolId[marketId];
        if (canonical == 0) _revert(ERR_STATE, 2); // MarketNotRegistered

        uint256 feeOrHook = canonicalFeeOrHook[marketId];

        uint256 twapBps = _getTWAPPrice(marketId);
        if (twapBps == 0) return 0;

        RebalanceValidation memory validation = _validateRebalanceConditions(marketId, canonical);

        uint256 totalYes = totalYesVaultShares[marketId];
        uint256 totalNo = totalNoVaultShares[marketId];

        if ((totalYes | totalNo) == 0) return 0;

        uint256 noId = _getNoId(marketId);

        bool yesIsLower = vault.yesShares < vault.noShares;

        if ((yesIsLower && totalYes == 0) || (!yesIsLower && totalNo == 0)) return 0;

        uint112 preMergeYes = vault.yesShares;
        uint112 preMergeNo = vault.noShares;

        uint256 mergeAmount = yesIsLower ? vault.yesShares : vault.noShares;
        if (mergeAmount != 0) {
            PAMM.merge(marketId, mergeAmount, address(this));
            unchecked {
                vault.yesShares -= uint112(mergeAmount);
                vault.noShares -= uint112(mergeAmount);
            }
            _distributeFeesSplit(marketId, mergeAmount, preMergeYes, preMergeNo, validation.twapBps);
        }

        uint256 availableCollateral = rebalanceCollateralBudget[marketId];
        if (availableCollateral == 0) return 0;

        uint256 collateralForSwap;
        uint256 bounty;
        unchecked {
            uint256 maxCollateralNeeded =
                ((yesIsLower
                                ? (vault.noShares - vault.yesShares)
                                : (vault.yesShares - vault.noShares))
                        * (yesIsLower ? validation.twapBps : (10_000 - validation.twapBps)))
                    / 10_000;
            collateralUsed = availableCollateral < maxCollateralNeeded
                ? availableCollateral
                : maxCollateralNeeded;

            // Reserve bounty from collateralUsed (0.1%)
            bounty = mulDiv(collateralUsed, 10, 10_000); // 0.1% bounty
            collateralForSwap = collateralUsed - bounty;
        }
        if (collateralForSwap == 0) return 0;

        (IZAMM.PoolKey memory k, bool keyYesIsId0) = _buildKey(marketId, noId, feeOrHook);
        if (_derivePoolId(k) != canonical) _revert(ERR_COMPUTATION, 7); // NonCanonicalPool

        uint256 feeBps = _getPoolFeeBps(feeOrHook, canonical);

        uint256 minOut = _calculateRebalanceMinOut(
            collateralForSwap,
            yesIsLower ? validation.noReserve : validation.yesReserve,
            yesIsLower ? validation.yesReserve : validation.noReserve,
            feeBps
        );
        bool zeroForOne = yesIsLower ? !keyYesIsId0 : keyYesIsId0;
        if (minOut == 0) return 0;

        // Now safe to proceed with state changes
        _splitShares(marketId, collateralForSwap, collateral);

        uint256 swapTokenId = yesIsLower ? noId : marketId;
        ZAMM.deposit(address(PAMM), swapTokenId, collateralForSwap);

        uint256 swappedShares =
            ZAMM.swapExactIn(k, collateralForSwap, minOut, zeroForOne, address(this), deadline);

        uint256 currentShares = yesIsLower ? vault.yesShares : vault.noShares;
        uint256 totalAcquired;
        unchecked {
            totalAcquired = collateralForSwap + swappedShares;
        }
        if (totalAcquired > MAX_UINT112) _revert(ERR_SHARES, 3); // SharesOverflow
        _checkU112Overflow(currentShares, totalAcquired);

        unchecked {
            if (yesIsLower) {
                vault.yesShares += uint112(totalAcquired);
            } else {
                vault.noShares += uint112(totalAcquired);
            }
            rebalanceCollateralBudget[marketId] -= collateralUsed;
        }
        vault.lastActivity = uint32(block.timestamp);

        // Pay small bounty to caller to incentivize permissionless rebalancing
        if (bounty != 0) {
            _transferCollateral(collateral, msg.sender, bounty);
        }

        emit Rebalanced(marketId, collateralUsed, totalAcquired, yesIsLower);
    }

    /// @dev Execute vault OTC fill and account proceeds
    function _executeVaultOTCFill(
        uint256 marketId,
        bool buyYes,
        uint256 remainingCollateral,
        uint256 pYes,
        address to,
        uint256 noId
    ) internal returns (uint256 sharesOut, uint256 collateralUsed, uint8 venueIncrement) {
        BootstrapVault storage vault = bootstrapVaults[marketId];
        (uint256 otcShares, uint256 otcCollateralUsed, bool otcFilled) =
            _tryVaultOTCFill(marketId, buyYes, remainingCollateral, pYes);

        if (!otcFilled || otcShares == 0) return (0, 0, 0);

        uint112 preYesInv = vault.yesShares;
        uint112 preNoInv = vault.noShares;

        // Defensive checks before unchecked arithmetic
        if (otcShares > MAX_UINT112) _revert(ERR_SHARES, 3); // SharesOverflow
        if (buyYes) {
            if (otcShares > vault.yesShares) _revert(ERR_VALIDATION, 4); // InsufficientShares
        } else {
            if (otcShares > vault.noShares) _revert(ERR_VALIDATION, 4); // InsufficientShares
        }

        unchecked {
            if (buyYes) {
                vault.yesShares -= uint112(otcShares);
                PAMM.transfer(to, marketId, otcShares);
            } else {
                vault.noShares -= uint112(otcShares);
                PAMM.transfer(to, noId, otcShares);
            }
        }

        (uint256 principal, uint256 spreadFee) = _accountVaultOTCProceeds(
            marketId, buyYes, otcShares, otcCollateralUsed, pYes, preYesInv, preNoInv
        );
        vault.lastActivity = uint32(block.timestamp);

        unchecked {
            uint256 effectivePriceBps = mulDiv(otcCollateralUsed, 10_000, otcShares);
            emit VaultOTCFill(
                marketId,
                msg.sender,
                to,
                buyYes,
                otcCollateralUsed,
                otcShares,
                effectivePriceBps,
                principal,
                spreadFee
            );
        }

        return (otcShares, otcCollateralUsed, 1);
    }

    /// @dev Execute AMM swap
    function _executeAMMSwap(
        uint256 marketId,
        bool buyYes,
        uint256 remainingCollateral,
        uint256 minSharesOut,
        uint256 totalSharesOut,
        address to,
        uint256 deadline,
        uint256 noId,
        uint256 feeOrHook
    ) internal returns (uint256 ammSharesOut) {
        address collateral = _getCollateral(marketId);
        _splitShares(marketId, remainingCollateral, collateral);

        uint256 swapTokenId = buyYes ? noId : marketId;
        uint256 desiredTokenId = buyYes ? marketId : noId;

        ZAMM.deposit(address(PAMM), swapTokenId, remainingCollateral);

        (IZAMM.PoolKey memory k, bool yesIsId0) = _buildKey(marketId, noId, feeOrHook);
        bool zeroForOne = buyYes ? !yesIsId0 : yesIsId0;

        uint256 minSwapOut;
        unchecked {
            uint256 minRemainingOut =
                minSharesOut > totalSharesOut ? minSharesOut - totalSharesOut : 0;
            minSwapOut =
                minRemainingOut > remainingCollateral ? minRemainingOut - remainingCollateral : 0;
        }

        uint256 swappedShares = ZAMM.swapExactIn(
            k, remainingCollateral, minSwapOut, zeroForOne, address(this), deadline
        );

        ammSharesOut = remainingCollateral + swappedShares;
        PAMM.transfer(to, desiredTokenId, ammSharesOut);
    }

    function _shouldUseVaultMint(uint256 marketId, BootstrapVault memory vault, bool buyYes)
        internal
        view
        returns (bool)
    {
        uint64 close = _getClose(marketId);
        unchecked {
            if (close < block.timestamp + 2 days) {
                // BOOTSTRAP_WINDOW
                return false;
            }
        }

        uint256 yesShares = vault.yesShares;
        uint256 noShares = vault.noShares;

        // If both sides are empty, allow mint for initial bootstrapping
        if ((yesShares | noShares) == 0) return true;

        // If one side is empty (but not both), allow only if mint fills the empty side
        if (yesShares == 0) return !buyYes;
        if (noShares == 0) return buyYes;

        // Check 2x imbalance ratio and equal case
        uint256 larger = yesShares > noShares ? yesShares : noShares;
        uint256 smaller = yesShares > noShares ? noShares : yesShares;

        if (larger > smaller * 2) return false; // Max 2x imbalance for mint
        if (yesShares == noShares) return true;

        // Allow only if adding to the scarce side
        bool yesScarce = yesShares < noShares;
        return (buyYes && !yesScarce) || (!buyYes && yesScarce);
    }

    // ============ TWAP Functions ============

    /// @notice Get current cumulative price from ZAMM pool
    /// @return cumulative Cumulative price in UQ112x112
    /// @return success Whether computation succeeded
    function _getCurrentCumulative(uint256 marketId)
        internal
        view
        returns (uint256 cumulative, bool success)
    {
        uint256 poolId = canonicalPoolId[marketId];
        if (poolId == 0) return (0, false);

        (
            bool ok,
            uint112 r0,
            uint112 r1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast
        ) = _staticPools(poolId);

        if (!ok || r0 == 0 || r1 == 0) return (0, false);

        {
            // Get canonical NO token ID (inline for gas efficiency)
            uint256 noId = _getNoId(marketId);
            bool yesIsId0 = marketId < noId;

            // Consolidate cumulative calculation in assembly
            assembly ("memory-safe") {
                // Select cumulative: yesIsId0 ? price0CumulativeLast : price1CumulativeLast
                let poolCumulative :=
                    xor(
                        price0CumulativeLast,
                        mul(xor(price0CumulativeLast, price1CumulativeLast), iszero(yesIsId0))
                    )

                // Compute timeElapsed (wrap-safe uint32 arithmetic)
                let timeElapsed := sub(and(timestamp(), 0xffffffff), blockTimestampLast)

                switch iszero(timeElapsed)
                case 1 {
                    // If timeElapsed == 0, return poolCumulative
                    cumulative := poolCumulative
                    success := 1
                }
                default {
                    // Select reserves based on token ordering
                    let yesRes := xor(r0, mul(xor(r0, r1), iszero(yesIsId0)))
                    let noRes := xor(r1, mul(xor(r1, r0), iszero(yesIsId0)))

                    // Compute NO/YES ratio in UQ112x112: (noReserve << 112) / yesReserve
                    let currentPrice := div(shl(112, noRes), yesRes)

                    // Compute prod = currentPrice * timeElapsed with overflow check
                    let prod := mul(currentPrice, timeElapsed)

                    // Check for overflow: prod / timeElapsed == currentPrice
                    switch eq(div(prod, timeElapsed), currentPrice)
                    case 0 {
                        // Overflow detected
                        cumulative := 0
                        success := 0
                    }
                    default {
                        // Compute sum = poolCumulative + prod
                        let sum := add(poolCumulative, prod)

                        // Check for overflow: sum >= poolCumulative
                        switch lt(sum, poolCumulative)
                        case 1 {
                            // Overflow detected
                            cumulative := 0
                            success := 0
                        }
                        default {
                            cumulative := sum
                            success := 1
                        }
                    }
                }
            }

            return (cumulative, success);
        }
    }

    /// @notice Update TWAP observation (permissionless)
    /// @param marketId Market ID
    function updateTWAPObservation(uint256 marketId) public {
        TWAPObservations storage obs = twapObservations[marketId];

        if (obs.timestamp1 == 0) _revert(ERR_COMPUTATION, 3); // TWAPRequired
        if (uint256(obs.timestamp1) > block.timestamp) _revert(ERR_COMPUTATION, 2); // TWAPCorrupt

        if (block.timestamp - uint256(obs.timestamp1) < MIN_TWAP_UPDATE_INTERVAL) {
            _revert(ERR_TIMING, 1); // TooSoon
        }

        (uint256 currentCumulative, bool success) = _getCurrentCumulative(marketId);
        if (!success) _revert(ERR_TIMING, 4); // PoolNotReady

        if (currentCumulative < obs.cumulative1) _revert(ERR_TIMING, 4); // PoolNotReady

        _updateTWAPObservation(obs, marketId, currentCumulative);
    }

    /// @notice Get TWAP price for a market
    /// @return twapBps TWAP in basis points [1-9999], or 0 if unavailable
    function _getTWAPPrice(uint256 marketId) internal view returns (uint256 twapBps) {
        TWAPObservations storage obs = twapObservations[marketId];

        if (obs.cacheBlockNum == uint32(block.number) && obs.cachedTwapBps != 0) {
            return obs.cachedTwapBps;
        }

        if (obs.timestamp1 == 0) return 0;

        if (block.timestamp < obs.timestamp1) return 0;
        if (obs.timestamp1 < obs.timestamp0) return 0;

        uint256 timeElapsed;
        uint256 twapUQ112x112;

        if (block.timestamp - obs.timestamp1 < MIN_TWAP_UPDATE_INTERVAL) {
            unchecked {
                timeElapsed = obs.timestamp1 - obs.timestamp0;
            }
            if (timeElapsed == 0) return 0;

            if (obs.cumulative1 < obs.cumulative0) return 0;

            unchecked {
                twapUQ112x112 = (obs.cumulative1 - obs.cumulative0) / timeElapsed;
            }
            return _convertUQ112x112ToBps(twapUQ112x112);
        }

        (uint256 currentCumulative, bool success) = _getCurrentCumulative(marketId);
        if (!success || currentCumulative < obs.cumulative1) return 0;

        unchecked {
            timeElapsed = block.timestamp - obs.timestamp1;
        }
        if (timeElapsed == 0) return 0;

        unchecked {
            twapUQ112x112 = (currentCumulative - obs.cumulative1) / timeElapsed;
        }
        return _convertUQ112x112ToBps(twapUQ112x112);
    }

    /// @dev Update TWAP observation with new cumulative value
    function _updateTWAPObservation(
        TWAPObservations storage obs,
        uint256 marketId,
        uint256 currentCumulative
    ) internal {
        uint256 poolId = canonicalPoolId[marketId];
        (bool ok, uint112 r0, uint112 r1,,,) = _staticPools(poolId);
        uint128 totalReserves = ok ? uint128(r0) + uint128(r1) : 0;

        obs.timestamp0 = obs.timestamp1;
        obs.cumulative0 = obs.cumulative1;
        obs.timestamp1 = uint32(block.timestamp);
        obs.cumulative1 = currentCumulative;
        obs.reservesAtObs1 = totalReserves;

        uint256 timeElapsed = uint32(block.timestamp) - obs.timestamp0;
        if (timeElapsed > 0 && obs.cumulative1 >= obs.cumulative0) {
            uint256 twapUQ112x112 = (obs.cumulative1 - obs.cumulative0) / timeElapsed;
            obs.cachedTwapBps = uint32(_convertUQ112x112ToBps(twapUQ112x112));
            obs.cacheBlockNum = uint32(block.number);
        } else {
            obs.cachedTwapBps = 0;
            obs.cacheBlockNum = 0;
        }
    }

    /// @notice Convert UQ112x112 NO/YES ratio to YES probability in basis points
    /// @dev Formula: pYES_bps = (10000 * r) / (1 + r) = 10000 * NO / (YES + NO), where r = NO/YES
    /// @param twapUQ112x112 NO/YES ratio in UQ112x112 fixed-point format
    /// @return twapBps Probability of YES outcome in basis points [1-9999]
    function _convertUQ112x112ToBps(uint256 twapUQ112x112) internal pure returns (uint256 twapBps) {
        // Compute pYES = (10000 * r) / (2^112 + r), where r = NO/YES in UQ112x112
        assembly ("memory-safe") {
            let denom := add(shl(112, 1), twapUQ112x112)
            twapBps := div(mul(10000, twapUQ112x112), denom)
            if iszero(twapBps) { twapBps := 1 }
            if iszero(lt(twapBps, 10000)) { twapBps := 9999 }
        }
    }

    // ============ Vault Internal Functions ============

    function _addVaultFeesWithSnapshot(
        uint256 marketId,
        bool isYes,
        uint256 feeAmount,
        uint256 totalSharesSnapshot
    ) internal {
        if (feeAmount == 0) return;
        if (totalSharesSnapshot == 0) {
            assembly ("memory-safe") {
                mstore(0x00, marketId)
                mstore(0x20, rebalanceCollateralBudget.slot)
                let slot := keccak256(0x00, 0x40)
                sstore(slot, add(sload(slot), feeAmount))
            }
            return;
        }

        uint256 accPerShare = fullMulDiv(feeAmount, 1e18, totalSharesSnapshot);
        uint256 distributed = fullMulDiv(accPerShare, totalSharesSnapshot, 1e18);
        uint256 maxAcc = MAX_ACC_PER_SHARE;

        assembly ("memory-safe") {
            let dust := sub(feeAmount, distributed)
            if dust {
                mstore(0x00, marketId)
                mstore(0x20, rebalanceCollateralBudget.slot)
                let slot := keccak256(0x00, 0x40)
                sstore(slot, add(sload(slot), dust))
            }

            mstore(0x00, marketId)
            let accSlot :=
                xor(
                    accYesCollateralPerShare.slot,
                    mul(
                        xor(accYesCollateralPerShare.slot, accNoCollateralPerShare.slot),
                        iszero(isYes)
                    )
                )
            mstore(0x20, accSlot)
            let slot := keccak256(0x00, 0x40)
            let newAcc := add(sload(slot), accPerShare)
            // MAX_ACC_PER_SHARE = type(uint256).max / type(uint112).max
            if gt(newAcc, maxAcc) {
                mstore(0x00, 0x077a9c33) // ValidationError(0) = Overflow
                mstore(0x20, 0)
                revert(0x1c, 0x24)
            }
            sstore(slot, newAcc)
        }
    }

    /// @notice Distribute OTC spread with scarcity weighting (40-60% cap)
    /// @param marketId Market ID
    /// @param amount Spread to distribute
    /// @param preYesInv YES inventory before trade
    /// @param preNoInv NO inventory before trade
    /// @return distributed True if LPs exist
    function _distributeOtcSpreadScarcityCapped(
        uint256 marketId,
        uint256 amount,
        uint112 preYesInv,
        uint112 preNoInv
    ) internal returns (bool distributed) {
        if (amount == 0) return false;

        uint256 yesLP = totalYesVaultShares[marketId];
        uint256 noLP = totalNoVaultShares[marketId];

        if ((yesLP | noLP) == 0) return false;

        if (yesLP == 0) {
            _addVaultFeesWithSnapshot(marketId, false, amount, noLP);
            return true;
        }
        if (noLP == 0) {
            _addVaultFeesWithSnapshot(marketId, true, amount, yesLP);
            return true;
        }

        uint256 denom = uint256(preYesInv) + uint256(preNoInv);

        if (denom == 0) {
            uint256 half = amount >> 1;
            _addVaultFeesWithSnapshot(marketId, true, half, yesLP);
            unchecked {
                _addVaultFeesWithSnapshot(marketId, false, amount - half, noLP);
            }
            return true;
        }

        uint256 wYesBps = mulDiv(uint256(preNoInv), 10_000, denom);

        if (wYesBps < 4000) wYesBps = 4000; // 40% minimum
        if (wYesBps > 6000) wYesBps = 6000; // 60% maximum

        uint256 yesFee = mulDiv(amount, wYesBps, 10_000);
        _addVaultFeesWithSnapshot(marketId, true, yesFee, yesLP);

        unchecked {
            _addVaultFeesWithSnapshot(marketId, false, amount - yesFee, noLP);
        }

        return true;
    }

    /// @notice Distribute fees symmetrically using pre-trade snapshot
    /// @param marketId Market ID
    /// @param feeAmount Fees to distribute
    /// @param yesInv Pre-trade YES inventory
    /// @param noInv Pre-trade NO inventory
    /// @param pYes TWAP price in bps
    function _addVaultFeesSymmetricWithSnapshot(
        uint256 marketId,
        uint256 feeAmount,
        uint112 yesInv,
        uint112 noInv,
        uint256 pYes
    ) internal returns (bool distributed) {
        if (feeAmount == 0) return false;

        uint256 yesLP = totalYesVaultShares[marketId];
        uint256 noLP = totalNoVaultShares[marketId];

        if ((yesLP | noLP) == 0) return false;

        if (yesLP == 0) {
            _addVaultFeesWithSnapshot(marketId, false, feeAmount, noLP);
            return true;
        }
        if (noLP == 0) {
            _addVaultFeesWithSnapshot(marketId, true, feeAmount, yesLP);
            return true;
        }

        if (pYes == 0) {
            uint256 half = feeAmount >> 1;
            _addVaultFeesWithSnapshot(marketId, true, half, yesLP);
            unchecked {
                _addVaultFeesWithSnapshot(marketId, false, feeAmount - half, noLP);
            }
            return true;
        }

        if (pYes >= 10_000) pYes = 9_999;

        uint256 yesNotional;
        uint256 noNotional;
        uint256 denom;
        unchecked {
            yesNotional = uint256(yesInv) * pYes;
            noNotional = uint256(noInv) * (10_000 - pYes);
            denom = yesNotional + noNotional;
        }

        if (denom == 0) {
            uint256 half;
            unchecked {
                half = feeAmount >> 1;
            }
            _addVaultFeesWithSnapshot(marketId, true, half, yesLP);
            unchecked {
                _addVaultFeesWithSnapshot(marketId, false, feeAmount - half, noLP);
            }
            return true;
        }

        uint256 yesFee;
        unchecked {
            yesFee = mulDiv(feeAmount, yesNotional, denom);
        }
        _addVaultFeesWithSnapshot(marketId, true, yesFee, yesLP);
        unchecked {
            _addVaultFeesWithSnapshot(marketId, false, feeAmount - yesFee, noLP);
        }
        return true;
    }

    /// @notice Calculate dynamic spread based on inventory imbalance
    /// @dev Returns relative spread boosts that will be applied multiplicatively
    /// @param yesShares YES inventory
    /// @param noShares NO inventory
    /// @param buyYes True if buying YES
    /// @param close Market close time
    /// @return relativeSpreadBps Relative spread to apply (base + boosts)
    /// @return imbalanceBps Inventory imbalance in bps (for dynamic budget split)
    function _calculateDynamicSpread(uint256 yesShares, uint256 noShares, bool buyYes, uint64 close)
        internal
        view
        returns (uint256 relativeSpreadBps, uint256 imbalanceBps)
    {
        relativeSpreadBps = 100; // 1% base relative spread

        uint256 totalShares;
        assembly ("memory-safe") {
            totalShares := add(yesShares, noShares)
        }
        if (totalShares != 0) {
            bool yesScarce;
            bool consumingScarce;
            assembly ("memory-safe") {
                yesScarce := lt(yesShares, noShares)
                consumingScarce := or(
                    and(buyYes, yesScarce),
                    and(iszero(buyYes), iszero(yesScarce))
                )
            }

            if (consumingScarce) {
                assembly ("memory-safe") {
                    let larger :=
                        xor(yesShares, mul(xor(yesShares, noShares), gt(noShares, yesShares)))
                    imbalanceBps := div(mul(larger, 10000), totalShares)
                }

                uint256 midpoint = 5000; // 50% balance point
                if (imbalanceBps > midpoint) {
                    uint256 maxSpread = 400; // 4% max imbalance spread
                    assembly ("memory-safe") {
                        let excessImbalance := sub(imbalanceBps, midpoint)
                        let imbalanceBoost := div(mul(maxSpread, excessImbalance), midpoint)
                        relativeSpreadBps := add(relativeSpreadBps, imbalanceBoost)
                    }
                }
            }
        }

        assembly ("memory-safe") {
            if lt(timestamp(), close) {
                let timeToClose := sub(close, timestamp())

                if lt(timeToClose, 86400) {
                    let timeBoost := div(mul(200, sub(86400, timeToClose)), 86400) // 2% max time boost
                    relativeSpreadBps := add(relativeSpreadBps, timeBoost)
                }
            }

            if gt(relativeSpreadBps, MAX_SPREAD_BPS) {
                relativeSpreadBps := MAX_SPREAD_BPS
            }
        }

        return (relativeSpreadBps, imbalanceBps);
    }

    /// @notice Try vault OTC fill (supports partial)
    /// @param yesTwapBps TWAP price in bps
    /// @return sharesOut Shares filled (0 if none)
    /// @return collateralUsed Collateral consumed (0 if none)
    /// @return filled True if vault participated
    function _tryVaultOTCFill(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 yesTwapBps
    ) internal view returns (uint256 sharesOut, uint256 collateralUsed, bool filled) {
        if (collateralIn == 0 || collateralIn > MAX_COLLATERAL_IN) return (0, 0, false);

        if (yesTwapBps == 0) return (0, 0, false);

        uint64 close = _getClose(marketId);
        if (_isInCloseWindow(marketId, close)) return (0, 0, false);

        BootstrapVault memory vault = bootstrapVaults[marketId];
        uint256 availableShares = buyYes ? vault.yesShares : vault.noShares;
        if (availableShares == 0) return (0, 0, false);

        uint256 canonical = canonicalPoolId[marketId];
        if (canonical == 0) return (0, 0, false);

        {
            (bool ok, uint112 r0, uint112 r1,,,) = _staticPools(canonical);
            if (!ok || r0 == 0 || r1 == 0) return (0, 0, false);

            uint256 noId = _getNoId(marketId);
            uint256 deviation;

            assembly ("memory-safe") {
                let yesIsId0 := lt(marketId, noId)
                let yesRes := xor(r0, mul(xor(r0, r1), iszero(yesIsId0)))
                let noRes := xor(r1, mul(xor(r1, r0), iszero(yesIsId0)))

                let total := add(yesRes, noRes)
                let spotYesBps := div(mul(noRes, 10000), total)

                if iszero(spotYesBps) { spotYesBps := 1 }

                let diff := sub(spotYesBps, yesTwapBps)
                deviation := xor(
                    diff,
                    mul(xor(diff, sub(yesTwapBps, spotYesBps)), sgt(yesTwapBps, spotYesBps))
                )
            }

            if (deviation > 500) return (0, 0, false);
        }
        (uint256 relativeSpreadBps,) =
            _calculateDynamicSpread(vault.yesShares, vault.noShares, buyYes, close);

        assembly ("memory-safe") {
            let sharePriceBps :=
                xor(yesTwapBps, mul(xor(yesTwapBps, sub(10000, yesTwapBps)), iszero(buyYes)))

            // Hybrid spread: max(minAbsolute, fairPrice * relativeSpread / 10000)
            let relativeSpread := div(mul(sharePriceBps, relativeSpreadBps), 10000)
            let spreadBps := relativeSpread
            if lt(spreadBps, MIN_ABSOLUTE_SPREAD_BPS) {
                spreadBps := MIN_ABSOLUTE_SPREAD_BPS
            }

            let effectivePriceBps := add(sharePriceBps, spreadBps)
            if gt(effectivePriceBps, 10000) { effectivePriceBps := 10000 }

            let rawShares := div(mul(collateralIn, 10000), effectivePriceBps)

            let maxSharesFromVault := div(mul(availableShares, 3000), 10000) // 30% max vault depletion

            sharesOut := rawShares
            if gt(sharesOut, maxSharesFromVault) { sharesOut := maxSharesFromVault }
            if gt(sharesOut, availableShares) { sharesOut := availableShares }

            collateralUsed := collateralIn
            if iszero(eq(sharesOut, rawShares)) {
                collateralUsed := div(add(mul(sharesOut, effectivePriceBps), 9999), 10000)
            }

            filled := gt(sharesOut, 0)
        }

        return (sharesOut, collateralUsed, filled);
    }
}

function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z) {
    assembly ("memory-safe") {
        z := mul(x, y)
        if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
            mstore(0x00, 0x05832717) // ComputationError(0) = MulDivFailed
            mstore(0x20, 0)
            revert(0x1c, 0x24)
        }
        z := div(z, d)
    }
}

function fullMulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z) {
    assembly ("memory-safe") {
        z := mul(x, y)
        for {} 1 {} {
            if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                let mm := mulmod(x, y, not(0))
                let p1 := sub(mm, add(z, lt(mm, z)))
                let r := mulmod(x, y, d)
                let t := and(d, sub(0, d))
                if iszero(gt(d, p1)) {
                    mstore(0x00, 0x05832717) // ComputationError(1) = FullMulDivFailed
                    mstore(0x20, 1)
                    revert(0x1c, 0x24)
                }
                d := div(d, t)
                let inv := xor(2, mul(3, d))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                z := mul(
                    or(mul(sub(p1, gt(r, z)), add(div(sub(0, t), t), 1)), div(sub(z, r), t)),
                    mul(sub(2, mul(d, inv)), inv)
                )
                break
            }
            z := div(z, d)
            break
        }
    }
}

/// @dev Sets max approval once if allowance <= uint128.max
function ensureApproval(address token, address spender) {
    assembly ("memory-safe") {
        mstore(0x00, 0xdd62ed3e000000000000000000000000)
        mstore(0x14, address())
        mstore(0x34, spender)
        let success := staticcall(gas(), token, 0x10, 0x44, 0x00, 0x20)

        let needsApproval := 1
        if and(success, eq(returndatasize(), 32)) {
            if gt(mload(0x00), 0xffffffffffffffffffffffffffffffff) {
                needsApproval := 0
            }
        }

        if needsApproval {
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

function safeTransferETH(address to, uint256 amount) {
    assembly ("memory-safe") {
        if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
            mstore(0x00, 0x2929f974) // TransferError(2) = ETHTransferFailed
            mstore(0x20, 2)
            revert(0x1c, 0x24)
        }
    }
}

function safeTransfer(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0xa9059cbb000000000000000000000000) // transfer(address,uint256)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x2929f974) // TransferError(0) = TransferFailed
                mstore(0x20, 0)
                revert(0x1c, 0x24)
            }
        }
        mstore(0x34, 0)
    }
}

function safeTransferFrom(address token, address from, address to, uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x60, amount)
        mstore(0x40, to)
        mstore(0x2c, shl(96, from))
        mstore(0x0c, 0x23b872dd000000000000000000000000) // transferFrom(address,address,uint256)
        let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x2929f974) // TransferError(1) = TransferFromFailed
                mstore(0x20, 1)
                revert(0x1c, 0x24)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}
