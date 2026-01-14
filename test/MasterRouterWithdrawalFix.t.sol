// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "../src/MasterRouter.sol";

interface IPAMMExtended is IPAMM {
    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);

    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @notice Test to verify withdrawal accounting fix
contract MasterRouterWithdrawalFixTest is Test {
    MasterRouter public router;
    IPAMMExtended public pamm = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public taker = address(0x3);

    uint256 public marketId;
    uint256 public noId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        router = new MasterRouter();

        (marketId, noId) = pamm.createMarket(
            "Test Market", address(this), address(0), uint64(block.timestamp + 30 days), false
        );

        vm.deal(alice, 200 ether);
        vm.deal(bob, 200 ether);
        vm.deal(taker, 200 ether);
    }

    /// @notice Critical test: Verify withdrawal doesn't break other users' accounting
    function test_withdrawalDoesNotBreakOtherUsersAccounting() public {
        // Setup: Alice and Bob each pool 100 shares at 0.50
        vm.prank(alice);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, bob);

        // Total pool: 200 shares at 0.50

        // 50 shares get filled
        vm.prank(taker);
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, 0, taker, 0);

        // Check unfilled before Alice withdraws
        (, uint256 aliceUnfilledBefore,,) = router.getUserPosition(marketId, false, 5000, alice);
        (, uint256 bobUnfilledBefore,,) = router.getUserPosition(marketId, false, 5000, bob);

        assertEq(aliceUnfilledBefore, 75 ether, "Alice should have 75 unfilled");
        assertEq(bobUnfilledBefore, 75 ether, "Bob should have 75 unfilled");

        // Alice withdraws her 75 unfilled shares
        vm.prank(alice);
        (uint256 withdrawn,) = router.withdrawFromPool(marketId, false, 5000, 75 ether, alice);
        assertEq(withdrawn, 75 ether, "Alice withdrew 75");

        // CRITICAL: Bob's unfilled should STILL be 75, not affected by Alice's withdrawal
        (, uint256 bobUnfilledAfter,,) = router.getUserPosition(marketId, false, 5000, bob);
        assertEq(
            bobUnfilledAfter, 75 ether, "Bob's unfilled should remain 75 after Alice withdraws"
        );

        // Alice should now have 0 unfilled
        (, uint256 aliceUnfilledAfter,,) = router.getUserPosition(marketId, false, 5000, alice);
        assertEq(aliceUnfilledAfter, 0, "Alice should have 0 unfilled after withdrawing all");
    }

    /// @notice Test: Proportional earnings remain correct after withdrawal
    /// @dev In accumulator model: must claim before withdraw to preserve earnings
    function test_proportionalEarningsAfterWithdrawal() public {
        // Setup: Alice pools 100, Bob pools 200 (1:2 ratio)
        vm.prank(alice);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 200 ether}(marketId, 200 ether, true, 5000, bob);

        // 60 shares get filled (20% filled), paying 30 ETH
        vm.prank(taker);
        router.fillFromPool{value: 30 ether}(marketId, false, 5000, 60 ether, 0, taker, 0);

        // Alice MUST claim before withdrawing in accumulator model
        vm.prank(alice);
        uint256 aliceFirstClaim = router.claimProceeds(marketId, false, 5000, alice);
        // Alice gets 1/3 of 30 ETH = 10 ETH
        assertEq(aliceFirstClaim, 10 ether, "Alice claims first fill share");

        // Alice withdraws some unfilled shares
        vm.prank(alice);
        router.withdrawFromPool(marketId, false, 5000, 40 ether, alice);

        // More shares get filled - 40 shares for 20 ETH
        // Pool now has: Alice ~50 scaled, Bob 200 scaled = 250 total
        vm.prank(taker);
        router.fillFromPool{value: 20 ether}(marketId, false, 5000, 40 ether, 0, taker, 0);

        // Check earnings from second fill
        vm.prank(alice);
        uint256 aliceSecondClaim = router.claimProceeds(marketId, false, 5000, alice);

        vm.prank(bob);
        uint256 bobEarned = router.claimProceeds(marketId, false, 5000, bob);

        // Alice: 10 ETH (first claim) + some from second fill
        // Bob: 20 ETH (first fill) + some from second fill
        uint256 aliceTotal = aliceFirstClaim + aliceSecondClaim;

        // Total 50 ETH distributed, verify sum
        assertEq(aliceTotal + bobEarned, 50 ether, "Total earnings = 50 ETH");

        // Bob should get majority (he has 200/300 = 2/3 initially, more after Alice withdraws)
        assertGt(bobEarned, aliceTotal, "Bob earns more than Alice");
    }

    /// @notice Test: Multiple users withdraw without affecting each other
    function test_multipleUsersWithdrawIndependently() public {
        address carol = address(0x4);
        vm.deal(carol, 100 ether);

        // Three users pool equal amounts
        vm.prank(alice);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, bob);

        vm.prank(carol);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, carol);

        // 30 shares filled
        vm.prank(taker);
        router.fillFromPool{value: 15 ether}(marketId, false, 5000, 30 ether, 0, taker, 0);

        // Each should have 90 unfilled
        (, uint256 aliceUnfilled1,,) = router.getUserPosition(marketId, false, 5000, alice);
        (, uint256 bobUnfilled1,,) = router.getUserPosition(marketId, false, 5000, bob);
        (, uint256 carolUnfilled1,,) = router.getUserPosition(marketId, false, 5000, carol);

        assertEq(aliceUnfilled1, 90 ether);
        assertEq(bobUnfilled1, 90 ether);
        assertEq(carolUnfilled1, 90 ether);

        // Alice withdraws 50
        vm.prank(alice);
        router.withdrawFromPool(marketId, false, 5000, 50 ether, alice);

        // Bob and Carol should still have 90 unfilled
        (, uint256 bobUnfilled2,,) = router.getUserPosition(marketId, false, 5000, bob);
        (, uint256 carolUnfilled2,,) = router.getUserPosition(marketId, false, 5000, carol);

        assertEq(bobUnfilled2, 90 ether, "Bob unaffected by Alice withdrawal");
        assertEq(carolUnfilled2, 90 ether, "Carol unaffected by Alice withdrawal");

        // Bob withdraws all 90
        vm.prank(bob);
        router.withdrawFromPool(marketId, false, 5000, 0, bob); // 0 = withdraw all

        // Carol should still have 90 unfilled
        (, uint256 carolUnfilled3,,) = router.getUserPosition(marketId, false, 5000, carol);
        assertEq(carolUnfilled3, 90 ether, "Carol unaffected by Bob withdrawal");
    }

    /// @notice Test: Pool state tracking with accumulator model
    /// @dev In accumulator model: totalShares shows remaining (decreases on fill/withdraw)
    function test_sharesWithdrawnTracking() public {
        vm.prank(alice);
        bytes32 poolId =
            router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        // Check initial state - accumulator model: (totalShares, totalScaled, accCollPerScaled, collateralEarned)
        (uint256 totalShares, uint256 totalScaled,,) = router.pools(poolId);
        assertEq(totalShares, 100 ether, "Initial totalShares");
        assertEq(totalScaled, 100 ether, "Initial totalScaled");

        // 30 filled - totalShares decreases
        vm.prank(taker);
        router.fillFromPool{value: 15 ether}(marketId, false, 5000, 30 ether, 0, taker, 0);

        (totalShares, totalScaled,,) = router.pools(poolId);
        assertEq(totalShares, 70 ether, "70 shares remaining after 30 filled");
        assertEq(totalScaled, 100 ether, "totalScaled unchanged by fills");

        // Alice withdraws 40 - both totalShares and totalScaled decrease
        vm.prank(alice);
        router.withdrawFromPool(marketId, false, 5000, 40 ether, alice);

        (totalShares, totalScaled,,) = router.pools(poolId);
        assertEq(totalShares, 30 ether, "30 shares remaining after withdrawal");
        // totalScaled decreases proportionally: 100 * (40/70) = ~57 burned, ~43 remaining
        // Actually: burnScaled = ceilDiv(40 * 100, 70) = ceilDiv(4000, 70) = 58
        // So totalScaled = 100 - 58 = 42 (approximately)
        assertLt(totalScaled, 100 ether, "totalScaled decreased");

        // Alice's unfilled should be 30 (all remaining)
        (, uint256 aliceUnfilled,,) = router.getUserPosition(marketId, false, 5000, alice);
        assertEq(aliceUnfilled, 30 ether, "Alice can withdraw remaining 30");
    }
}
