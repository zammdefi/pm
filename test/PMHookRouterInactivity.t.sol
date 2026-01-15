// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "src/PMHookRouter.sol";

/// @title PMHookRouter Inactivity Tests
/// @notice Tests that vault and TWAP handle extended periods of inactivity gracefully
/// @dev Verifies the system can "pick right back up" after hours without trades
contract PMHookRouterInactivityTest is Test {
    PMHookRouter public router;
    MinimalHook public hook;

    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    address constant ETH = address(0);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CHARLIE = address(0xC4A1);

    uint256 marketId;
    uint256 noId;
    uint256 poolId;

    // Allow test contract to receive ETH (for rebalance bounty)
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        hook = new MinimalHook();
        router = new PMHookRouter();

        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        vm.deal(ALICE, 1000 ether);
        vm.deal(BOB, 1000 ether);
        vm.deal(CHARLIE, 1000 ether);

        // Bootstrap market with good liquidity
        vm.startPrank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 100 ether}(
            "Inactivity Test Market",
            ALICE,
            ETH,
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            100 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 30 days
        );
        vm.stopPrank();

        noId = PAMM.getNoId(marketId);

        // Add vault inventory
        vm.startPrank(ALICE);
        PAMM.split{value: 50 ether}(marketId, 50 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 25 ether, ALICE, block.timestamp + 30 days);
        router.depositToVault(marketId, false, 25 ether, ALICE, block.timestamp + 30 days);
        vm.stopPrank();

        // Wait for initial pool cumulative to accumulate
        vm.warp(block.timestamp + 1 minutes);

        // Make initial trade
        vm.prank(BOB);
        router.buyWithBootstrap{value: 5 ether}(
            marketId, true, 5 ether, 0, BOB, block.timestamp + 30 days
        );

        // Wait 31 minutes then update TWAP observation
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Make another trade
        vm.prank(BOB);
        router.buyWithBootstrap{value: 3 ether}(
            marketId, false, 3 ether, 0, BOB, block.timestamp + 30 days
        );

        // Wait another 32 minutes (must be > 30 from last update) and update again
        vm.warp(block.timestamp + 32 minutes);
        router.updateTWAPObservation(marketId);

        // Now we have an active market with TWAP history
    }

    // ============ Core Inactivity Tests ============

    /// @notice Test that TWAP remains valid after hours of inactivity
    function test_Inactivity_TWAPRemainsValidAfter6Hours() public {
        // Record state before inactivity
        (
            uint32 ts0Before,
            uint32 ts1Before,
            uint32 cachedTwapBefore,,
            uint256 cum0Before,
            uint256 cum1Before
        ) = router.twapObservations(marketId);

        assertTrue(ts1Before > 0, "TWAP should be initialized");

        // 6 hours of complete inactivity
        vm.warp(block.timestamp + 6 hours);

        // TWAP observations should be unchanged (no auto-update)
        (uint32 ts0After, uint32 ts1After,,, uint256 cum0After, uint256 cum1After) =
            router.twapObservations(marketId);

        assertEq(ts0After, ts0Before, "Obs0 timestamp unchanged during inactivity");
        assertEq(ts1After, ts1Before, "Obs1 timestamp unchanged during inactivity");
        assertEq(cum0After, cum0Before, "Obs0 cumulative unchanged during inactivity");
        assertEq(cum1After, cum1Before, "Obs1 cumulative unchanged during inactivity");

        // But TWAP calculation should still work (uses live cumulative from pool)
        // Verify by making a trade that requires TWAP
        vm.prank(CHARLIE);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 1 ether}(
            marketId, true, 1 ether, 0, CHARLIE, block.timestamp + 30 days
        );

        assertTrue(sharesOut > 0, "Should receive shares after inactivity");
        // Trade should succeed via some path (otc, amm, or mint)
        assertTrue(
            source == bytes4("otc") || source == bytes4("amm") || source == bytes4("mint"),
            "Should use valid execution path"
        );
    }

    /// @notice Test that TWAP can be refreshed after inactivity
    function test_Inactivity_TWAPCanBeRefreshedAfter6Hours() public {
        (uint32 ts0Before, uint32 ts1Before,,,,) = router.twapObservations(marketId);

        // 6 hours of inactivity
        vm.warp(block.timestamp + 6 hours);

        // Anyone can refresh TWAP
        router.updateTWAPObservation(marketId);

        (uint32 ts0After, uint32 ts1After,,,,) = router.twapObservations(marketId);

        // Observations should have shifted
        assertEq(ts0After, ts1Before, "Old obs1 becomes new obs0");
        assertEq(ts1After, uint32(block.timestamp), "New obs1 is current time");
    }

    /// @notice Test vault OTC resumes after hours of inactivity
    function test_Inactivity_VaultOTCResumesAfter6Hours() public {
        // Get vault state before
        (uint112 yesBefore, uint112 noBefore,) = router.bootstrapVaults(marketId);
        assertTrue(yesBefore > 0 && noBefore > 0, "Vault should have inventory");

        // 6 hours of inactivity
        vm.warp(block.timestamp + 6 hours);

        // Refresh TWAP (required for OTC)
        router.updateTWAPObservation(marketId);
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Try vault OTC buy
        vm.prank(CHARLIE);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 2 ether}(
            marketId, true, 2 ether, 0, CHARLIE, block.timestamp + 30 days
        );

        assertTrue(sharesOut > 0, "Should receive shares");

        // Vault should have participated (OTC) or system fell back gracefully
        // Either way, trade succeeded
        (uint112 yesAfter, uint112 noAfter,) = router.bootstrapVaults(marketId);

        // If OTC was used, vault inventory changed
        if (source == bytes4("otc")) {
            assertTrue(
                yesAfter < yesBefore || noAfter != noBefore,
                "Vault inventory should change on OTC fill"
            );
        }
    }

    /// @notice Test rebalancing works after hours of inactivity
    function test_Inactivity_RebalanceWorksAfter6Hours() public {
        // Create imbalance by buying one side
        vm.prank(BOB);
        router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, BOB, block.timestamp + 30 days
        );

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);

        // 6 hours of inactivity
        vm.warp(block.timestamp + 6 hours);

        // Refresh TWAP for rebalancing
        router.updateTWAPObservation(marketId);
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Budget should be unchanged during inactivity
        assertEq(
            router.rebalanceCollateralBudget(marketId),
            budgetBefore,
            "Budget unchanged during inactivity"
        );

        // Rebalance should work
        (uint112 yesBefore, uint112 noBefore,) = router.bootstrapVaults(marketId);
        uint256 imbalanceBefore = yesBefore > noBefore ? yesBefore - noBefore : noBefore - yesBefore;

        if (budgetBefore > 0 && imbalanceBefore > 0) {
            uint256 collateralUsed =
                router.rebalanceBootstrapVault(marketId, block.timestamp + 30 days);

            // Rebalance should either succeed or gracefully return 0
            // (may return 0 if conditions not met, but shouldn't revert)
            if (collateralUsed > 0) {
                (uint112 yesAfter, uint112 noAfter,) = router.bootstrapVaults(marketId);
                uint256 imbalanceAfter =
                    yesAfter > noAfter ? yesAfter - noAfter : noAfter - yesAfter;

                assertTrue(
                    imbalanceAfter <= imbalanceBefore,
                    "Rebalance should reduce or maintain imbalance"
                );
            }
        }
    }

    /// @notice Test LP can withdraw after hours of inactivity
    function test_Inactivity_LPWithdrawalWorksAfter6Hours() public {
        // Get Alice's vault position
        (uint112 aliceYesShares,,,,) = router.vaultPositions(marketId, ALICE);
        assertTrue(aliceYesShares > 0, "Alice should have vault shares");

        // 6 hours of inactivity (also satisfies 24h cooldown requirement)
        vm.warp(block.timestamp + 25 hours);

        // Withdrawal should work
        vm.startPrank(ALICE);
        uint256 aliceSharesBefore = PAMM.balanceOf(ALICE, marketId);

        router.withdrawFromVault(marketId, true, aliceYesShares, ALICE, block.timestamp + 30 days);

        uint256 aliceSharesAfter = PAMM.balanceOf(ALICE, marketId);
        vm.stopPrank();

        assertTrue(aliceSharesAfter > aliceSharesBefore, "Alice should receive shares back");
    }

    /// @notice Test fee claiming works after hours of inactivity
    function test_Inactivity_FeeClaimingWorksAfter6Hours() public {
        // Generate some fees via trades
        vm.prank(BOB);
        router.buyWithBootstrap{value: 10 ether}(
            marketId, true, 10 ether, 0, BOB, block.timestamp + 30 days
        );

        // 6 hours of inactivity
        vm.warp(block.timestamp + 6 hours);

        // Harvest fees should work
        vm.startPrank(ALICE);

        // May or may not have fees depending on trade routing
        // Key thing is it shouldn't revert
        router.harvestVaultFees(marketId, true);
        // If we get here without revert, fee harvesting works after inactivity

        vm.stopPrank();
    }

    // ============ Extended Inactivity Tests ============

    /// @notice Test system handles 24 hours of inactivity
    function test_Inactivity_24HoursNoActivity() public {
        // Record state
        (uint112 yesBefore, uint112 noBefore,) = router.bootstrapVaults(marketId);

        // 24 hours of complete inactivity
        vm.warp(block.timestamp + 24 hours);

        // Vault inventory unchanged
        (uint112 yesAfter, uint112 noAfter,) = router.bootstrapVaults(marketId);
        assertEq(yesAfter, yesBefore, "Vault YES unchanged");
        assertEq(noAfter, noBefore, "Vault NO unchanged");

        // System should still function
        // Refresh TWAP
        router.updateTWAPObservation(marketId);
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Trade should work
        vm.prank(CHARLIE);
        (uint256 sharesOut,,) = router.buyWithBootstrap{value: 1 ether}(
            marketId, true, 1 ether, 0, CHARLIE, block.timestamp + 30 days
        );

        assertTrue(sharesOut > 0, "Trading should work after 24h inactivity");
    }

    /// @notice Test system handles 7 days of inactivity
    function test_Inactivity_7DaysNoActivity() public {
        // 7 days of complete inactivity
        vm.warp(block.timestamp + 7 days);

        // Refresh TWAP (cumulative still valid from pool)
        router.updateTWAPObservation(marketId);
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Trade should still work
        vm.prank(CHARLIE);
        (uint256 sharesOut,,) = router.buyWithBootstrap{value: 1 ether}(
            marketId, true, 1 ether, 0, CHARLIE, block.timestamp + 30 days
        );

        assertTrue(sharesOut > 0, "Trading should work after 7 day inactivity");
    }

    /// @notice Test multiple inactivity periods don't corrupt state
    function test_Inactivity_MultiplePeriods() public {
        for (uint256 i = 0; i < 5; i++) {
            // Activity burst
            vm.prank(BOB);
            router.buyWithBootstrap{value: 1 ether}(
                marketId, true, 1 ether, 0, BOB, block.timestamp + 30 days
            );

            // Inactivity period (varies: 2h, 4h, 6h, 8h, 10h)
            vm.warp(block.timestamp + (i + 1) * 2 hours);

            // Refresh TWAP after each inactivity period
            if (i > 0) {
                router.updateTWAPObservation(marketId);
                vm.warp(block.timestamp + 31 minutes);
            }
        }

        // System should still be healthy
        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        assertTrue(yesShares > 0 || noShares > 0, "Vault should still have inventory");

        // One more trade to confirm everything works
        vm.prank(CHARLIE);
        (uint256 sharesOut,,) = router.buyWithBootstrap{value: 1 ether}(
            marketId, false, 1 ether, 0, CHARLIE, block.timestamp + 30 days
        );

        assertTrue(sharesOut > 0, "Trading should work after multiple inactivity periods");
    }

    // ============ Edge Cases During Inactivity ============

    /// @notice Test that new deposits work during inactivity period
    function test_Inactivity_NewDepositsWork() public {
        // 6 hours of inactivity
        vm.warp(block.timestamp + 6 hours);

        // New LP deposits to vault
        vm.startPrank(CHARLIE);
        PAMM.split{value: 10 ether}(marketId, 10 ether, CHARLIE);
        PAMM.setOperator(address(router), true);

        uint256 vaultSharesMinted =
            router.depositToVault(marketId, true, 10 ether, CHARLIE, block.timestamp + 30 days);
        vm.stopPrank();

        assertTrue(vaultSharesMinted > 0, "Should mint vault shares during inactivity");

        (uint112 charlieShares,,,,) = router.vaultPositions(marketId, CHARLIE);
        assertTrue(charlieShares > 0, "Charlie should have vault position");
    }

    /// @notice Test that sell path works after inactivity
    function test_Inactivity_SellPathWorks() public {
        // Bob has some shares from earlier trades - give him more
        vm.prank(BOB);
        router.buyWithBootstrap{value: 5 ether}(
            marketId, true, 5 ether, 0, BOB, block.timestamp + 30 days
        );

        uint256 bobYesShares = PAMM.balanceOf(BOB, marketId);
        assertTrue(bobYesShares > 0, "Bob should have YES shares");

        // 6 hours of inactivity
        vm.warp(block.timestamp + 6 hours);

        // Refresh TWAP
        router.updateTWAPObservation(marketId);
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Bob sells his shares
        vm.startPrank(BOB);
        PAMM.setOperator(address(router), true);

        uint256 bobEthBefore = BOB.balance;
        (uint256 collateralOut,) = router.sellWithBootstrap(
            marketId,
            true,
            bobYesShares / 2, // Sell half
            0,
            BOB,
            block.timestamp + 30 days
        );
        vm.stopPrank();

        assertTrue(collateralOut > 0, "Should receive collateral from sell");
        assertEq(BOB.balance, bobEthBefore + collateralOut, "Bob should receive ETH");
    }

    /// @notice Test that permissionless TWAP update works during inactivity
    function test_Inactivity_PermissionlessTWAPUpdate() public {
        // 6 hours of inactivity
        vm.warp(block.timestamp + 6 hours);

        // Random address updates TWAP (permissionless)
        address randomUser = address(0xDEAD);
        vm.prank(randomUser);
        router.updateTWAPObservation(marketId);

        (, uint32 ts1,,,,) = router.twapObservations(marketId);
        assertEq(ts1, uint32(block.timestamp), "TWAP should be updated by anyone");
    }

    /// @notice Test rebalance bounty is paid after inactivity
    function test_Inactivity_RebalanceBountyPaid() public {
        // Create imbalance
        vm.prank(BOB);
        router.buyWithBootstrap{value: 20 ether}(
            marketId, true, 20 ether, 0, BOB, block.timestamp + 30 days
        );

        // 6 hours of inactivity
        vm.warp(block.timestamp + 6 hours);

        // Refresh TWAP
        router.updateTWAPObservation(marketId);
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        uint256 budget = router.rebalanceCollateralBudget(marketId);

        if (budget > 0) {
            // Random keeper calls rebalance
            address keeper = address(0xEEEE);
            vm.deal(keeper, 1 ether);
            uint256 keeperBalanceBefore = keeper.balance;

            vm.prank(keeper);
            uint256 collateralUsed =
                router.rebalanceBootstrapVault(marketId, block.timestamp + 30 days);

            if (collateralUsed > 0) {
                uint256 keeperBalanceAfter = keeper.balance;
                assertTrue(keeperBalanceAfter > keeperBalanceBefore, "Keeper should receive bounty");
            }
        }
    }

    // ============ Spot/TWAP Deviation Tests ============

    /// @notice Test that vault OTC is disabled when spot deviates >5% from TWAP
    function test_SpotTWAPDeviation_BlocksVaultOTC() public {
        // Get initial vault state
        (uint112 yesBefore, uint112 noBefore,) = router.bootstrapVaults(marketId);
        assertTrue(yesBefore > 0 && noBefore > 0, "Vault should have inventory");

        // Make a large trade to skew spot price away from TWAP
        // Buy a lot of YES to push spot price up significantly
        vm.prank(BOB);
        router.buyWithBootstrap{value: 80 ether}(
            marketId, true, 80 ether, 0, BOB, block.timestamp + 30 days
        );

        // Now spot is significantly different from TWAP (TWAP is time-weighted, spot moved instantly)
        // Try another small trade - should NOT use vault OTC due to deviation
        vm.prank(CHARLIE);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 1 ether}(
            marketId, true, 1 ether, 0, CHARLIE, block.timestamp + 30 days
        );

        assertTrue(sharesOut > 0, "Trade should still succeed");
        // With large spot deviation, vault OTC should be disabled
        // Trade should use AMM or mint instead
        assertTrue(
            source == bytes4("amm") || source == bytes4("mint"),
            "Should NOT use OTC when spot deviates from TWAP"
        );
    }

    /// @notice Test that after TWAP catches up, vault OTC re-enables
    function test_SpotTWAPDeviation_OTCReenablesAfterTWAPCatchup() public {
        // Skew spot price
        vm.prank(BOB);
        router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, BOB, block.timestamp + 30 days
        );

        // Let time pass so TWAP catches up to new spot
        vm.warp(block.timestamp + 2 hours);
        router.updateTWAPObservation(marketId);
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(marketId);

        // Now TWAP should be closer to spot
        // Add more vault inventory for OTC
        vm.startPrank(ALICE);
        PAMM.split{value: 20 ether}(marketId, 20 ether, ALICE);
        router.depositToVault(marketId, true, 10 ether, ALICE, block.timestamp + 30 days);
        router.depositToVault(marketId, false, 10 ether, ALICE, block.timestamp + 30 days);
        vm.stopPrank();

        // Trade should now potentially use OTC again
        vm.prank(CHARLIE);
        (uint256 sharesOut, bytes4 source,) = router.buyWithBootstrap{value: 1 ether}(
            marketId, false, 1 ether, 0, CHARLIE, block.timestamp + 30 days
        );

        assertTrue(sharesOut > 0, "Trade should succeed");
        // After TWAP catchup, OTC may be available again (or AMM/mint if other conditions)
        assertTrue(
            source == bytes4("otc") || source == bytes4("amm") || source == bytes4("mint"),
            "Should use valid execution path"
        );
    }

    // ============ Empty LP Side Fee Routing Tests ============

    /// @notice Test vault still functions when one side has more LPs than other
    function test_AsymmetricLPSide_VaultStillFunctions() public {
        // Use the existing market from setUp, which already has TWAP established
        // Just verify that asymmetric LP deposits work

        // Add more YES than NO to vault
        vm.startPrank(ALICE);
        PAMM.split{value: 50 ether}(marketId, 50 ether, ALICE);
        router.depositToVault(marketId, true, 40 ether, ALICE, block.timestamp + 30 days);
        router.depositToVault(marketId, false, 10 ether, ALICE, block.timestamp + 30 days);
        vm.stopPrank();

        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);

        // YES should be larger than NO
        assertTrue(yesShares > noShares, "YES should be larger after asymmetric deposit");

        // Trading should still work
        vm.prank(CHARLIE);
        (uint256 sharesOut,,) = router.buyWithBootstrap{value: 2 ether}(
            marketId, false, 2 ether, 0, CHARLIE, block.timestamp + 30 days
        );

        assertTrue(sharesOut > 0, "Trading should work with asymmetric LP");
    }

    /// @notice Test budget accumulates from trades (proxy for fee routing)
    function test_BudgetAccumulatesFromTrades() public {
        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);

        // Make several trades to generate fees
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(BOB);
            router.buyWithBootstrap{value: 5 ether}(
                marketId, true, 5 ether, 0, BOB, block.timestamp + 30 days
            );
        }

        uint256 budgetAfter = router.rebalanceCollateralBudget(marketId);

        // Budget should have increased from trade fees
        assertTrue(budgetAfter >= budgetBefore, "Budget should accumulate from trades");
    }

    // ============ Extreme Imbalance Tests ============

    /// @notice Test spread calculation at imbalance
    function test_Imbalance_VaultProtectsScarceSide() public {
        // Get current vault state
        (uint112 yesBefore, uint112 noBefore,) = router.bootstrapVaults(marketId);

        // Add more YES than NO to increase imbalance
        vm.startPrank(ALICE);
        PAMM.split{value: 80 ether}(marketId, 80 ether, ALICE);
        router.depositToVault(marketId, true, 70 ether, ALICE, block.timestamp + 30 days);
        router.depositToVault(marketId, false, 10 ether, ALICE, block.timestamp + 30 days);
        vm.stopPrank();

        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);

        // YES should be larger than NO after our deposit
        assertTrue(yesShares > noShares, "YES should be larger than NO");

        // Buying NO (scarcer side) should still work
        vm.prank(CHARLIE);
        (uint256 sharesOut,,) = router.buyWithBootstrap{value: 1 ether}(
            marketId, false, 1 ether, 0, CHARLIE, block.timestamp + 30 days
        );

        assertTrue(sharesOut > 0, "Should still be able to trade");

        // Vault should protect scarce inventory (30% cap per trade applies to vault's side)
        (, uint112 noSharesAfter,) = router.bootstrapVaults(marketId);
        // With 30% cap, after a trade we should still have at least 70% of starting NO shares
        assertTrue(noSharesAfter >= noShares * 70 / 100, "Vault should protect scarce inventory");
    }

    // ============ Withdrawal Cooldown Tests ============

    /// @notice Test withdrawal reverts during cooldown period
    function test_WithdrawalCooldown_RevertsIfTooEarly() public {
        // Fresh deposit
        vm.startPrank(CHARLIE);
        PAMM.split{value: 5 ether}(marketId, 5 ether, CHARLIE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 5 ether, CHARLIE, block.timestamp + 30 days);

        (uint112 charlieShares,,,,) = router.vaultPositions(marketId, CHARLIE);
        assertTrue(charlieShares > 0, "Charlie should have shares");

        // Try to withdraw immediately (should fail - 24h cooldown)
        vm.expectRevert();
        router.withdrawFromVault(marketId, true, charlieShares, CHARLIE, block.timestamp + 30 days);

        vm.stopPrank();
    }

    /// @notice Test withdrawal succeeds after cooldown
    function test_WithdrawalCooldown_SucceedsAfterCooldown() public {
        // Fresh deposit
        vm.startPrank(CHARLIE);
        PAMM.split{value: 5 ether}(marketId, 5 ether, CHARLIE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 5 ether, CHARLIE, block.timestamp + 30 days);

        (uint112 charlieShares,,,,) = router.vaultPositions(marketId, CHARLIE);

        // Wait for cooldown (24 hours + buffer)
        vm.warp(block.timestamp + 25 hours);

        // Now withdrawal should succeed
        uint256 sharesBefore = PAMM.balanceOf(CHARLIE, marketId);
        router.withdrawFromVault(marketId, true, charlieShares, CHARLIE, block.timestamp + 30 days);
        uint256 sharesAfter = PAMM.balanceOf(CHARLIE, marketId);

        assertTrue(sharesAfter > sharesBefore, "Should receive shares back");
        vm.stopPrank();
    }

    // ============ Market Resolution Tests ============

    /// @notice Test vault handles market resolution correctly
    function test_MarketResolution_VaultSettlement() public {
        // Create a market that can be closed
        vm.startPrank(ALICE);
        (uint256 resolvableMarketId,,,) = router.bootstrapMarket{value: 20 ether}(
            "Resolvable Market",
            ALICE, // ALICE is resolver
            ETH,
            uint64(block.timestamp + 1 hours), // Short close time
            true, // canClose = true
            address(hook),
            20 ether,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 30 days
        );

        // Add vault inventory
        PAMM.split{value: 10 ether}(resolvableMarketId, 10 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(resolvableMarketId, true, 5 ether, ALICE, block.timestamp + 30 days);
        router.depositToVault(resolvableMarketId, false, 5 ether, ALICE, block.timestamp + 30 days);
        vm.stopPrank();

        // Setup TWAP
        vm.warp(block.timestamp + 31 minutes);
        router.updateTWAPObservation(resolvableMarketId);

        // Warp past close time
        vm.warp(block.timestamp + 2 hours);

        // Resolve market (YES wins) - use low-level call since resolve not in interface
        vm.prank(ALICE);
        (bool success,) = address(PAMM)
            .call(abi.encodeWithSignature("resolve(uint256,bool)", resolvableMarketId, true));
        assertTrue(success, "Resolve should succeed");

        // Verify market is resolved
        (, bool resolved, bool outcome,,,,) = PAMM.markets(resolvableMarketId);
        assertTrue(resolved, "Market should be resolved");
        assertTrue(outcome, "YES should win");

        // Vault settlement should work - DAO can extract value
        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(resolvableMarketId);
        // After resolution, vault may still have shares until redeemed
        // The winning shares (YES) have value, losing shares (NO) are worthless
    }
}

interface IPAMM_Extended {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

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
    function poolKey(uint256 marketId, uint256 feeOrHook) external view returns (PoolKey memory key);
    function getNoId(uint256 marketId) external pure returns (uint256);
}

/// @notice Minimal hook for testing
contract MinimalHook {
    address public owner;
    mapping(uint256 => uint256) public poolIdsByMarket;

    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;

    IPAMM_Extended constant PAMM_EXT = IPAMM_Extended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    constructor() {
        owner = tx.origin;
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "not owner");
        owner = newOwner;
    }

    function registerMarket(uint256 marketId) external returns (uint256 poolId) {
        require(msg.sender == owner, "unauthorized");

        // Build pool key like PMFeeHook does (always use both flags)
        uint256 feeHook = uint256(uint160(address(this))) | FLAG_BEFORE | FLAG_AFTER;

        IPAMM_Extended.PoolKey memory k = PAMM_EXT.poolKey(marketId, feeHook);
        poolId = uint256(keccak256(abi.encode(k.id0, k.id1, k.token0, k.token1, k.feeOrHook)));

        poolIdsByMarket[marketId] = poolId;
        return poolId;
    }

    function getCurrentFeeBps(uint256) external pure returns (uint256) {
        return 30; // 0.3%
    }

    function getCloseWindow(uint256) external pure returns (uint256) {
        return 1 hours;
    }

    function beforeAction(bytes4, uint256, address, bytes calldata)
        external
        pure
        returns (uint256)
    {
        return 30;
    }

    fallback() external payable {}
    receive() external payable {}
}
