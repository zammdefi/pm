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

/// @title Fuzz Tests for MasterRouter Pooled Orderbook (Accumulator Model)
/// @notice Property-based testing with randomized inputs
contract MasterRouterFuzzTest is Test {
    MasterRouter public router;
    IPAMMExtended public pamm = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    address public constant ALICE = address(0x1);
    address public constant BOB = address(0x2);
    address public constant TAKER = address(0x99);

    uint256 public marketId;
    uint256 public noId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));
        router = new MasterRouter();

        (marketId, noId) = pamm.createMarket(
            "Fuzz Test Market", address(this), address(0), uint64(block.timestamp + 30 days), false
        );

        vm.deal(ALICE, type(uint128).max);
        vm.deal(BOB, type(uint128).max);
        vm.deal(TAKER, type(uint128).max);
    }

    /// @dev Ceiling division helper
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz: Pool any valid amount at any valid price
    function testFuzz_mintAndPool(uint256 amount, uint16 priceBps) public {
        // Bound inputs to reasonable ranges
        amount = bound(amount, 1 ether, 1000 ether);
        priceBps = uint16(bound(priceBps, 1, 9999));

        vm.deal(ALICE, amount);

        vm.prank(ALICE);
        bytes32 poolId = router.mintAndPool{value: amount}(marketId, amount, true, priceBps, ALICE);

        // Verify pool created correctly (accumulator model)
        (uint256 totalShares, uint256 totalScaled, uint256 accCollPerScaled,) = router.pools(poolId);
        assertEq(totalShares, amount, "Total shares matches amount");
        assertEq(totalScaled, amount, "Total scaled matches amount (first depositor)");
        assertEq(accCollPerScaled, 0, "No collateral earned yet");

        // Verify user position
        (uint256 userScaled, uint256 userWithdrawable,,) =
            router.getUserPosition(marketId, false, priceBps, ALICE);
        assertEq(userScaled, amount, "User scaled correct");
        assertEq(userWithdrawable, amount, "User withdrawable correct");
    }

    /// @notice Fuzz: Fill any valid amount from pool
    function testFuzz_fillFromPool(uint256 poolAmount, uint256 fillAmount, uint16 priceBps) public {
        // Bound inputs
        poolAmount = bound(poolAmount, 1 ether, 1000 ether);
        priceBps = uint16(bound(priceBps, 100, 9999)); // At least 1% to avoid zero collateral

        // Ensure fillAmount is valid
        fillAmount = bound(fillAmount, 0.01 ether, poolAmount);

        vm.deal(ALICE, poolAmount);

        // Pool
        vm.prank(ALICE);
        bytes32 poolId =
            router.mintAndPool{value: poolAmount}(marketId, poolAmount, true, priceBps, ALICE);

        // Calculate collateral needed (contract uses ceiling division)
        uint256 collateralNeeded = ceilDiv(fillAmount * priceBps, 10000);
        if (collateralNeeded == 0) return; // Skip if collateral rounds to 0

        vm.deal(TAKER, collateralNeeded);

        // Fill
        vm.prank(TAKER);
        (uint256 sharesBought, uint256 collateralPaid) = router.fillFromPool{
            value: collateralNeeded
        }(
            marketId, false, priceBps, fillAmount, TAKER
        );

        // Verify fill
        assertEq(sharesBought, fillAmount, "Shares bought matches requested");
        assertEq(collateralPaid, collateralNeeded, "Collateral paid matches expected");

        // Verify pool state updated
        (uint256 totalShares,,,) = router.pools(poolId);
        assertEq(totalShares, poolAmount - fillAmount, "Pool shares decreased by fill amount");
    }

    /// @notice Fuzz: Withdraw from pool
    function testFuzz_withdrawFromPool(uint256 poolAmount, uint256 withdrawAmount, uint16 priceBps)
        public
    {
        // Bound inputs
        poolAmount = bound(poolAmount, 1 ether, 1000 ether);
        priceBps = uint16(bound(priceBps, 1, 9999));
        withdrawAmount = bound(withdrawAmount, 0.01 ether, poolAmount);

        vm.deal(ALICE, poolAmount);

        // Pool
        vm.prank(ALICE);
        bytes32 poolId =
            router.mintAndPool{value: poolAmount}(marketId, poolAmount, true, priceBps, ALICE);

        // Withdraw
        vm.prank(ALICE);
        uint256 withdrawn =
            router.withdrawFromPool(marketId, false, priceBps, withdrawAmount, ALICE);

        // Verify withdrawal
        assertEq(withdrawn, withdrawAmount, "Withdrawn matches requested");

        // Verify pool state
        (uint256 totalShares,,,) = router.pools(poolId);
        assertEq(totalShares, poolAmount - withdrawAmount, "Pool shares decreased");

        // Verify Alice received NO tokens
        assertEq(pamm.balanceOf(ALICE, noId), withdrawAmount, "Alice received NO tokens");
    }

    /// @notice Fuzz: Claim proceeds after fills
    function testFuzz_claimProceeds(uint256 poolAmount, uint256 fillAmount, uint16 priceBps)
        public
    {
        // Bound inputs to reasonable ranges to minimize accumulator rounding
        poolAmount = bound(poolAmount, 1 ether, 100 ether);
        priceBps = uint16(bound(priceBps, 100, 9000));
        fillAmount = bound(fillAmount, 0.1 ether, poolAmount);

        vm.deal(ALICE, poolAmount);

        // Pool
        vm.prank(ALICE);
        router.mintAndPool{value: poolAmount}(marketId, poolAmount, true, priceBps, ALICE);

        // Calculate and fund collateral
        uint256 collateralNeeded = ceilDiv(fillAmount * priceBps, 10000);
        if (collateralNeeded == 0) return;
        vm.deal(TAKER, collateralNeeded);

        // Fill
        vm.prank(TAKER);
        router.fillFromPool{value: collateralNeeded}(marketId, false, priceBps, fillAmount, TAKER);

        // Check pending before claim (allow small rounding)
        (,, uint256 pending,) = router.getUserPosition(marketId, false, priceBps, ALICE);
        assertApproxEqAbs(pending, collateralNeeded, 100, "Pending matches collateral paid");

        // Claim
        uint256 aliceBalBefore = ALICE.balance;
        vm.prank(ALICE);
        uint256 claimed = router.claimProceeds(marketId, false, priceBps, ALICE);

        // Verify claim (allow rounding from accumulator math)
        assertApproxEqAbs(claimed, collateralNeeded, 100, "Claimed matches collateral");
        assertApproxEqAbs(
            ALICE.balance - aliceBalBefore, collateralNeeded, 100, "Balance increased"
        );

        // Verify no more pending
        (,, uint256 pendingAfter,) = router.getUserPosition(marketId, false, priceBps, ALICE);
        assertEq(pendingAfter, 0, "No pending after claim");
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Invariant: Sum of user scaled == pool totalScaled
    function testFuzz_invariant_scaledSum(uint256 amount1, uint256 amount2, uint16 priceBps)
        public
    {
        amount1 = bound(amount1, 0.1 ether, 100 ether);
        amount2 = bound(amount2, 0.1 ether, 100 ether);
        priceBps = uint16(bound(priceBps, 1, 9999));

        vm.deal(ALICE, amount1);
        vm.deal(BOB, amount2);

        // Both pool
        vm.prank(ALICE);
        bytes32 poolId =
            router.mintAndPool{value: amount1}(marketId, amount1, true, priceBps, ALICE);

        vm.prank(BOB);
        router.mintAndPool{value: amount2}(marketId, amount2, true, priceBps, BOB);

        // Check invariant
        (uint256 aliceScaled,,,) = router.getUserPosition(marketId, false, priceBps, ALICE);
        (uint256 bobScaled,,,) = router.getUserPosition(marketId, false, priceBps, BOB);
        (, uint256 totalScaled,,) = router.pools(poolId);

        assertEq(aliceScaled + bobScaled, totalScaled, "Sum of scaled == totalScaled");
    }

    /// @notice Invariant: Cannot withdraw more than available
    function testFuzz_invariant_cannotOverdraw(
        uint256 poolAmount,
        uint16 priceBps,
        uint256 fillPercent
    ) public {
        poolAmount = bound(poolAmount, 1 ether, 100 ether);
        priceBps = uint16(bound(priceBps, 100, 9999));
        fillPercent = bound(fillPercent, 0, 100);

        vm.deal(ALICE, poolAmount);

        // Pool
        vm.prank(ALICE);
        router.mintAndPool{value: poolAmount}(marketId, poolAmount, true, priceBps, ALICE);

        // Fill some percentage
        uint256 fillAmount = (poolAmount * fillPercent) / 100;
        if (fillAmount > 0) {
            uint256 collateral = ceilDiv(fillAmount * priceBps, 10000);
            if (collateral > 0) {
                vm.deal(TAKER, collateral);
                vm.prank(TAKER);
                router.fillFromPool{value: collateral}(marketId, false, priceBps, fillAmount, TAKER);
            }
        }

        // Get withdrawable
        (, uint256 withdrawable,,) = router.getUserPosition(marketId, false, priceBps, ALICE);

        // Try to withdraw more - should revert
        if (withdrawable < poolAmount) {
            vm.prank(ALICE);
            vm.expectRevert();
            router.withdrawFromPool(marketId, false, priceBps, withdrawable + 1, ALICE);
        }
    }

    /// @notice Invariant: Total collateral distributed equals total collateral paid
    function testFuzz_invariant_collateralConservation(
        uint256 amount1,
        uint256 amount2,
        uint256 fillAmount,
        uint16 priceBps
    ) public {
        amount1 = bound(amount1, 0.1 ether, 50 ether);
        amount2 = bound(amount2, 0.1 ether, 50 ether);
        priceBps = uint16(bound(priceBps, 100, 9999));

        uint256 totalPooled = amount1 + amount2;
        fillAmount = bound(fillAmount, 0.1 ether, totalPooled);

        vm.deal(ALICE, amount1);
        vm.deal(BOB, amount2);

        // Both pool
        vm.prank(ALICE);
        router.mintAndPool{value: amount1}(marketId, amount1, true, priceBps, ALICE);

        vm.prank(BOB);
        router.mintAndPool{value: amount2}(marketId, amount2, true, priceBps, BOB);

        // Fill
        uint256 collateral = ceilDiv(fillAmount * priceBps, 10000);
        if (collateral == 0) return;
        vm.deal(TAKER, collateral);

        vm.prank(TAKER);
        router.fillFromPool{value: collateral}(marketId, false, priceBps, fillAmount, TAKER);

        // Claim both
        vm.prank(ALICE);
        uint256 aliceClaimed = router.claimProceeds(marketId, false, priceBps, ALICE);

        vm.prank(BOB);
        uint256 bobClaimed = router.claimProceeds(marketId, false, priceBps, BOB);

        // Total claimed should equal collateral paid (allow small rounding from accumulator)
        // With two users and fixed-point math, rounding can accumulate up to ~2 wei per user
        assertApproxEqAbs(
            aliceClaimed + bobClaimed, collateral, 200, "Total claimed == collateral paid"
        );
    }

    /// @notice Invariant: Proportional earnings based on scaled shares
    function testFuzz_invariant_proportionalEarnings(
        uint256 amount1,
        uint256 amount2,
        uint256 fillAmount,
        uint16 priceBps
    ) public {
        // Tighter bounds to reduce rounding errors
        amount1 = bound(amount1, 1 ether, 20 ether);
        amount2 = bound(amount2, 1 ether, 20 ether);
        priceBps = uint16(bound(priceBps, 500, 8000));

        uint256 totalPooled = amount1 + amount2;
        fillAmount = bound(fillAmount, 0.5 ether, totalPooled / 2);

        vm.deal(ALICE, amount1);
        vm.deal(BOB, amount2);

        // Both pool
        vm.prank(ALICE);
        router.mintAndPool{value: amount1}(marketId, amount1, true, priceBps, ALICE);

        vm.prank(BOB);
        router.mintAndPool{value: amount2}(marketId, amount2, true, priceBps, BOB);

        // Fill
        uint256 collateral = ceilDiv(fillAmount * priceBps, 10000);
        if (collateral == 0) return;
        vm.deal(TAKER, collateral);

        vm.prank(TAKER);
        router.fillFromPool{value: collateral}(marketId, false, priceBps, fillAmount, TAKER);

        // Check pending proportions
        (,, uint256 alicePending,) = router.getUserPosition(marketId, false, priceBps, ALICE);
        (,, uint256 bobPending,) = router.getUserPosition(marketId, false, priceBps, BOB);

        // Alice's share should be proportional to her deposit
        // Allow 1 wei rounding error per user
        uint256 expectedAlice = (collateral * amount1) / totalPooled;
        uint256 expectedBob = (collateral * amount2) / totalPooled;

        // Allow small rounding errors from accumulator math
        assertApproxEqAbs(alicePending, expectedAlice, 100, "Alice earnings proportional");
        assertApproxEqAbs(bobPending, expectedBob, 100, "Bob earnings proportional");
    }

    /// @notice Fuzz: Claim-before-withdraw pattern
    function testFuzz_claimBeforeWithdraw(uint256 poolAmount, uint256 fillAmount, uint16 priceBps)
        public
    {
        // Tighter bounds
        poolAmount = bound(poolAmount, 1 ether, 50 ether);
        priceBps = uint16(bound(priceBps, 500, 8000));
        fillAmount = bound(fillAmount, 0.5 ether, poolAmount / 2); // Fill less than half

        vm.deal(ALICE, poolAmount);

        // Pool
        vm.prank(ALICE);
        router.mintAndPool{value: poolAmount}(marketId, poolAmount, true, priceBps, ALICE);

        // Fill some
        uint256 collateral = ceilDiv(fillAmount * priceBps, 10000);
        if (collateral == 0) return;
        vm.deal(TAKER, collateral);

        vm.prank(TAKER);
        router.fillFromPool{value: collateral}(marketId, false, priceBps, fillAmount, TAKER);

        // Claim BEFORE withdraw (allow rounding)
        vm.prank(ALICE);
        uint256 claimed = router.claimProceeds(marketId, false, priceBps, ALICE);
        assertApproxEqAbs(claimed, collateral, 100, "Claimed full collateral before withdraw");

        // Now withdraw remaining
        (, uint256 withdrawable,,) = router.getUserPosition(marketId, false, priceBps, ALICE);

        vm.prank(ALICE);
        uint256 withdrawn = router.withdrawFromPool(marketId, false, priceBps, withdrawable, ALICE);
        assertEq(withdrawn, withdrawable, "Withdrew all remaining");

        // Verify final state
        (uint256 aliceScaled,,,) = router.getUserPosition(marketId, false, priceBps, ALICE);
        assertEq(aliceScaled, 0, "Alice fully exited");
    }

    /// @notice Fuzz: Multiple fills accumulate correctly
    function testFuzz_multipleFills(uint256 poolAmount, uint8 numFills, uint16 priceBps) public {
        // Tighter bounds for predictable behavior
        poolAmount = bound(poolAmount, 10 ether, 50 ether);
        numFills = uint8(bound(numFills, 1, 5));
        priceBps = uint16(bound(priceBps, 1000, 8000));

        vm.deal(ALICE, poolAmount);

        // Pool
        vm.prank(ALICE);
        router.mintAndPool{value: poolAmount}(marketId, poolAmount, true, priceBps, ALICE);

        uint256 totalCollateral = 0;
        uint256 fillPerRound = poolAmount / (uint256(numFills) + 2); // Leave plenty unfilled

        // Ensure fillPerRound is meaningful
        if (fillPerRound < 0.1 ether) return;

        for (uint256 i = 0; i < numFills; i++) {
            uint256 collateral = ceilDiv(fillPerRound * priceBps, 10000);
            if (collateral == 0) continue;

            vm.deal(TAKER, collateral);
            vm.prank(TAKER);
            router.fillFromPool{value: collateral}(marketId, false, priceBps, fillPerRound, TAKER);

            totalCollateral += collateral;
        }

        if (totalCollateral == 0) return; // Nothing to claim

        // Claim all (allow rounding error proportional to number of fills)
        vm.prank(ALICE);
        uint256 claimed = router.claimProceeds(marketId, false, priceBps, ALICE);

        // More generous tolerance for multiple operations
        assertApproxEqAbs(
            claimed,
            totalCollateral,
            uint256(numFills) * 100,
            "Claimed equals total collateral from all fills"
        );
    }
}
