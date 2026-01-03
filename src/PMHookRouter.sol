// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IPMRouter {
    function getActiveOrders(uint256 marketId, bool isYes, bool isBuy, uint256 limit)
        external
        view
        returns (bytes32[] memory orderHashes);

    function fillOrdersThenSwap(
        uint256 marketId,
        bool isYes,
        bool isBuy,
        uint256 totalAmount,
        uint256 minOutput,
        bytes32[] calldata orderHashes,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 totalOutput);

    function buy(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 sharesOut);
}

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

/// @title PMHookRouter - Prediction Market Router with Bootstrap Vaults
/// @notice Routing layer for hooked prediction markets with automated vault market making
/// @dev Execution waterfall: orderbook+AMM => vault OTC => vault mint => AMM fallback
///      Vault LPs earn principal (fair value) + spread fees from OTC fills (CL-style directional).
///      For non-hooked markets, use PMRouter directly.
///      Dynamic spreads on vault fills complement PMFeeHook's AMM fees to protect LPs
///      during imbalanced markets while encouraging rebalancing trades
/// @dev ONLY supports markets created via bootstrapMarket(). External markets cannot be registered.
contract PMHookRouter {
    address constant ETH = address(0);

    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;

    // Transient storage slots (EIP-1153)
    uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268;

    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IPMRouter constant PM_ROUTER = IPMRouter(0x000000000055fF709f26efB262fba8B0AE8c35Dc);
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, 0xab143c06) // `Reentrancy()`
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_SLOT, address())
        }
        _;
        assembly ("memory-safe") {
            tstore(REENTRANCY_SLOT, 0)
        }
    }

    // ============ Helper Functions ============

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
                    mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
                    revert(0x1c, 0x04)
                }
            }
        }
    }

    function _distributeFeesSplit(
        uint256 marketId,
        uint256 feeAmount,
        uint112 preYes,
        uint112 preNo,
        uint256 twap
    ) internal {
        uint256 toLPs;
        uint256 toRebalance;
        assembly ("memory-safe") {
            toLPs := div(mul(feeAmount, LP_FEE_SPLIT_BPS), 10000)
            toRebalance := sub(feeAmount, toLPs)
        }
        if (!_addVaultFeesSymmetricWithSnapshot(marketId, toLPs, preYes, preNo, twap)) {
            if (toLPs != 0) {
                unchecked {
                    rebalanceCollateralBudget[marketId] += toLPs;
                }
            }
        }
        unchecked {
            rebalanceCollateralBudget[marketId] += toRebalance;
        }
    }

    /// @notice Account for vault OTC proceeds by splitting principal from spread/fee
    /// @dev Implements concentrated-liquidity-style accounting: principal goes to inventory sellers,
    ///      spread is split between LPs and rebalance budget (80/20)
    /// @param marketId The market ID
    /// @param buyYes Whether user is buying YES (true) or NO (false)
    /// @param sharesOut Number of shares sold by vault
    /// @param collateralUsed Total collateral paid by user (principal + spread)
    /// @param pYes TWAP yes probability in basis points [1..9999]
    /// @return principal Fair value portion at TWAP (100% to seller-side LPs)
    /// @return spreadFee Spread portion above TWAP (80% to seller-side LPs, 20% to rebalance budget)
    function _accountVaultOTCProceeds(
        uint256 marketId,
        bool buyYes,
        uint256 sharesOut,
        uint256 collateralUsed,
        uint256 pYes
    ) internal returns (uint256 principal, uint256 spreadFee) {
        // 1) Compute fair principal at TWAP (ceil to favor LPs)
        uint256 fairBps = buyYes ? pYes : (10_000 - pYes);
        principal = (sharesOut * fairBps + 9_999) / 10_000; // ceil division

        // collateralUsed is priced at (fair + spread), so must be >= principal
        // If not, pricing math is broken - hard fail to prevent crediting more than received
        assembly ("memory-safe") {
            if lt(collateralUsed, principal) {
                mstore(0x00, 0x35278d12) // Overflow()
                revert(0x1c, 0x04)
            }
        }
        spreadFee = collateralUsed - principal;

        // 2) Principal always goes to the side that sold inventory
        // When buying YES, YES vault sold inventory -> credit YES LPs
        // When buying NO, NO vault sold inventory -> credit NO LPs
        uint256 sellerLP = buyYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];

        _addVaultFeesWithSnapshot(marketId, buyYes, principal, sellerLP);

        // 3) Spread is the "fee" bucket: split between LPs and rebalance budget
        if (spreadFee != 0) {
            uint256 toLPs = (spreadFee * LP_FEE_SPLIT_BPS) / 10_000;
            uint256 toBudget = spreadFee - toLPs;

            // Option B: Symmetric distribution - spread goes to BOTH sides (like _distributeFeesBothSides)
            // This prevents liquidity from concentrating on one side
            if (_distributeFeesBothSides(marketId, toLPs)) {
                // Fees distributed
            } else {
                // No LPs exist - shouldn't happen since sellerLP > 0, but handle gracefully
                _addVaultFeesWithSnapshot(marketId, buyYes, toLPs, sellerLP);
            }

            if (toBudget != 0) {
                unchecked {
                    rebalanceCollateralBudget[marketId] += toBudget;
                }
            }
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

        // Prevent deposits when vault shares exist but assets are depleted (zombie state)
        // Existing LPs must withdraw first to clear their shares before new deposits allowed
        assembly ("memory-safe") {
            // VaultDepleted check: totalVaultShares != 0 && totalAssets == 0
            if and(iszero(iszero(totalVaultShares)), iszero(totalAssets)) {
                mstore(0x00, 0x5d4fbdf4) // VaultDepleted()
                revert(0x1c, 0x04)
            }
            // SharesOverflow check: shares > type(uint112).max
            if gt(shares, 0xffffffffffffffffffffffffffff) {
                mstore(0x00, 0xf4c64125) // SharesOverflow()
                revert(0x1c, 0x04)
            }
        }

        if ((totalVaultShares | totalAssets) == 0) {
            vaultSharesMinted = shares;
        } else {
            vaultSharesMinted = fullMulDiv(shares, totalVaultShares, totalAssets);
        }

        assembly ("memory-safe") {
            // ZeroVaultShares check
            if iszero(vaultSharesMinted) {
                mstore(0x00, 0x50df4b3c) // ZeroVaultShares()
                revert(0x1c, 0x04)
            }
            // VaultSharesOverflow check
            if gt(vaultSharesMinted, 0xffffffffffffffffffffffffffff) {
                mstore(0x00, 0x03ba4fc2) // VaultSharesOverflow()
                revert(0x1c, 0x04)
            }
        }

        UserVaultPosition storage position = vaultPositions[marketId][receiver];

        if (isYes) {
            // Check vault.yesShares won't overflow
            assembly ("memory-safe") {
                if gt(
                    add(shr(0, and(sload(vault.slot), 0xffffffffffffffffffffffffffff)), shares),
                    0xffffffffffffffffffffffffffff
                ) {
                    mstore(0x00, 0xf4c64125) // SharesOverflow()
                    revert(0x1c, 0x04)
                }
            }
            // Check position.yesVaultShares won't overflow
            if (uint256(position.yesVaultShares) + vaultSharesMinted > type(uint112).max) {
                revert VaultSharesOverflow();
            }

            unchecked {
                vault.yesShares += uint112(shares);
                totalYesVaultShares[marketId] += vaultSharesMinted;
                position.yesVaultShares += uint112(vaultSharesMinted);
                position.yesRewardDebt += mulDiv(
                    vaultSharesMinted, accYesCollateralPerShare[marketId], 1e18
                );
            }
        } else {
            // Check vault.noShares won't overflow
            assembly ("memory-safe") {
                if gt(
                    add(and(shr(112, sload(vault.slot)), 0xffffffffffffffffffffffffffff), shares),
                    0xffffffffffffffffffffffffffff
                ) {
                    mstore(0x00, 0xf4c64125) // SharesOverflow()
                    revert(0x1c, 0x04)
                }
            }
            // Check position.noVaultShares won't overflow
            if (uint256(position.noVaultShares) + vaultSharesMinted > type(uint112).max) {
                revert VaultSharesOverflow();
            }

            unchecked {
                vault.noShares += uint112(shares);
                totalNoVaultShares[marketId] += vaultSharesMinted;
                position.noVaultShares += uint112(vaultSharesMinted);
                position.noRewardDebt += mulDiv(
                    vaultSharesMinted, accNoCollateralPerShare[marketId], 1e18
                );
            }
        }
    }

    // ============ Bootstrap Vault Storage ============

    struct BootstrapVault {
        uint112 yesShares;
        uint112 noShares;
        uint32 lastActivity;
    }

    // Uses poolId != 0 as "registered" sentinel (keccak256 collision with 0 is infeasible)
    mapping(uint256 => uint256) public canonicalPoolId;
    mapping(uint256 => uint256) public canonicalFeeOrHook;
    mapping(uint256 => BootstrapVault) public bootstrapVaults;
    mapping(uint256 => uint256) public rebalanceCollateralBudget;

    // ============ TWAP Tracking ============
    // Sliding window TWAP using ZAMM's pool-maintained cumulatives (Uniswap V2 oracle pattern)
    //
    // ARCHITECTURE:
    // - Stores TWO observations per market (obs0 = older, obs1 = newer)
    // - TWAP window is ALWAYS >= MIN_TWAP_UPDATE_INTERVAL (30 minutes) to prevent manipulation
    // - NO/YES ratio averaged over sliding window, converted to probability in basis points
    // - Works for all trades (even those bypassing this router - reads directly from ZAMM pool state)
    //
    // UPDATE MECHANISMS:
    // 1. Permissionless: Anyone can call updateTWAPObservation() after 30 minutes
    // 2. Opportunistic: Trading/rebalancing automatically updates TWAP when eligible (via _tryUpdateTWAP)
    //
    // BOOTSTRAP DELAY (CRITICAL SECURITY FEATURE):
    // - Initialized at market creation with both observations set to pool creation time
    // - For first 30 minutes: TWAP returns 0, disabling vault OTC fills and rebalancing
    // - This prevents manipulation during critical bootstrap phase when liquidity is thin
    // - After 30 min: TWAP auto-activates, vault functionality enabled (no manual update required)
    // - During delay: Mint path and AMM path remain fully functional
    //
    // STALENESS BEHAVIOR (IMPORTANT FOR INFREQUENT MARKETS):
    // - "Stale TWAP" (not updated recently) is STILL VALID and provides manipulation resistance
    // - If obs1 is old (e.g., updated 6 hours ago), _getTWAPPrice uses 6-hour window (obs1 -> current)
    // - Longer windows are MORE resistant to manipulation, not less
    // - Vault OTC and rebalancing continue working with stale TWAP - no 30-minute timeout
    // - The 30-minute protection ONLY applies immediately after updates to prevent short-window attacks
    //
    // EXAMPLE TIMELINE (Infrequent Market):
    // t=0: Market created, TWAP initialized (both obs at t=0)
    // t=0 to t=30min: TWAP returns 0 => vault OTC disabled, mint/AMM work
    // t=30min+: TWAP auto-activates, uses obs1=>current window (starts at 30min, grows over time)
    // t=35min: Optional: Trade may trigger opportunistic update => obs0=t0, obs1=t35min (keeps TWAP fresh)
    // t=36min to t=infinity: TWAP valid using obs1=>current window (grows from 1min to hours/days if not updated)
    // - If no trades for 7 days, next trade uses 7-day TWAP (extremely manipulation-resistant)
    // - Vault OTC and rebalancing remain functional throughout (updates improve freshness but not required)
    //
    // MANIPULATION RESISTANCE:
    // - If obs1 is too recent (< 30 min old), _getTWAPPrice uses obs0->obs1 window instead of obs1->current
    // - This prevents attackers from: update TWAP => wait 1 block => manipulate pool => use nearly-spot TWAP
    // - After 30 min, uses obs1=>current which provides increasingly strong manipulation resistance as time passes
    // - Spot-vs-TWAP deviation checks (MAX_REBALANCE_DEVIATION_BPS) provide additional protection

    struct TWAPObservations {
        uint32 timestamp0; // Older checkpoint (4 bytes) \
        uint32 timestamp1; // Newer checkpoint (4 bytes)  |-- packed in slot 0
        uint192 _unused; // Padding (24 bytes)         /
        uint256 cumulative0; // ZAMM's cumulative at timestamp0 (slot 1: 32 bytes)
        uint256 cumulative1; // ZAMM's cumulative at timestamp1 (slot 2: 32 bytes)
    }

    mapping(uint256 => TWAPObservations) public twapObservations;

    // TWAP Security Parameters
    uint32 constant MIN_TWAP_UPDATE_INTERVAL = 30 minutes; // Minimum TWAP window - prevents short-window manipulation
    uint16 constant MAX_REBALANCE_DEVIATION_BPS = 500; // 5% max spot-TWAP deviation - prevents pool manipulation

    // ============ Vault LP Accounting ============
    // - Vault OTC principal: 100% to seller-side LPs (CL-style directional accounting)
    // - Vault OTC spread: 80% to seller-side LPs, 20% to rebalance budget
    // - ERC4626-style share accounting with reward debt pattern
    // - Solvency invariant: balance >= rebalanceCollateralBudget + LP_claimable_fees
    // - All vault shares are user-owned (no protocol-owned shares)

    struct UserVaultPosition {
        uint112 yesVaultShares;
        uint112 noVaultShares;
        uint256 yesRewardDebt;
        uint256 noRewardDebt;
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

    // Vault Economic Parameters
    uint256 constant BOOTSTRAP_WINDOW = 2 days; // Min time before close to allow mint path
    uint16 constant MAX_VAULT_FILL_BPS = 3000; // 30% max vault depletion per trade
    uint16 constant MIN_TWAP_SPREAD_BPS = 100; // 1% base spread for LP protection
    uint16 constant MAX_IMBALANCE_SPREAD_BPS = 400; // 4% max spread from imbalance alone
    uint16 constant MAX_TIME_BOOST_BPS = 200; // 2% max boost from time pressure alone
    uint16 constant MAX_SPREAD_BPS = 500; // 5% overall spread cap (prevents excessive spreads)
    uint16 constant IMBALANCE_MIDPOINT_BPS = 5000; // 50% balance point (threshold & range for imbalance spread calculation)
    uint16 constant DEFAULT_FEE_BPS = 30; // 0.3% fallback AMM fee
    // Note: Vault close window is dynamically queried from hook via _getCloseWindow() (fallback: 1 hour)
    uint16 constant LP_FEE_SPLIT_BPS = 8000; // 80% to LPs, 20% to rebalance budget
    uint16 constant REBALANCE_SWAP_SLIPPAGE_BPS = 75; // 0.75% tight tolerance (spot-TWAP deviation already checked at 3%)
    uint16 constant VAULT_MINT_MAX_IMBALANCE_RATIO = 2; // Max 2x imbalance allowed for mint path

    // Overflow protection: prevent collateralIn * 10_000 from overflowing uint256
    uint256 constant MAX_COLLATERAL_IN = type(uint256).max / 10_000;

    // Overflow protection for reward accumulators: prevent mulDiv(shares, accPerShare, 1e18) overflow
    // Max safe accumulator: type(uint256).max / type(uint112).max ~= 2^144 / 1e18 ~= 2.2e25
    // This bound ensures reward debt calculations never overflow even with max vault shares
    uint256 constant MAX_ACC_PER_SHARE = type(uint256).max / type(uint112).max;

    error Expired();
    error TooSoon();
    error Overflow();
    error Slippage();
    error AmountZero();
    error Reentrancy();
    error ZeroShares();
    error NotResolver();
    error MarketClosed();
    error MulDivFailed();
    error PoolNotReady();
    error TWAPRequired();
    error NoVaultShares();
    error VaultDepleted();
    error ApproveFailed();
    error MarketResolved();
    error SharesOverflow();
    error TransferFailed();
    error TWAPInitFailed();
    error MarketNotClosed();
    error SlippageTooHigh();
    error ZeroVaultShares();
    error FullMulDivFailed();
    error InvalidETHAmount();
    error InvalidCloseTime();
    error NonCanonicalPool();
    error ETHTransferFailed();
    error HookInvalidPoolId();
    error MarketNotResolved();
    error InsufficientOutput();
    error InsufficientShares();
    error TransferFromFailed();
    error CirculatingLPsExist();
    error MarketNotRegistered();
    error SpotDeviantFromTWAP();
    error VaultSharesOverflow();
    error SharesReturnedOverflow();
    error InsufficientVaultShares();
    error MarketAlreadyRegistered();

    constructor() payable {
        PAMM.setOperator(address(ZAMM), true);
        PAMM.setOperator(address(PAMM), true);
    }

    receive() external payable {}

    // ============ Multicall ============

    function multicall(bytes[] calldata data) public returns (bytes[] memory results) {
        uint256 len = data.length;
        results = new bytes[](len);
        for (uint256 i; i != len; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
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
            if iszero(call(gas(), token, 0, m, 0xe4, 0x00, 0x00)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
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
            if iszero(call(gas(), token, 0, m, 0x104, 0x00, 0x00)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    // ============ Hook Integration ============

    function _hookFeeOrHook(address hook) internal pure returns (uint256) {
        return uint256(uint160(hook)) | FLAG_BEFORE | FLAG_AFTER;
    }

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
        // Prevent re-registration to protect vault pricing and rebalance invariants
        if (canonicalPoolId[marketId] != 0) revert MarketAlreadyRegistered();

        poolId = IPMFeeHook(hook).registerMarket(marketId);
        feeOrHook = _hookFeeOrHook(hook);

        uint256 yesId = marketId;
        uint256 noId = PAMM.getNoId(marketId);
        (IZAMM.PoolKey memory k,) = _buildKey(yesId, noId, feeOrHook);
        uint256 derivedPoolId =
            uint256(keccak256(abi.encode(k.id0, k.id1, k.token0, k.token1, k.feeOrHook)));
        if (poolId != derivedPoolId) revert HookInvalidPoolId();

        canonicalPoolId[marketId] = poolId;
        canonicalFeeOrHook[marketId] = feeOrHook;
    }

    /// @notice Bootstrap complete market in one transaction
    /// @dev IMPORTANT: Vault OTC fills and rebalancing are DISABLED for first 30 minutes after creation
    /// @dev This bootstrap delay prevents manipulation during thin liquidity phase. Mint and AMM paths work immediately.
    /// @dev After 30 minutes, TWAP auto-activates and vault functionality becomes available (no manual call required)
    /// @param collateralForLP Liquidity for 50/50 AMM pool. Can be as low as ~$100 for demos. Larger pools support larger trades.
    /// @param collateralForBuy Optional initial trade to cross pool (recommended for immediate TWAP quality, not required)
    /// @dev Hook's 12% price impact limit scales with pool size: $100 pool->~$10 max trade, $1k pool->~$100 max trade
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
        nonReentrant
        returns (uint256 marketId, uint256 poolId, uint256 lpShares, uint256 sharesOut)
    {
        assembly ("memory-safe") {
            if gt(timestamp(), deadline) {
                mstore(0x00, 0x203d82d8) // Expired()
                revert(0x1c, 0x04)
            }
            if iszero(gt(close, timestamp())) {
                mstore(0x00, 0xd9bb344d) // InvalidCloseTime()
                revert(0x1c, 0x04)
            }
            if iszero(collateralForLP) {
                mstore(0x00, 0x1f2a2005) // AmountZero()
                revert(0x1c, 0x04)
            }
        }

        // Note: No minimum liquidity enforced - allows demo markets from ~$100+
        // Recommendation: For production markets with rebalancing/OTC, use ≥$500-1000
        // Small pools work but have higher slippage and price impact sensitivity

        if (to == address(0)) {
            to = msg.sender;
        }

        uint256 totalCollateral = collateralForLP + collateralForBuy;

        if (collateral == ETH) {
            if (msg.value < totalCollateral) revert InvalidETHAmount();
        } else {
            if (msg.value != 0) revert InvalidETHAmount(); // Don't accept ETH for ERC20 markets
            if (totalCollateral != 0) {
                safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
                ensureApproval(collateral, address(PAMM));
            }
        }

        (marketId,) = PAMM.createMarket(description, resolver, collateral, close, canClose);

        (poolId,) = _registerMarket(hook, marketId);

        if (collateralForLP != 0) {
            if (collateral == ETH) {
                PAMM.split{value: collateralForLP}(marketId, collateralForLP, address(this));
            } else {
                PAMM.split(marketId, collateralForLP, address(this));
            }

            uint256 yesId = marketId;
            uint256 noId = PAMM.getNoId(marketId);

            ZAMM.deposit(address(PAMM), yesId, collateralForLP);
            ZAMM.deposit(address(PAMM), noId, collateralForLP);

            (IZAMM.PoolKey memory k,) = _buildKey(yesId, noId, _hookFeeOrHook(hook));

            // Pool initialization: mins=0 is safe (no existing price to exploit, we're setting initial 50/50 ratio)
            (,, lpShares) =
                ZAMM.addLiquidity(k, collateralForLP, collateralForLP, 0, 0, to, deadline);

            ZAMM.recoverTransientBalance(address(PAMM), yesId, to);
            ZAMM.recoverTransientBalance(address(PAMM), noId, to);

            // Initialize TWAP observations after adding liquidity (prevents manipulation)
            // REQUIRED - revert if TWAP cannot be initialized
            (uint256 initialCumulative, bool success) = _getCurrentCumulative(marketId);
            if (!success) revert TWAPInitFailed();

            // Initialize both observations at pool creation (both identical at t=0)
            // Note: TWAP becomes meaningful after time passes OR collateralForBuy crosses pool
            twapObservations[marketId] = TWAPObservations({
                timestamp0: uint32(block.timestamp),
                timestamp1: uint32(block.timestamp),
                _unused: 0,
                cumulative0: initialCumulative,
                cumulative1: initialCumulative
            });
        }

        // Optional: Cross pool for immediate TWAP differentiation (helps vault OTC pricing)
        if (collateralForBuy != 0) {
            sharesOut = _bootstrapBuy(
                marketId,
                hook,
                collateral,
                collateralForLP,
                buyYes,
                collateralForBuy,
                minSharesOut,
                to,
                deadline
            );
        }

        _refundExcessETH(collateral, totalCollateral);
    }

    function _bootstrapBuy(
        uint256 marketId,
        address hook,
        address collateral,
        uint256 collateralForLP,
        bool buyYes,
        uint256 collateralForBuy,
        uint256 minSharesOut,
        address to,
        uint256 deadline
    ) internal returns (uint256 sharesOut) {
        // Cache token IDs
        uint256 yesId = marketId;
        uint256 noId = PAMM.getNoId(marketId);

        if (collateral == ETH) {
            PAMM.split{value: collateralForBuy}(marketId, collateralForBuy, address(this));
        } else {
            PAMM.split(marketId, collateralForBuy, address(this));
        }

        if (collateralForLP != 0) {
            uint256 swapTokenId = buyYes ? noId : yesId;
            uint256 desiredTokenId = buyYes ? yesId : noId;

            ZAMM.deposit(address(PAMM), swapTokenId, collateralForBuy);

            (IZAMM.PoolKey memory k, bool yesIsId0) = _buildKey(yesId, noId, _hookFeeOrHook(hook));
            bool zeroForOne = buyYes ? !yesIsId0 : yesIsId0;

            uint256 swappedShares =
                ZAMM.swapExactIn(k, collateralForBuy, 0, zeroForOne, address(this), deadline);

            sharesOut = collateralForBuy + swappedShares;
            if (sharesOut < minSharesOut) revert InsufficientOutput();
            PAMM.transfer(to, desiredTokenId, sharesOut);
        } else {
            uint256 desiredTokenId = buyYes ? yesId : noId;
            sharesOut = collateralForBuy;
            PAMM.transfer(to, desiredTokenId, sharesOut);

            // Credit opposite side to vault for buyer (earn LP fees instead of donating to protocol)
            uint256 vaultSharesMinted = _depositToVaultSide(marketId, !buyYes, collateralForBuy, to);

            bootstrapVaults[marketId].lastActivity = uint32(block.timestamp);

            emit VaultDeposit(marketId, to, !buyYes, collateralForBuy, vaultSharesMinted);
        }
    }

    // ============ buyWithBootstrap (Main Entry Point) ============

    /// @notice Buy shares with multi-venue routing: vault OTC -> mint -> orderbook -> AMM
    /// @dev Supports partial fills across multiple venues for best execution
    /// @dev Execution flow:
    /// @dev 1. Vault OTC: Fill up to MAX_VAULT_FILL_BPS from bootstrap vault at TWAP + dynamic spread
    /// @dev 2. Mint: Use remaining collateral to mint shares + deposit opposite side to vault (if conditions met)
    /// @dev 3. Orderbook + AMM: Route remainder through PM_ROUTER.fillOrdersThenSwap (orderbook -> AMM)
    /// @dev
    /// @dev TWAP dependency: Vault OTC requires valid TWAP (auto-activates 30min after bootstrap)
    /// @dev Opportunistic TWAP update: Automatically updates TWAP when eligible before routing
    /// @dev Multi-venue slippage: minSharesOut applies to total output across all venues
    /// @param marketId The market ID to buy from
    /// @param buyYes True to buy YES shares, false for NO shares
    /// @param collateralIn Total collateral to spend
    /// @param minSharesOut Minimum shares to receive (slippage check across all venues)
    /// @param to Recipient of shares
    /// @param deadline Transaction deadline
    /// @return sharesOut Total shares acquired across all venues
    /// @return source Primary venue used ("otc", "mint", "book", "mult")
    /// @return vaultSharesMinted Vault shares minted if mint path was used
    function buyWithBootstrap(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        address to,
        uint256 deadline
    )
        public
        payable
        nonReentrant
        returns (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted)
    {
        {
            (, bool resolved,,, uint64 close,,) = PAMM.markets(marketId);
            assembly ("memory-safe") {
                // MarketResolved check
                if resolved {
                    mstore(0x00, 0x7fb7503e) // MarketResolved()
                    revert(0x1c, 0x04)
                }
                // MarketClosed check
                if iszero(lt(timestamp(), close)) {
                    mstore(0x00, 0xaa90c61a) // MarketClosed()
                    revert(0x1c, 0x04)
                }
            }
        }
        assembly ("memory-safe") {
            // Expired check
            if gt(timestamp(), deadline) {
                mstore(0x00, 0x203d82d8) // Expired()
                revert(0x1c, 0x04)
            }
            // AmountZero check
            if iszero(collateralIn) {
                mstore(0x00, 0x1f2a2005) // AmountZero()
                revert(0x1c, 0x04)
            }
        }
        if (collateralIn > MAX_COLLATERAL_IN) revert Overflow();
        if (to == address(0)) to = msg.sender;

        // Load canonical feeOrHook for this market
        uint256 feeOrHook = canonicalFeeOrHook[marketId];

        // Ensure market was registered via bootstrapMarket()
        uint256 canonical = canonicalPoolId[marketId];
        assembly ("memory-safe") {
            if iszero(canonical) {
                mstore(0x00, 0x99e120bc) // MarketNotRegistered()
                revert(0x1c, 0x04)
            }
        }

        // Opportunistically update TWAP to keep it fresh (non-reverting)
        // This enables vault OTC fills and improves overall system responsiveness
        _tryUpdateTWAP(marketId);

        // Cache external calls for gas savings
        uint256 noId = PAMM.getNoId(marketId);
        (,,,,, address collateral,) = PAMM.markets(marketId);

        if (collateral == ETH) {
            if (msg.value < collateralIn) revert InvalidETHAmount();
        } else {
            if (msg.value != 0) revert InvalidETHAmount(); // Don't accept ETH for ERC20 markets
            safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
        }

        // Track remaining collateral and total output across venues
        uint256 remainingCollateral = collateralIn;
        uint256 totalSharesOut;
        uint8 venueCount; // Track how many venues were used

        BootstrapVault storage vault = bootstrapVaults[marketId];

        // === VENUE 1: Vault OTC (partial fill supported) ===
        (uint256 otcShares, uint256 otcCollateralUsed, bool otcFillable) =
            _tryVaultOTCFill(marketId, buyYes, remainingCollateral);

        if (otcFillable && otcShares > 0) {
            uint256 pYes = _getTWAPPrice(marketId);

            unchecked {
                if (buyYes) {
                    vault.yesShares -= uint112(otcShares);
                    PAMM.transfer(to, marketId, otcShares);
                } else {
                    vault.noShares -= uint112(otcShares);
                    PAMM.transfer(to, noId, otcShares);
                }
            }

            // Account for OTC proceeds: split principal (fair value) from spread (fee)
            (uint256 principal, uint256 spreadFee) =
                _accountVaultOTCProceeds(marketId, buyYes, otcShares, otcCollateralUsed, pYes);
            vault.lastActivity = uint32(block.timestamp);

            unchecked {
                uint256 effectivePriceBps = (otcCollateralUsed * 10_000) / otcShares; // Safe: multiplication bounded, otcShares != 0
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

                totalSharesOut += otcShares;
                remainingCollateral -= otcCollateralUsed;
                venueCount++;
            }
            source = bytes4("otc");
        }

        // === VENUE 2: Mint Path (partial fill supported) ===
        if (remainingCollateral > 0 && _shouldUseVaultMint(marketId, vault, buyYes)) {
            // Check if opposite side is in zombie state before attempting mint
            uint256 oppositeVaultShares =
                !buyYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];
            uint256 oppositeAssets = !buyYes ? vault.yesShares : vault.noShares;

            // If zombie state, skip mint path and fall through to orderbook/AMM
            if (oppositeVaultShares == 0 || oppositeAssets != 0) {
                if (collateral == ETH) {
                    PAMM.split{value: remainingCollateral}(
                        marketId, remainingCollateral, address(this)
                    );
                } else {
                    ensureApproval(collateral, address(PAMM));
                    PAMM.split(marketId, remainingCollateral, address(this));
                }

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
                    venueCount++;
                }
                if (source == bytes4(0)) source = bytes4("mint");
            }
        }

        // === VENUE 3: Orderbook + AMM (PM_ROUTER.fillOrdersThenSwap handles partial fills internally) ===
        if (remainingCollateral > 0) {
            if (collateral != ETH) {
                ensureApproval(collateral, address(PM_ROUTER));
            }

            // Track balance before router call for both ETH and ERC20 (to detect partial spends)
            uint256 balanceBefore =
                collateral == ETH ? address(this).balance : getBalance(collateral, address(this));

            // Get active orders for this market
            bytes32[] memory orderHashes;
            try PM_ROUTER.getActiveOrders(marketId, buyYes, false, 10) returns (
                bytes32[] memory _orderHashes
            ) {
                orderHashes = _orderHashes;
            } catch {
                orderHashes = new bytes32[](0);
            }

            try PM_ROUTER.fillOrdersThenSwap{value: collateral == ETH ? remainingCollateral : 0}(
                marketId,
                buyYes,
                true, // isBuy=true (taker is buyer)
                remainingCollateral,
                0, // No intermediate slippage check - we check total at the end
                orderHashes,
                feeOrHook,
                to,
                deadline
            ) returns (
                uint256 routerShares
            ) {
                unchecked {
                    totalSharesOut += routerShares;
                    venueCount++;
                    if (source == bytes4(0)) {
                        source = orderHashes.length > 0 ? bytes4("book") : bytes4("amm");
                    }

                    // Track actual spent via balance delta for both ETH and ERC20
                    // This handles cases where PM_ROUTER doesn't consume full amount or refunds
                    uint256 balanceAfter = collateral == ETH
                        ? address(this).balance
                        : getBalance(collateral, address(this));
                    uint256 actualSpent =
                        balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
                    if (actualSpent > remainingCollateral) actualSpent = remainingCollateral;
                    remainingCollateral -= actualSpent;
                }
            } catch (bytes memory err) {
                // If we already got some shares from other venues, don't revert
                // But we need to keep remainingCollateral for refund
                if (totalSharesOut == 0) {
                    // Bubble original error for better debugging
                    assembly ("memory-safe") {
                        revert(add(err, 0x20), mload(err))
                    }
                }
                // If router failed but we got shares from other venues,
                // remainingCollateral is still accurate and will be refunded
            }
        }

        assembly ("memory-safe") {
            // Final slippage check across all venues
            if lt(totalSharesOut, minSharesOut) {
                mstore(0x00, 0x3d93e699) // Slippage()
                revert(0x1c, 0x04)
            }
        }

        // If multiple venues were used, mark as "mult"
        if (venueCount > 1) source = bytes4("mult");

        // Refund any unused collateral
        if (remainingCollateral > 0) {
            if (collateral == ETH) {
                safeTransferETH(msg.sender, remainingCollateral);
            } else {
                safeTransfer(collateral, msg.sender, remainingCollateral);
            }
        }

        // Refund excess ETH if user sent more than collateralIn
        if (collateral == ETH && msg.value > collateralIn) {
            unchecked {
                safeTransferETH(msg.sender, msg.value - collateralIn);
            }
        }

        return (totalSharesOut, source, vaultSharesMinted);
    }

    // ============ Vault LP Functions ============

    function depositToVault(
        uint256 marketId,
        bool isYes,
        uint256 shares,
        address receiver,
        uint256 deadline
    ) public nonReentrant returns (uint256 vaultSharesMinted) {
        {
            (, bool resolved,,, uint64 close,,) = PAMM.markets(marketId);
            assembly ("memory-safe") {
                if resolved {
                    mstore(0x00, 0x7fb7503e) // MarketResolved()
                    revert(0x1c, 0x04)
                }
                if iszero(lt(timestamp(), close)) {
                    mstore(0x00, 0xaa90c61a) // MarketClosed()
                    revert(0x1c, 0x04)
                }
            }
        }
        assembly ("memory-safe") {
            if gt(timestamp(), deadline) {
                mstore(0x00, 0x203d82d8) // Expired()
                revert(0x1c, 0x04)
            }
        }
        assembly ("memory-safe") {
            if iszero(sload(add(canonicalPoolId.slot, marketId))) {
                mstore(0x00, 0x99e120bc) // MarketNotRegistered()
                revert(0x1c, 0x04)
            }
        }
        assembly ("memory-safe") {
            if iszero(shares) {
                mstore(0x00, 0xf7c09189) // ZeroShares()
                revert(0x1c, 0x04)
            }
            if gt(shares, 0xffffffffffffffffffffffffffff) {
                mstore(0x00, 0xf4c64125) // SharesOverflow()
                revert(0x1c, 0x04)
            }
        }
        if (receiver == address(0)) receiver = msg.sender;

        // Cache share ID calculation
        uint256 shareId = isYes ? marketId : PAMM.getNoId(marketId);

        PAMM.transferFrom(msg.sender, address(this), shareId, shares);

        vaultSharesMinted = _depositToVaultSide(marketId, isYes, shares, receiver);

        bootstrapVaults[marketId].lastActivity = uint32(block.timestamp);

        emit VaultDeposit(marketId, receiver, isYes, shares, vaultSharesMinted);
    }

    function withdrawFromVault(
        uint256 marketId,
        bool isYes,
        uint256 vaultSharesToRedeem,
        address receiver,
        uint256 deadline
    ) public nonReentrant returns (uint256 sharesReturned, uint256 feesEarned) {
        assembly ("memory-safe") {
            if gt(timestamp(), deadline) {
                mstore(0x00, 0x203d82d8) // Expired()
                revert(0x1c, 0x04)
            }
            if iszero(vaultSharesToRedeem) {
                mstore(0x00, 0x50df4b3c) // ZeroVaultShares()
                revert(0x1c, 0x04)
            }
        }
        assembly ("memory-safe") {
            if iszero(sload(add(canonicalPoolId.slot, marketId))) {
                mstore(0x00, 0x99e120bc) // MarketNotRegistered()
                revert(0x1c, 0x04)
            }
        }
        if (receiver == address(0)) receiver = msg.sender;

        UserVaultPosition storage position = vaultPositions[marketId][msg.sender];
        uint256 userVaultShares = isYes ? position.yesVaultShares : position.noVaultShares;
        assembly ("memory-safe") {
            if lt(userVaultShares, vaultSharesToRedeem) {
                mstore(0x00, 0xa9b5f4f9) // InsufficientVaultShares()
                revert(0x1c, 0x04)
            }
        }

        BootstrapVault storage vault = bootstrapVaults[marketId];
        uint256 totalVaultShares =
            isYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];
        assembly ("memory-safe") {
            if iszero(totalVaultShares) {
                mstore(0x00, 0x21e3da89) // NoVaultShares()
                revert(0x1c, 0x04)
            }
        }

        uint256 totalShares = isYes ? vault.yesShares : vault.noShares;
        sharesReturned = mulDiv(vaultSharesToRedeem, totalShares, totalVaultShares);
        assembly ("memory-safe") {
            if gt(sharesReturned, 0xffffffffffffffffffffffffffff) {
                mstore(0x00, 0x88c923f1) // SharesReturnedOverflow()
                revert(0x1c, 0x04)
            }
        }

        uint256 accPerShare =
            isYes ? accYesCollateralPerShare[marketId] : accNoCollateralPerShare[marketId];
        uint256 userRewardDebt = isYes ? position.yesRewardDebt : position.noRewardDebt;

        uint256 accumulatedForWithdraw = mulDiv(vaultSharesToRedeem, accPerShare, 1e18);
        // Use 512-bit mulDiv to prevent overflow when userRewardDebt is large
        uint256 debtForWithdraw = fullMulDiv(userRewardDebt, vaultSharesToRedeem, userVaultShares);
        feesEarned =
            accumulatedForWithdraw > debtForWithdraw ? accumulatedForWithdraw - debtForWithdraw : 0;

        unchecked {
            if (isYes) {
                vault.yesShares -= uint112(sharesReturned);
                position.yesVaultShares -= uint112(vaultSharesToRedeem);
                position.yesRewardDebt -= debtForWithdraw;
                totalYesVaultShares[marketId] -= vaultSharesToRedeem;
            } else {
                vault.noShares -= uint112(sharesReturned);
                position.noVaultShares -= uint112(vaultSharesToRedeem);
                position.noRewardDebt -= debtForWithdraw;
                totalNoVaultShares[marketId] -= vaultSharesToRedeem;
            }
        }

        // Cache share ID calculation
        uint256 shareId = isYes ? marketId : PAMM.getNoId(marketId);
        if (sharesReturned != 0) {
            PAMM.transfer(receiver, shareId, sharesReturned);
        }

        // Transfer fees if any earned
        if (feesEarned != 0) {
            (,,,,, address collateral,) = PAMM.markets(marketId);
            if (collateral == ETH) {
                safeTransferETH(receiver, feesEarned);
            } else {
                safeTransfer(collateral, receiver, feesEarned);
            }
        }

        emit VaultWithdraw(
            marketId, receiver, isYes, vaultSharesToRedeem, sharesReturned, feesEarned
        );
    }

    /// @notice One-click LP: Split collateral into YES+NO shares, deposit to vaults, and add AMM liquidity
    /// @dev Supports ETH and ERC20 markets. User specifies how much to allocate to each liquidity type.
    /// @dev Always uses canonical pool for AMM liquidity
    /// @param marketId The market to provide liquidity for
    /// @param collateralAmount Amount of collateral to split (creates equal YES and NO shares)
    /// @param vaultYesShares Amount of YES shares to deposit to vault (earns OTC fees)
    /// @param vaultNoShares Amount of NO shares to deposit to vault (earns OTC fees)
    /// @param ammLPShares Amount of YES+NO shares to add to canonical AMM pool (must be available after vault deposits)
    /// @param minAmount0 Minimum YES shares to add to AMM (slippage protection)
    /// @param minAmount1 Minimum NO shares to add to AMM (slippage protection)
    /// @param receiver Address to receive vault shares, AMM LP tokens, and any leftover outcome shares
    /// @param deadline Transaction must execute before this timestamp
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
        nonReentrant
        returns (uint256 yesVaultSharesMinted, uint256 noVaultSharesMinted, uint256 ammLiquidity)
    {
        {
            (, bool resolved,,, uint64 close,,) = PAMM.markets(marketId);
            assembly ("memory-safe") {
                if resolved {
                    mstore(0x00, 0x7fb7503e) // MarketResolved()
                    revert(0x1c, 0x04)
                }
                if iszero(lt(timestamp(), close)) {
                    mstore(0x00, 0xaa90c61a) // MarketClosed()
                    revert(0x1c, 0x04)
                }
            }
        }
        assembly ("memory-safe") {
            if gt(timestamp(), deadline) {
                mstore(0x00, 0x203d82d8) // Expired()
                revert(0x1c, 0x04)
            }
            if iszero(collateralAmount) {
                mstore(0x00, 0x1f2a2005) // AmountZero()
                revert(0x1c, 0x04)
            }
        }
        if (receiver == address(0)) receiver = msg.sender;

        // Load canonical feeOrHook for this market
        uint256 feeOrHook = canonicalFeeOrHook[marketId];

        // Ensure market was registered via bootstrapMarket()
        assembly ("memory-safe") {
            if iszero(sload(add(canonicalPoolId.slot, marketId))) {
                mstore(0x00, 0x99e120bc) // MarketNotRegistered()
                revert(0x1c, 0x04)
            }
        }

        uint256 yesRemaining;
        uint256 noRemaining;
        assembly ("memory-safe") {
            // Validate: can't use more shares than we'll have
            if gt(vaultYesShares, collateralAmount) {
                mstore(0x00, 0xe6f56ce5) // InsufficientShares()
                revert(0x1c, 0x04)
            }
            if gt(vaultNoShares, collateralAmount) {
                mstore(0x00, 0xe6f56ce5) // InsufficientShares()
                revert(0x1c, 0x04)
            }

            yesRemaining := sub(collateralAmount, vaultYesShares)
            noRemaining := sub(collateralAmount, vaultNoShares)

            // AMM requires equal YES+NO, so check both sides have enough
            if or(gt(ammLPShares, yesRemaining), gt(ammLPShares, noRemaining)) {
                mstore(0x00, 0xe6f56ce5) // InsufficientShares()
                revert(0x1c, 0x04)
            }
        }

        (,,,,, address collateral,) = PAMM.markets(marketId);

        // Take collateral and split into YES + NO shares
        if (collateral == ETH) {
            if (msg.value < collateralAmount) revert InvalidETHAmount();
            PAMM.split{value: collateralAmount}(marketId, collateralAmount, address(this));
        } else {
            if (msg.value != 0) revert InvalidETHAmount();
            safeTransferFrom(collateral, msg.sender, address(this), collateralAmount);
            ensureApproval(collateral, address(PAMM));
            PAMM.split(marketId, collateralAmount, address(this));
        }

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
        uint256 noId = PAMM.getNoId(marketId);
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
    }

    // ============ Vault Settlement ============

    /// @notice Settle remaining rebalance budget by distributing to LPs
    /// @dev Can be called after market close OR if the market is resolved. Merges balanced inventory and distributes all collateral as fees.
    function settleRebalanceBudget(uint256 marketId)
        public
        nonReentrant
        returns (uint256 budgetDistributed, uint256 sharesMerged)
    {
        assembly ("memory-safe") {
            if iszero(sload(add(canonicalPoolId.slot, marketId))) {
                mstore(0x00, 0x99e120bc) // MarketNotRegistered()
                revert(0x1c, 0x04)
            }
        }
        // Check market close time or early resolution
        (, bool resolved,,, uint64 close,,) = PAMM.markets(marketId);
        if (!resolved && block.timestamp < close) revert MarketNotClosed();

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
    }

    /// @notice Redeem vault's winning shares after market resolution and send to DAO
    /// @dev Only works if no user LPs exist (all have withdrawn)
    /// @param marketId The market ID to redeem from
    /// @return payout Amount of collateral sent to DAO
    function redeemVaultWinningShares(uint256 marketId)
        public
        nonReentrant
        returns (uint256 payout)
    {
        assembly ("memory-safe") {
            if iszero(sload(add(canonicalPoolId.slot, marketId))) {
                mstore(0x00, 0x99e120bc) // MarketNotRegistered()
                revert(0x1c, 0x04)
            }
        }
        (, bool resolved, bool outcome,,,,) = PAMM.markets(marketId);
        assembly ("memory-safe") {
            if iszero(resolved) {
                mstore(0x00, 0x3fcc0a52) // MarketNotResolved()
                revert(0x1c, 0x04)
            }
        }

        uint256 totalYes = totalYesVaultShares[marketId];
        uint256 totalNo = totalNoVaultShares[marketId];

        // Only allow cleanup if no user LPs remain
        assembly ("memory-safe") {
            if or(iszero(iszero(totalYes)), iszero(iszero(totalNo))) {
                mstore(0x00, 0x49e74a63) // CirculatingLPsExist()
                revert(0x1c, 0x04)
            }
        }

        BootstrapVault storage vault = bootstrapVaults[marketId];

        // Check which shares are winners
        uint256 winningShares = outcome ? vault.yesShares : vault.noShares;
        if (winningShares == 0) return 0;

        // Claim winning shares - PAMM sends payout directly to DAO
        (, payout) = PAMM.claim(marketId, DAO);

        // Clear vault's winning shares and accounting (losing shares are already worthless)
        if (outcome) {
            vault.yesShares = 0;
            totalYesVaultShares[marketId] = 0;
        } else {
            vault.noShares = 0;
            totalNoVaultShares[marketId] = 0;
        }

        emit VaultWinningSharesRedeemed(marketId, outcome, winningShares, payout);
    }

    /// @notice Complete market finalization - extracts all remaining vault value to DAO
    /// @dev Only works if no user LPs exist (all have withdrawn)
    /// @param marketId The market to finalize
    /// @return totalToDAO Total collateral value sent to DAO
    function finalizeMarket(uint256 marketId) public nonReentrant returns (uint256 totalToDAO) {
        assembly ("memory-safe") {
            if iszero(sload(add(canonicalPoolId.slot, marketId))) {
                mstore(0x00, 0x99e120bc) // MarketNotRegistered()
                revert(0x1c, 0x04)
            }
        }
        // Cache market data
        (, bool resolved, bool outcome,, uint64 close, address collateral,) = PAMM.markets(marketId);
        if (block.timestamp < close && !resolved) revert MarketNotClosed();

        // Cache vault share totals
        uint256 totalYes = totalYesVaultShares[marketId];
        uint256 totalNo = totalNoVaultShares[marketId];

        // Only finalize if no user LPs remain
        if ((totalYes | totalNo) != 0) return 0;

        BootstrapVault storage vault = bootstrapVaults[marketId];

        // Step 1: Merge balanced pairs in vault to collateral (only if not resolved)
        uint256 sharesMerged = vault.yesShares < vault.noShares ? vault.yesShares : vault.noShares;
        if (!resolved && sharesMerged != 0) {
            PAMM.merge(marketId, sharesMerged, address(this));
            unchecked {
                vault.yesShares -= uint112(sharesMerged); // Safe: sharesMerged = min(yes, no)
                vault.noShares -= uint112(sharesMerged); // Safe: sharesMerged = min(yes, no)
                rebalanceCollateralBudget[marketId] += sharesMerged; // Safe: adding uint112 to uint256
            }
        }

        // Step 2: Claim winning shares if market is resolved
        if (resolved) {
            uint256 winningShares = outcome ? vault.yesShares : vault.noShares;
            if (winningShares != 0) {
                (, uint256 payout) = PAMM.claim(marketId, DAO);
                unchecked {
                    totalToDAO += payout; // Safe: adding to uint256
                }
                // Clear winning shares and accounting
                if (outcome) {
                    vault.yesShares = 0;
                    totalYesVaultShares[marketId] = 0;
                } else {
                    vault.noShares = 0;
                    totalNoVaultShares[marketId] = 0;
                }
            }
        }

        // Step 3: Distribute budget to LPs or send to DAO
        uint256 budget = rebalanceCollateralBudget[marketId];
        uint256 budgetDistributed;

        if (budget > 0) {
            rebalanceCollateralBudget[marketId] = 0;

            if (_distributeFeesBothSides(marketId, budget)) {
                budgetDistributed = budget;
            } else {
                if (collateral == ETH) {
                    safeTransferETH(DAO, budget);
                } else {
                    safeTransfer(collateral, DAO, budget);
                }
                unchecked {
                    totalToDAO += budget;
                }
            }
        }

        emit MarketFinalized(marketId, totalToDAO, sharesMerged, budgetDistributed);
    }

    // ============ Vault Rebalancing ============

    /// @notice Helper struct to reduce stack pressure in rebalancing
    struct RebalanceValidation {
        uint256 twapBps;
        uint256 yesReserve;
        uint256 noReserve;
        bool yesIsId0;
    }

    /// @notice Validate TWAP and spot price for rebalancing
    /// @dev Checks spot-TWAP deviation to prevent manipulation
    /// @return validation Struct containing validated prices and reserves
    function _validateRebalanceConditions(uint256 marketId, uint256 canonical)
        internal
        view
        returns (RebalanceValidation memory validation)
    {
        validation.twapBps = _getTWAPPrice(marketId);
        assembly ("memory-safe") {
            if iszero(validation) {
                mstore(0x00, 0xd0c95456) // TWAPRequired()
                revert(0x1c, 0x04)
            }
        }

        // Read spot reserves for deviation check (safety valve against manipulation)
        uint112 r0;
        uint112 r1;
        try ZAMM.pools(canonical) returns (
            uint112 _r0, uint112 _r1, uint32, uint256, uint256, uint256, uint256
        ) {
            r0 = _r0;
            r1 = _r1;
        } catch {
            revert PoolNotReady();
        }
        if ((r0 | r1) == 0) revert PoolNotReady();

        uint256 noId = PAMM.getNoId(marketId);
        validation.yesIsId0 = marketId < noId;

        validation.yesReserve = validation.yesIsId0 ? uint256(r0) : uint256(r1);
        validation.noReserve = validation.yesIsId0 ? uint256(r1) : uint256(r0);

        uint256 total;
        uint256 spotYesBps;
        unchecked {
            total = validation.yesReserve + validation.noReserve;
            spotYesBps = (validation.noReserve * 10_000) / total;
        }

        assembly ("memory-safe") {
            if iszero(spotYesBps) { spotYesBps := 1 }
            if iszero(lt(spotYesBps, 10000)) { spotYesBps := 9999 }
        }

        // Calculate deviation (twapBps guaranteed non-zero by check above)
        uint256 deviation;
        uint256 maxDev = MAX_REBALANCE_DEVIATION_BPS;
        assembly ("memory-safe") {
            let diff := sub(spotYesBps, validation)
            deviation := xor(
                diff,
                mul(xor(diff, sub(validation, spotYesBps)), sgt(validation, spotYesBps))
            )
            if gt(deviation, maxDev) {
                mstore(0x00, 0xf2d7c1c6) // SpotDeviantFromTWAP()
                revert(0x1c, 0x04)
            }
        }
    }

    /// @notice Calculate minimum output for rebalance swap
    /// @dev Uses constant-product formula with fee adjustment and slippage tolerance
    function _calculateRebalanceMinOut(
        uint256 collateralUsed,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256 minOut) {
        // ZAMM constant-product: amountOut = (amountIn * (1-fee) * reserveOut) / (reserveIn + amountIn * (1-fee))
        uint256 amountInWithFee;
        uint256 denominator;
        unchecked {
            amountInWithFee = collateralUsed * (10_000 - feeBps); // Safe: feeBps < 10_000 by validation
            denominator = (reserveIn * 10_000) + amountInWithFee; // Safe: both uint112-derived values
        }
        uint256 expectedSwapOut = mulDiv(amountInWithFee, reserveOut, denominator);

        // Protect against thin pools / tiny rebalances where swap output is negligible
        if (expectedSwapOut == 0) return 0;

        assembly ("memory-safe") {
            // Apply tight slippage tolerance to swap output only
            minOut := div(mul(expectedSwapOut, sub(10000, REBALANCE_SWAP_SLIPPAGE_BPS)), 10000)
            // Prevent truncation to 0 and subtract 1 for rounding tolerance
            switch minOut
            case 0 { minOut := 1 }
            default {
                if gt(minOut, 1) { minOut := sub(minOut, 1) }
            }
        }
    }

    /// @notice Get fee basis points for a pool (handles both hook and static fee modes)
    function _getPoolFeeBps(uint256 feeOrHook, uint256 canonical)
        internal
        view
        returns (uint256 feeBps)
    {
        bool isHook = (feeOrHook & (FLAG_BEFORE | FLAG_AFTER)) != 0;
        if (isHook) {
            address hook = address(uint160(feeOrHook));
            try IPMFeeHook(hook).getCurrentFeeBps(canonical) returns (uint256 fee) {
                feeBps = fee;
            } catch {
                feeBps = DEFAULT_FEE_BPS;
            }
        } else {
            feeBps = feeOrHook;
        }

        // Validate feeBps (>= 10000 indicates halted/invalid market, use fallback for rebalance calculations)
        // Note: User swaps are protected by hook's beforeAction revert, this only affects internal fee estimates
        assembly ("memory-safe") {
            if iszero(lt(feeBps, 10000)) {
                feeBps := DEFAULT_FEE_BPS
            }
        }
    }

    /// @notice Get close window for a market (queries hook's dynamic config)
    function _getCloseWindow(uint256 marketId) internal view returns (uint256) {
        uint256 feeOrHook = canonicalFeeOrHook[marketId];
        bool isHook = (feeOrHook & (FLAG_BEFORE | FLAG_AFTER)) != 0;
        if (isHook) {
            address hook = address(uint160(feeOrHook));
            try IPMFeeHook(hook).getCloseWindow(marketId) returns (uint256 window) {
                return window;
            } catch {
                return 3600; // 1 hour fallback
            }
        }
        return 3600; // 1 hour fallback for non-hooked markets
    }

    /// @notice Rebalance vault inventory using rebalance budget collateral
    /// @dev Merges balanced pairs to collateral, then buys underweight side to equalize vault inventory
    /// @dev REQUIRES TWAP: Uses TWAP for pricing and spot-vs-TWAP deviation checks to prevent manipulation
    /// @dev Will return 0 (no-op) if: TWAP unavailable, no budget, no LPs, within close window
    /// @dev Opportunistically updates TWAP when eligible to maximize rebalance availability
    function rebalanceBootstrapVault(uint256 marketId, uint256 deadline)
        public
        nonReentrant
        returns (uint256 collateralUsed)
    {
        {
            (, bool resolved,,, uint64 closeTime,,) = PAMM.markets(marketId);
            assembly ("memory-safe") {
                if resolved {
                    mstore(0x00, 0x7fb7503e) // MarketResolved()
                    revert(0x1c, 0x04)
                }
                if iszero(lt(timestamp(), closeTime)) {
                    mstore(0x00, 0xaa90c61a) // MarketClosed()
                    revert(0x1c, 0x04)
                }
                if gt(timestamp(), deadline) {
                    mstore(0x00, 0x203d82d8) // Expired()
                    revert(0x1c, 0x04)
                }
            }
        }

        // Opportunistically update TWAP to keep it fresh (non-reverting)
        // Rebalancing requires TWAP for spot-vs-TWAP deviation checks
        _tryUpdateTWAP(marketId);

        // Cache market data to avoid redundant external calls
        (,,,, uint64 close, address collateral,) = PAMM.markets(marketId);

        // Don't rebalance during close window
        uint256 closeWindow = _getCloseWindow(marketId);
        if (block.timestamp < close && close - block.timestamp < closeWindow) {
            return 0;
        }

        BootstrapVault storage vault = bootstrapVaults[marketId];

        // Check pool exists and validate spot-vs-TWAP BEFORE merging to prevent manipulation
        uint256 canonical = canonicalPoolId[marketId];
        if (canonical == 0) revert MarketNotRegistered();

        // Load canonical feeOrHook for this market
        uint256 feeOrHook = canonicalFeeOrHook[marketId];

        RebalanceValidation memory validation = _validateRebalanceConditions(marketId, canonical);

        // Check LPs exist BEFORE any state changes (merge, budget usage)
        uint256 totalYes = totalYesVaultShares[marketId];
        uint256 totalNo = totalNoVaultShares[marketId];

        // Don't rebalance if no LPs exist at all
        if ((totalYes | totalNo) == 0) return 0;

        // Cache noId for reuse
        uint256 noId = PAMM.getNoId(marketId);

        bool yesIsLower = vault.yesShares < vault.noShares;

        // Don't add inventory to a side with zero LPs (prevents donation attack)
        if ((yesIsLower && totalYes == 0) || (!yesIsLower && totalNo == 0)) return 0;

        // Capture pre-merge inventory for probability-weighted fee distribution
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

        uint256 deficit;
        uint256 sharePriceBps;
        uint256 maxCollateralNeeded;
        unchecked {
            deficit = yesIsLower
                ? (vault.noShares - vault.yesShares)
                : (vault.yesShares - vault.noShares);
            sharePriceBps = yesIsLower ? validation.twapBps : (10_000 - validation.twapBps);
            maxCollateralNeeded = (deficit * sharePriceBps) / 10_000;
        }
        collateralUsed =
            availableCollateral < maxCollateralNeeded ? availableCollateral : maxCollateralNeeded;
        if (collateralUsed == 0) return 0;

        // Build pool key from canonical feeOrHook and validate consistency (defensive check)
        (IZAMM.PoolKey memory k, bool keyYesIsId0) = _buildKey(marketId, noId, feeOrHook);
        uint256 derivedPoolId =
            uint256(keccak256(abi.encode(k.id0, k.id1, k.token0, k.token1, k.feeOrHook)));
        if (derivedPoolId != canonical) revert NonCanonicalPool();

        uint256 feeBps = _getPoolFeeBps(feeOrHook, canonical);

        // Calculate expected swap output BEFORE any state changes
        bool zeroForOne = yesIsLower ? !keyYesIsId0 : keyYesIsId0;
        uint256 reserveIn = yesIsLower ? validation.noReserve : validation.yesReserve;
        uint256 reserveOut = yesIsLower ? validation.yesReserve : validation.noReserve;

        uint256 minOut = _calculateRebalanceMinOut(collateralUsed, reserveIn, reserveOut, feeBps);
        if (minOut == 0) return 0;

        // Now safe to proceed with state changes
        if (collateral == ETH) {
            PAMM.split{value: collateralUsed}(marketId, collateralUsed, address(this));
        } else {
            ensureApproval(collateral, address(PAMM));
            PAMM.split(marketId, collateralUsed, address(this));
        }

        uint256 swapTokenId = yesIsLower ? noId : marketId;
        ZAMM.deposit(address(PAMM), swapTokenId, collateralUsed);

        uint256 swappedShares =
            ZAMM.swapExactIn(k, collateralUsed, minOut, zeroForOne, address(this), deadline);

        uint256 totalAcquired;
        uint256 currentShares = yesIsLower ? vault.yesShares : vault.noShares;
        assembly ("memory-safe") {
            totalAcquired := add(collateralUsed, swappedShares)
            if gt(totalAcquired, 0xffffffffffffffffffffffffffff) {
                mstore(0x00, 0xf4c64125) // SharesOverflow()
                revert(0x1c, 0x04)
            }
            if gt(add(currentShares, totalAcquired), 0xffffffffffffffffffffffffffff) {
                mstore(0x00, 0xf4c64125) // SharesOverflow()
                revert(0x1c, 0x04)
            }
        }

        unchecked {
            if (yesIsLower) {
                vault.yesShares += uint112(totalAcquired);
            } else {
                vault.noShares += uint112(totalAcquired);
            }
            rebalanceCollateralBudget[marketId] -= collateralUsed;
        }
        vault.lastActivity = uint32(block.timestamp);

        emit Rebalanced(marketId, collateralUsed, totalAcquired, yesIsLower);
    }

    function _shouldUseVaultMint(uint256 marketId, BootstrapVault memory vault, bool buyYes)
        internal
        view
        returns (bool)
    {
        (,,,, uint64 close,,) = PAMM.markets(marketId);
        unchecked {
            if (close < block.timestamp + BOOTSTRAP_WINDOW) {
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

        if (larger > smaller * VAULT_MINT_MAX_IMBALANCE_RATIO) return false;
        if (yesShares == noShares) return true;

        // Allow only if adding to the scarce side
        bool yesScarce = yesShares < noShares;
        return (buyYes && !yesScarce) || (!buyYes && yesScarce);
    }

    // ============ TWAP Functions ============

    /// @notice Get current cumulative price from ZAMM pool
    /// @dev Computes counterfactual cumulative: poolCumulative + price * (now - poolTimestamp)
    /// @return cumulative The current cumulative price in UQ112x112 format
    /// @return success Whether the cumulative could be computed
    function _getCurrentCumulative(uint256 marketId)
        internal
        view
        returns (uint256 cumulative, bool success)
    {
        uint256 poolId = canonicalPoolId[marketId];
        if (poolId == 0) return (0, false);

        try ZAMM.pools(poolId) returns (
            uint112 r0,
            uint112 r1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast,
            uint256,
            uint256
        ) {
            if ((r0 | r1) == 0) return (0, false);

            uint256 noId = PAMM.getNoId(marketId);
            bool yesIsId0 = marketId < noId;

            // Select cumulative that represents NO/YES ratio
            // yesIsId0: price0 = reserve1/reserve0 = NO/YES
            // !yesIsId0: price1 = reserve0/reserve1 = NO/YES
            uint256 poolCumulative = yesIsId0 ? price0CumulativeLast : price1CumulativeLast;

            // Compute counterfactual cumulative (Uniswap V2 pattern with wrap-safe uint32 arithmetic)
            uint32 timeElapsed;
            unchecked {
                timeElapsed = uint32(block.timestamp) - blockTimestampLast; // wrap-safe
            }

            if (timeElapsed > 0) {
                uint256 yesReserve = yesIsId0 ? uint256(r0) : uint256(r1);
                uint256 noReserve = yesIsId0 ? uint256(r1) : uint256(r0);

                // Compute NO/YES ratio in UQ112x112: (noReserve / yesReserve) * 2^112
                uint256 currentPrice;
                unchecked {
                    currentPrice = (noReserve << 112) / yesReserve; // Safe: both uint112, shift won't overflow 256 bits
                }

                // Detect multiplication overflow (currentPrice ~2^224, timeElapsed up to 2^32)
                uint256 prod;
                unchecked {
                    prod = currentPrice * uint256(timeElapsed);
                }
                if (prod / uint256(timeElapsed) != currentPrice) {
                    return (0, false); // Overflow
                }

                uint256 sum;
                unchecked {
                    sum = poolCumulative + prod;
                }
                if (sum < poolCumulative) return (0, false);

                cumulative = sum;
            } else {
                cumulative = poolCumulative;
            }

            return (cumulative, true);
        } catch {
            return (0, false);
        }
    }

    /// @notice Update TWAP observation to advance the sliding window
    /// @dev Permissionless - can be called by anyone after MIN_TWAP_UPDATE_INTERVAL
    /// @dev OPTIONAL: TWAP auto-activates 30min after bootstrap even without updates
    /// @dev Updates keep TWAP fresh and improve manipulation resistance, but not strictly required
    /// @dev Stale TWAP remains valid indefinitely (longer windows = more manipulation-resistant)
    /// @dev Shifts observations: obs0 = obs1, obs1 = current
    /// @param marketId The market ID to update
    function updateTWAPObservation(uint256 marketId) public {
        TWAPObservations storage obs = twapObservations[marketId];

        // TWAP must be initialized at bootstrap
        if (obs.timestamp1 == 0) revert TWAPRequired();

        // Require minimum time between updates
        if (block.timestamp - obs.timestamp1 < MIN_TWAP_UPDATE_INTERVAL) {
            revert TooSoon();
        }

        // Get current cumulative from pool
        (uint256 currentCumulative, bool success) = _getCurrentCumulative(marketId);
        if (!success) revert PoolNotReady();

        // Shift observations: obs0 = obs1, obs1 = current
        obs.timestamp0 = obs.timestamp1;
        obs.cumulative0 = obs.cumulative1;
        obs.timestamp1 = uint32(block.timestamp);
        obs.cumulative1 = currentCumulative;
    }

    /// @notice Opportunistically update TWAP if eligible (non-reverting)
    /// @dev Called automatically during trades/rebalances to keep TWAP fresh
    /// @dev Does not revert on failure - just returns success status
    /// @param marketId The market ID to update
    /// @return updated Whether the TWAP was successfully updated
    function _tryUpdateTWAP(uint256 marketId) internal returns (bool updated) {
        TWAPObservations storage obs = twapObservations[marketId];

        // Skip if not initialized or too soon
        if (obs.timestamp1 == 0) return false;
        if (block.timestamp - obs.timestamp1 < MIN_TWAP_UPDATE_INTERVAL) return false;

        // Get current cumulative from pool
        (uint256 currentCumulative, bool success) = _getCurrentCumulative(marketId);
        if (!success) return false;

        // Update observations
        obs.timestamp0 = obs.timestamp1;
        obs.cumulative0 = obs.cumulative1;
        obs.timestamp1 = uint32(block.timestamp);
        obs.cumulative1 = currentCumulative;

        return true;
    }

    /// @notice Get sliding window TWAP price for a market
    /// @dev Returns time-weighted average over recent window, or 0 if not initialized
    /// @return twapBps TWAP in basis points [1-9999], or 0 if unavailable
    function _getTWAPPrice(uint256 marketId) internal view returns (uint256 twapBps) {
        TWAPObservations storage obs = twapObservations[marketId];

        // TWAP must be initialized at bootstrap (prevents manipulation)
        if (obs.timestamp1 == 0) return 0;

        uint256 timeElapsed;
        uint256 twapUQ112x112;

        // If obs1 is too recent, use the guaranteed-long window obs0 -> obs1
        // This prevents manipulation right after updateTWAPObservation() where the window would be very short
        if (block.timestamp - obs.timestamp1 < MIN_TWAP_UPDATE_INTERVAL) {
            unchecked {
                timeElapsed = obs.timestamp1 - obs.timestamp0;
            }
            if (timeElapsed == 0) return 0;

            // Safety check: cumulative should be monotonically increasing
            if (obs.cumulative1 < obs.cumulative0) return 0;

            // Compute TWAP from obs0 -> obs1
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

        // Compute TWAP from obs1 -> current (recent window, guaranteed >= MIN_TWAP_UPDATE_INTERVAL)
        unchecked {
            twapUQ112x112 = (currentCumulative - obs.cumulative1) / timeElapsed;
        }
        return _convertUQ112x112ToBps(twapUQ112x112);
    }

    /// @notice Convert UQ112x112 ratio to probability in basis points
    /// @param twapUQ112x112 The NO/YES ratio in UQ112x112 format
    /// @return twapBps The probability in basis points [1-9999]
    function _convertUQ112x112ToBps(uint256 twapUQ112x112) internal pure returns (uint256 twapBps) {
        // Convert UQ112x112 ratio (NO/YES) to probability in bps
        // r = NO/YES (in UQ112x112)
        // pYes = r/(1+r) = NO/(YES+NO)    [matches spot formula]
        // pYesBps = 10000 * r/(1+r)
        //
        // To avoid precision loss with UQ112x112:
        // pYesBps = (10000 * r) / (2^112 + r)
        assembly ("memory-safe") {
            let denom := add(shl(112, 1), twapUQ112x112)
            twapBps := div(mul(10000, twapUQ112x112), denom)

            // Clamp to [1, 9999]
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

        // If no LPs exist, add to rebalance budget
        if (totalSharesSnapshot == 0) {
            unchecked {
                rebalanceCollateralBudget[marketId] += feeAmount;
            }
            return;
        }

        // Distribute all fees to all LPs (no protocol split)
        uint256 accPerShare = mulDiv(feeAmount, 1e18, totalSharesSnapshot);
        uint256 newAcc =
            (isYes ? accYesCollateralPerShare[marketId] : accNoCollateralPerShare[marketId])
                + accPerShare;
        uint256 maxAcc = MAX_ACC_PER_SHARE;
        assembly ("memory-safe") {
            if gt(newAcc, maxAcc) {
                mstore(0x00, 0x35278d12) // Overflow()
                revert(0x1c, 0x04)
            }
        }
        if (isYes) {
            accYesCollateralPerShare[marketId] = newAcc;
        } else {
            accNoCollateralPerShare[marketId] = newAcc;
        }
    }

    /// @notice Distribute fees to LPs on both YES and NO sides
    /// @dev Uses snapshots to prevent state mutation affecting second side's calculation
    /// @param marketId The market ID
    /// @param amount Fees to distribute
    /// @return distributed Whether fees were distributed to LPs (false if no LPs exist)
    function _distributeFeesBothSides(uint256 marketId, uint256 amount)
        internal
        returns (bool distributed)
    {
        if (amount == 0) return false;

        // Snapshot before any mutations
        uint256 yesLP = totalYesVaultShares[marketId];
        uint256 noLP = totalNoVaultShares[marketId];

        if ((yesLP | noLP) == 0) {
            return false; // Caller handles "no LPs" case
        } else if (yesLP == 0) {
            // Only NO LPs - give all to NO side
            _addVaultFeesWithSnapshot(marketId, false, amount, noLP);
        } else if (noLP == 0) {
            // Only YES LPs - give all to YES side
            _addVaultFeesWithSnapshot(marketId, true, amount, yesLP);
        } else {
            // Both sides have LPs - split 50/50
            uint256 half = amount >> 1;
            _addVaultFeesWithSnapshot(marketId, true, half, yesLP);
            unchecked {
                _addVaultFeesWithSnapshot(marketId, false, amount - half, noLP); // Safe: half <= amount
            }
        }
        return true;
    }

    /// @notice Distribute fees symmetrically using pre-trade vault snapshot
    /// @dev This ensures fees are weighted by the capital that was at risk when the quote was created
    /// @param marketId The market ID
    /// @param feeAmount Total fees to distribute
    /// @param yesInv Pre-trade YES inventory
    /// @param noInv Pre-trade NO inventory
    /// @param pYes TWAP price in basis points (reuse to avoid redundant call)
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

        // If nobody can receive fees, return false so caller can decide what to do
        // (Caller should reinvest or handle appropriately - prevents double-spend)
        if ((yesLP | noLP) == 0) {
            return false;
        }

        // If only one side has LPs, give to that side
        if (yesLP == 0) {
            _addVaultFeesWithSnapshot(marketId, false, feeAmount, noLP);
            return true;
        }
        if (noLP == 0) {
            _addVaultFeesWithSnapshot(marketId, true, feeAmount, yesLP);
            return true;
        }

        if (pYes == 0) {
            // Fallback: 50/50 split if TWAP not ready
            uint256 half = feeAmount >> 1;
            _addVaultFeesWithSnapshot(marketId, true, half, yesLP);
            unchecked {
                _addVaultFeesWithSnapshot(marketId, false, feeAmount - half, noLP);
            }
            return true;
        }

        // Use pre-trade inventory for fair weighting
        uint256 yesNotional;
        uint256 noNotional;
        uint256 denom;
        unchecked {
            yesNotional = uint256(yesInv) * pYes;
            // pYes is clamped to [1, 9999], so subtraction is safe
            noNotional = uint256(noInv) * (10_000 - pYes);
            denom = yesNotional + noNotional; // Safe: both products bounded by uint112 * 10000
        }

        if (denom == 0) {
            // Edge case: inventories zero or pYes extreme - use 50/50
            uint256 half;
            unchecked {
                half = feeAmount >> 1;
            }
            _addVaultFeesWithSnapshot(marketId, true, half, yesLP);
            unchecked {
                _addVaultFeesWithSnapshot(marketId, false, feeAmount - half, noLP); // Safe: half <= feeAmount
            }
            return true;
        }

        uint256 yesFee;
        unchecked {
            yesFee = mulDiv(feeAmount, yesNotional, denom);
        }
        _addVaultFeesWithSnapshot(marketId, true, yesFee, yesLP);
        unchecked {
            _addVaultFeesWithSnapshot(marketId, false, feeAmount - yesFee, noLP); // Safe: yesFee <= feeAmount by mulDiv
        }
        return true;
    }

    /// @notice Calculate directional dynamic spread based on inventory imbalance and time to close
    /// @dev Spread widens when consuming scarce inventory, narrows when consuming abundant inventory
    /// @param yesShares Current YES inventory
    /// @param noShares Current NO inventory
    /// @param buyYes Whether trade is buying YES (consuming YES inventory)
    /// @param close Market close timestamp
    /// @return spreadBps The calculated spread in basis points
    function _calculateDynamicSpread(uint256 yesShares, uint256 noShares, bool buyYes, uint64 close)
        internal
        view
        returns (uint256 spreadBps)
    {
        spreadBps = MIN_TWAP_SPREAD_BPS;

        // Directional inventory imbalance scaling
        uint256 totalShares;
        assembly ("memory-safe") {
            totalShares := add(yesShares, noShares) // Safe: both uint112
        }
        if (totalShares > 0) {
            bool yesScarce;
            bool consumingScarce;
            uint256 imbalanceBps;
            assembly ("memory-safe") {
                // Determine which side is scarce
                yesScarce := lt(yesShares, noShares)

                // Check if trade consumes the scarce side
                consumingScarce := or(
                    and(buyYes, yesScarce),
                    and(iszero(buyYes), iszero(yesScarce))
                )
            }

            if (consumingScarce) {
                assembly ("memory-safe") {
                    // Calculate how imbalanced the inventory is (in bps)
                    let larger :=
                        xor(yesShares, mul(xor(yesShares, noShares), gt(noShares, yesShares)))
                    imbalanceBps := div(mul(larger, 10000), totalShares)
                }

                // Scale spread above 50/50 threshold (5000 bps)
                // Linear from 0 at 50/50 to MAX_IMBALANCE_SPREAD_BPS at 100/0
                uint256 midpoint = IMBALANCE_MIDPOINT_BPS;
                if (imbalanceBps > midpoint) {
                    uint256 maxSpread = MAX_IMBALANCE_SPREAD_BPS;
                    assembly ("memory-safe") {
                        let excessImbalance := sub(imbalanceBps, midpoint)
                        let imbalanceBoost := div(mul(maxSpread, excessImbalance), midpoint)
                        spreadBps := add(spreadBps, imbalanceBoost)
                    }
                }
            }
        }

        // Time pressure scaling
        assembly ("memory-safe") {
            if lt(timestamp(), close) {
                let timeToClose := sub(close, timestamp())

                // Within last 24 hours, add time pressure boost
                if lt(timeToClose, 86400) {
                    // Linear: 0 boost at 24h before close, MAX_TIME_BOOST_BPS at close
                    let timeBoost := div(mul(MAX_TIME_BOOST_BPS, sub(86400, timeToClose)), 86400)
                    spreadBps := add(spreadBps, timeBoost)
                }
            }

            // Apply overall cap to prevent excessive spreads
            if gt(spreadBps, MAX_SPREAD_BPS) {
                spreadBps := MAX_SPREAD_BPS
            }
        }

        return spreadBps;
    }

    /// @notice Try to fill order from vault OTC inventory (supports partial fills)
    /// @return sharesOut Number of shares that can be filled from vault
    /// @return collateralUsed Amount of collateral consumed for this fill
    /// @return filled Whether vault can participate (false if disabled/unavailable)
    function _tryVaultOTCFill(uint256 marketId, bool buyYes, uint256 collateralIn)
        internal
        view
        returns (uint256 sharesOut, uint256 collateralUsed, bool filled)
    {
        uint256 maxCollateral = MAX_COLLATERAL_IN;
        assembly ("memory-safe") {
            if or(iszero(collateralIn), gt(collateralIn, maxCollateral)) {
                mstore(0x00, 0)
                mstore(0x20, 0)
                mstore(0x40, 0)
                return(0x00, 0x60)
            }
        }

        // Check if vault is closed due to close window
        (,,,, uint64 close,,) = PAMM.markets(marketId);
        uint256 closeWindow = _getCloseWindow(marketId);
        if (block.timestamp < close && close - block.timestamp < closeWindow) {
            return (0, 0, false);
        }

        BootstrapVault memory vault = bootstrapVaults[marketId];
        uint256 availableShares = buyYes ? vault.yesShares : vault.noShares;
        if (availableShares == 0) return (0, 0, false);

        uint256 yesTwapBps = _getTWAPPrice(marketId);

        if (yesTwapBps == 0) {
            return (0, 0, false);
        }

        // Check spot-vs-TWAP deviation to prevent manipulation (same as rebalancing)
        uint256 canonical = canonicalPoolId[marketId];
        if (canonical != 0) {
            try ZAMM.pools(canonical) returns (
                uint112 r0, uint112 r1, uint32, uint256, uint256, uint256, uint256
            ) {
                if ((r0 & r1) != 0) {
                    uint256 noId = PAMM.getNoId(marketId);
                    bool yesIsId0 = marketId < noId;
                    uint256 yesReserve = yesIsId0 ? uint256(r0) : uint256(r1);
                    uint256 noReserve = yesIsId0 ? uint256(r1) : uint256(r0);
                    uint256 total;
                    uint256 spotYesBps;
                    assembly ("memory-safe") {
                        total := add(yesReserve, noReserve)
                        spotYesBps := div(mul(noReserve, 10000), total)

                        // Clamp to [1, 9999]
                        if iszero(spotYesBps) { spotYesBps := 1 }
                        if iszero(lt(spotYesBps, 10000)) { spotYesBps := 9999 }
                    }

                    uint256 deviation;
                    uint256 maxDev = MAX_REBALANCE_DEVIATION_BPS;
                    assembly ("memory-safe") {
                        // Absolute difference
                        let diff := sub(spotYesBps, yesTwapBps)
                        deviation := xor(
                            diff,
                            mul(xor(diff, sub(yesTwapBps, spotYesBps)), sgt(yesTwapBps, spotYesBps))
                        )

                        if gt(deviation, maxDev) {
                            // Return (0, 0, false)
                            mstore(0x00, 0)
                            mstore(0x20, 0)
                            mstore(0x40, 0)
                            return(0x00, 0x60)
                        }
                    }
                }
            } catch {
                // If pools() reverts, skip deviation check and continue
                // (vault fill still enabled based on TWAP alone)
            }
        }

        uint256 sharePriceBps;
        assembly ("memory-safe") {
            sharePriceBps := xor(
                yesTwapBps,
                mul(xor(yesTwapBps, sub(10000, yesTwapBps)), iszero(buyYes))
            )
        }

        uint256 spreadBps = _calculateDynamicSpread(vault.yesShares, vault.noShares, buyYes, close);
        uint256 effectivePriceBps;
        uint256 rawShares;
        unchecked {
            effectivePriceBps = sharePriceBps + spreadBps;
            if (effectivePriceBps > 10_000) effectivePriceBps = 10_000;
            rawShares = (collateralIn * 10_000) / effectivePriceBps;
        }
        if (rawShares == 0) return (0, 0, false);

        unchecked {
            uint256 maxSharesFromVault = (availableShares * MAX_VAULT_FILL_BPS) / 10_000;
            sharesOut = rawShares;
            if (sharesOut > maxSharesFromVault) sharesOut = maxSharesFromVault;
            if (sharesOut > availableShares) sharesOut = availableShares;
            collateralUsed = (sharesOut == rawShares)
                ? collateralIn
                : (sharesOut * effectivePriceBps + 9_999) / 10_000;
        }

        return (sharesOut, collateralUsed, true);
    }
}

function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z) {
    assembly ("memory-safe") {
        z := mul(x, y)
        if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
            mstore(0x00, 0xad251c27) // MulDivFailed()
            revert(0x1c, 0x04)
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
                    mstore(0x00, 0xae47f702) // FullMulDivFailed()
                    revert(0x1c, 0x04)
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

/// @dev Sets max approval once if allowance <= uint128.max. Does NOT support tokens requiring approve(0) first.
function ensureApproval(address token, address spender) {
    assembly ("memory-safe") {
        mstore(0x00, 0xdd62ed3e000000000000000000000000) // allowance(address,address)
        mstore(0x14, address())
        mstore(0x34, spender)
        let success := staticcall(gas(), token, 0x10, 0x44, 0x00, 0x20)

        // Check if we need approval: !success OR returndatasize != 32 OR allowance <= uint128.max
        // Defensive: handle tokens that return no data or non-standard sizes
        let needsApproval := 1
        if and(success, eq(returndatasize(), 32)) {
            // Standard ERC20: check if allowance > uint128.max
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
                    mstore(0x00, 0x3e3f8f73)
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
            mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
            revert(0x1c, 0x04)
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
                mstore(0x00, 0x90b8ec18) // TransferFailed()
                revert(0x1c, 0x04)
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
                mstore(0x00, 0x7939f424) // TransferFromFailed()
                revert(0x1c, 0x04)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}

function getBalance(address token, address account) view returns (uint256 bal) {
    assembly ("memory-safe") {
        mstore(0x14, account)
        mstore(0x00, 0x70a08231000000000000000000000000) // balanceOf(address)
        bal := mul(
            mload(0x20),
            and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20))
        )
    }
}
