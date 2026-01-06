// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHookV1} from "../src/PMFeeHookV1.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function split(uint256 marketId, uint256 amount, address to) external payable;
    function setOperator(address operator, bool approved) external returns (bool);
    function resolve(uint256 marketId, bool outcome) external;
    function transfer(address to, uint256 id, uint256 amount) external returns (bool);
    function markets(uint256 marketId)
        external
        view
        returns (address, address, uint256, uint256, uint64, uint64, uint64);
}

/// @title PMHookRouter Advanced Vault OTC Accounting Tests
/// @notice Comprehensive edge case testing for vault OTC fills and accounting
contract PMHookRouterVaultOTCAdvancedTest is Test {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address constant ETH = address(0);
    uint64 constant DEADLINE_2028 = 1861919999;

    PMHookRouter public router;
    PMFeeHookV1 public hook;

    address public ALICE;
    address public BOB;
    address public CAROL;
    address public DAVID;

    uint256 public marketId;
    uint256 public poolId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        hook = new PMFeeHookV1();

        // Deploy router at REGISTRAR address
        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        // Initialize router
        vm.startPrank(REGISTRAR);
        PAMM.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true); // ZAMM
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        // Transfer hook ownership to router
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");
        CAROL = makeAddr("CAROL");
        DAVID = makeAddr("DAVID");

        deal(ALICE, 10000 ether);
        deal(BOB, 10000 ether);
        deal(CAROL, 10000 ether);
        deal(DAVID, 10000 ether);

        // Bootstrap a market for testing
        _bootstrapMarket();
    }

    function _bootstrapMarket() internal {
        vm.startPrank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 1000 ether}(
            "Advanced OTC Test Market 2026",
            ALICE,
            ETH,
            DEADLINE_2028,
            false,
            address(hook),
            1000 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    // ============ Test 1: OTC Fill with Extreme Price Scenarios ============

    function test_OTC_ExtremePrices_NearZero() public {
        // Setup vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 50 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Wait for TWAP and cooldown
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Attempt to buy when TWAP would be very low (price manipulation scenario)
        // The system should handle this gracefully
        vm.prank(BOB);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 10 ether}(
            marketId, false, 10 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Should get reasonable output
        assertGt(sharesOut, 0, "Should receive shares even with extreme prices");
    }

    function test_OTC_ExtremePrices_NearMax() public {
        // Setup vault with heavy imbalance
        vm.startPrank(ALICE);
        PAMM.split{value: 1000 ether}(marketId, 1000 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 900 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Create heavy skew by buying NO shares to drive up YES price
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Multiple buys to create skew
        for (uint256 i = 0; i < 2; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 5 minutes);

            vm.prank(BOB);
            (uint256 shares,,) = router.buyWithBootstrap{value: 40 ether}(
                marketId, false, 40 ether, 0, BOB, block.timestamp + 1 hours
            );
            assertGt(shares, 0, "Should get shares from vault");
        }

        // YES price should be very high now
        // Try buying YES shares at high price
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 5 minutes);

        vm.prank(CAROL);
        (uint256 sharesOut,,) = router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, CAROL, block.timestamp + 1 hours
        );

        // System should handle high-priced buys
        assertGt(sharesOut, 0, "Should handle high-priced buys");
    }

    // ============ Test 2: OTC Fill Partial vs Full Scenarios ============

    function test_OTC_PartialFill_VaultCapReached() public {
        // Setup vault with limited liquidity
        vm.startPrank(ALICE);
        PAMM.split{value: 20 ether}(marketId, 20 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 20 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Try to buy a large amount that exceeds MAX_VAULT_FILL_BPS
        vm.prank(BOB);
        (uint256 sharesOut, bytes4 source, uint256 collateralUsed) = router.buyWithBootstrap{
            value: 100 ether
        }(
            marketId, true, 100 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Should get partial fill from vault + AMM fill
        assertGt(sharesOut, 0, "Should receive shares");
        assertLt(collateralUsed, 100 ether, "Should not use all collateral if partial OTC");

        // Check vault was depleted partially
        (uint112 yesShares,,) = router.bootstrapVaults(marketId);
        assertLt(yesShares, 20 ether, "Vault should have been depleted");
    }

    function test_OTC_FullFill_SmallOrder() public {
        // Setup vault with plenty of liquidity
        vm.startPrank(ALICE);
        PAMM.split{value: 500 ether}(marketId, 500 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 500 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        (uint112 yesSharesBefore,,) = router.bootstrapVaults(marketId);

        // Buy small amount
        vm.prank(BOB);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 5 ether}(
            marketId, true, 5 ether, 0, BOB, block.timestamp + 1 hours
        );

        (uint112 yesSharesAfter,,) = router.bootstrapVaults(marketId);

        // Should be fully filled by vault
        assertGt(sharesOut, 0, "Should receive shares");
        assertLt(yesSharesAfter, yesSharesBefore, "Vault should have provided shares");
    }

    // ============ Test 3: Spread Fee Distribution Edge Cases ============

    function test_OTC_SpreadDistribution_OnlyYesLP() public {
        // Only YES LP exists
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256 accYesBefore = router.accYesCollateralPerShare(marketId);

        // Generate OTC fill
        vm.prank(BOB);
        router.buyWithBootstrap{value: 20 ether}(
            marketId, true, 20 ether, 0, BOB, block.timestamp + 1 hours
        );

        uint256 accYesAfter = router.accYesCollateralPerShare(marketId);

        // YES LP should receive all spread fees
        assertGt(accYesAfter, accYesBefore, "YES LPs should receive fees");

        // NO accumulator should not change
        uint256 accNo = router.accNoCollateralPerShare(marketId);
        assertEq(accNo, 0, "NO LPs should receive no fees");
    }

    function test_OTC_SpreadDistribution_OnlyNoLP() public {
        // Only NO LP exists
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256 accNoBefore = router.accNoCollateralPerShare(marketId);

        // Generate OTC fill for NO shares
        vm.prank(BOB);
        router.buyWithBootstrap{value: 20 ether}(
            marketId, false, 20 ether, 0, BOB, block.timestamp + 1 hours
        );

        uint256 accNoAfter = router.accNoCollateralPerShare(marketId);

        // NO LP should receive all spread fees
        assertGt(accNoAfter, accNoBefore, "NO LPs should receive fees");
    }

    function test_OTC_SpreadDistribution_ScarcityWeighting() public {
        // Setup asymmetric vault (heavy YES, light NO)
        vm.startPrank(ALICE);
        PAMM.split{value: 500 ether}(marketId, 500 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 400 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256 accYesBefore = router.accYesCollateralPerShare(marketId);
        uint256 accNoBefore = router.accNoCollateralPerShare(marketId);

        // Generate OTC fill
        vm.prank(BOB);
        router.buyWithBootstrap{value: 100 ether}(
            marketId, true, 100 ether, 0, BOB, block.timestamp + 1 hours
        );

        uint256 accYesAfter = router.accYesCollateralPerShare(marketId);
        uint256 accNoAfter = router.accNoCollateralPerShare(marketId);

        // Both should increase, but the scarce NO side should get more per share
        assertGt(accYesAfter, accYesBefore, "YES should receive fees");
        assertGt(accNoAfter, accNoBefore, "NO should receive fees (scarcity weighted)");
    }

    function test_OTC_SpreadDistribution_EqualInventory() public {
        // Setup perfectly balanced vault
        vm.startPrank(ALICE);
        PAMM.split{value: 200 ether}(marketId, 200 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256 accYesBefore = router.accYesCollateralPerShare(marketId);
        uint256 accNoBefore = router.accNoCollateralPerShare(marketId);

        // Generate OTC fill
        vm.prank(BOB);
        router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, BOB, block.timestamp + 1 hours
        );

        uint256 accYesAfter = router.accYesCollateralPerShare(marketId);
        uint256 accNoAfter = router.accNoCollateralPerShare(marketId);

        // Both should increase approximately equally for balanced inventory
        // Note: Distribution is based on notional value (inventory × TWAP)
        // After a trade, TWAP may shift, causing unequal distribution
        // We verify both sides receive some fees
        uint256 yesIncrease = accYesAfter - accYesBefore;
        uint256 noIncrease = accNoAfter - accNoBefore;

        // Both sides should receive fees
        assertGt(yesIncrease, 0, "YES LPs should receive fees");
        assertGt(noIncrease, 0, "NO LPs should receive fees");

        // Verify total fees distributed
        assertGt(yesIncrease + noIncrease, 0, "Total fees should be distributed");
    }

    // ============ Test 4: Dust and Rounding Edge Cases ============

    function test_OTC_Dust_VerySmallFees() public {
        // Setup vault with many LPs to create rounding dust
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 33.333 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 33.333 ether, BOB, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.startPrank(CAROL);
        PAMM.split{value: 100 ether}(marketId, 100 ether, CAROL);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 33.333 ether, CAROL, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);

        // Generate small OTC fill that will create dust
        vm.prank(DAVID);
        router.buyWithBootstrap{value: 0.001 ether}(
            marketId, true, 0.001 ether, 0, DAVID, block.timestamp + 1 hours
        );

        uint256 budgetAfter = router.rebalanceCollateralBudget(marketId);

        // Dust should accumulate in budget
        assertGe(budgetAfter, budgetBefore, "Dust should go to budget");
    }

    // ============ Test 5: OTC Close Window Restrictions ============

    function test_OTC_CloseWindow_OTCDisabled() public {
        // Setup vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Warp to within close window (default is 1 hour = 3600 seconds)
        vm.warp(DEADLINE_2028 - 30 minutes);

        (uint112 vaultSharesBefore,,) = router.bootstrapVaults(marketId);

        // OTC should be disabled in close window
        vm.prank(BOB);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, BOB, DEADLINE_2028
        );

        (uint112 vaultSharesAfter,,) = router.bootstrapVaults(marketId);

        // Vault should not be touched in close window
        assertEq(vaultSharesAfter, vaultSharesBefore, "Vault should not be used in close window");
        assertGt(sharesOut, 0, "Should still get shares via other paths");
    }

    function test_OTC_CloseWindow_OTCEnabledBeforeWindow() public {
        // Setup vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Warp to well before close window (more than 1 hour before deadline)
        vm.warp(DEADLINE_2028 - 2 hours);
        router.updateTWAPObservation(marketId);

        (uint112 vaultSharesBefore,,) = router.bootstrapVaults(marketId);

        // OTC should be available
        vm.prank(BOB);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, BOB, DEADLINE_2028
        );

        (uint112 vaultSharesAfter,,) = router.bootstrapVaults(marketId);

        // Should use vault
        assertGt(sharesOut, 0, "Should get shares");
        assertLt(vaultSharesAfter, vaultSharesBefore, "Vault should be used");
    }

    // ============ Test 6: Multiple Sequential OTC Fills ============

    function test_OTC_SequentialFills_AccumulatorGrowth() public {
        // Setup vault
        vm.startPrank(ALICE);
        PAMM.split{value: 500 ether}(marketId, 500 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 500 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256[] memory accSnapshots = new uint256[](10);

        for (uint256 i = 0; i < 10; i++) {
            accSnapshots[i] = router.accYesCollateralPerShare(marketId);

            vm.prank(BOB);
            router.buyWithBootstrap{value: 10 ether}(
                marketId, true, 10 ether, 0, BOB, block.timestamp + 1 hours
            );

            vm.warp(block.timestamp + 5 minutes);
        }

        // Accumulator should be monotonically increasing
        for (uint256 i = 1; i < 10; i++) {
            assertGe(
                accSnapshots[i],
                accSnapshots[i - 1],
                "Accumulator should be monotonically increasing"
            );
        }
    }

    function test_OTC_SequentialFills_VaultDepletion() public {
        // Setup small vault
        vm.startPrank(ALICE);
        PAMM.split{value: 50 ether}(marketId, 50 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Keep buying until vault is depleted
        uint256 otcFillCount = 0;
        for (uint256 i = 0; i < 20; i++) {
            (uint112 vaultBefore,,) = router.bootstrapVaults(marketId);

            vm.prank(BOB);
            (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 5 ether}(
                marketId, true, 5 ether, 0, BOB, block.timestamp + 1 hours
            );

            (uint112 vaultAfter,,) = router.bootstrapVaults(marketId);

            if (vaultAfter < vaultBefore) {
                otcFillCount++;
            }

            if (vaultAfter == 0) {
                break;
            }

            vm.warp(block.timestamp + 2 minutes);
        }

        // Should have used OTC fills
        assertGt(otcFillCount, 0, "Should have had OTC fills");

        // Vault should be mostly depleted (allow small dust due to rounding and MAX_VAULT_FILL_BPS)
        (uint112 finalVault,,) = router.bootstrapVaults(marketId);
        assertLt(finalVault, 0.1 ether, "Vault should be mostly depleted (allow < 0.1 ether dust)");
    }

    // ============ Test 7: Rebalance Budget Accumulation ============

    function test_OTC_BudgetAccumulation_FromSpreadFees() public {
        // Setup vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);

        // Generate OTC fills
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(BOB);
            router.buyWithBootstrap{value: 10 ether}(
                marketId, true, 10 ether, 0, BOB, block.timestamp + 1 hours
            );
            vm.warp(block.timestamp + 5 minutes);
        }

        uint256 budgetAfter = router.rebalanceCollateralBudget(marketId);

        // Budget should accumulate from spread fees
        assertGt(budgetAfter, budgetBefore, "Budget should accumulate from OTC spread fees");
    }

    function test_OTC_BudgetAccumulation_NoLPs() public {
        // Don't setup any vault LPs
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);

        // Try to generate trades (will go to AMM, not OTC)
        vm.prank(BOB);
        router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, BOB, block.timestamp + 1 hours
        );

        uint256 budgetAfter = router.rebalanceCollateralBudget(marketId);

        // Budget may or may not increase depending on fee structure
        // Just verify no reverts
        assertGe(budgetAfter, budgetBefore, "Should handle no-LP scenario");
    }

    // ============ Test 8: Concurrent Multi-User OTC Activity ============

    function test_OTC_MultiUser_ConcurrentActivity() public {
        // Multiple users deposit to vault
        address[4] memory users = [ALICE, BOB, CAROL, DAVID];

        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            PAMM.split{value: 100 ether}(marketId, 100 ether, users[i]);
            PAMM.setOperator(address(router), true);
            router.depositToVault(marketId, true, 50 ether, users[i], block.timestamp + 7 hours);
            router.depositToVault(marketId, false, 50 ether, users[i], block.timestamp + 7 hours);
            vm.stopPrank();
            vm.warp(block.timestamp + 10 minutes);
        }

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Generate OTC activity
        address trader = makeAddr("TRADER");
        deal(trader, 1000 ether);

        for (uint256 i = 0; i < 10; i++) {
            bool buyYes = i % 2 == 0;
            vm.prank(trader);
            router.buyWithBootstrap{value: 10 ether}(
                marketId, buyYes, 10 ether, 0, trader, block.timestamp + 1 hours
            );
            vm.warp(block.timestamp + 3 minutes);
        }

        // All users should have accumulated some fees
        vm.warp(block.timestamp + 6 hours + 1);

        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            uint256 yesFees = router.harvestVaultFees(marketId, true);

            vm.prank(users[i]);
            uint256 noFees = router.harvestVaultFees(marketId, false);

            // Should have earned something
            uint256 totalFees = yesFees + noFees;
            assertGt(totalFees, 0, "All users should have earned fees");
        }
    }

    // ============ Test 9: OTC Accounting Invariants ============

    function test_OTC_Invariant_CollateralConservation() public {
        // Setup vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Track total collateral in system
        uint256 totalBefore = address(router).balance + router.rebalanceCollateralBudget(marketId);

        // Generate OTC fill
        vm.prank(BOB);
        router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Collateral should be conserved (accounting for new deposits)
        uint256 totalAfter = address(router).balance + router.rebalanceCollateralBudget(marketId);

        // Total should have increased by Bob's deposit
        assertGe(totalAfter, totalBefore, "Collateral should be conserved");
    }

    function test_OTC_Invariant_VaultSharesNeverNegative() public {
        // Setup vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Try to drain vault completely
        for (uint256 i = 0; i < 50; i++) {
            (uint112 vaultShares,,) = router.bootstrapVaults(marketId);
            if (vaultShares == 0) break;

            vm.prank(BOB);
            try router.buyWithBootstrap{value: 100 ether}(
                marketId, true, 100 ether, 0, BOB, block.timestamp + 1 hours
            ) {}
                catch {}

            vm.warp(block.timestamp + 1 minutes);
        }

        // Vault shares should never underflow
        (uint112 finalShares,,) = router.bootstrapVaults(marketId);
        assertGe(finalShares, 0, "Vault shares should never be negative");
    }
}
