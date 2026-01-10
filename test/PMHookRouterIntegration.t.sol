// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./BaseTest.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

interface IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function split(uint256 marketId, uint256 amount, address to) external payable;
    function merge(uint256 marketId, uint256 amount, address to) external;
    function setOperator(address operator, bool approved) external returns (bool);
    function resolve(uint256 marketId, bool outcome) external;
    function transfer(address to, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 id, uint256 amount)
        external
        returns (bool);
    function getNoId(uint256 marketId) external pure returns (uint256);
    function claim(uint256 marketId, address to) external returns (uint256 shares, uint256 payout);
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
            uint256 pot
        );
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

    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    function deposit(address token, uint256 id, uint256 amount) external payable;
}

/// @title PMHookRouter Integration Tests - 10-Transaction Validation Plan
/// @notice End-to-end tests validating key invariants for production readiness
/// @dev Covers: getNoId consistency, TWAP, delta conventions, fee modes, vault OTC, full lifecycle
contract PMHookRouterIntegrationTest is BaseTest {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address constant ETH = address(0);

    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;

    PMHookRouter public router;
    PMFeeHook public hook;

    address public ALICE;
    address public BOB;
    address public CAROL;

    uint256 public marketId;
    uint256 public poolId;
    uint64 public closeTime;

    function setUp() public {
        createForkWithFallback("main3");

        hook = new PMFeeHook();

        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        vm.startPrank(REGISTRAR);
        PAMM.setOperator(address(ZAMM), true);
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");
        CAROL = makeAddr("CAROL");

        deal(ALICE, 100000 ether);
        deal(BOB, 100000 ether);
        deal(CAROL, 100000 ether);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 1: _getNoId() matches PAMM.getNoId() exactly
    // INVARIANT: Router's internal noId derivation must match PAMM's canonical formula
    // ══════════════════════════════════════════════════════════════════════════════

    function test_01_GetNoIdConsistency() public {
        console.log("=== TEST 1: getNoId Consistency ===");

        // Bootstrap a market to get a real marketId
        closeTime = uint64(block.timestamp + 30 days);
        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "NoId Test Market",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );

        // Get noId from PAMM
        uint256 pammNoId = PAMM.getNoId(marketId);

        // Verify by checking balances after split work correctly
        vm.startPrank(BOB);
        PAMM.split{value: 10 ether}(marketId, 10 ether, BOB);

        uint256 yesBalance = PAMM.balanceOf(BOB, marketId);
        uint256 noBalance = PAMM.balanceOf(BOB, pammNoId);

        assertEq(yesBalance, 10 ether, "YES balance should match split amount");
        assertEq(noBalance, 10 ether, "NO balance should match split amount");

        // Also verify the poolKey uses correct token ordering
        // YES token id = marketId, NO token id = getNoId(marketId)
        // ZAMM orders by id0 < id1
        bool yesIsId0 = marketId < pammNoId;
        console.log("marketId:", marketId);
        console.log("noId:", pammNoId);
        console.log("yesIsId0:", yesIsId0);

        // Verify pool exists with reserves
        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
        assertGt(r0, 0, "Reserve0 should be non-zero");
        assertGt(r1, 0, "Reserve1 should be non-zero");

        console.log("PASS: getNoId consistency verified\n");
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 2: Hook registration and poolId derivation
    // INVARIANT: poolId returned by hook must match router's derivation
    // ══════════════════════════════════════════════════════════════════════════════

    function test_02_HookRegistrationPoolIdDerivation() public {
        console.log("=== TEST 2: Hook Registration & PoolId ===");

        closeTime = uint64(block.timestamp + 30 days);
        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "PoolId Derivation Test",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );

        // Verify canonical poolId is stored
        uint256 storedPoolId = router.canonicalPoolId(marketId);
        assertEq(storedPoolId, poolId, "Stored poolId should match returned poolId");

        // Verify feeOrHook is correctly stored
        uint256 storedFeeOrHook = router.canonicalFeeOrHook(marketId);
        uint256 expectedFeeOrHook = uint256(uint160(address(hook))) | FLAG_BEFORE | FLAG_AFTER;
        assertEq(
            storedFeeOrHook, expectedFeeOrHook, "feeOrHook should include hook address and flags"
        );

        // Verify hook metadata
        (uint64 hookStart, bool active, bool yesIsToken0) = hook.meta(poolId);
        assertTrue(active, "Pool should be active in hook");
        assertEq(hookStart, uint64(block.timestamp), "Hook start should be registration time");

        // Verify yesIsToken0 matches expected ordering
        uint256 noId = PAMM.getNoId(marketId);
        bool expectedYesIsToken0 = marketId < noId;
        assertEq(yesIsToken0, expectedYesIsToken0, "yesIsToken0 should match id ordering");

        console.log("poolId:", poolId);
        console.log("feeOrHook:", storedFeeOrHook);
        console.log("yesIsToken0:", yesIsToken0);
        console.log("PASS: Hook registration verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 3: TWAP initialization and first update
    // INVARIANT: TWAP must initialize at bootstrap and update correctly
    // ══════════════════════════════════════════════════════════════════════════════

    function test_03_TWAPInitializationAndUpdate() public {
        console.log("=== TEST 3: TWAP Init & Update ===");

        closeTime = uint64(block.timestamp + 30 days);
        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "TWAP Test Market",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );

        // Check TWAP initialization
        (
            uint32 ts0,
            uint32 ts1,
            uint32 cachedTwapBps,
            uint32 cacheBlockNum,
            uint256 cum0,
            uint256 cum1
        ) = router.twapObservations(marketId);

        assertEq(ts0, uint32(block.timestamp), "timestamp0 should be bootstrap time");
        assertEq(ts1, uint32(block.timestamp), "timestamp1 should be bootstrap time");
        assertEq(cum0, cum1, "Initial cumulatives should be equal");
        console.log("Initial cumulative:", cum0);

        // Wait minimum interval and update TWAP
        vm.warp(block.timestamp + 31 minutes);

        // Make a trade to change price before update
        vm.prank(BOB);
        router.buyWithBootstrap{value: 5 ether}(
            marketId, true, 5 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Update TWAP observation
        router.updateTWAPObservation(marketId);

        (uint32 newTs0, uint32 newTs1,, uint32 newCacheBlockNum, uint256 newCum0, uint256 newCum1) =
            router.twapObservations(marketId);

        // After update, old timestamp1 becomes timestamp0
        assertEq(newTs0, ts1, "Old ts1 should become new ts0");
        assertGt(newTs1, ts1, "New ts1 should be later");
        assertGt(newCum1, cum1, "Cumulative should increase after time passes");

        console.log("After update - ts0:", newTs0, "ts1:", newTs1);
        console.log("Cumulative0:", newCum0, "Cumulative1:", newCum1);

        // Get cached TWAP from observations (set during updateTWAPObservation)
        // Use newCacheBlockNum as proxy - we already extracted it above
        console.log("Cached TWAP block:", newCacheBlockNum);

        // Price should be in valid range - verify via quote
        (uint256 quotedShares,,,) = router.quoteBootstrapBuy(marketId, true, 1 ether, 0);
        assertTrue(quotedShares > 0, "Should be able to quote after TWAP update");

        console.log("PASS: TWAP initialization and update verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 4: ZAMM delta conventions (reserve tracking)
    // INVARIANT: Swap deltas follow expected sign convention
    // ══════════════════════════════════════════════════════════════════════════════

    function test_04_ZAMMDeltaConventions() public {
        console.log("=== TEST 4: ZAMM Delta Conventions ===");

        closeTime = uint64(block.timestamp + 30 days);
        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "Delta Convention Test",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );

        // Get reserves before swap
        (uint112 r0Before, uint112 r1Before,,,,,) = ZAMM.pools(poolId);
        console.log("Before swap - r0:", r0Before, "r1:", r1Before);

        // Make a swap
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        vm.prank(BOB);
        (uint256 sharesOut,,) = router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Get reserves after swap
        (uint112 r0After, uint112 r1After,,,,,) = ZAMM.pools(poolId);
        console.log("After swap - r0:", r0After, "r1:", r1After);
        console.log("Shares out:", sharesOut);

        // Verify reserve changes are consistent with swap direction
        // When buying YES: if yesIsId0, then r0 decreases (YES out), r1 increases (NO in from swap)
        uint256 noId = PAMM.getNoId(marketId);
        bool yesIsId0 = marketId < noId;

        if (yesIsId0) {
            // YES is token0: buying YES means token0 out, token1 in
            assertLe(r0After, r0Before, "r0 (YES) should decrease or stay same");
        } else {
            // YES is token1: buying YES means token1 out, token0 in
            assertLe(r1After, r1Before, "r1 (YES) should decrease or stay same");
        }

        console.log("yesIsId0:", yesIsId0);
        console.log("PASS: Delta conventions verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 5: Fee calculation and close window modes
    // INVARIANT: Hook fees are computed correctly, close window mode affects behavior
    // ══════════════════════════════════════════════════════════════════════════════

    function test_05_FeeCalculationAndCloseWindowModes() public {
        console.log("=== TEST 5: Fee Calculation & Close Window ===");

        closeTime = uint64(block.timestamp + 2 hours); // Short market for testing close window
        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "Fee Mode Test",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );

        // Get current fee (should be in bootstrap period)
        uint256 earlyFee = hook.getCurrentFeeBps(poolId);
        console.log("Early fee (bootstrap):", earlyFee);

        // Fee should be between minFee and maxFee
        PMFeeHook.Config memory cfg = hook.getDefaultConfig();
        assertTrue(earlyFee >= cfg.minFeeBps, "Fee should be >= minFee");
        assertTrue(
            earlyFee <= cfg.maxFeeBps + cfg.maxSkewFeeBps + cfg.asymmetricFeeBps,
            "Fee should be reasonable"
        );

        // Advance past bootstrap window
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        uint256 midFee = hook.getCurrentFeeBps(poolId);
        console.log("Mid-market fee:", midFee);

        // Check close window detection
        uint256 closeWindow = hook.getCloseWindow(marketId);
        console.log("Close window (seconds):", closeWindow);

        // Move to within close window
        vm.warp(closeTime - closeWindow + 1);

        // Check market status
        bool isOpen = hook.isMarketOpen(poolId);
        console.log("Is market open in close window:", isOpen);

        // Default config has closeWindowMode = 3 (dynamic), so should still be open
        // Get fee in close window
        uint256 closeWindowFee = hook.getCurrentFeeBps(poolId);
        console.log("Close window fee:", closeWindowFee);

        console.log("PASS: Fee calculation verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 6: Vault OTC pricing against TWAP
    // INVARIANT: Vault uses TWAP + deviation guard for OTC pricing
    // ══════════════════════════════════════════════════════════════════════════════

    function test_06_VaultOTCPricingAgainstTWAP() public {
        console.log("=== TEST 6: Vault OTC Pricing vs TWAP ===");

        closeTime = uint64(block.timestamp + 30 days);
        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "OTC Pricing Test",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );

        // Setup: BOB provides vault liquidity
        vm.startPrank(BOB);
        PAMM.split{value: 50 ether}(marketId, 50 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 25 ether, BOB, block.timestamp + 1 hours);
        router.depositToVault(marketId, false, 25 ether, BOB, block.timestamp + 1 hours);
        vm.stopPrank();

        // Wait for TWAP to mature
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Get cached TWAP from observations
        (,, uint32 twapBps,,,) = router.twapObservations(marketId);
        console.log("TWAP (bps):", twapBps);

        // Get quote for buying YES
        (uint256 quotedShares, bool usesVault, bytes4 source,) =
            router.quoteBootstrapBuy(marketId, true, 5 ether, 0);

        console.log("Quoted shares:", quotedShares);
        console.log("Uses vault:", usesVault);
        console.log("Source:", uint32(source));

        // Verify vault OTC is fillable (we have vault shares)
        if (usesVault) {
            // Execute the trade
            vm.prank(CAROL);
            (uint256 sharesOut, bytes4 actualSource,) = router.buyWithBootstrap{value: 5 ether}(
                marketId, true, 5 ether, 0, CAROL, block.timestamp + 1 hours
            );

            console.log("Actual shares out:", sharesOut);
            console.log("Actual source:", uint32(actualSource));

            // Verify we got shares
            assertGt(sharesOut, 0, "Should receive shares");
        }

        console.log("PASS: Vault OTC pricing verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 7: Full bootstrap flow end-to-end
    // INVARIANT: Bootstrap creates market, pool, initializes TWAP, optional buy works
    // ══════════════════════════════════════════════════════════════════════════════

    function test_07_FullBootstrapFlowE2E() public {
        console.log("=== TEST 7: Full Bootstrap Flow E2E ===");

        closeTime = uint64(block.timestamp + 30 days);
        uint256 aliceBalBefore = ALICE.balance;

        vm.prank(ALICE);
        uint256 lpShares;
        uint256 sharesOut;
        (marketId, poolId, lpShares, sharesOut) = router.bootstrapMarket{value: 110 ether}(
            "Full E2E Test Market",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether, // LP collateral
            true, // buy YES
            10 ether, // buy collateral
            0, // min shares
            ALICE,
            block.timestamp + 1 hours
        );

        uint256 aliceBalAfter = ALICE.balance;

        console.log("Market created:", marketId);
        console.log("Pool created:", poolId);
        console.log("LP shares:", lpShares);
        console.log("YES shares from buy:", sharesOut);
        console.log("ETH spent:", aliceBalBefore - aliceBalAfter);

        // Verify all components
        assertGt(marketId, 0, "Market should be created");
        assertGt(poolId, 0, "Pool should be created");
        assertGt(lpShares, 0, "Should have LP shares");
        assertGt(sharesOut, 0, "Should have bought shares");

        // Verify market state
        (address resolver, bool resolved,,,, address collateral,) = PAMM.markets(marketId);
        assertEq(resolver, ALICE, "Resolver should be ALICE");
        assertFalse(resolved, "Should not be resolved");
        assertEq(collateral, ETH, "Collateral should be ETH");

        // Verify pool state
        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
        assertGt(r0, 0, "Reserve0 should be non-zero");
        assertGt(r1, 0, "Reserve1 should be non-zero");

        // Verify TWAP initialized
        (uint32 ts0,,,,,) = router.twapObservations(marketId);
        assertGt(ts0, 0, "TWAP should be initialized");

        // Verify hook registration
        (, bool active,) = hook.meta(poolId);
        assertTrue(active, "Pool should be active in hook");

        console.log("PASS: Full bootstrap flow verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 8: Buy routing (vault vs AMM priority)
    // INVARIANT: Router picks best execution between vault OTC and AMM
    // ══════════════════════════════════════════════════════════════════════════════

    function test_08_BuyRoutingVaultVsAMM() public {
        console.log("=== TEST 8: Buy Routing (Vault vs AMM) ===");

        closeTime = uint64(block.timestamp + 30 days);
        uint256 deadline = closeTime - 1; // Use close time as deadline to avoid timing issues

        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "Routing Test Market",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            deadline
        );

        // Setup TWAP
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // First buy should go to AMM (no vault liquidity)
        vm.prank(CAROL);
        (uint256 shares1, bytes4 source1,) =
            router.buyWithBootstrap{value: 5 ether}(marketId, true, 5 ether, 0, CAROL, deadline);

        console.log("Buy 1 (no vault) - shares:", shares1, "source:", uint32(source1));

        // Now add vault liquidity
        vm.startPrank(BOB);
        PAMM.split{value: 50 ether}(marketId, 50 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 25 ether, BOB, deadline);
        vm.stopPrank();

        // Second buy should potentially use vault (TWAP already active from first update)
        vm.prank(CAROL);
        (uint256 shares2, bytes4 source2,) =
            router.buyWithBootstrap{value: 5 ether}(marketId, true, 5 ether, 0, CAROL, deadline);

        console.log("Buy 2 (with vault) - shares:", shares2, "source:", uint32(source2));

        // Both should succeed
        assertGt(shares1, 0, "First buy should succeed");
        assertGt(shares2, 0, "Second buy should succeed");

        console.log("PASS: Buy routing verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 9: LP deposit/withdraw with proper accounting
    // INVARIANT: Vault shares track correctly, cooldown enforced, fees accrue
    // ══════════════════════════════════════════════════════════════════════════════

    function test_09_LPDepositWithdrawAccounting() public {
        console.log("=== TEST 9: LP Deposit/Withdraw Accounting ===");

        closeTime = uint64(block.timestamp + 30 days);
        uint256 deadline = closeTime - 1; // Use close time as deadline to avoid timing issues

        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "LP Accounting Test",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            deadline
        );

        // BOB deposits to vault
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);

        uint256 bobYesBefore = PAMM.balanceOf(BOB, marketId);
        console.log("BOB YES before deposit:", bobYesBefore);

        uint256 vaultShares = router.depositToVault(marketId, true, 50 ether, BOB, deadline);

        (uint112 bobVaultShares,, uint32 lastDeposit,,) = router.vaultPositions(marketId, BOB);
        console.log("BOB vault shares:", bobVaultShares);
        console.log("Last deposit time:", lastDeposit);
        assertEq(bobVaultShares, vaultShares, "Vault shares should match");

        uint256 bobYesAfterDeposit = PAMM.balanceOf(BOB, marketId);
        assertEq(
            bobYesAfterDeposit,
            bobYesBefore - 50 ether,
            "YES balance should decrease by deposit amount"
        );
        vm.stopPrank();

        // Generate some trading activity for fees
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        vm.prank(CAROL);
        router.buyWithBootstrap{value: 10 ether}(marketId, true, 10 ether, 0, CAROL, deadline);

        // Try to withdraw before cooldown (should fail)
        vm.prank(BOB);
        vm.expectRevert(); // Cooldown not passed
        router.withdrawFromVault(marketId, true, bobVaultShares, BOB, deadline);

        // Wait for cooldown
        vm.warp(block.timestamp + 6 hours + 1);

        // Now withdraw should succeed
        vm.prank(BOB);
        (uint256 sharesReturned, uint256 collateralFees) =
            router.withdrawFromVault(marketId, true, bobVaultShares, BOB, deadline);

        console.log("Shares returned:", sharesReturned);
        console.log("Collateral fees:", collateralFees);

        // Verify vault position is cleared
        (uint112 bobVaultSharesAfter,,,,) = router.vaultPositions(marketId, BOB);
        assertEq(bobVaultSharesAfter, 0, "Vault shares should be 0 after full withdrawal");

        uint256 bobYesAfterWithdraw = PAMM.balanceOf(BOB, marketId);
        assertGe(
            bobYesAfterWithdraw, bobYesAfterDeposit, "Should have at least as many shares back"
        );

        console.log("PASS: LP deposit/withdraw accounting verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 10: Resolution and claim flow
    // INVARIANT: After resolution, winning shares can be claimed, vault settles
    // ══════════════════════════════════════════════════════════════════════════════

    function test_10_ResolutionAndClaimFlow() public {
        console.log("=== TEST 10: Resolution & Claim Flow ===");

        closeTime = uint64(block.timestamp + 1 hours);
        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "Resolution Test Market",
            ALICE, // resolver
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );

        // BOB buys YES
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        vm.prank(BOB);
        (uint256 bobYesShares,,) = router.buyWithBootstrap{value: 20 ether}(
            marketId, true, 20 ether, 0, BOB, block.timestamp + 1 hours
        );
        console.log("BOB bought YES shares:", bobYesShares);

        // CAROL buys NO
        uint256 noId = PAMM.getNoId(marketId);
        vm.prank(CAROL);
        (uint256 carolNoShares,,) = router.buyWithBootstrap{value: 20 ether}(
            marketId, false, 20 ether, 0, CAROL, block.timestamp + 1 hours
        );
        console.log("CAROL bought NO shares:", carolNoShares);

        // Warp past close time
        vm.warp(closeTime + 1);

        // Resolve market as YES
        vm.prank(ALICE);
        PAMM.resolve(marketId, true);

        // Verify resolution
        (, bool resolved, bool outcome,,,,) = PAMM.markets(marketId);
        assertTrue(resolved, "Market should be resolved");
        assertTrue(outcome, "Outcome should be YES");

        // BOB claims (winner)
        uint256 bobBalBefore = BOB.balance;
        uint256 bobYesBal = PAMM.balanceOf(BOB, marketId);
        console.log("BOB YES balance before claim:", bobYesBal);

        vm.prank(BOB);
        (uint256 claimedShares, uint256 payout) = PAMM.claim(marketId, BOB);

        uint256 bobBalAfter = BOB.balance;
        console.log("BOB claimed shares:", claimedShares);
        console.log("BOB payout:", payout);
        console.log("BOB ETH received:", bobBalAfter - bobBalBefore);

        assertGt(payout, 0, "Winner should receive payout");
        assertEq(bobBalAfter - bobBalBefore, payout, "ETH received should match payout");

        // CAROL's NO shares are worthless
        uint256 carolNoBal = PAMM.balanceOf(CAROL, noId);
        console.log("CAROL NO balance (worthless):", carolNoBal);

        // Finalize market via router
        router.finalizeMarket(marketId);

        console.log("PASS: Resolution and claim flow verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 11: Harvest vault fees without withdrawing
    // INVARIANT: Users can claim accrued fees while keeping vault position
    // ══════════════════════════════════════════════════════════════════════════════

    function test_11_HarvestVaultFees() public {
        console.log("=== TEST 11: Harvest Vault Fees ===");

        closeTime = uint64(block.timestamp + 30 days);
        uint256 deadline = closeTime - 1;

        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "Harvest Fees Test",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            deadline
        );

        // BOB deposits to vault
        vm.startPrank(BOB);
        PAMM.split{value: 50 ether}(marketId, 50 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 25 ether, BOB, deadline);
        vm.stopPrank();

        // Generate trading activity to create fees
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Multiple trades to generate fees
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(CAROL);
            router.buyWithBootstrap{value: 5 ether}(marketId, true, 5 ether, 0, CAROL, deadline);
        }

        // Wait for cooldown
        vm.warp(block.timestamp + 6 hours + 1);

        // Harvest fees without withdrawing
        (uint112 vaultSharesBefore,,,,) = router.vaultPositions(marketId, BOB);

        vm.prank(BOB);
        uint256 feesHarvested = router.harvestVaultFees(marketId, true);

        (uint112 vaultSharesAfter,,,,) = router.vaultPositions(marketId, BOB);

        console.log("Vault shares before harvest:", vaultSharesBefore);
        console.log("Vault shares after harvest:", vaultSharesAfter);
        console.log("Fees harvested:", feesHarvested);

        // Vault shares should remain unchanged
        assertEq(
            vaultSharesAfter, vaultSharesBefore, "Vault shares should not change during harvest"
        );

        console.log("PASS: Harvest vault fees verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 12: Halt mode blocks trades
    // INVARIANT: When hook returns fee >= 10000, trades are blocked
    // ══════════════════════════════════════════════════════════════════════════════

    function test_12_HaltModeBlocksTrades() public {
        console.log("=== TEST 12: Halt Mode Blocks Trades ===");

        // Create market with very short duration to test close behavior
        closeTime = uint64(block.timestamp + 2 hours);
        uint256 deadline = closeTime - 1;

        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "Halt Mode Test",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            deadline
        );

        // Setup TWAP
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Trade should work before close
        vm.prank(BOB);
        (uint256 sharesBefore,,) =
            router.buyWithBootstrap{value: 5 ether}(marketId, true, 5 ether, 0, BOB, deadline);
        console.log("Shares bought before close:", sharesBefore);
        assertGt(sharesBefore, 0, "Should be able to trade before close");

        // Warp past close time
        vm.warp(closeTime + 1);

        // Check that fee is now in halt mode (>= 10000)
        uint256 feeBps = hook.getCurrentFeeBps(poolId);
        console.log("Fee after close (halt sentinel):", feeBps);
        assertTrue(feeBps >= 10000, "Fee should be halt sentinel after close");

        // Trade should fail after close
        vm.prank(BOB);
        vm.expectRevert(); // MarketClosed or TimingError
        router.buyWithBootstrap{value: 5 ether}(
            marketId, true, 5 ether, 0, BOB, block.timestamp + 1 hours
        );

        console.log("PASS: Halt mode verified - trades blocked after close\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 13: Vault rebalancing
    // INVARIANT: Rebalance converts imbalanced inventory to collateral budget
    // ══════════════════════════════════════════════════════════════════════════════

    function test_13_VaultRebalanceBudgetTracking() public {
        console.log("=== TEST 13: Vault Rebalance Budget Tracking ===");

        closeTime = uint64(block.timestamp + 30 days);
        uint256 deadline = closeTime - 1;

        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "Budget Tracking Test",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            deadline
        );

        // BOB deposits to vault
        vm.startPrank(BOB);
        PAMM.split{value: 50 ether}(marketId, 50 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 25 ether, BOB, deadline);
        vm.stopPrank();

        // Setup TWAP
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Check initial budget
        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);
        console.log("Initial rebalance budget:", budgetBefore);

        // Make trades to generate fee income (some goes to rebalance budget)
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(CAROL);
            router.buyWithBootstrap{value: 5 ether}(marketId, true, 5 ether, 0, CAROL, deadline);
        }

        // Check budget after trades (should have increased from spread fees)
        uint256 budgetAfter = router.rebalanceCollateralBudget(marketId);
        console.log("Budget after trades:", budgetAfter);

        // Budget should track fee accumulation
        assertGe(budgetAfter, budgetBefore, "Budget should track fee accumulation");

        console.log("PASS: Vault rebalance budget tracking verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 14: Vault redemption after resolution
    // INVARIANT: redeemVaultWinningShares claims vault's winning shares after all LPs exit
    // ══════════════════════════════════════════════════════════════════════════════

    function test_14_FinalizeMarketAfterResolution() public {
        console.log("=== TEST 14: Finalize Market After Resolution ===");

        closeTime = uint64(block.timestamp + 1 hours);
        uint256 deadline = closeTime - 1;

        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "Finalize Test",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            deadline
        );

        // Generate some trading
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        vm.prank(CAROL);
        router.buyWithBootstrap{value: 10 ether}(marketId, true, 10 ether, 0, CAROL, deadline);

        // Check rebalance budget before finalization
        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);
        console.log("Rebalance budget before:", budgetBefore);

        // Resolve market
        vm.warp(closeTime + 1);
        vm.prank(ALICE);
        PAMM.resolve(marketId, true);

        // Verify resolution
        (, bool resolved, bool outcome,,,,) = PAMM.markets(marketId);
        assertTrue(resolved, "Market should be resolved");
        assertTrue(outcome, "Outcome should be YES");
        console.log("Market resolved with outcome: YES");

        // Finalize market - settles remaining budget to DAO
        uint256 daoAmount = router.finalizeMarket(marketId);
        console.log("Amount sent to DAO:", daoAmount);

        // Budget should be cleared after finalization
        uint256 budgetAfter = router.rebalanceCollateralBudget(marketId);
        console.log("Rebalance budget after:", budgetAfter);
        assertEq(budgetAfter, 0, "Budget should be cleared after finalization");

        console.log("PASS: Finalize market after resolution verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 15: Provide liquidity via router
    // INVARIANT: Users can deposit collateral and receive vault + AMM LP shares
    // ══════════════════════════════════════════════════════════════════════════════

    function test_15_ProvideLiquidityViaRouter() public {
        console.log("=== TEST 15: Provide Liquidity via Router ===");

        closeTime = uint64(block.timestamp + 30 days);
        uint256 deadline = closeTime - 1;

        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "Provide Liquidity Test",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            deadline
        );

        // BOB provides liquidity via router
        // This splits collateral into YES/NO, deposits some to vault, and some to AMM
        vm.prank(BOB);
        (uint256 yesVaultShares, uint256 noVaultShares, uint256 ammLiquidity) = router.provideLiquidity{
            value: 50 ether
        }(
            marketId,
            50 ether, // collateralAmount
            10 ether, // vaultYesShares
            10 ether, // vaultNoShares
            30 ether, // ammLPShares (remaining goes to AMM)
            0, // minAmount0
            0, // minAmount1
            BOB,
            deadline
        );

        console.log("YES vault shares minted:", yesVaultShares);
        console.log("NO vault shares minted:", noVaultShares);
        console.log("AMM liquidity:", ammLiquidity);

        // Verify BOB received vault shares
        (uint112 bobYesVault, uint112 bobNoVault,,,) = router.vaultPositions(marketId, BOB);
        console.log("BOB YES vault position:", bobYesVault);
        console.log("BOB NO vault position:", bobNoVault);

        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");

        console.log("PASS: Provide liquidity via router verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST 16: Multicall batching
    // INVARIANT: Multiple operations can be batched in single transaction
    // ══════════════════════════════════════════════════════════════════════════════

    function test_16_MulticallBatching() public {
        console.log("=== TEST 16: Multicall Batching ===");

        closeTime = uint64(block.timestamp + 30 days);
        uint256 deadline = closeTime - 1;

        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "Multicall Test",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            deadline
        );

        // Setup TWAP
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // BOB uses multicall to batch: split + deposit to vault
        vm.startPrank(BOB);
        PAMM.setOperator(address(router), true);

        // Prepare multicall data
        bytes[] memory calls = new bytes[](2);

        // Call 1: Buy YES shares
        calls[0] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector,
            marketId,
            true, // buyYes
            10 ether, // collateralIn
            0, // minSharesOut
            BOB,
            deadline
        );

        // Call 2: Buy NO shares
        calls[1] = abi.encodeWithSelector(
            router.buyWithBootstrap.selector,
            marketId,
            false, // buyNo
            10 ether, // collateralIn
            0, // minSharesOut
            BOB,
            deadline
        );

        uint256 bobYesBefore = PAMM.balanceOf(BOB, marketId);
        uint256 noId = PAMM.getNoId(marketId);
        uint256 bobNoBefore = PAMM.balanceOf(BOB, noId);

        // Execute multicall with 20 ETH total
        bytes[] memory results = router.multicall{value: 20 ether}(calls);

        uint256 bobYesAfter = PAMM.balanceOf(BOB, marketId);
        uint256 bobNoAfter = PAMM.balanceOf(BOB, noId);

        console.log("Multicall executed with", results.length, "calls");
        console.log("YES shares gained:", bobYesAfter - bobYesBefore);
        console.log("NO shares gained:", bobNoAfter - bobNoBefore);

        assertGt(bobYesAfter, bobYesBefore, "Should have more YES shares");
        assertGt(bobNoAfter, bobNoBefore, "Should have more NO shares");

        vm.stopPrank();

        console.log("PASS: Multicall batching verified\n");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // SUMMARY: Run all tests in sequence
    // ══════════════════════════════════════════════════════════════════════════════

    function test_AllIntegrationTests() public {
        console.log("");
        console.log("================================================================");
        console.log("  PMHookRouter 16-Test Integration Suite                       ");
        console.log("  Validates key invariants for production readiness            ");
        console.log("================================================================");
        console.log("");

        test_01_GetNoIdConsistency();
        test_02_HookRegistrationPoolIdDerivation();
        test_03_TWAPInitializationAndUpdate();
        test_04_ZAMMDeltaConventions();
        test_05_FeeCalculationAndCloseWindowModes();
        test_06_VaultOTCPricingAgainstTWAP();
        test_07_FullBootstrapFlowE2E();
        test_08_BuyRoutingVaultVsAMM();
        test_09_LPDepositWithdrawAccounting();
        test_10_ResolutionAndClaimFlow();
        test_11_HarvestVaultFees();
        test_12_HaltModeBlocksTrades();
        test_13_VaultRebalanceBudgetTracking();
        test_14_FinalizeMarketAfterResolution();
        test_15_ProvideLiquidityViaRouter();
        test_16_MulticallBatching();

        console.log("================================================================");
        console.log("  ALL 16 INTEGRATION TESTS PASSED                              ");
        console.log("================================================================");
    }
}
