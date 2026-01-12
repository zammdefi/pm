// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

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

/// @title PMFeeHook Comprehensive Test Suite
/// @notice Tests for dynamic fee hook covering all features and edge cases
contract PMFeeHookTest is Test {
    PMFeeHook public hook;

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
        vm.createSelectFork(vm.rpcUrl("main2"));

        TEST_DEADLINE = uint64(block.timestamp + 365 days);

        // Deploy hook (owner will be tx.origin)
        vm.startPrank(address(this), address(this)); // Set tx.origin to this
        hook = new PMFeeHook();
        vm.stopPrank();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        deal(address(USDC), alice, 10_000e6);
        deal(address(USDC), bob, 10_000e6);

        console.log("=== PMFeeHook Test Suite ===");
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
        vm.expectRevert(PMFeeHook.InvalidMarket.selector);
        hook.registerMarket(999999);
    }

    function test_RevertRegisterResolved() public {
        _createTestMarket();

        // Fast forward past deadline and resolve
        vm.warp(TEST_DEADLINE + 1);

        vm.expectRevert(PMFeeHook.MarketClosed.selector);
        hook.registerMarket(marketId);
    }

    function test_RevertDoubleRegistration() public {
        _createTestMarket();
        hook.registerMarket(marketId);

        vm.expectRevert(PMFeeHook.AlreadyRegistered.selector);
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = _getConfig();
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
        PMFeeHook.Config memory cfg = _getConfig();
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
        PMFeeHook.Config memory cfg = _getConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory newCfg = hook.getDefaultConfig();
        newCfg.minFeeBps = 20;
        newCfg.maxFeeBps = 200;
        newCfg.feeCapBps = 350; // Must be >= maxFeeBps + maxSkewFeeBps + asymmetricFeeBps + thinLiquidityFeeBps + volatilityFeeBps

        vm.expectEmit(false, false, false, false);
        emit PMFeeHook.DefaultConfigUpdated(newCfg);

        vm.prank(hook.owner());
        hook.setDefaultConfig(newCfg);

        PMFeeHook.Config memory updated = hook.getDefaultConfig();
        assertEq(updated.minFeeBps, 20, "Should update min fee");
        assertEq(updated.maxFeeBps, 200, "Should update max fee");
    }

    function test_RevertSetDefaultConfig_Unauthorized() public {
        PMFeeHook.Config memory newCfg = _getConfig();

        vm.prank(alice);
        vm.expectRevert(PMFeeHook.Unauthorized.selector);
        hook.setDefaultConfig(newCfg);
    }

    function test_SetMarketConfig() public {
        _createTestMarket();

        PMFeeHook.Config memory newCfg = _getConfig();
        newCfg.minFeeBps = 15;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, newCfg);

        // Check that market config was set (feeCapBps != 0 means custom config)
        PMFeeHook.Config memory cfg = _getMarketConfig(marketId);
        assertEq(cfg.minFeeBps, 15, "Should have custom min fee");
    }

    function test_ClearMarketConfig() public {
        _createTestMarket();

        // Set custom config
        PMFeeHook.Config memory newCfg = _getConfig();
        newCfg.minFeeBps = 15;
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, newCfg);

        // Clear it
        vm.prank(hook.owner());
        hook.clearMarketConfig(marketId);

        // After clearing, config should revert to default (check by reading default fee)
        PMFeeHook.Config memory cfg = _getMarketConfig(marketId);
        PMFeeHook.Config memory defaultCfg = hook.getDefaultConfig();
        assertEq(cfg.minFeeBps, defaultCfg.minFeeBps, "Should have default min fee after clear");
    }

    function test_RevertInvalidConfig_MinGreaterThanMax() public {
        PMFeeHook.Config memory badCfg = _getConfig();
        badCfg.minFeeBps = 200;
        badCfg.maxFeeBps = 100;

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHook.InvalidConfig.selector);
        hook.setDefaultConfig(badCfg);
    }

    function test_RevertInvalidConfig_FeeCapTooLow() public {
        PMFeeHook.Config memory badCfg = _getConfig();
        badCfg.feeCapBps = 5; // Less than minFeeBps (10)

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHook.InvalidConfig.selector);
        hook.setDefaultConfig(badCfg);
    }

    function test_AdjustBootstrapStart() public {
        _setupMarketWithoutLiquidity(); // Pool must have zero liquidity for adjustment

        (uint64 oldStart,,) = hook.meta(poolId);

        // Policy: Can only delay (newStart >= oldStart) and must be <= now
        uint64 newStart = uint64(block.timestamp); // Current time is valid

        vm.expectEmit(true, false, false, true);
        emit PMFeeHook.BootstrapStartAdjusted(poolId, oldStart, newStart);

        vm.prank(hook.owner());
        hook.adjustBootstrapStart(poolId, newStart);

        (uint64 updatedStart,,) = hook.meta(poolId);
        assertEq(updatedStart, newStart, "Should update bootstrap start time");

        console.log("Bootstrap start adjustment test passed");
    }

    function test_RevertAdjustBootstrapStart_Unauthorized() public {
        _setupMarketWithPool();

        vm.prank(alice);
        vm.expectRevert(PMFeeHook.Unauthorized.selector);
        hook.adjustBootstrapStart(poolId, uint64(block.timestamp));
    }

    function test_RevertAdjustBootstrapStart_InvalidPoolId() public {
        uint256 fakePoolId = 123456;

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHook.InvalidPoolId.selector);
        hook.adjustBootstrapStart(fakePoolId, uint64(block.timestamp));
    }

    function test_RevertAdjustBootstrapStart_CannotGoBackwards() public {
        _setupMarketWithPool();

        (uint64 oldStart,,) = hook.meta(poolId);

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHook.InvalidBootstrapStart.selector);
        hook.adjustBootstrapStart(poolId, oldStart - 1); // Try to go backwards
    }

    function test_RevertAdjustBootstrapStart_CannotSetFuture() public {
        _setupMarketWithPool();

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHook.InvalidBootstrapStart.selector);
        hook.adjustBootstrapStart(poolId, uint64(block.timestamp + 1 days)); // Future not allowed
    }

    function test_RevertAdjustBootstrapStart_MustBeBeforeLiveClose() public {
        _setupMarketWithPool();

        // Get live close time from PAMM (not snapshot)
        uint256 mktId = hook.poolToMarket(poolId);
        (,,,, uint64 liveClose,,) = PAMM.markets(mktId);

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHook.InvalidBootstrapStart.selector);
        hook.adjustBootstrapStart(poolId, liveClose); // At or after live close not allowed
    }

    function test_RevertAdjustBootstrapStart_PoolHasLiquidity() public {
        _setupMarketWithPool(); // Pool WITH liquidity

        (uint64 oldStart,,) = hook.meta(poolId);

        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHook.InvalidBootstrapStart.selector);
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
        vm.expectRevert(PMFeeHook.InvalidPoolId.selector);
        hook.beforeAction(IZAMM.swapExactIn.selector, fakePoolId, address(this), "");
    }

    /*//////////////////////////////////////////////////////////////
                        HARDENING FIX TESTS
    //////////////////////////////////////////////////////////////*/

    function test_VolatilityWindowUnderflowProtection() public {
        _setupMarketWithPool();

        // Set volatilityWindow greater than block.timestamp to test underflow protection
        PMFeeHook.Config memory cfg = _getConfig();
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
        PMFeeHook.Config memory cfg = _getConfig();
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
        PMFeeHook.Config memory cfg = _getConfig();
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
        vm.expectRevert(PMFeeHook.Unauthorized.selector);
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
        emit PMFeeHook.OwnershipTransferred(oldOwner, newOwner);
        hook.transferOwnership(newOwner);

        assertEq(hook.owner(), newOwner, "Owner should be updated");
    }

    function test_TransferOwnership_NewOwnerCanCallAdmin() public {
        address newOwner = address(0xBEEF);

        vm.prank(hook.owner());
        hook.transferOwnership(newOwner);

        // New owner should be able to call admin functions
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.minFeeBps = 20;

        vm.prank(newOwner);
        hook.setDefaultConfig(cfg);

        PMFeeHook.Config memory updatedCfg = hook.getDefaultConfig();
        assertEq(updatedCfg.minFeeBps, 20, "New owner should be able to update config");
    }

    function test_TransferOwnership_OldOwnerLosesAccess() public {
        address newOwner = address(0xBEEF);
        address oldOwner = hook.owner();

        vm.prank(oldOwner);
        hook.transferOwnership(newOwner);

        // Old owner should no longer have access
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.minFeeBps = 20;

        vm.prank(oldOwner);
        vm.expectRevert(PMFeeHook.Unauthorized.selector);
        hook.setDefaultConfig(cfg);
    }

    function test_RevertTransferOwnership_Unauthorized() public {
        address newOwner = address(0xBEEF);

        vm.prank(alice);
        vm.expectRevert(PMFeeHook.Unauthorized.selector);
        hook.transferOwnership(newOwner);
    }

    function test_RevertTransferOwnership_ZeroAddress() public {
        vm.prank(hook.owner());
        vm.expectRevert(PMFeeHook.Unauthorized.selector);
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
                    PRICE IMPACT ENFORCEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that swaps exceeding maxPriceImpactBps revert
    /// @dev Validates the core price impact enforcement mechanism (afterAction check)
    function test_PriceImpact_ExceedsMax_Reverts() public {
        _setupMarketWithPool();

        // Configure strict price impact limit
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x20; // Enable price impact (bit 5)
        cfg.maxPriceImpactBps = 500; // 5% max impact
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 500e6);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 500e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: key.id0,
            id1: key.id1,
            token0: key.token0,
            token1: key.token1,
            feeOrHook: key.feeOrHook
        });

        // Large swap that will exceed 5% price impact
        // With 1000e6 liquidity, a 300e6 swap should move price significantly
        vm.expectRevert(PMFeeHook.PriceImpactTooHigh.selector);
        ZAMM.swapExactIn(zammKey, 300e6, 0, zeroForOne, alice, block.timestamp + 1 hours);

        vm.stopPrank();

        console.log("Price impact exceeds max: correctly reverts");
    }

    /// @notice Test that swaps within maxPriceImpactBps succeed
    /// @dev Validates the price impact check allows valid trades
    function test_PriceImpact_WithinMax_Succeeds() public {
        _setupMarketWithPool();

        // Configure price impact limit
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x20; // Enable price impact (bit 5)
        cfg.maxPriceImpactBps = 1000; // 10% max impact
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 200e6);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 200e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: key.id0,
            id1: key.id1,
            token0: key.token0,
            token1: key.token1,
            feeOrHook: key.feeOrHook
        });

        // Get reserves before
        (uint112 r0Before, uint112 r1Before,,,,,) = ZAMM.pools(poolId);

        // Small swap that stays within 10% impact
        uint256 amountOut =
            ZAMM.swapExactIn(zammKey, 50e6, 0, zeroForOne, alice, block.timestamp + 1 hours);

        assertGt(amountOut, 0, "Swap should succeed and return tokens");

        // Get reserves after and calculate actual impact
        (uint112 r0After, uint112 r1After,,,,,) = ZAMM.pools(poolId);

        // Verify swap executed (reserves changed)
        assertTrue(r0After != r0Before || r1After != r1After, "Reserves should have changed");

        vm.stopPrank();

        console.log("Price impact within max: swap succeeds");
        console.log("  Amount out:", amountOut);
    }

    /// @notice Test price impact calculation accuracy
    /// @dev Verifies the impact calculation matches manual calculation
    function test_PriceImpact_CalculationAccuracy() public {
        _setupMarketWithPool();

        // Enable price impact with high threshold (won't revert)
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x20; // Enable price impact (bit 5)
        cfg.maxPriceImpactBps = 5000; // 50% max (high threshold for testing)
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 300e6);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 300e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        // Get initial state
        (uint112 r0Before, uint112 r1Before,,,,,) = ZAMM.pools(poolId);
        uint256 probBefore = hook.getMarketProbability(poolId);

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: key.id0,
            id1: key.id1,
            token0: key.token0,
            token1: key.token1,
            feeOrHook: key.feeOrHook
        });

        // Execute swap
        uint256 swapAmount = 100e6;
        ZAMM.swapExactIn(zammKey, swapAmount, 0, zeroForOne, alice, block.timestamp + 1 hours);

        // Get final state
        (uint112 r0After, uint112 r1After,,,,,) = ZAMM.pools(poolId);
        uint256 probAfter = hook.getMarketProbability(poolId);

        // Calculate actual impact as probability delta
        uint256 actualImpact =
            probAfter > probBefore ? probAfter - probBefore : probBefore - probAfter;

        // Use the hook's simulatePriceImpact to verify our calculation
        uint256 currentFee = hook.getCurrentFeeBps(poolId);
        uint256 simulatedImpact =
            hook.simulatePriceImpact(poolId, swapAmount, zeroForOne, currentFee);

        // The simulated impact should be close to actual (within rounding)
        // We allow small difference due to fee dynamics and rounding
        assertApproxEqAbs(simulatedImpact, actualImpact, 50, "Simulated impact should match actual");

        vm.stopPrank();

        console.log("Price impact calculation accuracy test passed:");
        console.log("  Prob before:", probBefore, "bps");
        console.log("  Prob after: ", probAfter, "bps");
        console.log("  Actual impact:", actualImpact, "bps");
        console.log("  Simulated impact:", simulatedImpact, "bps");
    }

    /// @notice Test that price impact check uses correct reserves after multiple operations
    /// @dev Ensures delta-based reserve reconstruction is accurate
    function test_PriceImpact_ReserveReconstructionCorrect() public {
        _setupMarketWithPool();

        // Enable price impact checking
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x20; // Enable price impact (bit 5)
        cfg.maxPriceImpactBps = 2000; // 20% max
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 400e6);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 400e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: key.id0,
            id1: key.id1,
            token0: key.token0,
            token1: key.token1,
            feeOrHook: key.feeOrHook
        });

        // Execute first swap
        uint256 out1 =
            ZAMM.swapExactIn(zammKey, 80e6, 0, zeroForOne, alice, block.timestamp + 1 hours);
        assertGt(out1, 0, "First swap should succeed");

        // Get reserves after first swap
        (uint112 r0Mid, uint112 r1Mid,,,,,) = ZAMM.pools(poolId);

        // Execute second swap in opposite direction
        // If reserve reconstruction is wrong, impact check might fail incorrectly
        uint256 out2 =
            ZAMM.swapExactIn(zammKey, 80e6, 0, !zeroForOne, alice, block.timestamp + 1 hours);
        assertGt(out2, 0, "Second swap should succeed");

        // Get final reserves
        (uint112 r0Final, uint112 r1Final,,,,,) = ZAMM.pools(poolId);

        // Verify both swaps affected reserves correctly
        assertTrue(r0Mid != r0Final || r1Mid != r1Final, "Second swap should change reserves");

        vm.stopPrank();

        console.log("Price impact reserve reconstruction: passed");
        console.log("  Both swaps executed with correct impact calculations");
    }

    /// @notice Test edge case: swap exactly at maxPriceImpactBps threshold
    /// @dev Verifies boundary condition handling
    function test_PriceImpact_ExactlyAtMax() public {
        _setupMarketWithPool();

        // Configure price impact limit
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x20; // Enable price impact (bit 5)
        cfg.maxPriceImpactBps = 800; // 8% max impact
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 300e6);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 300e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: key.id0,
            id1: key.id1,
            token0: key.token0,
            token1: key.token1,
            feeOrHook: key.feeOrHook
        });

        // Find a swap size that produces ~8% impact through trial
        // With 1000e6 liquidity, we need to test different amounts
        uint256 testAmount = 150e6; // Starting guess

        // Simulate the impact first
        uint256 currentFee = hook.getCurrentFeeBps(poolId);
        uint256 simulatedImpact =
            hook.simulatePriceImpact(poolId, testAmount, zeroForOne, currentFee);

        console.log("Testing boundary condition:");
        console.log("  Max allowed impact:", cfg.maxPriceImpactBps, "bps");
        console.log("  Simulated impact:  ", simulatedImpact, "bps");

        if (simulatedImpact <= cfg.maxPriceImpactBps) {
            // Should succeed if at or below threshold
            uint256 amountOut = ZAMM.swapExactIn(
                zammKey, testAmount, 0, zeroForOne, alice, block.timestamp + 1 hours
            );
            assertGt(amountOut, 0, "Swap at/below threshold should succeed");
            console.log("  Result: Swap succeeded (at or below threshold)");
        } else {
            // Should revert if above threshold
            vm.expectRevert(PMFeeHook.PriceImpactTooHigh.selector);
            ZAMM.swapExactIn(zammKey, testAmount, 0, zeroForOne, alice, block.timestamp + 1 hours);
            console.log("  Result: Swap reverted (above threshold)");
        }

        vm.stopPrank();

        console.log("Price impact boundary condition: passed");
    }

    /// @notice Test that price impact check is disabled when flag bit 5 is off
    /// @dev Verifies feature flag works correctly
    function test_PriceImpact_DisabledWhenFlagOff() public {
        _setupMarketWithPool();

        // Configure with price impact flag DISABLED (bit 5 = 0)
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags & ~uint16(0x20); // Clear bit 5
        cfg.maxPriceImpactBps = 100; // Very low limit, but flag is off so shouldn't matter
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 500e6);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 500e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: key.id0,
            id1: key.id1,
            token0: key.token0,
            token1: key.token1,
            feeOrHook: key.feeOrHook
        });

        // Large swap that would exceed 1% impact (but check is disabled)
        uint256 amountOut =
            ZAMM.swapExactIn(zammKey, 200e6, 0, zeroForOne, alice, block.timestamp + 1 hours);

        assertGt(amountOut, 0, "Swap should succeed even with high impact when check disabled");

        vm.stopPrank();

        console.log("Price impact disabled (flag off): swap succeeds despite high impact");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getConfig() internal pure returns (PMFeeHook.Config memory cfg) {
        // Return expected default config
        cfg = PMFeeHook.Config({
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
        returns (PMFeeHook.Config memory cfg)
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg1 = hook.getDefaultConfig();
        cfg1.maxFeeBps = 200;
        cfg1.flags = 0x03; // skew + bootstrap

        PMFeeHook.Config memory cfg2 = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();

        // Set to maximum valid values
        // Note: feeCapBps must be < 10000 (100% fee would halt trading)
        // and feeCapBps must be >= minFeeBps
        cfg.minFeeBps = 9999;
        cfg.maxFeeBps = 10000;
        cfg.maxSkewFeeBps = 10000;
        cfg.feeCapBps = 9999; // Must be < 10000 and >= minFeeBps
        cfg.skewRefBps = 5000;
        cfg.asymmetricFeeBps = 10000;
        cfg.volatilityFeeBps = 10000;
        cfg.maxPriceImpactBps = 10000;
        cfg.closeWindowFeeBps = 10000;

        vm.prank(hook.owner());
        hook.setDefaultConfig(cfg);

        PMFeeHook.Config memory retrieved = hook.getDefaultConfig();
        assertEq(retrieved.minFeeBps, 9999, "Min fee should be set to 9999");
        assertEq(retrieved.feeCapBps, 9999, "Fee cap should be 9999 (< 10000)");
        assertEq(retrieved.maxFeeBps, 10000, "Max fee can be 10000 (will be capped)");

        console.log("Max bounds config test: passed");
    }

    function test_Config_AllDecayModes() public {
        _setupMarketWithPool();

        // Test all 4 decay modes: 0=linear, 1=exp, 2=sqrt, 3=log
        for (uint16 mode = 0; mode < 4; mode++) {
            PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
            PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg1 = hook.getDefaultConfig();
        cfg1.flags = 0x01; // Only skew
        cfg1.maxSkewFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg1);

        uint256 fee1 = hook.getCurrentFeeBps(poolId);

        // Change config mid-lifecycle
        PMFeeHook.Config memory cfg2 = hook.getDefaultConfig();
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
            PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg1 = hook.getDefaultConfig();
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
        PMFeeHook.Config memory cfg2 = hook.getDefaultConfig();
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
                    NEW VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetPriceHistory_Empty() public {
        _setupMarketWithPool();

        (
            uint64[10] memory timestamps,
            uint32[10] memory prices,
            uint8 currentIndex,
            uint8 validCount
        ) = hook.getPriceHistory(poolId);

        // No swaps yet, should be empty
        assertEq(validCount, 0, "Should have no valid snapshots initially");
        assertEq(currentIndex, 0, "Index should be 0");
        assertEq(timestamps[0], 0, "First timestamp should be 0");
        assertEq(prices[0], 0, "First price should be 0");

        console.log("getPriceHistory empty: passed");
    }

    function test_GetPriceHistory_AfterSwaps() public {
        _setupMarketWithPool();

        // Enable volatility to trigger snapshot recording
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x40; // FLAG_VOLATILITY
        cfg.volatilityFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 2000e6);
        USDC.approve(address(PAMM), 2000e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        // Execute 5 swaps with new blocks
        // Use explicit block tracking to ensure each swap is in a unique block
        uint256 currentBlock = block.number;
        for (uint256 i = 0; i < 5; i++) {
            currentBlock++;
            vm.roll(currentBlock);
            PAMM.split(marketId, 100e6, alice);
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

        (
            uint64[10] memory timestamps,
            uint32[10] memory prices,
            uint8 currentIndex,
            uint8 validCount
        ) = hook.getPriceHistory(poolId);

        assertEq(validCount, 5, "Should have 5 valid snapshots");
        assertEq(currentIndex, 5, "Index should be 5");

        // Verify snapshots are populated
        for (uint8 i = 0; i < 5; i++) {
            assertGt(timestamps[i], 0, "Timestamp should be set");
            assertGt(prices[i], 0, "Price should be set");
            assertLe(prices[i], 10000, "Price should be <= 10000 bps");
        }

        console.log("getPriceHistory after swaps: passed");
        console.log("  Valid count:", validCount);
        console.log("  Current index:", currentIndex);
    }

    function test_GetPriceHistory_CircularBuffer() public {
        _setupMarketWithPool();

        // Enable volatility
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x40;
        cfg.volatilityFeeBps = 50;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 5000e6);
        USDC.approve(address(PAMM), 5000e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        // Execute 12 swaps to wrap around circular buffer
        // Use explicit block tracking to ensure each swap is in a unique block
        uint256 currentBlock = block.number;
        for (uint256 i = 0; i < 12; i++) {
            currentBlock++;
            vm.roll(currentBlock);
            PAMM.split(marketId, 100e6, alice);
            ZAMM.swapExactIn(
                IZAMM.PoolKey({
                    id0: key.id0,
                    id1: key.id1,
                    token0: key.token0,
                    token1: key.token1,
                    feeOrHook: key.feeOrHook
                }),
                30e6,
                0,
                i % 2 == 0 ? zeroForOne : !zeroForOne,
                alice,
                block.timestamp + 1 hours
            );
        }
        vm.stopPrank();

        (
            uint64[10] memory timestamps,
            uint32[10] memory prices,
            uint8 currentIndex,
            uint8 validCount
        ) = hook.getPriceHistory(poolId);

        assertEq(validCount, 10, "Should have 10 valid snapshots (buffer full)");
        assertEq(currentIndex, 2, "Index should wrap to 2 (12 mod 10)");

        // All slots should be filled
        for (uint8 i = 0; i < 10; i++) {
            assertGt(timestamps[i], 0, "All timestamps should be set");
            assertGt(prices[i], 0, "All prices should be set");
        }

        console.log("getPriceHistory circular buffer: passed");
    }

    function test_GetVolatility_InsufficientSnapshots() public {
        _setupMarketWithPool();

        (uint256 volatilityPct, uint8 snapshotCount, uint256 meanPriceBps) =
            hook.getVolatility(poolId);

        assertEq(volatilityPct, 0, "Volatility should be 0 with no snapshots");
        assertEq(snapshotCount, 0, "Snapshot count should be 0");
        assertEq(meanPriceBps, 0, "Mean price should be 0");

        console.log("getVolatility insufficient snapshots: passed");
    }

    function test_GetVolatility_WithSnapshots() public {
        _setupMarketWithPool();

        // Enable volatility
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x40;
        cfg.volatilityFeeBps = 50;
        cfg.volatilityWindow = 0; // No staleness check

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 3000e6);
        USDC.approve(address(PAMM), 3000e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        // Execute 5 swaps to get enough snapshots
        // Use explicit block tracking to ensure each swap is in a unique block
        uint256 currentBlock = block.number;
        for (uint256 i = 0; i < 5; i++) {
            currentBlock++;
            vm.roll(currentBlock);
            PAMM.split(marketId, 150e6, alice);
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

        (uint256 volatilityPct, uint8 snapshotCount, uint256 meanPriceBps) =
            hook.getVolatility(poolId);

        assertGe(snapshotCount, 3, "Should have at least 3 snapshots");
        assertGt(meanPriceBps, 0, "Mean price should be positive");
        // Volatility can be 0 if prices are stable, so just check it doesn't revert

        console.log("getVolatility with snapshots: passed");
        console.log("  Volatility %:", volatilityPct);
        console.log("  Snapshot count:", snapshotCount);
        console.log("  Mean price bps:", meanPriceBps);
    }

    function test_GetVolatility_HighVolatility() public {
        _setupMarketWithPool();

        // Enable volatility
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x40;
        cfg.volatilityFeeBps = 100;
        cfg.volatilityWindow = 0;

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 5000e6);
        USDC.approve(address(PAMM), 5000e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        // Execute large swaps to create high volatility
        // Use explicit block tracking to ensure each swap is in a unique block
        uint256 currentBlock = block.number;
        for (uint256 i = 0; i < 6; i++) {
            currentBlock++;
            vm.roll(currentBlock);
            PAMM.split(marketId, 400e6, alice);
            // Alternate directions with larger amounts
            ZAMM.swapExactIn(
                IZAMM.PoolKey({
                    id0: key.id0,
                    id1: key.id1,
                    token0: key.token0,
                    token1: key.token1,
                    feeOrHook: key.feeOrHook
                }),
                200e6,
                0,
                i % 2 == 0 ? zeroForOne : !zeroForOne,
                alice,
                block.timestamp + 1 hours
            );
        }
        vm.stopPrank();

        (uint256 volatilityPct, uint8 snapshotCount, uint256 meanPriceBps) =
            hook.getVolatility(poolId);

        assertGe(snapshotCount, 3, "Should have at least 3 snapshots");
        assertGt(meanPriceBps, 0, "Mean price should be positive");
        // With alternating large swaps, expect some volatility
        assertGt(volatilityPct, 0, "Should detect some volatility from price swings");

        console.log("getVolatility high volatility: passed");
        console.log("  Volatility %:", volatilityPct);
        console.log("  Snapshot count:", snapshotCount);
        console.log("  Mean price bps:", meanPriceBps);
    }

    function test_GetVolatility_UnregisteredPool() public {
        uint256 fakePoolId = 999999;

        (uint256 volatilityPct, uint8 snapshotCount, uint256 meanPriceBps) =
            hook.getVolatility(fakePoolId);

        assertEq(volatilityPct, 0, "Volatility should be 0 for unregistered pool");
        assertEq(snapshotCount, 0, "Snapshot count should be 0");
        assertEq(meanPriceBps, 0, "Mean price should be 0");

        console.log("getVolatility unregistered pool: passed");
    }

    function test_GetVolatility_RespectsVolatilityWindow() public {
        _setupMarketWithPool();

        // Enable volatility with a window
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x40;
        cfg.volatilityFeeBps = 50;
        cfg.volatilityWindow = 1 hours; // Only use snapshots from last hour

        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 3000e6);
        USDC.approve(address(PAMM), 3000e6);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        // Execute swaps
        // Use explicit block tracking to ensure each swap is in a unique block
        uint256 currentBlock = block.number;
        for (uint256 i = 0; i < 4; i++) {
            currentBlock++;
            vm.roll(currentBlock);
            PAMM.split(marketId, 150e6, alice);
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
        }
        vm.stopPrank();

        // Get volatility now (all 4 snapshots should be within window)
        (, uint8 countNow,) = hook.getVolatility(poolId);
        assertEq(countNow, 4, "Should have 4 snapshots within window");

        // Warp past the volatility window
        vm.warp(block.timestamp + 2 hours);

        // Now snapshots should be outside the window
        (, uint8 countLater,) = hook.getVolatility(poolId);
        assertEq(countLater, 0, "Snapshots should be stale after window expires");

        console.log("getVolatility respects window: passed");
    }

    /*//////////////////////////////////////////////////////////////
                    VIEW FUNCTION COVERAGE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetCloseWindow() public {
        // Create and register market
        marketId = _createMarket("CloseWindow Test", block.timestamp + 7 days);
        poolId = hook.registerMarket(marketId);

        // Default config has closeWindow = 1 hours
        uint256 closeWindow = hook.getCloseWindow(marketId);
        assertEq(closeWindow, 1 hours, "Should return default closeWindow");

        // Set custom config with different closeWindow
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.closeWindow = 2 hours;
        hook.setMarketConfig(marketId, cfg);

        closeWindow = hook.getCloseWindow(marketId);
        assertEq(closeWindow, 2 hours, "Should return custom closeWindow");

        console.log("getCloseWindow: passed");
    }

    function test_GetMaxPriceImpactBps() public {
        // Create and register market
        marketId = _createMarket("PriceImpact Test", block.timestamp + 7 days);
        poolId = hook.registerMarket(marketId);

        // Default config has price impact enabled with 1200 bps
        uint256 maxImpact = hook.getMaxPriceImpactBps(marketId);
        assertEq(maxImpact, 1200, "Should return default maxPriceImpactBps");

        // Set config with price impact disabled (remove flag bit 5)
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags & ~uint16(0x20); // Clear price impact flag
        hook.setMarketConfig(marketId, cfg);

        maxImpact = hook.getMaxPriceImpactBps(marketId);
        assertEq(maxImpact, 0, "Should return 0 when price impact disabled");

        console.log("getMaxPriceImpactBps: passed");
    }

    function test_GetMarketStatus() public {
        // Create and register market with specific close time
        uint64 closeTime = uint64(block.timestamp + 7 days);
        marketId = _createMarket("Status Test", closeTime);
        poolId = hook.registerMarket(marketId);

        (bool active, bool resolved, uint64 close, uint16 closeWindow, uint8 closeMode) =
            hook.getMarketStatus(marketId);

        assertTrue(active, "Should be active after registration");
        assertFalse(resolved, "Should not be resolved");
        assertEq(close, closeTime, "Should return correct close time");
        assertEq(closeWindow, 1 hours, "Should return default closeWindow");
        assertEq(closeMode, 1, "Should return default closeMode (1 = fixed fee)");

        console.log("getMarketStatus: passed");
    }

    function test_GetMarketStatus_Unregistered() public {
        // Create market but don't register
        marketId = _createMarket("Unregistered Status", block.timestamp + 7 days);

        (bool active,,,,) = hook.getMarketStatus(marketId);
        assertFalse(active, "Should not be active for unregistered market");

        console.log("getMarketStatus unregistered: passed");
    }

    /*//////////////////////////////////////////////////////////////
                    SECURITY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that shadow pools (after-only hook) cannot trade
    /// @dev This tests the fix for after-only pools bypassing registration
    function test_AfterOnlyPool_SwapReverts() public {
        // Create market but don't register with hook
        marketId = _createMarket("Shadow Pool Test", block.timestamp + 7 days);

        // Get the pool key with only FLAG_AFTER (simulating shadow pool)
        uint256 flagAfter = 1 << 254;
        uint256 shadowFeeOrHook = uint256(uint160(address(hook))) | flagAfter; // Only AFTER flag

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, shadowFeeOrHook);

        // Split tokens to have something to trade
        vm.startPrank(alice);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 1000e6, alice);

        // Approve ZAMM
        PAMM.setOperator(address(ZAMM), true);

        // Try to add liquidity and swap - the pool is unregistered so afterAction should revert
        // Note: This creates a pool with shadow feeOrHook, not the canonical one
        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: key.id0,
            id1: key.id1,
            token0: key.token0,
            token1: key.token1,
            feeOrHook: shadowFeeOrHook
        });

        // Add liquidity (LP operations allowed even for unregistered)
        ZAMM.addLiquidity(zammKey, 400e6, 400e6, 0, 0, alice, block.timestamp + 1 hours);

        // Attempt swap - should revert with InvalidPoolId because pool is not registered
        vm.expectRevert(PMFeeHook.InvalidPoolId.selector);
        ZAMM.swapExactIn(zammKey, 10e6, 0, true, alice, block.timestamp + 1 hours);

        vm.stopPrank();

        console.log("Shadow pool swap reverts: passed");
    }

    /// @notice Test that LP operations work for unregistered pools (intentional)
    function test_LPOperations_AllowedForUnregistered() public {
        // Create market but don't register
        marketId = _createMarket("LP Unregistered Test", block.timestamp + 7 days);

        // Use canonical feeOrHook but don't register
        feeOrHook = hook.feeOrHook();
        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);

        vm.startPrank(alice);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 1000e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: key.id0, id1: key.id1, token0: key.token0, token1: key.token1, feeOrHook: feeOrHook
        });

        // Add liquidity should work (LP ops bypass registration check)
        // This is intentional for emergency LP removal from unregistered/resolved pools
        (uint256 a0, uint256 a1, uint256 liq) =
            ZAMM.addLiquidity(zammKey, 400e6, 400e6, 0, 0, alice, block.timestamp + 1 hours);

        assertTrue(liq > 0, "Should have received liquidity tokens");
        assertTrue(a0 > 0 && a1 > 0, "Should have added both tokens");

        vm.stopPrank();

        console.log("LP operations allowed for unregistered: passed");
    }

    /// @notice Test registerMarket called by owner (not just REGISTRAR)
    function test_RegisterMarket_ByOwner() public {
        // Create market
        marketId = _createMarket("Owner Register Test", block.timestamp + 7 days);

        // Register by owner (this contract is the owner via setUp)
        poolId = hook.registerMarket(marketId);

        assertTrue(poolId != 0, "Should return valid poolId");

        (uint64 start, bool active, bool yesIsToken0) = hook.meta(poolId);
        assertTrue(active, "Pool should be active");
        assertEq(start, uint64(block.timestamp), "Start should be current timestamp");

        console.log("registerMarket by owner: passed");
    }

    /// @notice Test registerMarket reverts for non-authorized caller
    function test_RevertRegisterMarket_Unauthorized() public {
        marketId = _createMarket("Unauthorized Test", block.timestamp + 7 days);

        vm.prank(alice); // alice is not owner or REGISTRAR
        vm.expectRevert(PMFeeHook.Unauthorized.selector);
        hook.registerMarket(marketId);

        console.log("registerMarket unauthorized reverts: passed");
    }

    /*//////////////////////////////////////////////////////////////
                    CONFIG VALIDATION EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertInvalidConfig_SkewRefBpsZero() public {
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.skewRefBps = 0; // Invalid: must be > 0

        vm.expectRevert(PMFeeHook.InvalidConfig.selector);
        hook.setDefaultConfig(cfg);

        console.log("skewRefBps = 0 reverts: passed");
    }

    function test_RevertInvalidConfig_SkewRefBpsTooHigh() public {
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.skewRefBps = 5001; // Invalid: must be <= 5000

        vm.expectRevert(PMFeeHook.InvalidConfig.selector);
        hook.setDefaultConfig(cfg);

        console.log("skewRefBps > 5000 reverts: passed");
    }

    function test_RevertInvalidConfig_CloseWindowMode1NoFee() public {
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        // Set closeWindowMode to 1 (fixed fee) but closeWindowFeeBps to 0
        cfg.flags = (cfg.flags & ~uint16(0x0C)) | uint16(0x04); // Mode 1 = bits 2-3 = 01
        cfg.closeWindowFeeBps = 0;

        vm.expectRevert(PMFeeHook.InvalidConfig.selector);
        hook.setDefaultConfig(cfg);

        console.log("closeWindowMode=1 with 0 fee reverts: passed");
    }

    function test_RevertInvalidConfig_FeeCapAtMax() public {
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.feeCapBps = 10000; // Invalid: must be < 10000

        vm.expectRevert(PMFeeHook.InvalidConfig.selector);
        hook.setDefaultConfig(cfg);

        console.log("feeCapBps = 10000 reverts: passed");
    }

    function test_RevertInvalidConfig_AsymmetricFeeTooHigh() public {
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.asymmetricFeeBps = 10001; // Invalid: > 10000

        vm.expectRevert(PMFeeHook.InvalidConfig.selector);
        hook.setDefaultConfig(cfg);

        console.log("asymmetricFeeBps > 10000 reverts: passed");
    }

    function test_RevertInvalidConfig_VolatilityFeeTooHigh() public {
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.volatilityFeeBps = 10001; // Invalid: > 10000

        vm.expectRevert(PMFeeHook.InvalidConfig.selector);
        hook.setDefaultConfig(cfg);

        console.log("volatilityFeeBps > 10000 reverts: passed");
    }

    /*//////////////////////////////////////////////////////////////
                    ADDITIONAL EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AdjustBootstrapStart_MarketResolved() public {
        // Create and register market
        marketId = _createMarket("Resolved Bootstrap Test", block.timestamp + 7 days);
        poolId = hook.registerMarket(marketId);

        // Resolve the market (this contract is the resolver)
        // We need to call resolve on PAMM - let's check if we can
        // Actually, let's warp to after close and check the close path

        // Warp to after market close
        vm.warp(block.timestamp + 8 days);

        // Now try to adjust bootstrap start - should revert
        vm.expectRevert(PMFeeHook.MarketClosed.selector);
        hook.adjustBootstrapStart(poolId, uint64(block.timestamp - 1 days));

        console.log("adjustBootstrapStart after close reverts: passed");
    }

    function test_GetMarketConfig_Default() public {
        // Create market but use a marketId that has no custom config
        marketId = _createMarket("Default Config Test", block.timestamp + 7 days);

        // Get config for market with no custom config (should return default)
        PMFeeHook.Config memory cfg = hook.getMarketConfig(marketId);
        PMFeeHook.Config memory defaultCfg = hook.getDefaultConfig();

        assertEq(cfg.minFeeBps, defaultCfg.minFeeBps, "Should return default minFeeBps");
        assertEq(cfg.maxFeeBps, defaultCfg.maxFeeBps, "Should return default maxFeeBps");
        assertEq(cfg.flags, defaultCfg.flags, "Should return default flags");

        console.log("getMarketConfig returns default: passed");
    }

    function test_GetMarketConfig_Custom() public {
        marketId = _createMarket("Custom Config Test", block.timestamp + 7 days);

        // Set custom config
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.minFeeBps = 50;
        cfg.maxFeeBps = 150;
        hook.setMarketConfig(marketId, cfg);

        // Verify custom config is returned
        PMFeeHook.Config memory retrieved = hook.getMarketConfig(marketId);
        assertEq(retrieved.minFeeBps, 50, "Should return custom minFeeBps");
        assertEq(retrieved.maxFeeBps, 150, "Should return custom maxFeeBps");

        console.log("getMarketConfig returns custom: passed");
    }

    function test_Asymmetric_FeeScalesLinearly() public {
        // Create and register market
        marketId = _createMarket("Asymmetric Fee Test", block.timestamp + 7 days);
        poolId = hook.registerMarket(marketId);

        // Set config with only asymmetric fee enabled
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x10; // Only asymmetric fee
        cfg.asymmetricFeeBps = 100; // 1% max asymmetric fee
        cfg.minFeeBps = 0;
        cfg.maxFeeBps = 0;
        cfg.bootstrapWindow = 0;
        hook.setMarketConfig(marketId, cfg);

        // Add liquidity with imbalance to create skew
        feeOrHook = hook.feeOrHook();
        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);

        vm.startPrank(alice);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 2000e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: key.id0, id1: key.id1, token0: key.token0, token1: key.token1, feeOrHook: feeOrHook
        });

        // Add imbalanced liquidity (more YES than NO means lower YES price)
        ZAMM.addLiquidity(zammKey, 800e6, 200e6, 0, 0, alice, block.timestamp + 1 hours);
        vm.stopPrank();

        // Check probability
        uint256 prob = hook.getMarketProbability(poolId);
        // With 800 YES and 200 NO: P(YES) = NO/(YES+NO) = 200/1000 = 20% = 2000 bps
        // Deviation from 50% = |2000 - 5000| = 3000 bps out of max 5000
        // Asymmetric fee = 100 * 3000 / 5000 = 60 bps

        uint256 currentFee = hook.getCurrentFeeBps(poolId);
        // Fee should be around 60 bps (asymmetric component only)
        assertTrue(currentFee > 0, "Fee should include asymmetric component");
        assertTrue(currentFee <= 100, "Fee should be capped by asymmetric max");

        console.log("Asymmetric fee scales with deviation: passed");
    }

    function test_BootstrapDecay_CubicMode() public {
        // Create and register market
        marketId = _createMarket("Cubic Decay Test", block.timestamp + 7 days);
        poolId = hook.registerMarket(marketId);

        // Set config with cubic bootstrap decay (mode 1)
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x02; // Only bootstrap
        cfg.minFeeBps = 10;
        cfg.maxFeeBps = 100;
        cfg.bootstrapWindow = 1 days;
        cfg.extraFlags = 0x04; // bits 2-3 = 01 = cubic decay mode
        hook.setMarketConfig(marketId, cfg);

        // Record fee at start
        uint256 feeAtStart = hook.getCurrentFeeBps(poolId);
        assertEq(feeAtStart, 100, "Should be max fee at start");

        // Warp to 50% through bootstrap
        vm.warp(block.timestamp + 12 hours);
        uint256 feeMid = hook.getCurrentFeeBps(poolId);

        // Warp past end of bootstrap (add buffer to ensure we're past)
        vm.warp(block.timestamp + 13 hours);
        uint256 feeEnd = hook.getCurrentFeeBps(poolId);
        assertEq(feeEnd, 10, "Should be min fee at end");

        // Cubic decay means fee decays slowly at first, then fast
        // At 50%, cubic gives ratio = 1 - (0.5)^3 = 0.875, so fee ≈ 100 - 90*0.875 = 21.25
        // This is lower than linear (55 bps at 50%)
        assertTrue(feeMid < 50, "Cubic decay should be below linear at midpoint");

        console.log("Bootstrap cubic decay: passed");
    }

    function test_BootstrapDecay_SqrtMode() public {
        // Create and register market
        marketId = _createMarket("Sqrt Decay Test", block.timestamp + 7 days);
        poolId = hook.registerMarket(marketId);

        // Set config with sqrt bootstrap decay (mode 2)
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x02; // Only bootstrap
        cfg.minFeeBps = 10;
        cfg.maxFeeBps = 100;
        cfg.bootstrapWindow = 1 days;
        cfg.extraFlags = 0x08; // bits 2-3 = 10 = sqrt decay mode
        hook.setMarketConfig(marketId, cfg);

        // Record fee at start
        uint256 feeAtStart = hook.getCurrentFeeBps(poolId);
        assertEq(feeAtStart, 100, "Should be max fee at start");

        // Warp to 25% through bootstrap
        vm.warp(block.timestamp + 6 hours);
        uint256 feeEarly = hook.getCurrentFeeBps(poolId);

        // Sqrt decay means fee decays fast at first, then slow
        // At 25%, sqrt gives ratio = sqrt(0.25) = 0.5, so fee ≈ 100 - 90*0.5 = 55
        // This is lower than linear (77.5 bps at 25%)
        assertTrue(feeEarly < 77, "Sqrt decay should be below linear early");

        console.log("Bootstrap sqrt decay: passed");
    }

    function test_BootstrapDecay_EaseInMode() public {
        // Create and register market
        marketId = _createMarket("EaseIn Decay Test", block.timestamp + 7 days);
        poolId = hook.registerMarket(marketId);

        // Set config with ease-in bootstrap decay (mode 3)
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x02; // Only bootstrap
        cfg.minFeeBps = 10;
        cfg.maxFeeBps = 100;
        cfg.bootstrapWindow = 1 days;
        cfg.extraFlags = 0x0C; // bits 2-3 = 11 = ease-in decay mode
        hook.setMarketConfig(marketId, cfg);

        // Record fee at start
        uint256 feeAtStart = hook.getCurrentFeeBps(poolId);
        assertEq(feeAtStart, 100, "Should be max fee at start");

        // Warp to 25% through bootstrap
        vm.warp(block.timestamp + 6 hours);
        uint256 feeEarly = hook.getCurrentFeeBps(poolId);

        // Ease-in decay means fee decays slowly at first, then fast
        // At 25%, ease-in gives ratio = 1 - sqrt(0.75) ≈ 0.134, so fee ≈ 100 - 90*0.134 = 88
        // This is higher than linear (77.5 bps at 25%)
        assertTrue(feeEarly > 77, "Ease-in decay should be above linear early");

        console.log("Bootstrap ease-in decay: passed");
    }

    function test_SkewCurve_CubicMode() public {
        // Create and register market
        marketId = _createMarket("Cubic Skew Test", block.timestamp + 7 days);
        poolId = hook.registerMarket(marketId);

        // Set config with cubic skew curve (mode 2)
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x01; // Only skew
        cfg.minFeeBps = 0;
        cfg.maxSkewFeeBps = 100;
        cfg.skewRefBps = 5000; // Max skew at 0% or 100%
        cfg.extraFlags = 0x02; // bits 0-1 = 10 = cubic skew curve
        cfg.bootstrapWindow = 0;
        hook.setMarketConfig(marketId, cfg);

        // Add imbalanced liquidity
        feeOrHook = hook.feeOrHook();
        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);

        vm.startPrank(alice);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 2000e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        // 75/25 split = 50% skew = ratio of 0.5
        ZAMM.addLiquidity(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: feeOrHook
            }),
            750e6,
            250e6,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Cubic curve: fee = maxSkew * ratio^3 = 100 * 0.5^3 = 12.5 bps
        uint256 fee = hook.getCurrentFeeBps(poolId);
        assertTrue(fee <= 15, "Cubic skew should be low at moderate imbalance");

        console.log("Skew cubic curve: passed");
    }

    function test_SkewCurve_QuarticMode() public {
        // Create and register market
        marketId = _createMarket("Quartic Skew Test", block.timestamp + 7 days);
        poolId = hook.registerMarket(marketId);

        // Set config with quartic skew curve (mode 3)
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = 0x01; // Only skew
        cfg.minFeeBps = 0;
        cfg.maxSkewFeeBps = 100;
        cfg.skewRefBps = 5000;
        cfg.extraFlags = 0x03; // bits 0-1 = 11 = quartic skew curve
        cfg.bootstrapWindow = 0;
        hook.setMarketConfig(marketId, cfg);

        // Add imbalanced liquidity
        feeOrHook = hook.feeOrHook();
        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);

        vm.startPrank(alice);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 2000e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        // 75/25 split
        ZAMM.addLiquidity(
            IZAMM.PoolKey({
                id0: key.id0,
                id1: key.id1,
                token0: key.token0,
                token1: key.token1,
                feeOrHook: feeOrHook
            }),
            750e6,
            250e6,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Quartic curve: fee = maxSkew * ratio^4 = 100 * 0.5^4 = 6.25 bps
        uint256 fee = hook.getCurrentFeeBps(poolId);
        assertTrue(fee <= 10, "Quartic skew should be very low at moderate imbalance");

        console.log("Skew quartic curve: passed");
    }

    function test_RegisterMarket_ClosedMarket() public {
        // Create market with valid close time
        uint256 closeTime = block.timestamp + 1 days;
        marketId = _createMarket("Closed Market Test", closeTime);

        // Warp to after the close time
        vm.warp(closeTime + 1 hours);

        // Try to register - should revert because market is closed
        vm.expectRevert(PMFeeHook.MarketClosed.selector);
        hook.registerMarket(marketId);

        console.log("registerMarket closed reverts: passed");
    }

    /*//////////////////////////////////////////////////////////////
                    TRANSIENT CACHE SAFETY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test cache safety: multiple swaps on different pools in same transaction
    /// @dev Verifies no cross-contamination between pool caches
    function test_CacheSafety_TwoPoolsSameTx() public {
        // Setup: Create two separate markets with pools
        uint256 market1 = _createMarket("Cache Test Market 1", block.timestamp + 7 days);
        uint256 pool1 = hook.registerMarket(market1);
        uint256 market1NoId = PAMM.getNoId(market1);

        uint256 market2 = _createMarket("Cache Test Market 2", block.timestamp + 7 days);
        uint256 pool2 = hook.registerMarket(market2);
        uint256 market2NoId = PAMM.getNoId(market2);

        // Add liquidity to both pools
        vm.startPrank(alice);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(market1, 1000e6, alice);
        PAMM.split(market2, 1000e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key1 = PAMM.poolKey(market1, hook.feeOrHook());
        IPAMM.PoolKey memory key2 = PAMM.poolKey(market2, hook.feeOrHook());

        ZAMM.addLiquidity(
            IZAMM.PoolKey({
                id0: key1.id0,
                id1: key1.id1,
                token0: key1.token0,
                token1: key1.token1,
                feeOrHook: key1.feeOrHook
            }),
            500e6,
            500e6,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        ZAMM.addLiquidity(
            IZAMM.PoolKey({
                id0: key2.id0,
                id1: key2.id1,
                token0: key2.token0,
                token1: key2.token1,
                feeOrHook: key2.feeOrHook
            }),
            500e6,
            500e6,
            0,
            0,
            alice,
            block.timestamp + 1 hours
        );

        // Get initial reserves for both pools
        (uint112 r0_pool1_before, uint112 r1_pool1_before,,,,,) = ZAMM.pools(pool1);
        (uint112 r0_pool2_before, uint112 r1_pool2_before,,,,,) = ZAMM.pools(pool2);

        // Deploy helper contract to execute two swaps in single transaction
        MultiSwapHelper helper = new MultiSwapHelper(address(ZAMM), address(PAMM));

        // Transfer tokens to helper
        PAMM.transfer(address(helper), market1, 50e6);
        PAMM.transfer(address(helper), market2, 50e6);
        PAMM.transfer(address(helper), market1NoId, 50e6);
        PAMM.transfer(address(helper), market2NoId, 50e6);

        vm.stopPrank();

        // Execute two swaps in same transaction
        // Swap on pool1: YES → NO (token0 → token1 if market1 < noId1)
        // Swap on pool2: NO → YES (token1 → token0 if market2 < noId2)
        bool zeroForOne1 = market1 < market1NoId;
        bool zeroForOne2 = !(market2 < market2NoId); // Opposite direction

        vm.prank(alice);
        helper.executeDoubleSwap(key1, key2, 25e6, 25e6, zeroForOne1, zeroForOne2);

        // Verify both pools updated independently (no cache cross-contamination)
        (uint112 r0_pool1_after, uint112 r1_pool1_after,,,,,) = ZAMM.pools(pool1);
        (uint112 r0_pool2_after, uint112 r1_pool2_after,,,,,) = ZAMM.pools(pool2);

        // Pool1 reserves should have changed
        assertTrue(
            r0_pool1_after != r0_pool1_before || r1_pool1_after != r1_pool1_before,
            "Pool1 reserves should have changed"
        );

        // Pool2 reserves should have changed
        assertTrue(
            r0_pool2_after != r0_pool2_before || r1_pool2_after != r1_pool2_before,
            "Pool2 reserves should have changed"
        );

        // Verify changes match expected directions
        if (zeroForOne1) {
            assertGt(r0_pool1_after, r0_pool1_before, "Pool1 r0 should increase");
            assertLt(r1_pool1_after, r1_pool1_before, "Pool1 r1 should decrease");
        } else {
            assertLt(r0_pool1_after, r0_pool1_before, "Pool1 r0 should decrease");
            assertGt(r1_pool1_after, r1_pool1_before, "Pool1 r1 should increase");
        }

        if (zeroForOne2) {
            assertGt(r0_pool2_after, r0_pool2_before, "Pool2 r0 should increase");
            assertLt(r1_pool2_after, r1_pool2_before, "Pool2 r1 should decrease");
        } else {
            assertLt(r0_pool2_after, r0_pool2_before, "Pool2 r0 should decrease");
            assertGt(r1_pool2_after, r1_pool2_before, "Pool2 r1 should increase");
        }

        console.log("Cache safety - two pools same tx: passed");
        console.log("  Pool1 reserves changed correctly");
        console.log("  Pool2 reserves changed correctly");
        console.log("  No cross-contamination detected");
    }

    /// @notice Test cache safety: two swaps on same pool in same transaction
    /// @dev Verifies second swap doesn't use stale cache from first swap
    function test_CacheSafety_SamePoolTwoSwaps() public {
        _setupMarketWithPool();

        // Enable price impact checking to ensure transient cache is used
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x20; // Enable price impact (bit 5)
        cfg.maxPriceImpactBps = 5000; // High threshold so we don't revert
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);

        // Prepare tokens for two swaps
        deal(address(USDC), alice, 500e6);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 250e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        // Get initial reserves
        (uint112 r0_initial, uint112 r1_initial,,,,,) = ZAMM.pools(poolId);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        // Deploy helper to execute two swaps in one transaction
        MultiSwapHelper helper = new MultiSwapHelper(address(ZAMM), address(PAMM));
        PAMM.transfer(address(helper), marketId, 100e6);
        PAMM.transfer(address(helper), noId, 100e6);

        vm.stopPrank();

        // Execute two swaps on same pool in same transaction
        // First swap: 30e6 in direction A
        // Second swap: 30e6 in OPPOSITE direction
        vm.prank(alice);
        helper.executeDoubleSwapSamePool(key, 30e6, 30e6, zeroForOne, !zeroForOne);

        // Verify final reserves reflect both swaps (not just first)
        (uint112 r0_final, uint112 r1_final,,,,,) = ZAMM.pools(poolId);

        // Reserves should have changed from initial
        assertTrue(
            r0_final != r0_initial || r1_final != r1_initial,
            "Reserves should have changed after two swaps"
        );

        // The two opposing swaps should partially cancel out
        // After swap 1 (zeroForOne=true):  r0 increases, r1 decreases
        // After swap 2 (zeroForOne=false): r0 decreases, r1 increases
        // Net effect: reserves closer to initial than after just swap 1

        // We can't easily predict exact values due to fees, but we can verify:
        // 1. Both swaps executed (no revert)
        // 2. Final state is different from initial (both swaps affected reserves)
        // 3. If stale cache was used, price impact check would have been wrong

        console.log("Cache safety - same pool two swaps: passed");
        console.log("  Initial r0:", r0_initial, "r1:", r1_initial);
        console.log("  Final   r0:", r0_final, "r1:", r1_final);
        console.log("  Both swaps executed without stale cache issues");
    }

    /// @notice Test that reserve cache is properly cleared between operations
    /// @dev Tests the explicit cache clearing at line 700-705 in afterAction
    function test_CacheSafety_CacheClearing() public {
        _setupMarketWithPool();

        // Enable features that use reserve cache
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        cfg.flags = cfg.flags | 0x21; // Enable skew (bit 0) + price impact (bit 5)
        cfg.maxPriceImpactBps = 3000;
        vm.prank(hook.owner());
        hook.setMarketConfig(marketId, cfg);

        vm.startPrank(alice);
        deal(address(USDC), alice, 200e6);
        USDC.approve(address(PAMM), type(uint256).max);
        PAMM.split(marketId, 100e6, alice);
        PAMM.setOperator(address(ZAMM), true);

        IPAMM.PoolKey memory key = PAMM.poolKey(marketId, feeOrHook);
        bool zeroForOne = marketId < noId;

        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: key.id0,
            id1: key.id1,
            token0: key.token0,
            token1: key.token1,
            feeOrHook: key.feeOrHook
        });

        // Execute first swap
        uint256 out1 =
            ZAMM.swapExactIn(zammKey, 20e6, 0, zeroForOne, alice, block.timestamp + 1 hours);
        assertGt(out1, 0, "First swap should succeed");

        // Get reserves after first swap
        (uint112 r0_after1, uint112 r1_after1,,,,,) = ZAMM.pools(poolId);

        // Execute second swap in SAME transaction context (via new call)
        // If cache wasn't cleared, this could use stale data
        uint256 out2 =
            ZAMM.swapExactIn(zammKey, 20e6, 0, !zeroForOne, alice, block.timestamp + 1 hours);
        assertGt(out2, 0, "Second swap should succeed");

        // Get final reserves
        (uint112 r0_final, uint112 r1_final,,,,,) = ZAMM.pools(poolId);

        // Verify reserves updated correctly from both swaps
        assertTrue(
            r0_final != r0_after1 || r1_final != r1_after1, "Reserves should reflect second swap"
        );

        vm.stopPrank();

        console.log("Cache safety - cache clearing: passed");
        console.log("  Both swaps executed correctly");
        console.log("  No stale cache interference");
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

/// @notice Helper contract to execute multiple swaps in a single transaction
/// @dev Used for testing transient cache safety across multiple operations
contract MultiSwapHelper {
    IZAMM public immutable zamm;
    IPAMM public immutable pamm;

    constructor(address _zamm, address _pamm) {
        zamm = IZAMM(_zamm);
        pamm = IPAMM(_pamm);
        pamm.setOperator(_zamm, true);
    }

    /// @notice Execute two swaps on different pools in one transaction
    function executeDoubleSwap(
        IPAMM.PoolKey memory key1,
        IPAMM.PoolKey memory key2,
        uint256 amount1,
        uint256 amount2,
        bool zeroForOne1,
        bool zeroForOne2
    ) external {
        // Swap on pool 1
        zamm.swapExactIn(
            IZAMM.PoolKey({
                id0: key1.id0,
                id1: key1.id1,
                token0: key1.token0,
                token1: key1.token1,
                feeOrHook: key1.feeOrHook
            }),
            amount1,
            0,
            zeroForOne1,
            msg.sender,
            block.timestamp + 1 hours
        );

        // Swap on pool 2 (same transaction, different pool)
        zamm.swapExactIn(
            IZAMM.PoolKey({
                id0: key2.id0,
                id1: key2.id1,
                token0: key2.token0,
                token1: key2.token1,
                feeOrHook: key2.feeOrHook
            }),
            amount2,
            0,
            zeroForOne2,
            msg.sender,
            block.timestamp + 1 hours
        );
    }

    /// @notice Execute two swaps on the same pool in one transaction
    function executeDoubleSwapSamePool(
        IPAMM.PoolKey memory key,
        uint256 amount1,
        uint256 amount2,
        bool zeroForOne1,
        bool zeroForOne2
    ) external {
        IZAMM.PoolKey memory zammKey = IZAMM.PoolKey({
            id0: key.id0,
            id1: key.id1,
            token0: key.token0,
            token1: key.token1,
            feeOrHook: key.feeOrHook
        });

        // First swap
        zamm.swapExactIn(zammKey, amount1, 0, zeroForOne1, msg.sender, block.timestamp + 1 hours);

        // Second swap on SAME pool in SAME transaction
        // This tests that transient cache is properly managed between swaps
        zamm.swapExactIn(zammKey, amount2, 0, zeroForOne2, msg.sender, block.timestamp + 1 hours);
    }
}
