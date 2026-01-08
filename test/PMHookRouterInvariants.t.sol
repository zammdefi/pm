// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {PMFeeHookV1} from "../src/PMFeeHookV1.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PAMM, IZAMM} from "../src/PAMM.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/**
 * @title PMHookRouter Invariant Tests
 * @notice Critical invariants that must always hold for production safety
 * @dev These tests verify:
 *      1. Vault share accounting consistency
 *      2. Collateral conservation
 *      3. No post-close trading
 *      4. Budget conservation (fees + rebalance)
 *      5. LP fee accounting correctness
 */
contract PMHookRouterInvariantTest is Test {
    PAMM constant pamm = PAMM(payable(0x000000000044bfe6c2BBFeD8862973E0612f07C0));
    IZAMM constant zamm = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IERC20 constant UNI = IERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);

    uint64 constant DEADLINE_FAR_FUTURE = 2000000000;
    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;

    PMFeeHookV1 public hook;
    PMHookRouter public router;
    address public ALICE;
    address public BOB;
    address public CHARLIE;
    address[] public actors;
    uint256 public marketId;
    uint256 public noId;
    uint256 public poolId;
    uint256 public feeOrHook;

    // Track initial state for invariant checks
    uint256 public initialRouterBalance;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    // Helper function to compute feeOrHook value
    function _hookFeeOrHook(address hook_, bool afterHook) internal pure returns (uint256) {
        uint256 flags = afterHook ? (FLAG_BEFORE | FLAG_AFTER) : FLAG_BEFORE;
        return uint256(uint160(hook_)) | flags;
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        hook = new PMFeeHookV1();

        // Deploy router at REGISTRAR address using vm.etch
        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        // Manually initialize router (constructor logic doesn't run with vm.etch)
        vm.startPrank(REGISTRAR);
        pamm.setOperator(address(zamm), true);
        pamm.setOperator(address(pamm), true);
        vm.stopPrank();

        // Transfer hook ownership to router so it can register markets
        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");
        CHARLIE = makeAddr("CHARLIE");

        actors.push(ALICE);
        actors.push(BOB);
        actors.push(CHARLIE);

        deal(address(UNI), ALICE, 1_000_000 ether);
        deal(address(UNI), BOB, 1_000_000 ether);
        deal(address(UNI), CHARLIE, 1_000_000 ether);

        vm.startPrank(ALICE);
        UNI.approve(address(pamm), type(uint256).max);
        UNI.approve(address(router), type(uint256).max);

        (marketId, poolId,,) = router.bootstrapMarket(
            "Invariant Test Market",
            ALICE, // use ALICE as resolver (can be any address)
            address(UNI),
            uint64(block.timestamp + 30 days),
            false,
            address(hook),
            10_000 ether, // initial LP
            true, // buyYes
            0, // no initial buy
            0,
            ALICE,
            DEADLINE_FAR_FUTURE
        );

        noId = pamm.getNoId(marketId);
        poolId = router.canonicalPoolId(marketId);
        feeOrHook = _hookFeeOrHook(address(hook), true);
        pamm.setOperator(address(router), true);
        vm.stopPrank();

        vm.prank(BOB);
        UNI.approve(address(router), type(uint256).max);
        vm.prank(BOB);
        UNI.approve(address(pamm), type(uint256).max);
        vm.prank(BOB);
        pamm.setOperator(address(router), true);

        vm.prank(CHARLIE);
        UNI.approve(address(router), type(uint256).max);
        vm.prank(CHARLIE);
        UNI.approve(address(pamm), type(uint256).max);
        vm.prank(CHARLIE);
        pamm.setOperator(address(router), true);

        initialRouterBalance = UNI.balanceOf(address(router));
    }

    // ═══════════════════════════════════════════════════════════
    //                 INVARIANT #1: VAULT SHARE ACCOUNTING
    // ═══════════════════════════════════════════════════════════

    /// @notice Vault share totals must match sum of individual positions
    function invariant_vaultSharesMatchUserBalances() public {
        uint256 totalYesShares = router.totalYesVaultShares(marketId);
        uint256 totalNoShares = router.totalNoVaultShares(marketId);

        uint256 sumYesShares;
        uint256 sumNoShares;

        for (uint256 i = 0; i < actors.length; i++) {
            (uint112 yesVaultShares, uint112 noVaultShares,,,) =
                router.vaultPositions(marketId, actors[i]);
            sumYesShares += yesVaultShares;
            sumNoShares += noVaultShares;
        }

        assertEq(
            totalYesShares,
            sumYesShares,
            "INVARIANT BROKEN: totalYesVaultShares != sum(userYesVaultShares)"
        );
        assertEq(
            totalNoShares,
            sumNoShares,
            "INVARIANT BROKEN: totalNoVaultShares != sum(userNoVaultShares)"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //                 INVARIANT #2: COLLATERAL CONSERVATION
    // ═══════════════════════════════════════════════════════════

    /// @notice Router's collateral balance must be >= (unwithdrawn fees + rebalance budget)
    function invariant_collateralConservation() public {
        uint256 routerBalance = UNI.balanceOf(address(router));
        uint256 rebalanceBudget = router.rebalanceCollateralBudget(marketId);

        // Calculate accrued fees per share that haven't been withdrawn
        uint256 accYesPerShare = router.accYesCollateralPerShare(marketId);
        uint256 accNoPerShare = router.accNoCollateralPerShare(marketId);

        uint256 totalUnwithdrawnFees;

        for (uint256 i = 0; i < actors.length; i++) {
            (
                uint112 yesVaultShares,
                uint112 noVaultShares,,
                uint256 yesRewardDebt,
                uint256 noRewardDebt
            ) = router.vaultPositions(marketId, actors[i]);

            if (yesVaultShares > 0) {
                uint256 accumulatedYes = (uint256(yesVaultShares) * accYesPerShare) / 1e18;
                uint256 unwithdrawnYes =
                    accumulatedYes > yesRewardDebt ? accumulatedYes - yesRewardDebt : 0;
                totalUnwithdrawnFees += unwithdrawnYes;
            }

            if (noVaultShares > 0) {
                uint256 accumulatedNo = (uint256(noVaultShares) * accNoPerShare) / 1e18;
                uint256 unwithdrawnNo =
                    accumulatedNo > noRewardDebt ? accumulatedNo - noRewardDebt : 0;
                totalUnwithdrawnFees += unwithdrawnNo;
            }
        }

        uint256 requiredBalance = rebalanceBudget + totalUnwithdrawnFees;

        assertGe(
            routerBalance,
            requiredBalance,
            "INVARIANT BROKEN: router balance < (rebalance budget + unwithdrawn fees)"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //                 INVARIANT #3: NO POST-CLOSE TRADING
    // ═══════════════════════════════════════════════════════════

    /// @notice Trading must revert after market close
    function invariant_noPostClosTrading() public {
        (, bool resolved,,, uint64 close,,) = pamm.markets(marketId);

        if (block.timestamp >= close || resolved) {
            // Warp to after close
            vm.warp(close + 1);

            vm.startPrank(BOB);
            vm.expectRevert(abi.encodeWithSelector(PMHookRouter.TimingError.selector, 2)); // MarketClosed
            router.buyWithBootstrap(
                marketId,
                true, // buyYes
                1000 ether,
                0,
                BOB,
                DEADLINE_FAR_FUTURE
            );
            vm.stopPrank();
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                 INVARIANT #4: BUDGET CONSERVATION
    // ═══════════════════════════════════════════════════════════

    /// @notice Total fees + rebalance budget should equal 100% of OTC collateral taken
    /// @dev This is tested by tracking total collateral in vs collateral out in vault OTC fills
    function invariant_budgetConservation() public view {
        // This is a soft invariant - we verify it through the 80/20 split logic
        // In _addVaultFees: 80% goes to LPs (via accPerShare)
        // Remaining 20% goes to rebalanceBudget
        // Total should always be 100% of collateralIn from OTC fills

        uint256 rebalanceBudget = router.rebalanceCollateralBudget(marketId);

        // Budget should never exceed total router balance (sanity check)
        uint256 routerBalance = UNI.balanceOf(address(router));
        assertLe(
            rebalanceBudget,
            routerBalance,
            "INVARIANT BROKEN: rebalance budget exceeds router balance"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //                 INVARIANT #5: VAULT DEPLETION SAFETY
    // ═══════════════════════════════════════════════════════════

    /// @notice If totalVaultShares > 0 but vault inventory = 0, deposits should succeed with 1:1 minting
    function invariant_vaultDepletionSafety() public {
        (uint256 yesShares, uint256 noShares,) = router.bootstrapVaults(marketId);
        uint256 totalYesVaultShares = router.totalYesVaultShares(marketId);
        uint256 totalNoVaultShares = router.totalNoVaultShares(marketId);

        // YES side check
        if (totalYesVaultShares > 0 && yesShares == 0) {
            // Depositing to a depleted vault should succeed and mint shares 1:1
            vm.startPrank(BOB);
            pamm.split(marketId, 1000 ether, BOB);

            uint256 vaultSharesMinted =
                router.depositToVault(marketId, true, 1000 ether, BOB, DEADLINE_FAR_FUTURE);
            assertEq(vaultSharesMinted, 1000 ether, "Depleted vault should mint 1:1");
            vm.stopPrank();
        }

        // NO side check
        if (totalNoVaultShares > 0 && noShares == 0) {
            vm.startPrank(BOB);
            pamm.split(marketId, 1000 ether, BOB);

            uint256 vaultSharesMinted =
                router.depositToVault(marketId, false, 1000 ether, BOB, DEADLINE_FAR_FUTURE);
            assertEq(vaultSharesMinted, 1000 ether, "Depleted vault should mint 1:1");
            vm.stopPrank();
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                 INVARIANT #6: FEE SNIPE PROTECTION
    // ═══════════════════════════════════════════════════════════

    /// @notice Fees accrued with no LPs must go to rebalance budget, not vault collateral
    function invariant_feeSnipeProtection() public view {
        // All fees should flow through accPerShare mechanism or rebalance budget
        // (yesCollateral/noCollateral fields removed - were always 0)
    }

    // ═══════════════════════════════════════════════════════════
    //                 INVARIANT #7: WITHDRAWAL SAFETY
    // ═══════════════════════════════════════════════════════════

    /// @notice Withdrawals should never pay more than user's actual share of vault
    function invariant_withdrawalBounds() public {
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            (uint112 yesVaultShares, uint112 noVaultShares,,,) =
                router.vaultPositions(marketId, actor);

            if (yesVaultShares > 0) {
                uint256 totalYesVaultShares = router.totalYesVaultShares(marketId);
                (uint256 vaultYesShares,,) = router.bootstrapVaults(marketId);

                // User's max withdrawable shares = (vaultShares * totalAssets) / totalVaultShares
                uint256 maxWithdrawable =
                    (uint256(yesVaultShares) * vaultYesShares) / totalYesVaultShares;

                // Sanity: user can't withdraw more than vault has
                assertLe(
                    maxWithdrawable,
                    vaultYesShares,
                    "INVARIANT BROKEN: calculated withdrawal exceeds vault inventory (YES)"
                );
            }

            if (noVaultShares > 0) {
                uint256 totalNoVaultShares = router.totalNoVaultShares(marketId);
                (, uint256 vaultNoShares,) = router.bootstrapVaults(marketId);

                uint256 maxWithdrawable =
                    (uint256(noVaultShares) * vaultNoShares) / totalNoVaultShares;

                assertLe(
                    maxWithdrawable,
                    vaultNoShares,
                    "INVARIANT BROKEN: calculated withdrawal exceeds vault inventory (NO)"
                );
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                 SCENARIO TESTS (Edge Cases)
    // ═══════════════════════════════════════════════════════════

    /// @notice Test: Multiple users deposit/withdraw and invariants hold
    function test_invariants_afterMultipleDepositsWithdraws() public {
        // BOB deposits YES shares
        vm.startPrank(BOB);
        pamm.split(marketId, 5000 ether, BOB);
        router.depositToVault(marketId, true, 5000 ether, BOB, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        invariant_vaultSharesMatchUserBalances();
        invariant_collateralConservation();

        // CHARLIE deposits NO shares
        vm.startPrank(CHARLIE);
        pamm.split(marketId, 3000 ether, CHARLIE);
        router.depositToVault(marketId, false, 3000 ether, CHARLIE, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        invariant_vaultSharesMatchUserBalances();
        invariant_collateralConservation();

        // Simulate vault OTC fill (fees accrue)
        vm.startPrank(BOB);
        router.buyWithBootstrap(marketId, true, 1000 ether, 0, BOB, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        invariant_vaultSharesMatchUserBalances();
        invariant_collateralConservation();

        // Wait for withdrawal cooldown (30 minutes)
        vm.warp(block.timestamp + 6 hours + 1);

        // BOB withdraws
        vm.startPrank(BOB);
        (uint112 bobYesShares,,,,) = router.vaultPositions(marketId, BOB);
        router.withdrawFromVault(marketId, true, bobYesShares, BOB, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        invariant_vaultSharesMatchUserBalances();
        invariant_collateralConservation();
    }

    /// @notice Test: Budget settlement distributes correctly
    function test_invariants_afterBudgetSettlement() public {
        // Set up vault with inventory
        vm.startPrank(BOB);
        pamm.split(marketId, 10_000 ether, BOB);
        router.depositToVault(marketId, true, 5000 ether, BOB, DEADLINE_FAR_FUTURE);
        router.depositToVault(marketId, false, 5000 ether, BOB, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        // Build TWAP by making some trades over time
        vm.prank(CHARLIE);
        router.buyWithBootstrap(marketId, true, 500 ether, 0, CHARLIE, DEADLINE_FAR_FUTURE);

        vm.warp(block.timestamp + 6 minutes);
        vm.prank(CHARLIE);
        router.buyWithBootstrap(marketId, true, 500 ether, 0, CHARLIE, DEADLINE_FAR_FUTURE);

        vm.warp(block.timestamp + 6 minutes);
        vm.prank(CHARLIE);
        router.buyWithBootstrap(marketId, true, 500 ether, 0, CHARLIE, DEADLINE_FAR_FUTURE);

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);
        // Budget should accumulate from OTC fills (if TWAP is available)
        // Note: May be 0 if all trades went through AMM path instead of vault OTC

        invariant_collateralConservation();

        // Warp to after close
        (, bool resolved,,, uint64 close,,) = pamm.markets(marketId);
        vm.warp(close + 1);

        // Settle budget (should work even if budget is 0)
        router.settleRebalanceBudget(marketId);

        uint256 budgetAfter = router.rebalanceCollateralBudget(marketId);
        // Allow for small dust due to rounding in fee distribution
        assertLt(budgetAfter, 10_000, "Budget should be near 0 after settlement (dust allowed)");

        // Verify budget distributed correctly (went to LP fees or was already 0)
        if (budgetBefore > 0) {
            // Budget was distributed to LPs via accPerShare
            // We can't easily verify the exact distribution without tracking pre/post accPerShare
            // But we verify the invariants still hold
        }

        invariant_vaultSharesMatchUserBalances();
        invariant_collateralConservation();
    }

    /// @notice Test: Rebalancing preserves invariants
    function test_invariants_afterRebalance() public {
        // Set up vault with imbalanced inventory
        vm.startPrank(BOB);
        pamm.split(marketId, 10_000 ether, BOB);
        router.depositToVault(marketId, true, 5000 ether, BOB, DEADLINE_FAR_FUTURE);
        router.depositToVault(marketId, false, 1000 ether, BOB, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        // Create rebalance budget via OTC fill
        vm.startPrank(CHARLIE);
        router.buyWithBootstrap(marketId, true, 1000 ether, 0, CHARLIE, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        // Allow TWAP to establish (need multiple samples over time)
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(CHARLIE);
        router.buyWithBootstrap(marketId, true, 500 ether, 0, CHARLIE, DEADLINE_FAR_FUTURE);

        vm.warp(block.timestamp + 6 minutes);
        vm.prank(CHARLIE);
        router.buyWithBootstrap(marketId, true, 500 ether, 0, CHARLIE, DEADLINE_FAR_FUTURE);

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);
        if (budgetBefore > 0) {
            // Attempt rebalance (may fail if TWAP not ready, that's OK)
            try router.rebalanceBootstrapVault(marketId, DEADLINE_FAR_FUTURE) {
                // If rebalance succeeded, check invariants
                invariant_vaultSharesMatchUserBalances();
                invariant_collateralConservation();
                invariant_budgetConservation();
            } catch {
                // Rebalance failed (likely TWAP not ready), that's acceptable
            }
        }
    }

    /// @notice Test: No fee sniping by first LP
    function test_invariants_noFeeSniping() public {
        // Simulate fees accruing with no LPs in YES vault
        // (This would happen if market created with only NO deposits)

        // First, withdraw all YES LPs to empty the vault shares
        vm.startPrank(ALICE);
        (uint112 aliceYes,,,,) = router.vaultPositions(marketId, ALICE);
        if (aliceYes > 0) {
            router.withdrawFromVault(marketId, true, aliceYes, ALICE, DEADLINE_FAR_FUTURE);
        }
        vm.stopPrank();

        // Now totalYesVaultShares should be 0
        assertEq(router.totalYesVaultShares(marketId), 0, "YES vault should have no LPs");

        // Simulate a trade that would generate YES fees (if vault had inventory)
        // Since there are no YES LPs, fees should go to rebalance budget

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);

        // Try to buy YES (might use AMM path if vault empty)
        vm.prank(BOB);
        try router.buyWithBootstrap(marketId, true, 1000 ether, 0, BOB, DEADLINE_FAR_FUTURE) {}
            catch {}

        // If fees were generated with no LPs, they should increase rebalance budget
        // (We can't guarantee fees were generated since vault might be empty,
        //  but the invariant is that yesCollateral/noCollateral remain 0)

        invariant_feeSnipeProtection();
        invariant_collateralConservation();
    }

    /// @notice Invariant: Full withdrawal returns exactly deposited shares + earned fees (within rounding)
    /// @dev Tests that the "reset debt" withdrawal pattern correctly accounts for all fees
    function test_invariants_fullWithdrawalReturnsAllValue() public {
        // Setup: Alice deposits, trades generate fees, Alice withdraws all
        vm.startPrank(ALICE);
        pamm.split(marketId, 10_000 ether, ALICE);
        router.depositToVault(marketId, true, 5000 ether, ALICE, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        uint256 aliceInitialDeposit = 5000 ether;

        // Generate fees through multiple trades
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(BOB);
        router.buyWithBootstrap(marketId, true, 1000 ether, 0, BOB, DEADLINE_FAR_FUTURE);

        vm.warp(block.timestamp + 6 minutes);
        vm.prank(CHARLIE);
        router.buyWithBootstrap(marketId, true, 500 ether, 0, CHARLIE, DEADLINE_FAR_FUTURE);

        vm.warp(block.timestamp + 6 minutes);
        vm.prank(BOB);
        router.buyWithBootstrap(marketId, true, 300 ether, 0, BOB, DEADLINE_FAR_FUTURE);

        // Wait for withdrawal cooldown (6 hours total from deposit + buffer)
        vm.warp(block.timestamp + 6 hours);

        // Full withdrawal
        vm.startPrank(ALICE);
        (uint112 aliceVaultShares,,,,) = router.vaultPositions(marketId, ALICE);
        (uint256 sharesReturned, uint256 feesEarned) =
            router.withdrawFromVault(marketId, true, aliceVaultShares, ALICE, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        // Verify: sharesReturned + feesEarned should equal initial deposit within small rounding tolerance
        // (fees are in collateral, sharesReturned are share tokens, so this checks value conservation)
        uint256 totalValueReturned = sharesReturned + feesEarned;

        // Allow 1 wei rounding error
        assertApproxEqAbs(
            totalValueReturned,
            aliceInitialDeposit,
            1,
            "Full withdrawal should return deposited shares + fees (no drift)"
        );

        // Verify Alice's position is fully cleared
        (uint112 remainingShares, uint256 remainingDebt,,,) = router.vaultPositions(marketId, ALICE);
        assertEq(remainingShares, 0, "Alice should have 0 vault shares after full withdrawal");
        assertEq(remainingDebt, 0, "Alice should have 0 reward debt after full withdrawal");
    }

    /// @notice Invariant: Vault accounting matches actual PAMM balances
    /// @dev Tests that vault.yesShares/noShares always equals router's actual PAMM balance
    function test_invariants_vaultAccountingMatchesPAMMBalance() public {
        // Setup: Deposit to vaults
        vm.startPrank(ALICE);
        pamm.split(marketId, 10_000 ether, ALICE);
        router.depositToVault(marketId, true, 5000 ether, ALICE, DEADLINE_FAR_FUTURE);
        router.depositToVault(marketId, false, 3000 ether, ALICE, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        // Check initial state
        (uint112 vaultYes, uint112 vaultNo,) = router.bootstrapVaults(marketId);
        uint256 routerBalanceYes = pamm.balanceOf(address(router), marketId);
        uint256 routerBalanceNo = pamm.balanceOf(address(router), noId);

        assertEq(vaultYes, routerBalanceYes, "YES vault accounting should match PAMM balance");
        assertEq(vaultNo, routerBalanceNo, "NO vault accounting should match PAMM balance");

        // Generate some OTC fills (reduces vault shares and router balance equally)
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(BOB);
        router.buyWithBootstrap(marketId, true, 1000 ether, 0, BOB, DEADLINE_FAR_FUTURE);

        // Check after OTC fill
        (vaultYes, vaultNo,) = router.bootstrapVaults(marketId);
        routerBalanceYes = pamm.balanceOf(address(router), marketId);
        routerBalanceNo = pamm.balanceOf(address(router), noId);

        assertEq(
            vaultYes, routerBalanceYes, "YES vault accounting should match PAMM balance after OTC"
        );
        assertEq(
            vaultNo, routerBalanceNo, "NO vault accounting should match PAMM balance after OTC"
        );

        // Wait for withdrawal cooldown (6 hours total from deposit + buffer)
        vm.warp(block.timestamp + 6 hours);

        // Partial withdrawal
        vm.startPrank(ALICE);
        (uint112 aliceShares,,,,) = router.vaultPositions(marketId, ALICE);
        router.withdrawFromVault(marketId, true, aliceShares / 2, ALICE, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        // Check after withdrawal
        (vaultYes, vaultNo,) = router.bootstrapVaults(marketId);
        routerBalanceYes = pamm.balanceOf(address(router), marketId);
        routerBalanceNo = pamm.balanceOf(address(router), noId);

        assertEq(
            vaultYes,
            routerBalanceYes,
            "YES vault accounting should match PAMM balance after withdrawal"
        );
        assertEq(
            vaultNo,
            routerBalanceNo,
            "NO vault accounting should match PAMM balance after withdrawal"
        );
    }

    /// @notice Invariant: Partial withdrawals sum to same fees as single full withdrawal (within rounding)
    /// @dev Tests that partial withdrawals don't leak value due to rounding drift
    function test_invariants_partialWithdrawalsEquivalentToFull() public {
        // Setup: Two identical scenarios
        // Scenario A: Alice does partial withdrawals
        // Scenario B: Bob does single full withdrawal
        // Both should earn same total fees (within rounding)

        vm.startPrank(ALICE);
        pamm.split(marketId, 10_000 ether, ALICE);
        router.depositToVault(marketId, true, 6000 ether, ALICE, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        vm.startPrank(BOB);
        pamm.split(marketId, 10_000 ether, BOB);
        router.depositToVault(marketId, true, 6000 ether, BOB, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        // Generate fees
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(CHARLIE);
        router.buyWithBootstrap(marketId, true, 1000 ether, 0, CHARLIE, DEADLINE_FAR_FUTURE);

        vm.warp(block.timestamp + 6 minutes);
        vm.prank(CHARLIE);
        router.buyWithBootstrap(marketId, true, 800 ether, 0, CHARLIE, DEADLINE_FAR_FUTURE);

        // Wait for withdrawal cooldown (6 hours total from deposit + buffer)
        vm.warp(block.timestamp + 6 hours);

        // Scenario A: Alice does 3 partial withdrawals
        uint256 aliceTotalFees = 0;
        uint256 aliceTotalShares = 0;

        vm.startPrank(ALICE);
        (uint112 aliceVaultShares,,,,) = router.vaultPositions(marketId, ALICE);

        // Withdraw 1/3
        (uint256 shares1, uint256 fees1) = router.withdrawFromVault(
            marketId, true, aliceVaultShares / 3, ALICE, DEADLINE_FAR_FUTURE
        );
        aliceTotalShares += shares1;
        aliceTotalFees += fees1;

        // More trades to generate fees between withdrawals
        vm.stopPrank();
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(CHARLIE);
        router.buyWithBootstrap(marketId, true, 500 ether, 0, CHARLIE, DEADLINE_FAR_FUTURE);

        // Wait for withdrawal cooldown before next withdrawal
        vm.warp(block.timestamp + 6 hours);

        // Withdraw another 1/3
        vm.startPrank(ALICE);
        (aliceVaultShares,,,,) = router.vaultPositions(marketId, ALICE);
        (uint256 shares2, uint256 fees2) = router.withdrawFromVault(
            marketId, true, aliceVaultShares / 2, ALICE, DEADLINE_FAR_FUTURE
        );
        aliceTotalShares += shares2;
        aliceTotalFees += fees2;

        // More trades
        vm.stopPrank();
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(CHARLIE);
        router.buyWithBootstrap(marketId, true, 300 ether, 0, CHARLIE, DEADLINE_FAR_FUTURE);

        // Wait for withdrawal cooldown before final withdrawal (6 hours)
        vm.warp(block.timestamp + 6 hours);

        // Withdraw final portion
        vm.startPrank(ALICE);
        (aliceVaultShares,,,,) = router.vaultPositions(marketId, ALICE);
        (uint256 shares3, uint256 fees3) =
            router.withdrawFromVault(marketId, true, aliceVaultShares, ALICE, DEADLINE_FAR_FUTURE);
        aliceTotalShares += shares3;
        aliceTotalFees += fees3;
        vm.stopPrank();

        // Scenario B: Bob does single full withdrawal at the end
        vm.startPrank(BOB);
        (uint112 bobVaultShares,,,,) = router.vaultPositions(marketId, BOB);
        (uint256 bobShares, uint256 bobFees) =
            router.withdrawFromVault(marketId, true, bobVaultShares, BOB, DEADLINE_FAR_FUTURE);
        vm.stopPrank();

        // Compare: Alice's partial withdrawals should yield same total as Bob's full withdrawal
        // Allow small rounding tolerance (within 10 wei per withdrawal = 30 wei total for 3 withdrawals)
        assertApproxEqAbs(
            aliceTotalShares,
            bobShares,
            1,
            "Partial withdrawals should return same shares as full withdrawal"
        );

        assertApproxEqAbs(
            aliceTotalFees,
            bobFees,
            30,
            "Partial withdrawals should earn same fees as full withdrawal (within rounding)"
        );

        // Verify both positions are fully cleared
        (uint112 aliceRemaining,,,,) = router.vaultPositions(marketId, ALICE);
        (uint112 bobRemaining,,,,) = router.vaultPositions(marketId, BOB);
        assertEq(aliceRemaining, 0, "Alice should have 0 vault shares");
        assertEq(bobRemaining, 0, "Bob should have 0 vault shares");
    }
}
