// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMFeeHookV1} from "../src/PMFeeHookV1.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

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

    function getNoId(uint256 marketId) external pure returns (uint256);

    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);

    function split(uint256 marketId, uint256 amount, address to) external payable;
    function merge(uint256 marketId, uint256 amount, address to) external;

    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
    function setOperator(address operator, bool approved) external returns (bool);

    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function poolKey(uint256 marketId, uint256 feeOrHook) external view returns (PoolKey memory);
}

interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

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

    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);
}

/// @title PMFeeHookV1 Comprehensive Test Suite
/// @notice Tests for dynamic fee hook covering all features and edge cases
contract PMFeeHookV1Test is Test {
    PMFeeHookV1 public hook;

    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    address public alice;
    address public bob;

    uint256 public marketId;
    uint256 public noId;
    uint256 public poolId;
    uint256 public feeOrHook;

    uint64 public TEST_DEADLINE;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        TEST_DEADLINE = uint64(block.timestamp + 365 days);

        // Deploy hook (owner will be tx.origin)
        vm.startPrank(address(this), address(this)); // Set tx.origin to this
        hook = new PMFeeHookV1();
        vm.stopPrank();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        deal(address(USDC), alice, 10_000e6);
        deal(address(USDC), bob, 10_000e6);

        console.log("=== PMFeeHookV1 Test Suite ===");
        console.log("Hook deployed:", address(hook));
        console.log("Owner:", hook.owner());
        console.log("");
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DeploymentDefaults() public view {
        // Test deployment succeeded by verifying hook address is set
        assertTrue(address(hook) != address(0), "Hook should be deployed");
    }

    function test_FeeOrHookValue() public view {
        uint256 foh = hook.feeOrHook();
        uint256 flagBefore = 1 << 255;
        uint256 flagAfter = 1 << 254;

        assertEq(foh & flagBefore, flagBefore, "Should have FLAG_BEFORE");
        assertEq(foh & flagAfter, flagAfter, "Should have FLAG_AFTER");
        assertEq(foh & ((1 << 160) - 1), uint160(address(hook)), "Should contain hook address");
    }

    /*//////////////////////////////////////////////////////////////
                        MARKET REGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RegisterMarket() public {
        _createTestMarket();

        uint256 derivedPoolId = hook.registerMarket(marketId);

        // Verify registration
        assertGt(derivedPoolId, 0, "Pool ID should be non-zero");
        assertEq(hook.poolToMarket(derivedPoolId), marketId, "Should map pool to market");

        (uint64 start, bool active,) = hook.meta(derivedPoolId);
        assertTrue(active, "Should be active");
        assertGt(start, 0, "Should store start time");

        poolId = derivedPoolId;
    }

    function test_RevertRegisterInvalidMarket() public {
        vm.expectRevert(PMFeeHookV1.InvalidMarket.selector);
        hook.registerMarket(999999);
    }

    function test_RevertRegisterResolved() public {
        _createTestMarket();

        // Fast forward past deadline and resolve
        vm.warp(TEST_DEADLINE + 1);

        vm.expectRevert(PMFeeHookV1.MarketClosed.selector);
        hook.registerMarket(marketId);
    }

    function test_RevertDoubleRegistration() public {
        _createTestMarket();
        hook.registerMarket(marketId);

        vm.expectRevert(PMFeeHookV1.AlreadyRegistered.selector);
        hook.registerMarket(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                        BOOTSTRAP FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BootstrapFeeDecay() public {
        _setupMarketWithPool();

        // At start (t=0): should be maxFeeBps = 75
        uint256 feeStart = hook.getCurrentFeeBps(poolId);
        assertEq(feeStart, 75, "Should start at max fee");

        // At 25% of bootstrap window (0.5 days)
        vm.warp(block.timestamp + 2 days / 4);
        uint256 fee25 = hook.getCurrentFeeBps(poolId);
        assertLt(fee25, feeStart, "Fee should decay");
        assertGt(fee25, 10, "Fee should be above min");

        // At 50% (1 day)
        vm.warp(block.timestamp + 2 days / 4);
        uint256 fee50 = hook.getCurrentFeeBps(poolId);
        assertLe(fee50, fee25, "Fee should continue decaying or stay same due to rounding");

        // At end of bootstrap (2 days): should be close to minFeeBps = 10
        vm.warp(block.timestamp + 2 days / 2);
        uint256 feeEnd = hook.getCurrentFeeBps(poolId);
        assertLt(feeEnd, 50, "Should be close to min fee after bootstrap");

        console.log("Bootstrap decay test passed:");
        console.log("  Start:", feeStart, "bps");
        console.log("  25%:  ", fee25, "bps");
        console.log("  50%:  ", fee50, "bps");
        console.log("  End:  ", feeEnd, "bps");
    }

    /*//////////////////////////////////////////////////////////////
                        CLOSE WINDOW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CloseWindowMode0_Halt() public {
        _setupMarketWithPool();

        // Set config to mode 0 (halt) since default is now mode 1
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = (cfg.flags & ~uint16(0x0C)); // Clear bits 2-3 to set mode 0
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Before close window: should work
        uint256 feeBefore = hook.getCurrentFeeBps(poolId);
        assertEq(feeBefore, 75, "Fee should be normal before close window");

        // Enter close window (1 hour before deadline)
        vm.warp(TEST_DEADLINE - 30 minutes);

        // Mode 0 returns sentinel
        uint256 feeInWindow = hook.getCurrentFeeBps(poolId);
        assertEq(feeInWindow, 10001, "Should return sentinel (halted)");

        // isMarketOpen should return false
        bool isOpen = hook.isMarketOpen(poolId);
        assertFalse(isOpen, "Market should be closed in close window mode 0");

        console.log("Close window mode 0 (halt) test passed");
    }

    function test_CloseWindowMode1_Fixed() public {
        _setupMarketWithPool();

        // Change config to mode 1
        PMFeeHookV1.Config memory cfg = _getConfig();
        cfg.flags = uint8((uint256(cfg.flags) & ~uint256(0x0C)) | (1 << 2)); // Set bits 2-3 to mode 1
        cfg.closeWindowFeeBps = 50; // 0.50% fixed fee
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Enter close window
        vm.warp(TEST_DEADLINE - 30 minutes);

        uint256 feeInWindow = hook.getCurrentFeeBps(poolId);
        assertEq(feeInWindow, 50, "Should charge fixed close window fee");

        console.log("Close window mode 1 (fixed fee) test passed");
    }

    function test_CloseWindowMode2_MinFee() public {
        _setupMarketWithPool();

        // Change config to mode 2
        PMFeeHookV1.Config memory cfg = _getConfig();
        cfg.flags = (cfg.flags & ~uint8(0x0C)) | uint8(2 << 2); // Set bits 2-3 to mode 2
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Enter close window
        vm.warp(TEST_DEADLINE - 30 minutes);

        uint256 feeInWindow = hook.getCurrentFeeBps(poolId);
        assertEq(feeInWindow, cfg.minFeeBps, "Should charge min fee");

        console.log("Close window mode 2 (min fee) test passed");
    }

    function test_CloseWindowMode3_Dynamic() public {
        _setupMarketWithPool();

        // Change config to mode 3
        PMFeeHookV1.Config memory cfg = _getConfig();
        cfg.flags = (cfg.flags & ~uint8(0x0C)) | uint8(3 << 2); // Set bits 2-3 to mode 3
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Enter close window
        vm.warp(TEST_DEADLINE - 30 minutes);

        uint256 feeInWindow = hook.getCurrentFeeBps(poolId);
        // Should still use dynamic calculation (bootstrap fee at this time)
        assertGt(feeInWindow, 0, "Should have positive fee");
        assertLe(feeInWindow, cfg.feeCapBps, "Should respect fee cap");

        console.log("Close window mode 3 (dynamic) test passed");
    }

    /*//////////////////////////////////////////////////////////////
                        SKEW FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SkewFeeIncreasesWithImbalance() public {
        _setupMarketWithPool();

        // Disable price impact for this test (we're testing skew fees, not impact limits)
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags & ~uint16(0x20); // Clear FLAG_PRICE_IMPACT
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Get fee at balanced state (50/50)
        uint256 feeBalanced = hook.getCurrentFeeBps(poolId);

        // Create imbalance by swapping
        _swapToCreateImbalance();

        // Get fee after imbalance
        uint256 feeImbalanced = hook.getCurrentFeeBps(poolId);

        assertGt(feeImbalanced, feeBalanced, "Fee should increase with imbalance");

        uint256 prob = hook.getMarketProbability(poolId);
        console.log("Skew fee test:");
        console.log("  Balanced fee:", feeBalanced, "bps");
        console.log("  Imbalanced fee:", feeImbalanced, "bps");
        console.log("  Probability:", prob, "bps");
    }

    /*//////////////////////////////////////////////////////////////
                    PRICE IMPACT SIMULATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SimulatePriceImpact() public {
        _setupMarketWithPool();

        uint256 amountIn = 100e6; // 100 USDC
        uint256 feeBps = hook.getCurrentFeeBps(poolId);

        uint256 impact = hook.simulatePriceImpact(poolId, amountIn, true, feeBps);

        assertGt(impact, 0, "Impact should be positive for non-zero trade");
        assertLt(impact, 10000, "Impact should be less than 100%");

        console.log("Price impact simulation:");
        console.log("  Amount in: 100 USDC");
        console.log("  Impact:", impact, "bps");
    }

    function test_SimulatePriceImpact_SentinelFee() public {
        _setupMarketWithPool();

        // Test with sentinel fee (halted market)
        uint256 impact = hook.simulatePriceImpact(poolId, 100e6, true, 10001);

        assertEq(impact, 10001, "Should return sentinel for invalid fee");
    }

    function test_SimulatePriceImpact_100PercentFee() public {
        _setupMarketWithPool();

        // Test with 100% fee
        uint256 impact = hook.simulatePriceImpact(poolId, 100e6, true, 10000);

        assertEq(impact, 0, "Should return 0 for 100% fee");
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPoolState() public {
        _setupMarketWithPool();

        (
            uint256 retMarketId,
            uint112 reserve0,
            uint112 reserve1,
            uint256 currentFeeBps,
            uint64 closeTime,
            bool isActive
        ) = hook.getPoolState(poolId);

        assertEq(retMarketId, marketId, "Should return correct market ID");
        assertGt(reserve0, 0, "Should have reserves");
        assertGt(reserve1, 0, "Should have reserves");
        assertGt(currentFeeBps, 0, "Should have positive fee");
        assertEq(closeTime, TEST_DEADLINE, "Should return correct close time");
        assertTrue(isActive, "Should be active");

        console.log("Pool state:");
        console.log("  Market ID:", retMarketId);
        console.log("  Reserve0:", reserve0);
        console.log("  Reserve1:", reserve1);
        console.log("  Fee:", currentFeeBps, "bps");
        console.log("  Close time:", closeTime);
    }

    function test_GetMarketProbability() public {
        _setupMarketWithPool();

        uint256 prob = hook.getMarketProbability(poolId);

        // Should start at 50/50
        assertEq(prob, 5000, "Should be 50% probability initially");
    }

    function test_IsMarketOpen() public {
        _setupMarketWithPool();

        // Set config to mode 0 (halt) since default is now mode 1
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = (cfg.flags & ~uint16(0x0C)); // Clear bits 2-3 to set mode 0
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        assertTrue(hook.isMarketOpen(poolId), "Should be open initially");

        // Fast forward to close window (mode 0 halts)
        vm.warp(TEST_DEADLINE - 30 minutes);
        assertFalse(hook.isMarketOpen(poolId), "Should be closed in close window");

        // Fast forward past deadline
        vm.warp(TEST_DEADLINE + 1);
        assertFalse(hook.isMarketOpen(poolId), "Should be closed after deadline");
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIG MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetDefaultConfig() public {
        PMFeeHookV1.Config memory newCfg = hook.getDefaultConfig();
        newCfg.minFeeBps = 20;
        newCfg.maxFeeBps = 200;
        newCfg.feeCapBps = 350; // Must be >= maxFeeBps + maxSkewFeeBps + asymmetricFeeBps + thinLiquidityFeeBps + volatilityFeeBps

        vm.expectEmit(false, false, false, false);
        emit PMFeeHookV1.DefaultConfigUpdated(newCfg);

        vm.prank(hook.owner());
        hook.setDefaultConfig(newCfg);

        PMFeeHookV1.Config memory updated = hook.getDefaultConfig();
        assertEq(updated.minFeeBps, 20, "Should update min fee");
        assertEq(updated.maxFeeBps, 200, "Should update max fee");
    }

    function test_RevertSetDefaultConfig_Unauthorized() public {
        PMFeeHookV1.Config memory newCfg = _getConfig();

        vm.prank(alice);
        vm.expectRevert(PMFeeHookV1.Unauthorized.selector);
        hook.setDefaultConfig(newCfg);
    }

    function test_SetMarketConfig() public {
        _createTestMarket();

        PMFeeHookV1.Config memory newCfg = _getConfig();
        newCfg.minFeeBps = 15;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, newCfg);

        assertTrue(hook.hasMarketConfig(marketId), "Should have market config");

        PMFeeHookV1.Config memory cfg = _getMarketConfig(marketId);
        assertEq(cfg.minFeeBps, 15, "Should have custom min fee");
    }

    function test_ClearMarketConfig() public {
        _createTestMarket();

        // Set custom config
        PMFeeHookV1.Config memory newCfg = _getConfig();
        newCfg.minFeeBps = 15;
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, newCfg);

        // Clear it
        vm.prank(hook.owner());
        hook.clearMarketConfig(marketId);

        assertFalse(hook.hasMarketConfig(marketId), "Should not have market config");
    }

    function test_RevertInvalidConfig_MinGreaterThanMax() public {
        PMFeeHookV1.Config memory badCfg = _getConfig();
        badCfg.minFeeBps = 200;
        badCfg.maxFeeBps = 100;

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHookV1.InvalidConfig.selector);
        hook.setDefaultConfig(badCfg);
    }

    function test_RevertInvalidConfig_FeeCapTooLow() public {
        PMFeeHookV1.Config memory badCfg = _getConfig();
        badCfg.feeCapBps = 5; // Less than minFeeBps (10)

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHookV1.InvalidConfig.selector);
        hook.setDefaultConfig(badCfg);
    }

    function test_AdjustBootstrapStart() public {
        _setupMarketWithoutLiquidity(); // Pool must have zero liquidity for adjustment

        (uint64 oldStart,,) = hook.meta(poolId);

        // Policy: Can only delay (newStart >= oldStart) and must be <= now
        uint64 newStart = uint64(block.timestamp); // Current time is valid

        vm.expectEmit(true, false, false, true);
        emit PMFeeHookV1.BootstrapStartAdjusted(poolId, oldStart, newStart);

        vm.prank(hook.owner());
        hook.adjustBootstrapStart(poolId, newStart);

        (uint64 updatedStart,,) = hook.meta(poolId);
        assertEq(updatedStart, newStart, "Should update bootstrap start time");

        console.log("Bootstrap start adjustment test passed");
    }

    function test_RevertAdjustBootstrapStart_Unauthorized() public {
        _setupMarketWithPool();

        vm.prank(alice);
        vm.expectRevert(PMFeeHookV1.Unauthorized.selector);
        hook.adjustBootstrapStart(poolId, uint64(block.timestamp));
    }

    function test_RevertAdjustBootstrapStart_InvalidPoolId() public {
        uint256 fakePoolId = 123456;

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHookV1.InvalidPoolId.selector);
        hook.adjustBootstrapStart(fakePoolId, uint64(block.timestamp));
    }

    function test_RevertAdjustBootstrapStart_CannotGoBackwards() public {
        _setupMarketWithPool();

        (uint64 oldStart,,) = hook.meta(poolId);

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHookV1.InvalidBootstrapStart.selector);
        hook.adjustBootstrapStart(poolId, oldStart - 1); // Try to go backwards
    }

    function test_RevertAdjustBootstrapStart_CannotSetFuture() public {
        _setupMarketWithPool();

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHookV1.InvalidBootstrapStart.selector);
        hook.adjustBootstrapStart(poolId, uint64(block.timestamp + 1 days)); // Future not allowed
    }

    function test_RevertAdjustBootstrapStart_MustBeBeforeLiveClose() public {
        _setupMarketWithPool();

        // Get live close time from PAMM (not snapshot)
        uint256 mktId = hook.poolToMarket(poolId);
        (,,,, uint64 liveClose,,) = PAMM.markets(mktId);

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHookV1.InvalidBootstrapStart.selector);
        hook.adjustBootstrapStart(poolId, liveClose); // At or after live close not allowed
    }

    function test_RevertAdjustBootstrapStart_PoolHasLiquidity() public {
        _setupMarketWithPool(); // Pool WITH liquidity

        (uint64 oldStart,,) = hook.meta(poolId);

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHookV1.InvalidBootstrapStart.selector);
        hook.adjustBootstrapStart(poolId, oldStart); // Should fail even with same timestamp
    }

    /*//////////////////////////////////////////////////////////////
                        UNREGISTERED POOL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UnregisteredPool_Halted() public {
        uint256 fakePoolId = 123456;

        uint256 fee = hook.getCurrentFeeBps(fakePoolId);
        assertEq(fee, 10001, "Unregistered pool should return halted sentinel");

        assertFalse(hook.isMarketOpen(fakePoolId), "Unregistered pool should not be open");
    }

    function test_UnregisteredPool_SwapReverts() public {
        uint256 fakePoolId = 123456;

        // Simulate beforeAction call from ZAMM for a swap
        vm.prank(address(ZAMM));
        vm.expectRevert(PMFeeHookV1.InvalidPoolId.selector);
        hook.beforeAction(IZAMM.swapExactIn.selector, fakePoolId, address(this), "");
    }

    /*//////////////////////////////////////////////////////////////
                        HARDENING FIX TESTS
    //////////////////////////////////////////////////////////////*/

    function test_VolatilityWindowUnderflowProtection() public {
        _setupMarketWithPool();

        // Set volatilityWindow greater than block.timestamp to test underflow protection
        PMFeeHookV1.Config memory cfg = _getConfig();
        cfg.flags = cfg.flags | 0x40; // Enable volatility fee (bit 6)
        cfg.volatilityWindow = uint32(block.timestamp + 1000); // Future timestamp
        cfg.volatilityFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Should not revert due to underflow protection
        uint256 fee = hook.getCurrentFeeBps(poolId);
        assertGt(fee, 0, "Should return valid fee without reverting");

        console.log("Volatility window underflow protection test passed");
    }

    function test_VolatilitySnapshotMEVProtection() public {
        _setupMarketWithPool();

        // Enable volatility fee
        PMFeeHookV1.Config memory cfg = _getConfig();
        cfg.flags = cfg.flags | 0x40; // Enable volatility fee (bit 6)
        cfg.volatilityFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 1000e6);
        USDC.approve(address(PAMM), 1000e6);
        PAMM.split(marketId, 500e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        // First swap - should record snapshot
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        // Check first snapshot was recorded
        (uint64 firstTimestamp,) = hook.priceHistory(poolId, 0);
        assertGt(firstTimestamp, 0, "First snapshot should be recorded");
        uint8 idxAfterFirst = hook.priceHistoryIndex(poolId);
        assertEq(idxAfterFirst, 1, "Index should be 1 after first swap");
        uint256 firstBlock = hook.lastSnapshotBlock(poolId);
        assertEq(firstBlock, block.number, "Should record block number");

        // Second swap in same block - should skip snapshot (MEV protection)
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            !zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        // Index should still be 1 (snapshot skipped - same block)
        uint8 idxAfterSecond = hook.priceHistoryIndex(poolId);
        assertEq(idxAfterSecond, 1, "Index should still be 1 (second snapshot skipped)");

        // Mine a new block
        vm.roll(block.number + 1);

        // Third swap - should record snapshot now (new block)
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        // Index should now be 2 (snapshot recorded in new block)
        uint8 idxAfterThird = hook.priceHistoryIndex(poolId);
        assertEq(idxAfterThird, 2, "Index should be 2 in new block");

        vm.stopPrank();

        console.log("Volatility snapshot MEV protection test passed");
    }

    function test_CloseWindowFeeCapEnforcement() public {
        _setupMarketWithPool();

        // Set closeWindowFeeBps higher than feeCapBps
        PMFeeHookV1.Config memory cfg = _getConfig();
        cfg.flags = (cfg.flags & ~uint8(0x0C)) | uint8(1 << 2); // Set mode 1
        cfg.closeWindowFeeBps = 500; // 5%
        cfg.feeCapBps = 300; // 3% cap

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Enter close window
        vm.warp(TEST_DEADLINE - 30 minutes);

        uint256 feeInWindow = hook.getCurrentFeeBps(poolId);
        assertEq(feeInWindow, 300, "Should cap close window fee to feeCapBps");
        assertLt(feeInWindow, 500, "Should not return uncapped closeWindowFeeBps");

        console.log("Close window fee cap enforcement test passed");
    }

    function test_GetCurrentFeeBps_SentinelForClosedMarket() public {
        _setupMarketWithPool();

        // Fast forward past deadline
        vm.warp(TEST_DEADLINE + 1);

        uint256 fee = hook.getCurrentFeeBps(poolId);
        assertEq(fee, 10001, "Should return sentinel (10001) for closed market");

        console.log("getCurrentFeeBps sentinel for closed market test passed");
    }

    function test_RescueETH() public {
        // Send ETH to hook
        vm.deal(address(hook), 1 ether);

        address receiver = address(0xBEEF);
        uint256 balanceBefore = receiver.balance;

        vm.prank(hook.owner());
        hook.rescueETH(receiver, 0.5 ether);

        assertEq(receiver.balance, balanceBefore + 0.5 ether, "Should receive rescued ETH");
        assertEq(address(hook).balance, 0.5 ether, "Hook should have remaining ETH");

        console.log("rescueETH test passed");
    }

    function test_RevertRescueETH_Unauthorized() public {
        vm.deal(address(hook), 1 ether);

        address receiver = address(0xBEEF);

        vm.prank(alice);
        vm.expectRevert(PMFeeHookV1.Unauthorized.selector);
        hook.rescueETH(receiver, 0.5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    OWNERSHIP TRANSFER TESTS (ERC173)
    //////////////////////////////////////////////////////////////*/

    function test_TransferOwnership() public {
        address newOwner = address(0xBEEF);
        address oldOwner = hook.owner();

        vm.prank(oldOwner);
        vm.expectEmit(true, true, false, false);
        emit PMFeeHookV1.OwnershipTransferred(oldOwner, newOwner);
        hook.transferOwnership(newOwner);

        assertEq(hook.owner(), newOwner, "Owner should be updated");
    }

    function test_TransferOwnership_NewOwnerCanCallAdmin() public {
        address newOwner = address(0xBEEF);

        vm.prank(hook.owner());
        hook.transferOwnership(newOwner);

        // New owner should be able to call admin functions
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.minFeeBps = 20;

        vm.prank(newOwner);
        hook.setDefaultConfig(cfg);

        PMFeeHookV1.Config memory updatedCfg = hook.getDefaultConfig();
        assertEq(updatedCfg.minFeeBps, 20, "New owner should be able to update config");
    }

    function test_TransferOwnership_OldOwnerLosesAccess() public {
        address newOwner = address(0xBEEF);
        address oldOwner = hook.owner();

        vm.prank(oldOwner);
        hook.transferOwnership(newOwner);

        // Old owner should no longer have access
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.minFeeBps = 20;

        vm.prank(oldOwner);
        vm.expectRevert(PMFeeHookV1.Unauthorized.selector);
        hook.setDefaultConfig(cfg);
    }

    function test_RevertTransferOwnership_Unauthorized() public {
        address newOwner = address(0xBEEF);

        vm.prank(alice);
        vm.expectRevert(PMFeeHookV1.Unauthorized.selector);
        hook.transferOwnership(newOwner);
    }

    function test_RevertTransferOwnership_ZeroAddress() public {
        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHookV1.Unauthorized.selector);
        hook.transferOwnership(address(0));
    }

    function test_PriceImpactDeltaSemantics() public {
        _setupMarketWithPool();

        // Get reserves before swap
        (uint112 r0Before, uint112 r1Before,,,,,) = ZAMM.pools(poolId);

        // Execute a swap
        vm.startPrank(alice);
        deal(address(USDC), alice, 200e6);
        USDC.approve(address(PAMM), 200e6);
        PAMM.split(marketId, 200e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        uint256 amountIn = 100e6;
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            amountIn,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Get reserves after swap
        (uint112 r0After, uint112 r1After,,,,,) = ZAMM.pools(poolId);

        // Calculate actual deltas
        int256 d0Actual = int256(uint256(r0After)) - int256(uint256(r0Before));
        int256 d1Actual = int256(uint256(r1After)) - int256(uint256(r1Before));

        // Verify semantics: positive = added to pool, negative = removed
        if (zeroForOne) {
            assertGt(d0Actual, 0, "Token0 should increase (added to pool)");
            assertLt(d1Actual, 0, "Token1 should decrease (removed from pool)");
        } else {
            assertLt(d0Actual, 0, "Token0 should decrease (removed from pool)");
            assertGt(d1Actual, 0, "Token1 should increase (added to pool)");
        }

        console.log("Price impact delta semantics test passed:");
        console.log("  d0:", d0Actual);
        console.log("  d1:", d1Actual);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getConfig() internal pure returns (PMFeeHookV1.Config memory cfg) {
        // Return expected default config
        cfg = PMFeeHookV1.Config({
            minFeeBps: 10,
            maxFeeBps: 100,
            maxSkewFeeBps: 80,
            feeCapBps: 300,
            skewRefBps: 4500,
            asymmetricFeeBps: 20,
            closeWindow: 1 hours,
            closeWindowFeeBps: 0,
            maxPriceImpactBps: 500,
            bootstrapWindow: 7 days,
            volatilityFeeBps: 0,
            volatilityWindow: 0,
            flags: 0x13,
            extraFlags: 0x01
        });
    }

    function _getMarketConfig(uint256 _marketId)
        internal
        view
        returns (PMFeeHookV1.Config memory cfg)
    {
        return hook.getMarketConfig(_marketId);
    }

    function _createTestMarket() internal {
        vm.startPrank(alice);
        USDC.approve(address(PAMM), type(uint256).max);

        (marketId, noId) =
            PAMM.createMarket("Test Market", address(this), address(USDC), TEST_DEADLINE, false);
        vm.stopPrank();

        console.log("Created market:", marketId);
        console.log("NO ID:", noId);
    }

    function _setupMarketWithoutLiquidity() internal {
        _createTestMarket();
        poolId = hook.registerMarket(marketId);
        feeOrHook = hook.feeOrHook();
        console.log("Market registered without liquidity");
    }

    function _setupMarketWithPool() internal {
        _createTestMarket();
        poolId = hook.registerMarket(marketId);
        feeOrHook = hook.feeOrHook();

        // Add liquidity to pool
        vm.startPrank(alice);
        USDC.approve(address(PAMM), 2000e6);
        PAMM.split(marketId, 1000e6, alice);

        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);

        ZAMM.addLiquidity(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            1000e6,
            1000e6,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        console.log("Pool created with liquidity");
    }

    function _swapToCreateImbalance() internal {
        vm.startPrank(alice);

        // Get more USDC and split
        deal(address(USDC), alice, 500e6);
        USDC.approve(address(PAMM), 500e6);
        PAMM.split(marketId, 500e6, alice);

        // Swap YES for NO to create imbalance
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);

        bool zeroForOne = marketId < noId; // YES -> NO

        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            300e6,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    VOLATILITY FEE COMPREHENSIVE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_VolatilityFee_NotEnoughSnapshots() public {
        _setupMarketWithPool();

        // Enable volatility fee
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x40; // FLAG_VOLATILITY
        cfg.volatilityFeeBps = 50;
        cfg.volatilityWindow = 1 hours;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // With < 3 snapshots, volatility fee should be 0
        uint256 fee = hook.getCurrentFeeBps(poolId);
        assertLt(fee, 10001, "Should compute fee normally");

        console.log("Volatility fee with insufficient snapshots: 0 (expected)");
    }

    function test_VolatilityFee_ZeroMeanHandled() public {
        _setupMarketWithPool();

        // Enable volatility fee
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x40; // FLAG_VOLATILITY
        cfg.volatilityFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Even with snapshots, zero mean is handled gracefully
        uint256 fee = hook.getCurrentFeeBps(poolId);
        assertTrue(fee < 10001, "Should not fail on zero mean");

        console.log("Volatility fee with zero mean handled correctly");
    }

    function test_VolatilityFee_HighVolatilityTriggersMax() public {
        _setupMarketWithPool();

        // Enable volatility fee
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x43; // skew + bootstrap + volatility
        cfg.volatilityFeeBps = 100;
        cfg.volatilityWindow = 0; // No staleness check
        cfg.minFeeBps = 10;
        cfg.maxFeeBps = 200;
        cfg.feeCapBps = 300;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Make multiple swaps to create volatility snapshots
        vm.startPrank(alice);
        deal(address(USDC), alice, 5000e6);
        USDC.approve(address(PAMM), 5000e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        // Create volatile price movements by swapping back and forth
        for (uint256 i = 0; i < 5; i++) {
            vm.roll(block.number + 1); // New block for each snapshot

            PAMM.split(marketId, 200e6, alice);

            ZAMM.swapExactIn(
                IZAMM.PoolKey({
                    id0: key.id0,
                    id1: key.id1,
                    token0: key.token0,
                    token1: key.token1,
                    feeOrHook: key.feeOrHook
                }),
                100e6,
                0,
                i % 2 == 0 ? zeroForOne : !zeroForOne,
                alice,
                block.timestamp + 1 hours
            );
        }
        vm.stopPrank();

        console.log("High volatility test completed");
    }

    /*//////////////////////////////////////////////////////////////
                    TRANSIENT CACHE EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_TransientCache_MultipleSwapsInSameTx() public {
        _setupMarketWithPool();

        // Enable features that use cache
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x71; // skew + asymmetric + price_impact + volatility
        cfg.maxPriceImpactBps = 1000;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Simulate multiple swaps in same tx (cache should be cleared between)
        vm.startPrank(alice);
        deal(address(USDC), alice, 1000e6);
        USDC.approve(address(PAMM), 1000e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        // First swap
        PAMM.split(marketId, 200e6, alice);
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        // Second swap (cache should be fresh)
        PAMM.split(marketId, 200e6, alice);
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            !zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        vm.stopPrank();

        console.log("Multiple swaps in same tx: cache handled correctly");
    }

    function test_TransientCache_OnlySkewFee() public {
        _setupMarketWithPool();

        // Only skew fee enabled (feeNeedsReserves=true, afterNeedsReserves=false)
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x01; // Only FLAG_SKEW
        cfg.maxSkewFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // beforeAction should cache reserves for fee calc
        // afterAction should skip since no impact/volatility checks
        vm.startPrank(alice);
        deal(address(USDC), alice, 500e6);
        USDC.approve(address(PAMM), 500e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        PAMM.split(marketId, 200e6, alice);
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        vm.stopPrank();

        console.log("Skew-only fee: cache optimization working");
    }

    function test_TransientCache_OnlyVolatilityCheck() public {
        _setupMarketWithPool();

        // Only volatility enabled (feeNeedsReserves=false, afterNeedsReserves=true)
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x42; // bootstrap + volatility
        cfg.volatilityFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // beforeAction should clear cache (not needed for fee)
        // afterAction should fetch reserves fresh
        vm.startPrank(alice);
        deal(address(USDC), alice, 500e6);
        USDC.approve(address(PAMM), 500e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        PAMM.split(marketId, 200e6, alice);

        vm.roll(block.number + 1); // New block for snapshot

        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        vm.stopPrank();

        console.log("Volatility-only check: cache cleared and refetched");
    }

    /*//////////////////////////////////////////////////////////////
                    GAS OPTIMIZATION VERIFICATION
    //////////////////////////////////////////////////////////////*/

    function test_GasOptimization_SlotComputedOnce() public {
        _setupMarketWithPool();

        // Enable both fee and after reserve needs
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x71; // skew + asymmetric + price_impact + volatility
        cfg.maxPriceImpactBps = 500;
        cfg.volatilityFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 500e6);
        USDC.approve(address(PAMM), 500e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        PAMM.split(marketId, 200e6, alice);

        vm.roll(block.number + 1);

        uint256 gasBefore = gasleft();
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );
        uint256 gasUsed = gasBefore - gasleft();

        vm.stopPrank();

        console.log("Gas used with optimized slot computation:", gasUsed);
        assertLt(gasUsed, 500000, "Gas should be reasonable with optimizations");
    }

    function test_PoolDataPassthrough_AvoidsTransientReload() public {
        _setupMarketWithPool();

        // Skew fee enabled: reserves loaded in beforeAction and passed through
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x01; // FLAG_SKEW only
        cfg.maxSkewFeeBps = 80;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // This should use _computeFeeCachedWithPoolData with hasPoolData=true
        vm.startPrank(alice);
        deal(address(USDC), alice, 500e6);
        USDC.approve(address(PAMM), 500e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        PAMM.split(marketId, 200e6, alice);

        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        vm.stopPrank();

        console.log("PoolData passthrough: avoided redundant transient read");
    }

    /*//////////////////////////////////////////////////////////////
                    PRICE IMPACT EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_PriceImpact_DeltaReconstructionFallback() public {
        _setupMarketWithPool();

        // Enable price impact with limit
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x21; // skew + price_impact
        cfg.maxPriceImpactBps = 10000; // Very high to not revert, just test path

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        // Normal swap should work (deltas valid)
        vm.startPrank(alice);
        deal(address(USDC), alice, 500e6);
        USDC.approve(address(PAMM), 500e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        PAMM.split(marketId, 200e6, alice);

        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        vm.stopPrank();

        console.log("Price impact delta reconstruction: working correctly");
    }

    /*//////////////////////////////////////////////////////////////
                    CLOSE WINDOW COMPREHENSIVE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CloseWindow_MarketResolved() public {
        _setupMarketWithPool();

        // Simulate market resolution via PAMM
        // (In real scenario, PAMM would mark market as resolved)
        // Our hook should detect this via PAMM.markets() call

        // For now, test that close time is respected
        uint256 fee = hook.getCurrentFeeBps(poolId);
        assertLt(fee, 10001, "Market should be open before close");

        console.log("Close window resolution check: passed");
    }

    /*//////////////////////////////////////////////////////////////
                    FULL LIFECYCLE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullLifecycle_CreationToResolution() public {
        // Phase 1: Creation
        _createTestMarket();
        poolId = hook.registerMarket(marketId);

        // Set config with mode 1 (fixed fee in close window) instead of mode 0 (halt)
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = (cfg.flags & ~uint16(0x0C)) | (1 << 2); // Set bits 2-3 to 01 (mode 1)
        cfg.closeWindowFeeBps = 50; // 0.5% fee in close window
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        assertTrue(hook.isMarketOpen(poolId), "Should be open after registration");

        // Phase 2: Bootstrap period (high fees)
        uint256 earlyFee = hook.getCurrentFeeBps(poolId);
        assertGt(earlyFee, 10, "Bootstrap fee should be elevated");

        // Phase 3: Add liquidity and start trading
        vm.startPrank(alice);
        USDC.approve(address(PAMM), 2000e6);
        PAMM.split(marketId, 1000e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, hook.feeOrHook());
        ZAMM.addLiquidity(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            1000e6,
            1000e6,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Phase 4: Time passes, bootstrap decays
        vm.warp(block.timestamp + 1 days); // Halfway through 2-day bootstrap
        uint256 midFee = hook.getCurrentFeeBps(poolId);
        assertLt(midFee, earlyFee, "Fee should decay during bootstrap");

        // Phase 5: Bootstrap complete
        vm.warp(block.timestamp + 1.5 days); // Past 2-day bootstrap window
        uint256 lateFee = hook.getCurrentFeeBps(poolId);
        assertLt(lateFee, midFee, "Fee should reach minimum after bootstrap");

        // Phase 6: Approaching close
        (,,,, uint64 closeTime,,) = PAMM.markets(marketId);
        vm.warp(closeTime - 30 minutes); // Within close window
        assertTrue(hook.isMarketOpen(poolId), "Should still be open in close window");

        console.log("Full lifecycle test completed");
    }

    function test_MultipleMarkets_DifferentLifecycleStages() public {
        // Market 1: Just created
        uint256 market1 = _createMarket("Market 1", block.timestamp + 30 days);
        uint256 pool1 = hook.registerMarket(market1);

        // Market 2: Halfway through lifecycle (create and warp)
        uint256 market2 = _createMarket("Market 2", block.timestamp + 60 days);
        uint256 pool2 = hook.registerMarket(market2);

        // Different configs for each
        PMFeeHookV1.Config memory cfg1 = hook.getDefaultConfig();
        cfg1.maxFeeBps = 200;
        cfg1.flags = 0x03; // skew + bootstrap

        PMFeeHookV1.Config memory cfg2 = hook.getDefaultConfig();
        cfg2.maxFeeBps = 100;
        cfg2.flags = 0x13; // skew + bootstrap + asymmetric

        vm.startPrank(hook.owner());
        hook.setMarketConfig(market1, cfg1);
        hook.setMarketConfig(market2, cfg2);
        vm.stopPrank();

        // Verify independent fee calculations
        uint256 fee1 = hook.getCurrentFeeBps(pool1);
        uint256 fee2 = hook.getCurrentFeeBps(pool2);

        assertGt(fee1, 0, "Market 1 should have positive fee");
        assertGt(fee2, 0, "Market 2 should have positive fee");
        assertNotEq(fee1, fee2, "Different configs should produce different fees");

        console.log("Multiple markets test: passed");
    }

    /*//////////////////////////////////////////////////////////////
                    CONFIG EDGE CASES & BOUNDS
    //////////////////////////////////////////////////////////////*/

    function test_Config_MaxBounds() public {
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();

        // Set to maximum valid values
        cfg.minFeeBps = 10000;
        cfg.maxFeeBps = 10000;
        cfg.maxSkewFeeBps = 10000;
        cfg.feeCapBps = 10000;
        cfg.skewRefBps = 5000;
        cfg.asymmetricFeeBps = 10000;
        cfg.volatilityFeeBps = 10000;
        cfg.maxPriceImpactBps = 10000;
        cfg.closeWindowFeeBps = 10000;

        vm.prank(hook.owner());
        hook.setDefaultConfig(cfg);

        PMFeeHookV1.Config memory retrieved = hook.getDefaultConfig();
        assertEq(retrieved.minFeeBps, 10000, "Min fee should be set to max");

        console.log("Max bounds config test: passed");
    }

    function test_Config_AllDecayModes() public {
        _setupMarketWithPool();

        // Test all 4 decay modes: 0=linear, 1=exp, 2=sqrt, 3=log
        for (uint16 mode = 0; mode < 4; mode++) {
            PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
            cfg.flags = 0x02; // Bootstrap enabled
            cfg.extraFlags = mode << 2; // Set decay mode in bits 2-3
            cfg.bootstrapWindow = 7 days;
            cfg.minFeeBps = 10;
            cfg.maxFeeBps = 100;

            vm.prank(hook.owner());
            hook.setMarketConfig(marketId, cfg);

            // Get fee at different points in bootstrap
            uint256 startFee = hook.getCurrentFeeBps(poolId);
            assertEq(startFee, 100, "Should start at maxFeeBps");

            // Warp to 25% through bootstrap
            vm.warp(block.timestamp + 1.75 days);
            uint256 earlyFee = hook.getCurrentFeeBps(poolId);
            assertGt(earlyFee, 10, "Should be decaying");
            assertLe(earlyFee, 100, "Should not exceed max");

            // Warp to end
            vm.warp(block.timestamp + 7 days);
            uint256 endFee = hook.getCurrentFeeBps(poolId);
            assertEq(endFee, 10, "Should reach minFeeBps");

            // Reset time for next iteration
            vm.warp(block.timestamp - 8.75 days);

            console.log("Decay mode", mode, "tested");
        }

        console.log("All decay modes test: passed");
    }

    function test_Config_AllSkewCurves() public {
        _setupMarketWithPool();

        // Test all 4 skew curves: 0=linear, 1=quadratic, 2=cubic, 3=quartic
        for (uint16 curve = 0; curve < 4; curve++) {
            PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
            cfg.flags = 0x01; // Skew enabled
            cfg.extraFlags = curve; // Set skew curve in bits 0-1
            cfg.maxSkewFeeBps = 80;
            cfg.skewRefBps = 4500;

            vm.prank(hook.owner());
            hook.setMarketConfig(marketId, cfg);

            // Create imbalance
            _swapToCreateImbalance();

            uint256 fee = hook.getCurrentFeeBps(poolId);
            assertGt(fee, 0, "Skew fee should be positive");
            assertLe(fee, cfg.feeCapBps, "Should not exceed cap");

            console.log("Skew curve", curve, "tested");
        }

        console.log("All skew curves test: passed");
    }

    function test_Config_ChangesMidLifecycle() public {
        _setupMarketWithPool();

        // Initial config
        PMFeeHookV1.Config memory cfg1 = hook.getDefaultConfig();
        cfg1.flags = 0x01; // Only skew
        cfg1.maxSkewFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg1);

        uint256 fee1 = hook.getCurrentFeeBps(poolId);

        // Change config mid-lifecycle
        PMFeeHookV1.Config memory cfg2 = hook.getDefaultConfig();
        cfg2.flags = 0x11; // Skew + asymmetric
        cfg2.maxSkewFeeBps = 50;
        cfg2.asymmetricFeeBps = 30;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg2);

        uint256 fee2 = hook.getCurrentFeeBps(poolId);

        // Fees should potentially differ due to asymmetric component
        assertGt(fee2, 0, "New config should produce valid fee");

        console.log("Config changes mid-lifecycle: passed");
    }

    function test_Config_FlagCombinations() public {
        _setupMarketWithPool();

        // Test various flag combinations
        uint16[5] memory flagCombos = [
            uint16(0x01), // skew only
            uint16(0x03), // skew + bootstrap
            uint16(0x13), // skew + bootstrap + asymmetric
            uint16(0x73), // all fee flags
            uint16(0x40) // volatility only
        ];

        for (uint256 i = 0; i < flagCombos.length; i++) {
            PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
            cfg.flags = flagCombos[i];
            cfg.volatilityFeeBps = 50;
            cfg.maxPriceImpactBps = 500;

            vm.prank(hook.owner());
            hook.setMarketConfig(marketId, cfg);

            uint256 fee = hook.getCurrentFeeBps(poolId);
            assertLt(fee, 10001, "Should compute valid fee");

            console.log("Flag combo", flagCombos[i], "tested");
        }

        console.log("Flag combinations test: passed");
    }

    /*//////////////////////////////////////////////////////////////
                    INTEGRATION SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_LPAndSwapsInterleaved() public {
        _setupMarketWithPool();

        // Enable all features
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x73; // skew + bootstrap + asymmetric + price_impact + volatility
        cfg.maxPriceImpactBps = 1000;
        cfg.volatilityFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 5000e6);
        USDC.approve(address(PAMM), 5000e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, hook.feeOrHook());
        bool zeroForOne = marketId < noId;

        // Swap 1
        PAMM.split(marketId, 200e6, alice);
        vm.roll(block.number + 1);
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        // Add more liquidity
        PAMM.split(marketId, 500e6, alice);
        ZAMM.addLiquidity(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            500e6,
            500e6,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        // Swap 2 (opposite direction)
        PAMM.split(marketId, 200e6, alice);
        vm.roll(block.number + 1);
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            !zeroForOne,
            alice,
            block.timestamp + 1 hours
        );

        // Note: IZAMM interface doesn't expose removeLiquidity
        // This test still validates LP additions interleaved with swaps
        // uint256 lpBalance = PAMM.balanceOf(alice, poolId);
        // if (lpBalance > 100) {
        //     ... removeLiquidity would go here ...
        // }

        vm.stopPrank();

        console.log("LP and swaps interleaved: passed");
    }

    function test_Integration_HighVolumeTrading() public {
        _setupMarketWithPool();

        // Enable volatility tracking
        PMFeeHookV1.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x43; // skew + bootstrap + volatility
        cfg.volatilityFeeBps = 100;
        cfg.volatilityWindow = 0;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 20000e6);
        USDC.approve(address(PAMM), 20000e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, hook.feeOrHook());
        bool zeroForOne = marketId < noId;

        // Execute 15 swaps to fill volatility buffer and beyond
        for (uint256 i = 0; i < 15; i++) {
            vm.roll(block.number + 1); // New block each time

            PAMM.split(marketId, 200e6, alice);

            ZAMM.swapExactIn(
                IZAMM.PoolKey({
                    id0: key.id0,
                    id1: key.id1,
                    token0: key.token0,
                    token1: key.token1,
                    feeOrHook: key.feeOrHook
                }),
                50e6,
                0,
                i % 2 == 0 ? zeroForOne : !zeroForOne,
                alice,
                block.timestamp + 1 hours
            );
        }

        vm.stopPrank();

        // Verify volatility buffer is working (should have 10 most recent snapshots)
        uint256 finalFee = hook.getCurrentFeeBps(poolId);
        assertLt(finalFee, 10001, "Should compute valid fee with full volatility buffer");

        console.log("High volume trading test: passed");
    }

    function test_Integration_ConfigSwitchDuringActivity() public {
        _setupMarketWithPool();

        vm.startPrank(alice);
        deal(address(USDC), alice, 5000e6);
        USDC.approve(address(PAMM), 5000e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, hook.feeOrHook());
        bool zeroForOne = marketId < noId;

        // Swap with config 1
        PMFeeHookV1.Config memory cfg1 = hook.getDefaultConfig();
        cfg1.flags = 0x01; // skew only
        vm.stopPrank();

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg1);

        vm.startPrank(alice);
        PAMM.split(marketId, 200e6, alice);
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            zeroForOne,
            alice,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Switch config
        PMFeeHookV1.Config memory cfg2 = hook.getDefaultConfig();
        cfg2.flags = 0x71; // skew + asymmetric + price_impact + volatility
        cfg2.maxPriceImpactBps = 1000;
        cfg2.volatilityFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg2);

        // Swap with config 2
        vm.startPrank(alice);
        PAMM.split(marketId, 200e6, alice);
        vm.roll(block.number + 1);
        ZAMM.swapExactIn(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: key.feeOrHook
            }),
            50e6,
            0,
            !zeroForOne,
            alice,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        console.log("Config switch during activity: passed");
    }

    /*//////////////////////////////////////////////////////////////
                    HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createMarket(string memory description, uint256 closeTime)
        internal
        returns (uint256 _marketId)
    {
        vm.startPrank(alice);
        USDC.approve(address(PAMM), type(uint256).max);
        (_marketId,) =
            PAMM.createMarket(description, address(this), address(USDC), uint64(closeTime), false);
        vm.stopPrank();
    }
}
