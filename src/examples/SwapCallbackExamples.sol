// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Swap Callback Examples
/// @notice Example contracts showing advanced strategies using swapWithCallback
/// @dev These demonstrate the power of ZAMM's low-level swap() + hook calldata passing

interface IPMHookRouterV1 {
    function swapWithCallback(
        uint256 marketId,
        bool yesForNo,
        uint256 amountIn,
        uint256 minOut,
        uint256 feeOrHook,
        address to,
        address callbackContract,
        bytes calldata callbackData,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

interface IPAMM {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

// ============================================================================
// Example 1: Governance Vote Atomically with Trade
// ============================================================================

interface IUniswapGovernance {
    function castVote(uint256 proposalId, uint8 support) external;
}

/// @notice Vote on Uniswap governance atomically while trading fee switch market
/// @dev If trade succeeds, vote is cast. If trade fails, vote reverts too.
contract GovernanceVoteCallback {
    IUniswapGovernance public immutable governance;

    constructor(address _governance) {
        governance = IUniswapGovernance(_governance);
    }

    /// @notice Hook calls this mid-swap (if hook supports it, or could be called by ZAMM)
    function onSwapExecute(uint256, address sender, bytes calldata data) external {
        (uint256 proposalId, uint8 support) = abi.decode(data, (uint256, uint8));

        // Cast vote on behalf of trader (they must have delegated to this contract)
        governance.castVote(proposalId, support);

        // Swap continues after this returns
    }
}

// Usage:
// 1. User delegates votes to GovernanceVoteCallback
// 2. User calls router.swapWithCallback(..., governanceCallback, abi.encode(proposalId, support), ...)
// 3. Trade executes + vote is cast atomically!

// ============================================================================
// Example 2: Stop-Loss / Take-Profit Conditional Swap
// ============================================================================

/// @notice Only execute swap if price is within bounds
/// @dev Prevents sandwich attacks and implements limit-order-like behavior
contract ConditionalSwapCallback {
    struct Condition {
        uint256 minProbability; // In basis points (5000 = 50%)
        uint256 maxProbability;
        bool revertOnFail; // True to revert, false to no-op
    }

    error ConditionNotMet(uint256 currentProb, uint256 min, uint256 max);

    function onSwapExecute(uint256 poolId, address, bytes calldata data) external view {
        Condition memory cond = abi.decode(data, (Condition));

        // Get current market probability from pool reserves
        uint256 currentProb = _getPoolProbability(poolId);

        if (currentProb < cond.minProbability || currentProb > cond.maxProbability) {
            if (cond.revertOnFail) {
                revert ConditionNotMet(currentProb, cond.minProbability, cond.maxProbability);
            }
            // If not reverting, swap continues anyway
        }
    }

    function _getPoolProbability(uint256) internal pure returns (uint256) {
        // Would query ZAMM.pools(poolId) to get reserves and compute probability
        return 5000; // Placeholder
    }
}

// Usage:
// router.swapWithCallback(
//     marketId,
//     true, // YES -> NO
//     1000e18,
//     0,
//     feeOrHook,
//     msg.sender,
//     conditionalCallback,
//     abi.encode(ConditionalSwapCallback.Condition({
//         minProbability: 4500, // Only swap if market is 45-55%
//         maxProbability: 5500,
//         revertOnFail: true
//     })),
//     deadline
// );

// ============================================================================
// Example 3: Flash Arbitrage Across DEXs
// ============================================================================

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @notice Arbitrage PM shares against external DEX pricing
/// @dev Borrow shares via ZAMM callback, sell on DEX, buy back cheaper
contract ArbitrageCallback {
    IUniswapV2Router public immutable uniswapRouter;
    IPAMM public immutable pamm;

    constructor(address _router, address _pamm) {
        uniswapRouter = IUniswapV2Router(_router);
        pamm = IPAMM(_pamm);
    }

    struct ArbParams {
        address[] dexPath; // Path on Uniswap: [collateral, UNI, USDC, ...]
        uint256 minProfit;
    }

    /// @notice Execute arbitrage mid-swap
    /// @dev Hook/ZAMM calls this after sending shares to router but before taking payment
    function onSwapExecute(uint256 poolId, address trader, bytes calldata data) external {
        ArbParams memory params = abi.decode(data, (ArbParams));

        // At this point, router has received shares from ZAMM
        // We can use them for arbitrage!

        // 1. Check balance of shares we just received
        uint256 shareBalance = pamm.balanceOf(address(this), poolId);

        // 2. Sell shares on DEX for collateral
        // (Would need to wrap shares as ERC20 or use special DEX)

        // 3. Buy back shares cheaper from another source

        // 4. Repay ZAMM (happens automatically after callback returns)

        // 5. Keep profit
        uint256 profit = 0; // Calculate actual profit
        require(profit >= params.minProfit, "Insufficient arbitrage profit");
    }
}

// ============================================================================
// Example 4: Multi-Market Correlation Trading
// ============================================================================

/// @notice Trade multiple correlated markets atomically
/// @dev E.g., "If Trump wins, ETH will pump" - trade both markets together
contract CorrelationCallback {
    IPMHookRouterV1 public immutable router;

    constructor(address _router) {
        router = IPMHookRouterV1(_router);
    }

    struct CorrelatedTrade {
        uint256 marketId2;
        bool buyYes2;
        uint256 amount2;
        uint256 feeOrHook2;
    }

    /// @notice Execute correlated trade mid-swap
    /// @dev While swapping Market 1, also trade Market 2
    function onSwapExecute(uint256, address, bytes calldata data) external {
        CorrelatedTrade memory trade2 = abi.decode(data, (CorrelatedTrade));

        // Execute second trade
        // router.buy(trade2.marketId2, trade2.buyYes2, trade2.amount2, ...);

        // Both trades succeed or both fail atomically!
    }
}

// Usage Example:
// "I think Uniswap will activate fee switch (60% prob) AND UNI price will go up (70% prob)"
// router.swapWithCallback(
//     FEE_SWITCH_MARKET,
//     false, // Buy YES (NO->YES swap)
//     1000e18,
//     0,
//     feeOrHook,
//     msg.sender,
//     correlationCallback,
//     abi.encode(CorrelationCallback.CorrelatedTrade({
//         marketId2: UNI_PRICE_MARKET,
//         buyYes2: true,
//         amount2: 500e18,
//         feeOrHook2: feeOrHook
//     })),
//     deadline
// );

// ============================================================================
// Example 5: Social Trading - Copy Successful Traders
// ============================================================================

/// @notice Automatically copy trades from successful prediction market traders
contract CopyTradingCallback {
    mapping(address => bool) public trustedTraders;
    mapping(address => mapping(address => uint256)) public copyPercentage; // copier => trader => %

    event TradeCopied(
        address indexed copier, address indexed trader, uint256 marketId, uint256 amount
    );

    function onSwapExecute(uint256, address originalTrader, bytes calldata data) external {
        address[] memory copiers = abi.decode(data, (address[]));

        for (uint256 i = 0; i < copiers.length; i++) {
            address copier = copiers[i];
            uint256 copyPct = copyPercentage[copier][originalTrader];

            if (copyPct > 0) {
                // Execute proportional trade for copier
                // (Would need to get trade details from context)
                emit TradeCopied(copier, originalTrader, 0, 0);
            }
        }
    }
}

// ============================================================================
// Example 6: Privacy-Preserving Trading via ZK Proofs
// ============================================================================

/// @notice Execute trade only if ZK proof is valid (e.g., prove you're in whitelist without revealing identity)
contract ZKProofCallback {
    address public immutable verifier; // ZK proof verifier contract

    constructor(address _verifier) {
        verifier = _verifier;
    }

    struct ZKProof {
        uint256[2] a;
        uint256[2][2] b;
        uint256[2] c;
        uint256[] publicInputs;
    }

    error InvalidProof();

    function onSwapExecute(uint256, address, bytes calldata data) external view {
        ZKProof memory proof = abi.decode(data, (ZKProof));

        // Verify ZK proof (e.g., prove trader is accredited investor without revealing identity)
        (bool success,) = verifier.staticcall(
            abi.encodeWithSignature(
                "verifyProof(uint256[2],uint256[2][2],uint256[2],uint256[])",
                proof.a,
                proof.b,
                proof.c,
                proof.publicInputs
            )
        );

        if (!success) revert InvalidProof();

        // Trade continues if proof is valid
    }
}
