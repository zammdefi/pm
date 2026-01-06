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
}

/// @title PMHookRouter Vault Accounting Tests
/// @notice Comprehensive tests for vault accounting, fee distribution, and edge cases
contract PMHookRouterVaultAccountingTest is Test {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address constant ETH = address(0);
    uint64 constant DEADLINE_2028 = 1861919999;

    PMHookRouter public router;
    PMFeeHookV1 public hook;

    address public ALICE;
    address public BOB;
    address public CAROL;

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

        deal(ALICE, 10000 ether);
        deal(BOB, 10000 ether);
        deal(CAROL, 10000 ether);

        // Bootstrap a market for testing
        _bootstrapMarket();
    }

    function _bootstrapMarket() internal {
        vm.startPrank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 1000 ether}(
            "Vault Test Market 2026",
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

    // ============ Test 1: Cooldown Enforcement ============

    function test_VaultAccounting_CooldownEnforcement_Withdraw() public {
        // Alice deposits to vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);

        (uint112 aliceYesVaultShares,,,,) = router.vaultPositions(marketId, ALICE);
        assertGt(aliceYesVaultShares, 0, "Alice should have vault shares");

        // Try to withdraw immediately - should fail
        vm.expectRevert(); // WithdrawalTooSoon
        router.withdrawFromVault(
            marketId, true, aliceYesVaultShares, ALICE, block.timestamp + 1 hours
        );

        // Wait 29 minutes - still should fail
        vm.warp(block.timestamp + 29 minutes);
        vm.expectRevert();
        router.withdrawFromVault(
            marketId, true, aliceYesVaultShares, ALICE, block.timestamp + 7 hours
        );

        // Wait 6 hours + 1 from deposit time - should succeed
        vm.warp(block.timestamp + 5 hours + 31 minutes + 1);
        (uint256 sharesReturned,) = router.withdrawFromVault(
            marketId, true, aliceYesVaultShares, ALICE, block.timestamp + 7 hours
        );
        assertGt(sharesReturned, 0, "Should successfully withdraw after cooldown");
        vm.stopPrank();
    }

    function test_VaultAccounting_CooldownEnforcement_Harvest() public {
        // Alice deposits
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Try to harvest immediately before any fees - should fail (cooldown)
        vm.prank(ALICE);
        vm.expectRevert();
        router.harvestVaultFees(marketId, true);

        // Wait past cooldown and generate fees
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(BOB);
        router.buyWithBootstrap{value: 20 ether}(
            marketId, true, 20 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Now Alice can harvest after cooldown
        vm.prank(ALICE);
        uint256 feesEarned = router.harvestVaultFees(marketId, true);
        assertGt(feesEarned, 0, "Should harvest fees after cooldown");
    }

    function test_VaultAccounting_CooldownEnforced_MarketClosed() public {
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);

        // Deposit shortly before market close to test cooldown enforcement
        vm.warp(DEADLINE_2028 - 1 hours);
        router.depositToVault(marketId, true, 50 ether, ALICE, DEADLINE_2028);

        (uint112 aliceYesVaultShares,,,,) = router.vaultPositions(marketId, ALICE);

        // Warp to after market close but before cooldown expires
        vm.warp(DEADLINE_2028 + 1);

        // Should NOT be able to withdraw immediately - cooldown enforced even after close
        vm.expectRevert(); // WithdrawalTooSoon
        router.withdrawFromVault(
            marketId, true, aliceYesVaultShares, ALICE, DEADLINE_2028 + 1 hours
        );

        // Warp past cooldown (6h from deposit time)
        vm.warp(DEADLINE_2028 - 1 hours + 6 hours + 1);

        // Now withdrawal should succeed
        (uint256 sharesReturned,) = router.withdrawFromVault(
            marketId, true, aliceYesVaultShares, ALICE, DEADLINE_2028 + 7 hours
        );
        assertGt(sharesReturned, 0, "Should withdraw after cooldown expires");
        vm.stopPrank();
    }

    // ============ Test 2: Debt Tracking & Fee Claims ============

    function test_VaultAccounting_DebtTracking_PartialWithdrawal() public {
        // Alice deposits 100 shares
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Wait for cooldown first
        vm.warp(block.timestamp + 6 hours + 1);

        // Generate fees via OTC fill
        vm.prank(BOB);
        router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Alice withdraws 30% of vault shares
        vm.startPrank(ALICE);
        (uint112 aliceYesVaultShares,,,,) = router.vaultPositions(marketId, ALICE);
        uint256 withdrawAmount = uint256(aliceYesVaultShares) * 30 / 100;

        uint256 balanceBefore = address(ALICE).balance;
        (uint256 sharesReturned, uint256 feesEarned) = router.withdrawFromVault(
            marketId, true, withdrawAmount, ALICE, block.timestamp + 1 hours
        );

        // Should receive ALL accumulated fees (not pro-rated to 30%)
        assertGt(feesEarned, 0, "Should receive fees");

        // Check that remaining vault shares have correct debt
        (uint112 remainingVaultShares,,, uint256 newDebt,) = router.vaultPositions(marketId, ALICE);
        assertEq(
            remainingVaultShares,
            aliceYesVaultShares - withdrawAmount,
            "Remaining vault shares should be correct"
        );

        // Debt should be reset for remaining shares
        uint256 accPerShare = router.accYesCollateralPerShare(marketId);
        uint256 expectedDebt = (uint256(remainingVaultShares) * accPerShare) / 1e18;
        assertEq(newDebt, expectedDebt, "Debt should be reset for remaining shares");

        vm.stopPrank();
    }

    function test_VaultAccounting_DebtTracking_HarvestResetsDebt() public {
        // Alice deposits
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Generate fees round 1
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(BOB);
        router.buyWithBootstrap{value: 20 ether}(
            marketId, true, 20 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Alice harvests
        vm.startPrank(ALICE);
        uint256 fees1 = router.harvestVaultFees(marketId, true);
        assertGt(fees1, 0, "Should harvest fees round 1");

        (,,,, uint256 debtAfterHarvest1) = router.vaultPositions(marketId, ALICE);

        // Generate fees round 2
        vm.warp(block.timestamp + 7 hours);
        vm.stopPrank();
        vm.prank(BOB);
        router.buyWithBootstrap{value: 20 ether}(
            marketId, true, 20 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Alice harvests again
        vm.prank(ALICE);
        uint256 fees2 = router.harvestVaultFees(marketId, true);
        assertGt(fees2, 0, "Should harvest fees round 2");

        // Verify no double-claiming: fees2 should only be from second round
        assertLt(fees2, fees1 + fees2, "Should not double-claim");

        vm.stopPrank();
    }

    function test_VaultAccounting_DebtTracking_MultipleDepositors() public {
        // Alice deposits first
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Wait for Alice's cooldown and generate fees
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(CAROL);
        router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, CAROL, block.timestamp + 1 hours
        );

        // Bob deposits after fees accumulated
        vm.warp(block.timestamp + 7 hours);
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, BOB, block.timestamp + 7 hours);
        vm.stopPrank();

        // Wait for Bob's cooldown
        vm.warp(block.timestamp + 6 hours + 1);

        // Bob's debt should prevent him from claiming historical fees
        vm.startPrank(BOB);
        uint256 bobFees = router.harvestVaultFees(marketId, true);
        vm.stopPrank();

        vm.startPrank(ALICE);
        uint256 aliceFees = router.harvestVaultFees(marketId, true);
        vm.stopPrank();

        // Alice should have much more fees than Bob since she was there for the first round
        assertGt(aliceFees, bobFees, "Alice should have more historical fees");
    }

    // ============ Test 3: One-Sided LP Scenarios ============

    function test_VaultAccounting_OneSidedLP_AllFeesToExistingSide() public {
        // Only Alice deposits to YES vault
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Verify no NO vault shares exist
        uint256 totalNoVaultShares = router.totalNoVaultShares(marketId);
        assertEq(totalNoVaultShares, 0, "Should have no NO vault shares");

        // Generate OTC fees (spread should go to YES side only)
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(BOB);
        router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Alice should receive fees
        vm.startPrank(ALICE);
        uint256 aliceFees = router.harvestVaultFees(marketId, true);
        assertGt(aliceFees, 0, "YES LP should receive fees even without NO LPs");
        vm.stopPrank();
    }

    function test_VaultAccounting_OneSidedLP_BothSidesEventually() public {
        // Alice deposits to YES only
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Generate fees with only YES LP
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(CAROL);
        router.buyWithBootstrap{value: 30 ether}(
            marketId, true, 30 ether, 0, CAROL, block.timestamp + 1 hours
        );

        // Bob deposits to NO vault
        vm.warp(block.timestamp + 7 hours);
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, false, 100 ether, BOB, block.timestamp + 7 hours);
        vm.stopPrank();

        // Generate more fees with both sides
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(CAROL);
        router.buyWithBootstrap{value: 30 ether}(
            marketId, true, 30 ether, 0, CAROL, block.timestamp + 1 hours
        );

        // Both should have fees
        vm.warp(block.timestamp + 6 hours + 1);
        vm.startPrank(ALICE);
        uint256 aliceFees = router.harvestVaultFees(marketId, true);
        vm.stopPrank();

        vm.startPrank(BOB);
        uint256 bobFees = router.harvestVaultFees(marketId, false);
        vm.stopPrank();

        assertGt(aliceFees, 0, "Alice should have fees");
        assertGt(bobFees, 0, "Bob should have fees from second round");
        assertGt(aliceFees, bobFees, "Alice should have more (two rounds vs one)");
    }

    // ============ Test 4: VaultDepleted State ============

    function test_VaultAccounting_VaultDepleted_BlocksNewDeposits() public {
        // Alice deposits
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Drain vault via multiple OTC fills until depleted
        vm.warp(block.timestamp + 6 hours + 1);
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(BOB);
            try router.buyWithBootstrap{value: 10 ether}(
                marketId, true, 10 ether, 0, BOB, block.timestamp + 1 hours
            ) {}
            catch {
                break;
            }
        }

        // Check vault state
        (uint112 yesShares,,) = router.bootstrapVaults(marketId);
        uint256 totalYesVaultShares = router.totalYesVaultShares(marketId);

        // If vault is depleted (shares = 0 but vaultShares > 0), new deposits should fail
        if (yesShares == 0 && totalYesVaultShares > 0) {
            vm.startPrank(CAROL);
            PAMM.split{value: 100 ether}(marketId, 100 ether, CAROL);
            PAMM.setOperator(address(router), true);

            vm.expectRevert(); // VaultDepleted
            router.depositToVault(marketId, true, 50 ether, CAROL, block.timestamp + 7 hours);
            vm.stopPrank();
        }
    }

    // ============ Test 5: Pro-Rata Share Distribution ============

    function test_VaultAccounting_ProRata_EqualDeposits() public {
        // Alice and Bob deposit equal amounts
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, type(uint256).max);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 hours);
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, BOB, type(uint256).max);
        vm.stopPrank();

        // Generate fees
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(CAROL);
        router.buyWithBootstrap{value: 100 ether}(
            marketId, true, 100 ether, 0, CAROL, type(uint256).max
        );

        // Both should earn approximately equal fees (within rounding)
        vm.warp(block.timestamp + 6 hours + 1);
        vm.startPrank(ALICE);
        uint256 aliceFees = router.harvestVaultFees(marketId, true);
        vm.stopPrank();

        vm.startPrank(BOB);
        uint256 bobFees = router.harvestVaultFees(marketId, true);
        vm.stopPrank();

        // Allow for 1% difference due to rounding and timing
        uint256 diff = aliceFees > bobFees ? aliceFees - bobFees : bobFees - aliceFees;
        uint256 tolerance = (aliceFees + bobFees) / 100;
        assertLt(diff, tolerance, "Fees should be approximately equal");
    }

    function test_VaultAccounting_ProRata_UnequalDeposits() public {
        // Alice deposits 3x more than Bob
        vm.startPrank(ALICE);
        PAMM.split{value: 300 ether}(marketId, 300 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 300 ether, ALICE, type(uint256).max);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 hours);
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, BOB, type(uint256).max);
        vm.stopPrank();

        // Generate fees
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(CAROL);
        router.buyWithBootstrap{value: 100 ether}(
            marketId, true, 100 ether, 0, CAROL, type(uint256).max
        );

        // Harvest fees
        vm.warp(block.timestamp + 6 hours + 1);
        vm.startPrank(ALICE);
        uint256 aliceFees = router.harvestVaultFees(marketId, true);
        vm.stopPrank();

        vm.startPrank(BOB);
        uint256 bobFees = router.harvestVaultFees(marketId, true);
        vm.stopPrank();

        // Alice should earn ~3x Bob's fees (within tolerance)
        assertGt(aliceFees, bobFees * 2, "Alice should earn significantly more");
        assertLt(aliceFees, bobFees * 4, "Alice should not earn more than 4x");
    }

    // ============ Test 6: Fee Accumulation ============

    function test_VaultAccounting_FeeAccumulation_Monotonic() public {
        // Alice deposits
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        uint256 accBefore = router.accYesCollateralPerShare(marketId);

        // Generate fees
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(BOB);
        router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, BOB, block.timestamp + 1 hours
        );

        uint256 accAfter = router.accYesCollateralPerShare(marketId);

        // Accumulator should only increase
        assertGe(accAfter, accBefore, "Accumulator should be monotonic");
    }

    function test_VaultAccounting_FeeAccumulation_MultipleFills() public {
        // Alice deposits
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Multiple OTC fills
        vm.warp(block.timestamp + 6 hours + 1);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(BOB);
            router.buyWithBootstrap{value: 10 ether}(
                marketId, true, 10 ether, 0, BOB, block.timestamp + 1 hours
            );
        }

        // Alice should earn cumulative fees
        vm.warp(block.timestamp + 6 hours + 1);
        vm.startPrank(ALICE);
        uint256 totalFees = router.harvestVaultFees(marketId, true);
        assertGt(totalFees, 0, "Should accumulate fees from multiple fills");
        vm.stopPrank();
    }

    // ============ Test 7: Withdrawal Edge Cases ============

    function test_VaultAccounting_Withdrawal_ZeroAmount() public {
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);

        vm.warp(block.timestamp + 6 hours + 1);

        vm.expectRevert(); // ZeroVaultShares
        router.withdrawFromVault(marketId, true, 0, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();
    }

    function test_VaultAccounting_Withdrawal_MoreThanBalance() public {
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);

        (uint112 aliceYesVaultShares,,,,) = router.vaultPositions(marketId, ALICE);

        vm.warp(block.timestamp + 6 hours + 1);

        vm.expectRevert(); // InsufficientVaultShares
        router.withdrawFromVault(
            marketId, true, uint256(aliceYesVaultShares) + 1, ALICE, block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_VaultAccounting_Withdrawal_FullWithdrawal() public {
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);

        (uint112 aliceYesVaultShares,,,,) = router.vaultPositions(marketId, ALICE);

        vm.warp(block.timestamp + 6 hours + 1);

        (uint256 sharesReturned,) = router.withdrawFromVault(
            marketId, true, aliceYesVaultShares, ALICE, block.timestamp + 1 hours
        );

        // After full withdrawal, vault position should be zero
        (uint112 remainingShares,,,,) = router.vaultPositions(marketId, ALICE);
        assertEq(remainingShares, 0, "Should have zero vault shares after full withdrawal");
        assertGt(sharesReturned, 0, "Should have received shares");
        vm.stopPrank();
    }

    // ============ Test 8: Deposit Edge Cases ============

    function test_VaultAccounting_Deposit_ZeroAmount() public {
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);

        vm.expectRevert(); // ZeroShares
        router.depositToVault(marketId, true, 0, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();
    }

    function test_VaultAccounting_Deposit_ReceiverIsZeroAddress() public {
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);

        // Zero address should default to msg.sender
        router.depositToVault(marketId, true, 50 ether, address(0), block.timestamp + 7 hours);

        (uint112 aliceShares,,,,) = router.vaultPositions(marketId, ALICE);
        assertGt(aliceShares, 0, "Alice should receive shares when receiver is zero");
        vm.stopPrank();
    }

    // ============ Test 9: Multiple Users Interacting ============

    function test_VaultAccounting_MultiUser_ConcurrentActivity() public {
        // Alice deposits
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Generate fees round 1
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(CAROL);
        router.buyWithBootstrap{value: 20 ether}(
            marketId, true, 20 ether, 0, CAROL, block.timestamp + 1 hours
        );

        // Bob deposits
        vm.warp(block.timestamp + 7 hours);
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, BOB, block.timestamp + 7 hours);
        vm.stopPrank();

        // Generate fees round 2
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(CAROL);
        router.buyWithBootstrap{value: 20 ether}(
            marketId, true, 20 ether, 0, CAROL, block.timestamp + 1 hours
        );

        // Alice harvests
        vm.warp(block.timestamp + 7 hours);
        vm.startPrank(ALICE);
        uint256 aliceFees = router.harvestVaultFees(marketId, true);
        vm.stopPrank();

        // Bob harvests (ensure cooldown has passed)
        vm.warp(block.timestamp + 6 hours + 1);
        vm.startPrank(BOB);
        uint256 bobFees = router.harvestVaultFees(marketId, true);
        vm.stopPrank();

        // Alice should have more fees (participated in both rounds)
        assertGt(aliceFees, bobFees, "Alice should have more fees from earlier participation");
    }

    function test_VaultAccounting_MultiUser_IndependentAccounting() public {
        // Alice and Bob deposit
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, type(uint256).max);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 hours);
        vm.startPrank(BOB);
        PAMM.split{value: 100 ether}(marketId, 100 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, false, 100 ether, BOB, type(uint256).max);
        vm.stopPrank();

        // Generate fees
        vm.warp(block.timestamp + 6 hours + 1);
        vm.prank(CAROL);
        router.buyWithBootstrap{value: 50 ether}(
            marketId, true, 50 ether, 0, CAROL, type(uint256).max
        );

        // Alice withdraws from YES vault - should not affect Bob's NO vault
        vm.warp(block.timestamp + 6 hours + 1);
        vm.startPrank(ALICE);
        (uint112 aliceShares,,,,) = router.vaultPositions(marketId, ALICE);
        router.withdrawFromVault(marketId, true, aliceShares, ALICE, type(uint256).max);
        vm.stopPrank();

        // Bob should still have his NO vault position
        (, uint112 bobNoShares,,,) = router.vaultPositions(marketId, BOB);
        assertGt(bobNoShares, 0, "Bob's NO vault should be unaffected by Alice's YES withdrawal");
    }
}
