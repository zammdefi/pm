// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "../src/MasterRouter.sol";

interface IPAMMExt is IPAMM {
    function createMarket(string calldata, address, address, uint64, bool)
        external
        returns (uint256, uint256);
    function balanceOf(address, uint256) external view returns (uint256);
}

contract BugFixVerificationTest is Test {
    MasterRouter router;
    IPAMMExt pamm = IPAMMExt(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    uint256 marketId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));
        router = new MasterRouter();
        (marketId,) = pamm.createMarket(
            "Test", address(this), address(0), uint64(block.timestamp + 30 days), false
        );
    }

    /// @notice Verify ASK pool deposit preserves pending
    function test_fix_askPool_depositPreservesPending() public {
        address alice = address(0x1);
        address taker = address(0x2);
        vm.deal(alice, 200 ether);
        vm.deal(taker, 100 ether);

        // Alice deposits, taker fills, Alice has pending
        vm.prank(alice);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);
        vm.prank(taker);
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, 0, taker, 0);

        (,, uint256 pendingBefore,) = router.getUserPosition(marketId, false, 5000, alice);
        assertEq(pendingBefore, 25 ether, "Should have 25 ETH pending");

        // Alice deposits MORE - pending should be preserved
        vm.prank(alice);
        router.mintAndPool{value: 50 ether}(marketId, 50 ether, true, 5000, alice);

        (,, uint256 pendingAfter,) = router.getUserPosition(marketId, false, 5000, alice);
        assertEq(pendingAfter, 25 ether, "Pending should be preserved after deposit");
    }

    /// @notice Verify ASK pool withdrawal auto-claims pending (not lost)
    function test_fix_askPool_withdrawPreservesPending() public {
        address alice = address(0x1);
        address taker = address(0x2);
        vm.deal(alice, 100 ether);
        vm.deal(taker, 100 ether);

        vm.prank(alice);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);
        vm.prank(taker);
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, 0, taker, 0);

        (,, uint256 pendingBefore,) = router.getUserPosition(marketId, false, 5000, alice);
        assertEq(pendingBefore, 25 ether);

        uint256 aliceBalBefore = alice.balance;

        // Alice withdraws 25 shares (50% of remaining 50 shares)
        // withdrawFromPool auto-claims all pending to prevent loss
        vm.prank(alice);
        (uint256 sharesWithdrawn, uint256 collateralClaimed) =
            router.withdrawFromPool(marketId, false, 5000, 25 ether, alice);

        assertEq(sharesWithdrawn, 25 ether, "Should withdraw requested shares");
        assertEq(collateralClaimed, 25 ether, "Should auto-claim all pending");
        assertEq(alice.balance - aliceBalBefore, 25 ether, "Should receive claimed collateral");

        // Pending is now 0 because it was claimed (not lost)
        (,, uint256 pendingAfter,) = router.getUserPosition(marketId, false, 5000, alice);
        assertEq(pendingAfter, 0, "Pending claimed on withdrawal");
    }

    /// @notice Verify BID pool deposit preserves pending shares
    function test_fix_bidPool_depositPreservesPending() public {
        address alice = address(0x1);
        address seller = address(0x2);
        vm.deal(alice, 200 ether);
        vm.deal(seller, 100 ether);

        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        vm.prank(seller);
        pamm.split{value: 50 ether}(marketId, 50 ether, seller);
        vm.prank(seller);
        pamm.setOperator(address(router), true);
        vm.prank(seller);
        router.sellToPool(marketId, true, 5000, 50 ether, 0, seller, 0);

        (,, uint256 pendingBefore,) = router.getBidPosition(marketId, true, 5000, alice);
        assertEq(pendingBefore, 50 ether, "Should have 50 shares pending");

        // Alice adds more - pending should be preserved
        vm.prank(alice);
        router.createBidPool{value: 50 ether}(marketId, 50 ether, true, 5000, alice);

        (,, uint256 pendingAfter,) = router.getBidPosition(marketId, true, 5000, alice);
        assertEq(pendingAfter, 50 ether, "Pending shares should be preserved");
    }

    /// @notice Verify BID pool withdrawal auto-claims pending shares (not lost)
    function test_fix_bidPool_withdrawPreservesPending() public {
        address alice = address(0x1);
        address seller = address(0x2);
        vm.deal(alice, 100 ether);
        vm.deal(seller, 100 ether);

        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        vm.prank(seller);
        pamm.split{value: 50 ether}(marketId, 50 ether, seller);
        vm.prank(seller);
        pamm.setOperator(address(router), true);
        vm.prank(seller);
        router.sellToPool(marketId, true, 5000, 50 ether, 0, seller, 0);

        (,, uint256 pendingBefore,) = router.getBidPosition(marketId, true, 5000, alice);
        assertEq(pendingBefore, 50 ether);

        uint256 aliceSharesBefore = pamm.balanceOf(alice, marketId);

        // Alice withdraws 25 ETH (33% of remaining 75 ETH collateral)
        // withdrawFromBidPool auto-claims all pending shares to prevent loss
        vm.prank(alice);
        (uint256 collateralWithdrawn, uint256 sharesClaimed) =
            router.withdrawFromBidPool(marketId, true, 5000, 25 ether, alice);

        assertEq(collateralWithdrawn, 25 ether, "Should withdraw requested collateral");
        assertEq(sharesClaimed, 50 ether, "Should auto-claim all pending shares");
        assertEq(
            pamm.balanceOf(alice, marketId) - aliceSharesBefore,
            50 ether,
            "Should receive claimed shares"
        );

        // Pending is now 0 because it was claimed (not lost)
        (,, uint256 pendingAfter,) = router.getBidPosition(marketId, true, 5000, alice);
        assertEq(pendingAfter, 0, "Pending claimed on withdrawal");
    }
}
