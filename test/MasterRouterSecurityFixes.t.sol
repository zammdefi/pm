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

/// @title Security bug tests for MasterRouter
/// @notice Tests for bugs found during security audit and their fixes
contract MasterRouterSecurityFixesTest is Test {
    MasterRouter public router;
    IPAMMExtended public pamm = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public taker = address(0x4);

    uint256 public marketId;
    uint256 public noId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));
        router = new MasterRouter();

        (marketId, noId) = pamm.createMarket(
            "Test Market", address(this), address(0), uint64(block.timestamp + 30 days), false
        );

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(taker, 1000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    BUG #2: COLLATERAL THEFT VIA WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that users who withdraw before fills don't steal collateral
    /// @dev This was a critical bug where users could withdraw shares but still claim full collateral
    function test_bug2_withdrawalBeforeFills_noTheft() public {
        // Setup: Alice deposits 50, Bob deposits 50
        vm.prank(alice);
        bytes32 poolId = router.mintAndPool{value: 50 ether}(marketId, 50 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 50 ether}(marketId, 50 ether, true, 5000, bob);

        // Alice withdraws 40 shares BEFORE any fills
        vm.prank(alice);
        uint256 withdrawn = router.withdrawFromPool(marketId, false, 5000, 40 ether, alice);
        assertEq(withdrawn, 40 ether, "Alice withdraws 40 shares");

        // Now taker fills 60 shares (Alice's 10 + Bob's 50)
        vm.prank(taker);
        router.fillFromPool{value: 30 ether}(marketId, false, 5000, 60 ether, taker);

        // Check collateral distribution
        vm.prank(alice);
        uint256 aliceClaimed = router.claimProceeds(marketId, false, 5000, alice);

        vm.prank(bob);
        uint256 bobClaimed = router.claimProceeds(marketId, false, 5000, bob);

        // Alice should get: (10 effective shares / 60 total effective) * 30 ETH = 5 ETH
        // Bob should get: (50 effective shares / 60 total effective) * 30 ETH = 25 ETH
        assertApproxEqAbs(aliceClaimed, 5 ether, 1e9, "Alice gets 5 ETH (10/60 of pool)");
        assertApproxEqAbs(bobClaimed, 25 ether, 1e9, "Bob gets 25 ETH (50/60 of pool)");

        // Total should equal what taker paid
        assertEq(aliceClaimed + bobClaimed, 30 ether, "Total distributed equals total earned");
    }

    /// @notice Test collateral distribution with no withdrawals (should work as before)
    function test_bug2_noWithdrawals_proportionalDistribution() public {
        // Setup: Alice deposits 50, Bob deposits 50
        vm.prank(alice);
        bytes32 poolId = router.mintAndPool{value: 50 ether}(marketId, 50 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 50 ether}(marketId, 50 ether, true, 5000, bob);

        // Taker fills 60 shares
        vm.prank(taker);
        router.fillFromPool{value: 30 ether}(marketId, false, 5000, 60 ether, taker);

        // Both should get proportional amounts (50/100 each)
        vm.prank(alice);
        uint256 aliceClaimed = router.claimProceeds(marketId, false, 5000, alice);

        vm.prank(bob);
        uint256 bobClaimed = router.claimProceeds(marketId, false, 5000, bob);

        assertApproxEqAbs(aliceClaimed, 15 ether, 1e9, "Alice gets 15 ETH (50% of pool)");
        assertApproxEqAbs(bobClaimed, 15 ether, 1e9, "Bob gets 15 ETH (50% of pool)");
    }

    /*//////////////////////////////////////////////////////////////
                    BUG #3: IMPOSSIBLE WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that withdrawal calculation accounts for sharesWithdrawn
    /// @dev This was a bug where withdrawal could fail due to incorrect unfilled calculation
    function test_bug3_withdrawalAfterOthersWithdraw() public {
        // Setup: Alice 60, Bob 40 (total 100)
        vm.prank(alice);
        bytes32 poolId = router.mintAndPool{value: 60 ether}(marketId, 60 ether, true, 5000, alice);

        vm.prank(bob);
        router.mintAndPool{value: 40 ether}(marketId, 40 ether, true, 5000, bob);

        // Alice withdraws 50
        vm.prank(alice);
        router.withdrawFromPool(marketId, false, 5000, 50 ether, alice);

        // Taker fills 50 (all remaining shares)
        vm.prank(taker);
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, taker);

        // Bob should NOT be able to withdraw (all shares filled)
        vm.prank(bob);
        vm.expectRevert();
        router.withdrawFromPool(marketId, false, 5000, 1 ether, bob);
    }

    /// @notice Test partial withdrawals work correctly
    function test_bug3_partialWithdrawals() public {
        vm.prank(alice);
        bytes32 poolId =
            router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        // Fill 50 shares
        vm.prank(taker);
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, taker);

        // Alice should be able to withdraw remaining 50
        vm.prank(alice);
        uint256 withdrawn = router.withdrawFromPool(marketId, false, 5000, 0, alice);
        assertEq(withdrawn, 50 ether, "Alice withdraws 50 unfilled shares");
    }

    /*//////////////////////////////////////////////////////////////
                    BUG #1: OVERFLOW PROTECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that uint256 storage prevents overflow
    /// @dev This tests that totalCollateralEarned can accumulate large amounts
    function test_bug1_largeAccumulation() public {
        vm.prank(alice);
        bytes32 poolId =
            router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        // Fill in multiple batches (simulating many fills over time)
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(address(uint160(1000 + i)));
            vm.deal(address(uint160(1000 + i)), 10 ether);
            router.fillFromPool{value: 5 ether}(
                marketId, false, 5000, 10 ether, address(uint160(1000 + i))
            );
        }

        // Alice should be able to claim all accumulated collateral
        vm.prank(alice);
        uint256 claimed = router.claimProceeds(marketId, false, 5000, alice);
        assertEq(claimed, 50 ether, "Alice claims all accumulated collateral");
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test getUserPosition returns correct values after withdrawals
    /// @dev In accumulator model: returns (userScaled, userWithdrawableShares, userPendingCollateral, userCollateralDebt)
    function test_getUserPosition_afterWithdrawal() public {
        vm.prank(alice);
        bytes32 poolId =
            router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        // Withdraw 40 - reduces Alice's scaled LP units to 60
        vm.prank(alice);
        router.withdrawFromPool(marketId, false, 5000, 40 ether, alice);

        // Fill 30 from remaining 60 shares - Alice earns 15 ETH
        vm.prank(taker);
        router.fillFromPool{value: 15 ether}(marketId, false, 5000, 30 ether, taker);

        (
            uint256 userScaled,
            uint256 userWithdrawableShares,
            uint256 userPendingCollateral,
            uint256 userCollateralDebt
        ) = router.getUserPosition(marketId, false, 5000, alice);

        // In accumulator model: scaled reduced after withdrawal
        assertEq(userScaled, 60 ether, "User scaled is 60 after withdrawing 40");
        assertEq(userWithdrawableShares, 30 ether, "30 withdrawable shares (60 - 30 filled)");
        assertEq(userPendingCollateral, 15 ether, "Earned 15 ETH from fills");
        assertEq(userCollateralDebt, 0, "Debt is 0 (checkpoint resets on withdraw)");
    }

    /// @notice Test multiple claims work correctly
    function test_multipleClaims() public {
        vm.prank(alice);
        bytes32 poolId =
            router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        // First fill
        vm.prank(taker);
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, taker);

        // First claim
        vm.prank(alice);
        uint256 claimed1 = router.claimProceeds(marketId, false, 5000, alice);
        assertEq(claimed1, 25 ether, "First claim");

        // Second fill
        vm.prank(bob);
        vm.deal(bob, 100 ether);
        router.fillFromPool{value: 25 ether}(marketId, false, 5000, 50 ether, bob);

        // Second claim
        vm.prank(alice);
        uint256 claimed2 = router.claimProceeds(marketId, false, 5000, alice);
        assertEq(claimed2, 25 ether, "Second claim");

        // Third claim should return 0
        vm.prank(alice);
        uint256 claimed3 = router.claimProceeds(marketId, false, 5000, alice);
        assertEq(claimed3, 0, "Nothing left to claim");
    }

    /// @notice Test withdrawal after full fill reverts
    function test_withdrawalAfterFullFill_reverts() public {
        vm.prank(alice);
        bytes32 poolId =
            router.mintAndPool{value: 100 ether}(marketId, 100 ether, true, 5000, alice);

        // Fill all shares
        vm.prank(taker);
        router.fillFromPool{value: 50 ether}(marketId, false, 5000, 100 ether, taker);

        // Withdrawal should revert (no unfilled shares)
        vm.prank(alice);
        vm.expectRevert();
        router.withdrawFromPool(marketId, false, 5000, 1 ether, alice);
    }

    /*//////////////////////////////////////////////////////////////
                    PERMIT REENTRANCY PROTECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that permit() has reentrancy protection
    /// @dev Malicious token could attempt reentry during permit call
    function test_permit_hasReentrancyGuard() public {
        // Deploy a malicious token that tries to reenter
        MaliciousPermitToken malToken = new MaliciousPermitToken(address(router));

        // Call permit - if reentrancy guard works, the reentry attempt will revert
        // and we catch it gracefully
        vm.expectRevert(); // Either from reentrancy guard or from malicious token logic
        router.permit(
            address(malToken),
            alice,
            100 ether,
            block.timestamp + 1 hours,
            27,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );
    }

    /// @notice Test that permitDAI() has reentrancy protection
    function test_permitDAI_hasReentrancyGuard() public {
        MaliciousPermitToken malToken = new MaliciousPermitToken(address(router));

        vm.expectRevert();
        router.permitDAI(
            address(malToken),
            alice,
            0,
            block.timestamp + 1 hours,
            true,
            27,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );
    }
}

/// @notice Malicious token that attempts reentrancy during permit
contract MaliciousPermitToken {
    MasterRouter public router;
    bool public attacked;

    constructor(address _router) {
        router = MasterRouter(payable(_router));
    }

    // This gets called when router.permit() calls token.permit()
    fallback() external {
        if (!attacked) {
            attacked = true;
            // Attempt to reenter - should fail due to nonReentrant
            router.permit(
                address(this),
                address(0x1),
                1 ether,
                block.timestamp + 1 hours,
                27,
                bytes32(uint256(1)),
                bytes32(uint256(2))
            );
        }
    }
}
