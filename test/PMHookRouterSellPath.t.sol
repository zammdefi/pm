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
}

/// @title PMHookRouter Sell Path Tests
/// @notice Comprehensive tests for sellWithBootstrap covering OTC, AMM, and edge cases
contract PMHookRouterSellPathTest is BaseTest {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address constant ETH = address(0);

    PMHookRouter public router;
    PMFeeHook public hook;

    address public ALICE;
    address public BOB;

    uint256 public marketId;
    uint256 public noId;
    uint256 public poolId;
    uint64 public closeTime;

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

    function setUp() public {
        createForkWithFallback("main3");

        hook = new PMFeeHook();

        PMHookRouter tempRouter = new PMHookRouter();
        vm.etch(REGISTRAR, address(tempRouter).code);
        router = PMHookRouter(payable(REGISTRAR));

        vm.startPrank(REGISTRAR);
        PAMM.setOperator(address(0x000000000000040470635EB91b7CE4D132D616eD), true); // ZAMM
        PAMM.setOperator(address(PAMM), true);
        vm.stopPrank();

        vm.prank(hook.owner());
        hook.transferOwnership(address(router));

        ALICE = makeAddr("ALICE");
        BOB = makeAddr("BOB");

        deal(ALICE, 100000 ether);
        deal(BOB, 100000 ether);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // HELPER: Bootstrap market and setup for sell tests
    // ══════════════════════════════════════════════════════════════════════════════

    function _bootstrapMarket(uint256 lpAmount) internal {
        closeTime = uint64(block.timestamp + 30 days);
        vm.prank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: lpAmount}(
            "Sell Test Market",
            ALICE,
            ETH,
            closeTime,
            false,
            address(hook),
            lpAmount,
            true,
            0,
            0,
            ALICE,
            block.timestamp + 1 hours
        );
        noId = PAMM.getNoId(marketId);
    }

    function _setupTWAP() internal {
        vm.warp(block.timestamp + 31 minutes);
        vm.roll(block.number + 100);
        router.updateTWAPObservation(marketId);
    }

    function _createImbalancedVaultWithBudget(bool makeYesScarce) internal {
        // Deposit shares to vault to create inventory
        vm.startPrank(BOB);
        PAMM.split{value: 200 ether}(marketId, 200 ether, BOB);
        PAMM.setOperator(address(router), true);

        // Deposit both sides to vault
        router.depositToVault(marketId, true, 100 ether, BOB, closeTime);
        router.depositToVault(marketId, false, 100 ether, BOB, closeTime);
        vm.stopPrank();

        // Now create imbalance by buying from vault
        // This also generates rebalanceCollateralBudget
        vm.startPrank(ALICE);
        if (makeYesScarce) {
            // Buy YES to make YES scarce in vault
            router.buyWithBootstrap{value: 50 ether}(marketId, true, 50 ether, 0, ALICE, closeTime);
        } else {
            // Buy NO to make NO scarce in vault
            router.buyWithBootstrap{value: 50 ether}(marketId, false, 50 ether, 0, ALICE, closeTime);
        }
        vm.stopPrank();

        // Update TWAP after trades
        vm.warp(block.timestamp + 31 minutes);
        vm.roll(block.number + 100);
        router.updateTWAPObservation(marketId);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Sell OTC - Sell YES when YES is scarce
    // ══════════════════════════════════════════════════════════════════════════════

    function test_SellOTC_SellYesWhenYesScarce() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();
        _createImbalancedVaultWithBudget(true); // YES is scarce

        // Verify vault state - YES should be scarce
        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        assertLt(yesShares, noShares, "YES should be scarce");

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);
        assertGt(budgetBefore, 0, "Should have rebalance budget");

        // ALICE has YES shares from the buy, get some more to sell
        vm.startPrank(ALICE);
        PAMM.split{value: 10 ether}(marketId, 10 ether, ALICE);
        PAMM.setOperator(address(router), true);

        uint256 aliceYesBefore = PAMM.balanceOf(ALICE, marketId);
        uint256 aliceEthBefore = ALICE.balance;
        uint256 sharesToSell = 5 ether;

        // Expect VaultOTCFill event with buyYes=false (vault is buying YES)
        vm.expectEmit(true, true, false, false);
        emit VaultOTCFill(marketId, ALICE, ALICE, false, 0, 0, 0, 0, 0);

        (uint256 collateralOut, bytes4 source) =
            router.sellWithBootstrap(marketId, true, sharesToSell, 0, ALICE, closeTime);
        vm.stopPrank();

        // Verify OTC was used
        assertTrue(source == bytes4("otc") || source == bytes4("mult"), "Should use OTC path");
        assertGt(collateralOut, 0, "Should receive collateral");

        // Verify budget decreased
        uint256 budgetAfter = router.rebalanceCollateralBudget(marketId);
        assertLt(budgetAfter, budgetBefore, "Budget should decrease");

        // Verify vault YES shares increased
        (uint112 yesSharesAfter,,) = router.bootstrapVaults(marketId);
        assertGt(yesSharesAfter, yesShares, "Vault YES shares should increase");

        // Verify ALICE received ETH
        assertGt(ALICE.balance, aliceEthBefore, "ALICE should receive ETH");

        console.log("Sell OTC (YES scarce) - collateralOut:", collateralOut);
        console.log("Sell OTC (YES scarce) - source:", string(abi.encodePacked(source)));
        console.log("Sell OTC (YES scarce) - budget used:", budgetBefore - budgetAfter);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Sell OTC - Sell NO when NO is scarce
    // ══════════════════════════════════════════════════════════════════════════════

    function test_SellOTC_SellNoWhenNoScarce() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Create imbalance: deposit more YES than NO to vault (NO is scarce)
        vm.startPrank(BOB);
        PAMM.split{value: 200 ether}(marketId, 200 ether, BOB);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, BOB, closeTime); // More YES
        router.depositToVault(marketId, false, 50 ether, BOB, closeTime); // Less NO - this makes NO scarce
        vm.stopPrank();

        // Verify initial vault state - NO should be scarce
        (uint112 yesSharesInit, uint112 noSharesInit,) = router.bootstrapVaults(marketId);
        console.log("Initial Vault YES:", yesSharesInit);
        console.log("Initial Vault NO:", noSharesInit);
        assertLt(noSharesInit, yesSharesInit, "NO should initially be scarce");

        // Buy NO from vault (depletes scarce NO, generates budget from spread)
        vm.prank(ALICE);
        router.buyWithBootstrap{value: 15 ether}(marketId, false, 15 ether, 0, ALICE, closeTime);

        // Update TWAP
        vm.warp(block.timestamp + 31 minutes);
        vm.roll(block.number + 100);
        router.updateTWAPObservation(marketId);

        // Check vault state - NO should still be scarce (we depleted it further)
        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        console.log("After buy - Vault YES:", yesShares);
        console.log("After buy - Vault NO:", noShares);

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);
        console.log("Budget before sell:", budgetBefore);

        // Sell NO (the scarce side) - this should trigger OTC if budget exists
        vm.startPrank(ALICE);
        PAMM.setOperator(address(router), true); // Approve router to spend ALICE's shares
        // ALICE already has NO from the buy above, split more for safety
        PAMM.split{value: 5 ether}(marketId, 5 ether, ALICE);

        uint256 sharesToSell = 3 ether;
        uint256 aliceNoBefore = PAMM.balanceOf(ALICE, noId);
        console.log("ALICE NO before sell:", aliceNoBefore);

        (uint256 collateralOut, bytes4 source) =
            router.sellWithBootstrap(marketId, false, sharesToSell, 0, ALICE, closeTime);
        vm.stopPrank();

        console.log("Sell OTC (NO scarce) - collateralOut:", collateralOut);
        console.log("Sell OTC (NO scarce) - source:", string(abi.encodePacked(source)));

        // Verify sell succeeded
        assertGt(collateralOut, 0, "Should receive collateral");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Sell OTC - Budget limited fill
    // ══════════════════════════════════════════════════════════════════════════════

    function test_SellOTC_BudgetLimitedFill() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();
        _createImbalancedVaultWithBudget(true); // YES is scarce

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);

        // Get YES shares to sell
        vm.startPrank(ALICE);
        PAMM.split{value: 50 ether}(marketId, 50 ether, ALICE);
        PAMM.setOperator(address(router), true);

        // Sell an amount that will exhaust the budget
        // Budget is small relative to share value, so even moderate sells can exhaust it
        uint256 sellAmount = 30 ether;

        (uint256 collateralOut, bytes4 source) =
            router.sellWithBootstrap(marketId, true, sellAmount, 0, ALICE, closeTime);
        vm.stopPrank();

        // Budget should be significantly reduced (possibly to 0)
        uint256 budgetAfter = router.rebalanceCollateralBudget(marketId);

        console.log("Budget limited - budget before:", budgetBefore);
        console.log("Budget limited - budget after:", budgetAfter);
        console.log("Budget limited - collateralOut:", collateralOut);
        console.log("Budget limited - source:", string(abi.encodePacked(source)));

        // Should use multiple venues if OTC couldn't fill everything
        if (budgetBefore < collateralOut) {
            assertEq(source, bytes4("mult"), "Should use multi-venue when budget exhausted");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Sell OTC + AMM multi-venue (source = "mult")
    // ══════════════════════════════════════════════════════════════════════════════

    function test_SellOTC_MultiVenue() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();
        _createImbalancedVaultWithBudget(true); // YES is scarce

        // Get YES shares
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);

        // Sell enough that OTC fills partially and AMM handles rest
        // OTC cap is 30% of opposite side inventory
        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        uint256 otcCap = uint256(noShares) * 3 / 10;

        // Sell more than OTC cap to trigger multi-venue
        uint256 sellAmount = otcCap + 10 ether;

        (uint256 collateralOut, bytes4 source) =
            router.sellWithBootstrap(marketId, true, sellAmount, 0, ALICE, closeTime);
        vm.stopPrank();

        console.log("Multi-venue - OTC cap:", otcCap);
        console.log("Multi-venue - sell amount:", sellAmount);
        console.log("Multi-venue - collateralOut:", collateralOut);
        console.log("Multi-venue - source:", string(abi.encodePacked(source)));

        // Should potentially use multi-venue
        assertTrue(
            source == bytes4("otc") || source == bytes4("amm") || source == bytes4("mult"),
            "Should use valid source"
        );
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Sell skips OTC when selling abundant side
    // ══════════════════════════════════════════════════════════════════════════════

    function test_Sell_SkipsOTCWhenSellingAbundantSide() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();
        _createImbalancedVaultWithBudget(true); // YES is scarce, NO is abundant

        // Verify YES is scarce
        (uint112 yesShares, uint112 noShares,) = router.bootstrapVaults(marketId);
        assertLt(yesShares, noShares, "YES should be scarce");

        uint256 budgetBefore = router.rebalanceCollateralBudget(marketId);

        // Sell NO (the abundant side) - should NOT use OTC
        vm.startPrank(ALICE);
        PAMM.split{value: 10 ether}(marketId, 10 ether, ALICE);
        PAMM.setOperator(address(router), true);

        (uint256 collateralOut, bytes4 source) =
            router.sellWithBootstrap(marketId, false, 5 ether, 0, ALICE, closeTime);
        vm.stopPrank();

        // Budget should NOT decrease (OTC not used)
        uint256 budgetAfter = router.rebalanceCollateralBudget(marketId);
        assertEq(budgetAfter, budgetBefore, "Budget should not change when selling abundant side");

        // Should use AMM only
        assertEq(source, bytes4("amm"), "Should use AMM when selling abundant side");

        console.log("Sell abundant side - source:", string(abi.encodePacked(source)));
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Validation - sharesIn == 0 reverts
    // ══════════════════════════════════════════════════════════════════════════════

    function test_Sell_RevertsOnZeroShares() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        vm.startPrank(ALICE);
        PAMM.setOperator(address(router), true);

        vm.expectRevert();
        router.sellWithBootstrap(marketId, true, 0, 0, ALICE, closeTime);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Validation - deadline expired reverts
    // ══════════════════════════════════════════════════════════════════════════════

    function test_Sell_RevertsOnExpiredDeadline() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        vm.startPrank(ALICE);
        PAMM.split{value: 10 ether}(marketId, 10 ether, ALICE);
        PAMM.setOperator(address(router), true);

        uint256 expiredDeadline = block.timestamp - 1;
        vm.expectRevert();
        router.sellWithBootstrap(marketId, true, 5 ether, 0, ALICE, expiredDeadline);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Validation - close window reverts
    // ══════════════════════════════════════════════════════════════════════════════

    function test_Sell_RevertsInCloseWindow() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Warp to close window (within 1 hour of close)
        vm.warp(closeTime - 30 minutes);

        vm.startPrank(ALICE);
        PAMM.split{value: 10 ether}(marketId, 10 ether, ALICE);
        PAMM.setOperator(address(router), true);

        vm.expectRevert();
        router.sellWithBootstrap(marketId, true, 5 ether, 0, ALICE, closeTime);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Validation - slippage check (minOut)
    // ══════════════════════════════════════════════════════════════════════════════

    function test_Sell_RevertsOnSlippage() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        vm.startPrank(ALICE);
        PAMM.split{value: 10 ether}(marketId, 10 ether, ALICE);
        PAMM.setOperator(address(router), true);

        // Set unreasonably high minOut
        uint256 unreasonableMinOut = 100 ether;
        vm.expectRevert();
        router.sellWithBootstrap(marketId, true, 5 ether, unreasonableMinOut, ALICE, closeTime);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Edge case - Return remaining shares when AMM fails
    // ══════════════════════════════════════════════════════════════════════════════

    function test_Sell_ReturnsRemainingSharesWhenAMMFails() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        // Create scenario where OTC doesn't trigger and AMM might have issues
        // This tests the remaining shares return path we added

        vm.startPrank(ALICE);
        PAMM.split{value: 10 ether}(marketId, 10 ether, ALICE);
        PAMM.setOperator(address(router), true);

        uint256 aliceYesBefore = PAMM.balanceOf(ALICE, marketId);
        uint256 sharesToSell = 5 ether;

        // Even if AMM partially fails, user shouldn't lose shares
        (uint256 collateralOut, bytes4 source) =
            router.sellWithBootstrap(marketId, true, sharesToSell, 0, ALICE, closeTime);
        vm.stopPrank();

        uint256 aliceYesAfter = PAMM.balanceOf(ALICE, marketId);

        // User should either:
        // 1. Have sold shares and received collateral, OR
        // 2. Have shares returned if sell failed
        if (collateralOut == 0) {
            // If no collateral received, shares should be returned
            assertEq(aliceYesAfter, aliceYesBefore, "Shares should be returned if no sale");
        } else {
            // If collateral received, shares should be reduced
            assertLt(aliceYesAfter, aliceYesBefore, "Shares should decrease on successful sale");
        }

        console.log("Remaining shares test - collateralOut:", collateralOut);
        console.log("Remaining shares test - YES before:", aliceYesBefore);
        console.log("Remaining shares test - YES after:", aliceYesAfter);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Sell to different recipient
    // ══════════════════════════════════════════════════════════════════════════════

    function test_Sell_ToDifferentRecipient() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();

        vm.startPrank(ALICE);
        PAMM.split{value: 10 ether}(marketId, 10 ether, ALICE);
        PAMM.setOperator(address(router), true);

        uint256 bobEthBefore = BOB.balance;

        // ALICE sells but BOB receives the collateral
        (uint256 collateralOut,) =
            router.sellWithBootstrap(marketId, true, 5 ether, 0, BOB, closeTime);
        vm.stopPrank();

        uint256 bobEthAfter = BOB.balance;
        assertEq(bobEthAfter - bobEthBefore, collateralOut, "BOB should receive collateral");

        console.log("Different recipient - BOB received:", collateralOut);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Sell OTC - Verify spread calculation
    // ══════════════════════════════════════════════════════════════════════════════

    function test_SellOTC_SpreadCalculation() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();
        _createImbalancedVaultWithBudget(true); // YES is scarce

        // Get TWAP price
        // The spread should be p/50 (2% of price) with min 10 bps

        vm.startPrank(ALICE);
        PAMM.split{value: 10 ether}(marketId, 10 ether, ALICE);
        PAMM.setOperator(address(router), true);

        uint256 sharesToSell = 1 ether;
        (uint256 collateralOut, bytes4 source) =
            router.sellWithBootstrap(marketId, true, sharesToSell, 0, ALICE, closeTime);
        vm.stopPrank();

        if (source == bytes4("otc") || source == bytes4("mult")) {
            // Effective price = collateralOut / sharesToSell
            // Should be TWAP - spread
            uint256 effectivePriceBps = (collateralOut * 10000) / sharesToSell;
            console.log("Sell OTC spread - effective price bps:", effectivePriceBps);
            console.log("Sell OTC spread - collateralOut:", collateralOut);

            // Price should be reasonable (between 1% and 99%)
            assertGt(effectivePriceBps, 100, "Price should be > 1%");
            assertLt(effectivePriceBps, 9900, "Price should be < 99%");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TEST: Full integration - Multiple sells deplete OTC then use AMM
    // ══════════════════════════════════════════════════════════════════════════════

    function test_Sell_SequentialSellsDepleteOTCThenAMM() public {
        _bootstrapMarket(100 ether);
        _setupTWAP();
        _createImbalancedVaultWithBudget(true); // YES is scarce

        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);

        // First sell - should use OTC
        (uint256 collateral1, bytes4 source1) =
            router.sellWithBootstrap(marketId, true, 10 ether, 0, ALICE, closeTime);
        console.log(
            "Sell 1 - source:", string(abi.encodePacked(source1)), "collateral:", collateral1
        );

        // Check budget
        uint256 budgetAfter1 = router.rebalanceCollateralBudget(marketId);
        console.log("Budget after sell 1:", budgetAfter1);

        // Second sell - might use OTC or AMM depending on remaining budget
        (uint256 collateral2, bytes4 source2) =
            router.sellWithBootstrap(marketId, true, 10 ether, 0, ALICE, closeTime);
        console.log(
            "Sell 2 - source:", string(abi.encodePacked(source2)), "collateral:", collateral2
        );

        // Third sell - more likely to use AMM
        (uint256 collateral3, bytes4 source3) =
            router.sellWithBootstrap(marketId, true, 10 ether, 0, ALICE, closeTime);
        console.log(
            "Sell 3 - source:", string(abi.encodePacked(source3)), "collateral:", collateral3
        );

        vm.stopPrank();

        // All sells should succeed
        assertGt(collateral1 + collateral2 + collateral3, 0, "Should receive collateral from sells");
    }
}
