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
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, taker);

        (,, uint256 pendingBefore,) = router.getUserPosition(marketId, false, 5000, alice);
        assertEq(pendingBefore, 25 ether, "Should have 25 ETH pending");

        // Alice deposits MORE - pending should be preserved
        vm.prank(alice);
        router.mintAndPool{value: 50 ether}(marketId, 50 ether, true, 5000, alice);

        (,, uint256 pendingAfter,) = router.getUserPosition(marketId, false, 5000, alice);
        assertEq(pendingAfter, 25 ether, "Pending should be preserved after deposit");
    }

    /// @notice Verify ASK pool withdrawal preserves pending
    function test_fix_askPool_withdrawPreservesPending() public {
        address alice = address(0x1);
        address taker = address(0x2);
        vm.deal(alice, 100 ether);
        vm.deal(taker, 100 ether);

        vm.prank(alice);
        router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);
        vm.prank(taker);
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, taker);

        (,, uint256 pendingBefore,) = router.getUserPosition(marketId, false, 5000, alice);
        assertEq(pendingBefore, 25 ether);

        // Alice withdraws 25 shares (50% of remaining 50 shares)
        vm.prank(alice);
        router.withdrawFromPool(marketId, false, 5000, 25 ether, alice);

        (,, uint256 pendingAfter,) = router.getUserPosition(marketId, false, 5000, alice);
        // After withdrawing 50% of remaining shares, ~50% of pending remains
        assertGt(pendingAfter, 10 ether, "Should preserve proportional pending");
        assertLt(pendingAfter, 15 ether, "Proportional reduction");
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
        router.sellToPool(marketId, true, 5000, 50 ether, seller);

        (,, uint256 pendingBefore,) = router.getBidPosition(marketId, true, 5000, alice);
        assertEq(pendingBefore, 50 ether, "Should have 50 shares pending");

        // Alice adds more - pending should be preserved
        vm.prank(alice);
        router.createBidPool{value: 50 ether}(marketId, 50 ether, true, 5000, alice);

        (,, uint256 pendingAfter,) = router.getBidPosition(marketId, true, 5000, alice);
        assertEq(pendingAfter, 50 ether, "Pending shares should be preserved");
    }

    /// @notice Verify BID pool withdrawal preserves pending shares
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
        router.sellToPool(marketId, true, 5000, 50 ether, seller);

        (,, uint256 pendingBefore,) = router.getBidPosition(marketId, true, 5000, alice);
        assertEq(pendingBefore, 50 ether);

        // Alice withdraws 25 ETH (33% of remaining 75 ETH collateral)
        vm.prank(alice);
        router.withdrawFromBidPool(marketId, true, 5000, 25 ether, alice);

        (,, uint256 pendingAfter,) = router.getBidPosition(marketId, true, 5000, alice);
        // Remaining ~66% of scaled units, so ~66% of 50 pending = ~33 shares
        assertGt(pendingAfter, 30 ether, "Should preserve most pending shares");
        assertLt(pendingAfter, 40 ether, "Proportional reduction");
    }
}
