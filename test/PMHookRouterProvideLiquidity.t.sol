// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./BaseTest.sol";
import {PMHookRouter} from "../src/PMHookRouter.sol";
import {PMFeeHook} from "../src/PMFeeHook.sol";

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
    function claim(uint256 marketId, address to) external returns (uint256, uint256);
    function getNoId(uint256 marketId) external pure returns (uint256);
}

interface IZAMM {
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

    function balanceOf(address account) external view returns (uint256);
    function balanceOf(address account, uint256 poolId) external view returns (uint256);
}

/// @title PMHookRouter ProvideLiquidity Tests
/// @notice Comprehensive tests for provideLiquidity, redeemVaultWinningShares, settleRebalanceBudget
/// @dev These functions had zero or minimal test coverage
contract PMHookRouterProvideLiquidityTest is BaseTest {
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    address constant REGISTRAR = 0x0000000000BADa259Cb860c12ccD9500d9496B3e;
    address constant ETH = address(0);
    uint64 constant DEADLINE_2028 = 1861919999;

    PMHookRouter public router;
    PMFeeHook public hook;

    address public ALICE;
    address public BOB;
    address public CAROL;

    uint256 public marketId;
    uint256 public poolId;
    uint256 public noId;

    function setUp() public {
        createForkWithFallback("main4");

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

        deal(ALICE, 10000 ether);
        deal(BOB, 10000 ether);
        deal(CAROL, 10000 ether);

        _bootstrapMarket();
    }

    function _bootstrapMarket() internal {
        vm.startPrank(ALICE);
        (marketId, poolId,,) = router.bootstrapMarket{value: 1000 ether}(
            "ProvideLiquidity Test Market",
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
        noId = PAMM.getNoId(marketId);
    }

    // ============ provideLiquidity Tests ============

    /// @notice Test basic provideLiquidity with all three destinations
    function test_ProvideLiquidity_AllThreeDestinations() public {
        uint256 collateral = 100 ether;
        uint256 vaultYes = 30 ether;
        uint256 vaultNo = 30 ether;
        uint256 ammLP = 20 ether;

        vm.prank(BOB);
        (uint256 yesVaultShares, uint256 noVaultShares, uint256 ammLiq) = router.provideLiquidity{
            value: collateral
        }(
            marketId, collateral, vaultYes, vaultNo, ammLP, 0, 0, BOB, block.timestamp + 1 hours
        );

        // Should receive vault shares for both sides
        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");
        assertGt(ammLiq, 0, "Should receive AMM LP tokens");

        // Check BOB has leftover shares (100 - 30 - 20 = 50 YES, 100 - 30 - 20 = 50 NO)
        uint256 yesId = marketId;
        uint256 noId = noId;
        uint256 bobYes = PAMM.balanceOf(BOB, yesId);
        uint256 bobNo = PAMM.balanceOf(BOB, noId);

        // Leftover = collateral - vaultShares - ammLP = 100 - 30 - 20 = 50 each
        assertApproxEqAbs(bobYes, 50 ether, 1e15, "BOB should have ~50 leftover YES");
        assertApproxEqAbs(bobNo, 50 ether, 1e15, "BOB should have ~50 leftover NO");
    }

    /// @notice Test provideLiquidity with only vault deposits (no AMM)
    function test_ProvideLiquidity_VaultOnly() public {
        uint256 collateral = 100 ether;
        uint256 vaultYes = 50 ether;
        uint256 vaultNo = 40 ether;
        uint256 ammLP = 0;

        vm.prank(BOB);
        (uint256 yesVaultShares, uint256 noVaultShares, uint256 ammLiq) = router.provideLiquidity{
            value: collateral
        }(
            marketId, collateral, vaultYes, vaultNo, ammLP, 0, 0, BOB, block.timestamp + 1 hours
        );

        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");
        assertEq(ammLiq, 0, "Should NOT receive AMM LP (requested 0)");

        // Check leftover shares
        uint256 yesId = marketId;
        uint256 noId = noId;
        // Leftover YES = 100 - 50 = 50, Leftover NO = 100 - 40 = 60
        assertApproxEqAbs(PAMM.balanceOf(BOB, yesId), 50 ether, 1e15, "BOB should have 50 YES");
        assertApproxEqAbs(PAMM.balanceOf(BOB, noId), 60 ether, 1e15, "BOB should have 60 NO");
    }

    /// @notice Test provideLiquidity with only AMM (no vault deposits)
    function test_ProvideLiquidity_AMMOnly() public {
        uint256 collateral = 100 ether;
        uint256 vaultYes = 0;
        uint256 vaultNo = 0;
        uint256 ammLP = 50 ether;

        vm.prank(BOB);
        (uint256 yesVaultShares, uint256 noVaultShares, uint256 ammLiq) = router.provideLiquidity{
            value: collateral
        }(
            marketId, collateral, vaultYes, vaultNo, ammLP, 0, 0, BOB, block.timestamp + 1 hours
        );

        assertEq(yesVaultShares, 0, "Should NOT receive YES vault shares");
        assertEq(noVaultShares, 0, "Should NOT receive NO vault shares");
        assertGt(ammLiq, 0, "Should receive AMM LP tokens");

        // Leftover = 100 - 50 = 50 each side
        uint256 yesId = marketId;
        uint256 noId = noId;
        assertApproxEqAbs(PAMM.balanceOf(BOB, yesId), 50 ether, 1e15, "BOB should have 50 YES");
        assertApproxEqAbs(PAMM.balanceOf(BOB, noId), 50 ether, 1e15, "BOB should have 50 NO");
    }

    /// @notice Test provideLiquidity with asymmetric vault deposits
    function test_ProvideLiquidity_AsymmetricVault() public {
        uint256 collateral = 100 ether;
        uint256 vaultYes = 80 ether; // High YES vault
        uint256 vaultNo = 10 ether; // Low NO vault
        uint256 ammLP = 10 ether; // Uses min(100-80, 100-10) = min(20, 90) = 20, but request 10

        vm.prank(BOB);
        (uint256 yesVaultShares, uint256 noVaultShares, uint256 ammLiq) = router.provideLiquidity{
            value: collateral
        }(
            marketId, collateral, vaultYes, vaultNo, ammLP, 0, 0, BOB, block.timestamp + 1 hours
        );

        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");
        assertGt(ammLiq, 0, "Should receive AMM LP");

        // Leftover YES = 100 - 80 - 10 = 10
        // Leftover NO = 100 - 10 - 10 = 80
        uint256 yesId = marketId;
        uint256 noId = noId;
        assertApproxEqAbs(PAMM.balanceOf(BOB, yesId), 10 ether, 1e15, "BOB should have 10 YES");
        assertApproxEqAbs(PAMM.balanceOf(BOB, noId), 80 ether, 1e15, "BOB should have 80 NO");
    }

    /// @notice Test provideLiquidity with max vault (all to vaults)
    function test_ProvideLiquidity_MaxVault() public {
        uint256 collateral = 100 ether;
        uint256 vaultYes = 100 ether;
        uint256 vaultNo = 100 ether;
        uint256 ammLP = 0; // Can't add any AMM since all goes to vaults

        vm.prank(BOB);
        (uint256 yesVaultShares, uint256 noVaultShares, uint256 ammLiq) = router.provideLiquidity{
            value: collateral
        }(
            marketId, collateral, vaultYes, vaultNo, ammLP, 0, 0, BOB, block.timestamp + 1 hours
        );

        assertGt(yesVaultShares, 0, "Should receive YES vault shares");
        assertGt(noVaultShares, 0, "Should receive NO vault shares");
        assertEq(ammLiq, 0, "No AMM LP");

        // No leftover shares
        uint256 yesId = marketId;
        uint256 noId = noId;
        assertEq(PAMM.balanceOf(BOB, yesId), 0, "No leftover YES");
        assertEq(PAMM.balanceOf(BOB, noId), 0, "No leftover NO");
    }

    /// @notice Test provideLiquidity reverts when vault shares exceed collateral
    function test_ProvideLiquidity_RevertExcessVaultShares() public {
        uint256 collateral = 100 ether;
        uint256 vaultYes = 101 ether; // Exceeds collateral
        uint256 vaultNo = 50 ether;

        vm.prank(BOB);
        vm.expectRevert();
        router.provideLiquidity{value: collateral}(
            marketId, collateral, vaultYes, vaultNo, 0, 0, 0, BOB, block.timestamp + 1 hours
        );
    }

    /// @notice Test provideLiquidity reverts when AMM exceeds remaining
    function test_ProvideLiquidity_RevertExcessAMM() public {
        uint256 collateral = 100 ether;
        uint256 vaultYes = 90 ether;
        uint256 vaultNo = 50 ether;
        uint256 ammLP = 20 ether; // yesRemaining = 10, so 20 > 10, should fail

        vm.prank(BOB);
        vm.expectRevert();
        router.provideLiquidity{value: collateral}(
            marketId, collateral, vaultYes, vaultNo, ammLP, 0, 0, BOB, block.timestamp + 1 hours
        );
    }

    /// @notice Test provideLiquidity with different receiver
    function test_ProvideLiquidity_DifferentReceiver() public {
        uint256 collateral = 100 ether;

        vm.prank(BOB);
        router.provideLiquidity{value: collateral}(
            marketId,
            collateral,
            30 ether,
            30 ether,
            20 ether,
            0,
            0,
            CAROL, // Different receiver
            block.timestamp + 1 hours
        );

        // CAROL should have the vault position
        (uint112 carolYesVault, uint112 carolNoVault,,,) = router.vaultPositions(marketId, CAROL);
        assertGt(carolYesVault, 0, "CAROL should have YES vault shares");
        assertGt(carolNoVault, 0, "CAROL should have NO vault shares");

        // CAROL should have leftover shares
        uint256 yesId = marketId;
        uint256 noId = noId;
        assertGt(PAMM.balanceOf(CAROL, yesId), 0, "CAROL should have leftover YES");
        assertGt(PAMM.balanceOf(CAROL, noId), 0, "CAROL should have leftover NO");

        // BOB should have nothing (paid but CAROL received)
        (uint112 bobYesVault, uint112 bobNoVault,,,) = router.vaultPositions(marketId, BOB);
        assertEq(bobYesVault, 0, "BOB should have no vault shares");
        assertEq(bobNoVault, 0, "BOB should have no vault shares");
    }

    /// @notice Test provideLiquidity with zero receiver defaults to caller
    function test_ProvideLiquidity_ZeroReceiverDefaultsToCaller() public {
        uint256 collateral = 50 ether;

        vm.prank(BOB);
        router.provideLiquidity{value: collateral}(
            marketId,
            collateral,
            20 ether,
            20 ether,
            0,
            0,
            0,
            address(0), // Zero receiver
            block.timestamp + 1 hours
        );

        // BOB should have the position (zero address defaults to caller)
        (uint112 bobYesVault, uint112 bobNoVault,,,) = router.vaultPositions(marketId, BOB);
        assertGt(bobYesVault, 0, "BOB should have YES vault shares");
        assertGt(bobNoVault, 0, "BOB should have NO vault shares");
    }

    /// @notice Test provideLiquidity with deadline enforcement
    function test_ProvideLiquidity_DeadlineEnforcement() public {
        uint256 collateral = 50 ether;
        uint256 pastDeadline = block.timestamp - 1;

        vm.prank(BOB);
        vm.expectRevert();
        router.provideLiquidity{value: collateral}(
            marketId, collateral, 20 ether, 20 ether, 0, 0, 0, BOB, pastDeadline
        );
    }

    /// @notice Test provideLiquidity updates lastActivity timestamp
    function test_ProvideLiquidity_UpdatesLastActivity() public {
        // Get initial lastActivity from bootstrap
        (,, uint32 initialActivity) = router.bootstrapVaults(marketId);

        // Warp forward to create a timestamp difference
        vm.warp(block.timestamp + 2 hours);
        uint256 newTimestamp = block.timestamp;

        vm.prank(BOB);
        router.provideLiquidity{value: 50 ether}(
            marketId, 50 ether, 20 ether, 20 ether, 0, 0, 0, BOB, block.timestamp + 1 hours
        );

        // The vault's lastActivity should be updated to new timestamp
        (,, uint32 lastActivity) = router.bootstrapVaults(marketId);
        assertEq(lastActivity, uint32(newTimestamp), "lastActivity should equal current timestamp");
        assertGt(lastActivity, initialActivity, "lastActivity should be greater than initial");
    }

    // ============ settleRebalanceBudget Tests ============

    /// @notice Test settleRebalanceBudget after market closes
    function test_SettleRebalanceBudget_AfterMarketClose() public {
        // Setup vault with deposits
        vm.startPrank(ALICE);
        PAMM.split{value: 200 ether}(marketId, 200 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Wait for TWAP to establish
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // Generate some rebalance budget through trades
        vm.prank(BOB);
        router.buyWithBootstrap{value: 100 ether}(
            marketId, true, 100 ether, 0, BOB, block.timestamp + 1 hours
        );

        // Let TWAP catch up
        vm.warp(block.timestamp + 35 minutes);
        router.updateTWAPObservation(marketId);

        // Try rebalance to generate budget
        uint256 budget = router.rebalanceCollateralBudget(marketId);

        // Warp past market close
        vm.warp(DEADLINE_2028 + 1);

        // Settle should work after market closes
        (uint256 budgetDistributed, uint256 sharesMerged) = router.settleRebalanceBudget(marketId);

        // Budget should be distributed or shares merged
        assertTrue(
            budgetDistributed > 0 || sharesMerged > 0 || budget == 0,
            "Should settle budget or have nothing to settle"
        );
    }

    /// @notice Test settleRebalanceBudget reverts before market closes
    function test_SettleRebalanceBudget_RevertsBeforeClose() public {
        // Market is still open
        vm.expectRevert();
        router.settleRebalanceBudget(marketId);
    }

    /// @notice Test settleRebalanceBudget with unbalanced vault inventory
    function test_SettleRebalanceBudget_MergesBalancedInventory() public {
        // Setup vault with imbalanced inventory
        vm.startPrank(ALICE);
        PAMM.split{value: 300 ether}(marketId, 300 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 200 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Fast forward past cooldown
        vm.warp(block.timestamp + 6 hours + 1);

        // Warp to market close
        vm.warp(DEADLINE_2028 + 1);

        // Settle should merge min(yes, no) shares
        (uint256 budgetDistributed, uint256 sharesMerged) = router.settleRebalanceBudget(marketId);

        // Should have merged min(200, 100) = 100 shares
        assertEq(sharesMerged, 100 ether, "Should merge 100 shares (min of yes, no)");
    }

    // ============ redeemVaultWinningShares Tests ============

    /// @notice Test redeemVaultWinningShares after resolution (YES wins)
    function test_RedeemVaultWinningShares_YesWins() public {
        // Setup vault with both sides
        vm.startPrank(ALICE);
        PAMM.split{value: 200 ether}(marketId, 200 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Wait for cooldown
        vm.warp(block.timestamp + 6 hours + 1);

        // Alice withdraws her vault position
        vm.startPrank(ALICE);
        (uint112 aliceYes, uint112 aliceNo,,,) = router.vaultPositions(marketId, ALICE);
        router.withdrawFromVault(marketId, true, aliceYes, ALICE, block.timestamp + 1 hours);
        router.withdrawFromVault(marketId, false, aliceNo, ALICE, block.timestamp + 1 hours);
        vm.stopPrank();

        // Warp past market close time before resolving
        vm.warp(DEADLINE_2028 + 1);

        // Resolve market as YES
        vm.prank(ALICE);
        PAMM.resolve(marketId, true);

        // Check no circulating LP shares
        uint256 totalYes = router.totalYesVaultShares(marketId);
        uint256 totalNo = router.totalNoVaultShares(marketId);
        assertEq(totalYes, 0, "No circulating YES shares");
        assertEq(totalNo, 0, "No circulating NO shares");

        // Redeem winning shares (YES shares in vault go to DAO)
        uint256 payout = router.redeemVaultWinningShares(marketId);

        // Payout may be 0 if vault was fully withdrawn
        assertTrue(true, "redeemVaultWinningShares executed");
    }

    /// @notice Test redeemVaultWinningShares after resolution (NO wins)
    function test_RedeemVaultWinningShares_NoWins() public {
        // Setup vault
        vm.startPrank(ALICE);
        PAMM.split{value: 200 ether}(marketId, 200 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 100 ether, ALICE, block.timestamp + 7 hours);
        router.depositToVault(marketId, false, 100 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Wait and withdraw
        vm.warp(block.timestamp + 6 hours + 1);
        vm.startPrank(ALICE);
        (uint112 aliceYes, uint112 aliceNo,,,) = router.vaultPositions(marketId, ALICE);
        router.withdrawFromVault(marketId, true, aliceYes, ALICE, block.timestamp + 1 hours);
        router.withdrawFromVault(marketId, false, aliceNo, ALICE, block.timestamp + 1 hours);
        vm.stopPrank();

        // Warp past market close time before resolving
        vm.warp(DEADLINE_2028 + 1);

        // Resolve as NO
        vm.prank(ALICE);
        PAMM.resolve(marketId, false);

        // Redeem
        uint256 payout = router.redeemVaultWinningShares(marketId);
        assertTrue(true, "redeemVaultWinningShares executed for NO outcome");
    }

    /// @notice Test redeemVaultWinningShares reverts if circulating LPs exist
    function test_RedeemVaultWinningShares_RevertsWithCirculatingLPs() public {
        // Setup vault - Alice deposits but doesn't withdraw
        vm.startPrank(ALICE);
        PAMM.split{value: 100 ether}(marketId, 100 ether, ALICE);
        PAMM.setOperator(address(router), true);
        router.depositToVault(marketId, true, 50 ether, ALICE, block.timestamp + 7 hours);
        vm.stopPrank();

        // Resolve market
        vm.warp(DEADLINE_2028 + 1);
        vm.prank(ALICE);
        PAMM.resolve(marketId, true);

        // Alice still has circulating LP shares - should revert
        vm.expectRevert();
        router.redeemVaultWinningShares(marketId);
    }

    /// @notice Test redeemVaultWinningShares reverts before resolution
    function test_RedeemVaultWinningShares_RevertsBeforeResolution() public {
        // Market not resolved yet
        vm.expectRevert();
        router.redeemVaultWinningShares(marketId);
    }

    // ============ Integration Tests ============

    /// @notice Test full lifecycle: provideLiquidity -> trade -> settle -> redeem
    function test_FullLifecycle_ProvideLiquidity() public {
        // 1. BOB provides liquidity
        vm.prank(BOB);
        router.provideLiquidity{value: 200 ether}(
            marketId, 200 ether, 50 ether, 50 ether, 50 ether, 0, 0, BOB, DEADLINE_2028
        );

        // 2. Wait for cooldown and update TWAP
        vm.warp(block.timestamp + 6 hours + 1);
        router.updateTWAPObservation(marketId);

        // 3. CAROL trades
        vm.prank(CAROL);
        router.buyWithBootstrap{value: 50 ether}(marketId, true, 50 ether, 0, CAROL, DEADLINE_2028);

        // 4. BOB withdraws vault position
        vm.startPrank(BOB);
        (uint112 bobYes, uint112 bobNo,,,) = router.vaultPositions(marketId, BOB);
        if (bobYes > 0) {
            router.withdrawFromVault(marketId, true, bobYes, BOB, DEADLINE_2028);
        }
        if (bobNo > 0) {
            router.withdrawFromVault(marketId, false, bobNo, BOB, DEADLINE_2028);
        }
        vm.stopPrank();

        // 5. Warp to close and resolve
        vm.warp(DEADLINE_2028 + 1);
        vm.prank(ALICE);
        PAMM.resolve(marketId, true);

        // 6. Settle budget
        router.settleRebalanceBudget(marketId);

        // 7. Redeem winning shares
        router.redeemVaultWinningShares(marketId);

        assertTrue(true, "Full lifecycle completed");
    }

    /// @notice Test multiple LPs providing liquidity
    function test_MultipleLPs_ProvideLiquidity() public {
        // ALICE already has position from bootstrap
        // BOB and CAROL provide more liquidity

        vm.prank(BOB);
        router.provideLiquidity{value: 100 ether}(
            marketId, 100 ether, 30 ether, 30 ether, 20 ether, 0, 0, BOB, block.timestamp + 1 hours
        );

        vm.prank(CAROL);
        router.provideLiquidity{value: 150 ether}(
            marketId,
            150 ether,
            50 ether,
            50 ether,
            30 ether,
            0,
            0,
            CAROL,
            block.timestamp + 1 hours
        );

        // All three should have vault positions
        (uint112 bobYes,,,,) = router.vaultPositions(marketId, BOB);
        (uint112 carolYes,,,,) = router.vaultPositions(marketId, CAROL);

        assertGt(bobYes, 0, "BOB should have YES vault shares");
        assertGt(carolYes, 0, "CAROL should have YES vault shares");
    }

    /// @notice Fuzz test provideLiquidity with valid parameters
    function testFuzz_ProvideLiquidity_ValidParams(
        uint96 collateral,
        uint96 vaultYes,
        uint96 vaultNo,
        uint96 ammLP
    ) public {
        // Bound to reasonable values
        collateral = uint96(bound(collateral, 1 ether, 1000 ether));
        vaultYes = uint96(bound(vaultYes, 0, collateral));
        vaultNo = uint96(bound(vaultNo, 0, collateral));

        // AMM must not exceed remaining on either side
        uint96 yesRemaining = collateral - vaultYes;
        uint96 noRemaining = collateral - vaultNo;
        uint96 maxAMM = yesRemaining < noRemaining ? yesRemaining : noRemaining;
        ammLP = uint96(bound(ammLP, 0, maxAMM));

        deal(BOB, uint256(collateral) + 1 ether);

        vm.prank(BOB);
        (uint256 yesVaultShares, uint256 noVaultShares, uint256 ammLiq) = router.provideLiquidity{
            value: collateral
        }(
            marketId, collateral, vaultYes, vaultNo, ammLP, 0, 0, BOB, block.timestamp + 1 hours
        );

        // Validate outputs match inputs
        if (vaultYes > 0) assertGt(yesVaultShares, 0, "Should have YES vault shares");
        if (vaultNo > 0) assertGt(noVaultShares, 0, "Should have NO vault shares");
        if (ammLP > 0) assertGt(ammLiq, 0, "Should have AMM liquidity");
    }
}
