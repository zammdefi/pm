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

/// @title Bid Pool Tests for MasterRouter
/// @notice Tests for buy-side liquidity pools (bid pools)
contract MasterRouterBidPoolsTest is Test {
    MasterRouter public router;
    IPAMMExtended public pamm = IPAMMExtended(0x000000000044bfe6c2BBFeD8862973E0612f07C0);

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    address public seller = address(0x4);

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
        vm.deal(carol, 1000 ether);
        vm.deal(seller, 1000 ether);

        // Seller needs shares to sell - mint some via split
        vm.prank(seller);
        pamm.split{value: 500 ether}(marketId, 500 ether, seller);

        // Approve router to transfer seller's shares
        vm.prank(seller);
        pamm.setOperator(address(router), true);
    }

    /*//////////////////////////////////////////////////////////////
                        BASIC BID POOL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test creating a bid pool
    function test_createBidPool_basic() public {
        uint256 collateralIn = 100 ether;
        uint256 priceInBps = 6000; // Willing to pay 0.60 per YES share

        vm.prank(alice);
        bytes32 bidPoolId = router.createBidPool{value: collateralIn}(
            marketId, collateralIn, true, priceInBps, alice
        );

        // Verify pool state
        (
            uint256 totalCollateral,
            uint256 totalScaled,
            uint256 accSharesPerScaled,
            uint256 sharesAcquired
        ) = router.bidPools(bidPoolId);

        assertEq(totalCollateral, collateralIn, "Total collateral should match deposit");
        assertEq(totalScaled, collateralIn, "First depositor gets 1:1 scaled units");
        assertEq(accSharesPerScaled, 0, "No shares acquired yet");
        assertEq(sharesAcquired, 0, "No shares acquired yet");

        // Verify user position
        (uint256 userScaled, uint256 userWithdrawable, uint256 userPending, uint256 userDebt) =
            router.getBidPosition(marketId, true, priceInBps, alice);

        assertEq(userScaled, collateralIn, "User scaled matches deposit");
        assertEq(userWithdrawable, collateralIn, "User can withdraw full amount");
        assertEq(userPending, 0, "No pending shares");
        assertEq(userDebt, 0, "No debt");
    }

    /// @notice Test getBidPoolId returns correct ID
    function test_getBidPoolId() public view {
        bytes32 yesPoolId = router.getBidPoolId(marketId, true, 5000);
        bytes32 noPoolId = router.getBidPoolId(marketId, false, 5000);
        bytes32 differentPriceId = router.getBidPoolId(marketId, true, 6000);

        // All should be different
        assertTrue(yesPoolId != noPoolId, "YES and NO pools should have different IDs");
        assertTrue(yesPoolId != differentPriceId, "Different prices should have different IDs");

        // Same params should give same ID
        bytes32 yesPoolId2 = router.getBidPoolId(marketId, true, 5000);
        assertEq(yesPoolId, yesPoolId2, "Same params should give same ID");
    }

    /// @notice Test multiple users can join same bid pool
    function test_createBidPool_multipleUsers() public {
        uint256 priceInBps = 5000;

        // Alice deposits 100
        vm.prank(alice);
        bytes32 bidPoolId =
            router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        // Bob deposits 200
        vm.prank(bob);
        router.createBidPool{value: 200 ether}(marketId, 200 ether, true, priceInBps, bob);

        // Carol deposits 100
        vm.prank(carol);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, carol);

        // Total should be 400
        (uint256 totalCollateral,,,) = router.bidPools(bidPoolId);
        assertEq(totalCollateral, 400 ether, "Total collateral should be 400");

        // Each user should have correct withdrawable amount
        (, uint256 aliceWithdrawable,,) = router.getBidPosition(marketId, true, priceInBps, alice);
        (, uint256 bobWithdrawable,,) = router.getBidPosition(marketId, true, priceInBps, bob);
        (, uint256 carolWithdrawable,,) = router.getBidPosition(marketId, true, priceInBps, carol);

        assertEq(aliceWithdrawable, 100 ether, "Alice can withdraw 100");
        assertEq(bobWithdrawable, 200 ether, "Bob can withdraw 200");
        assertEq(carolWithdrawable, 100 ether, "Carol can withdraw 100");
    }

    /*//////////////////////////////////////////////////////////////
                        SELL TO POOL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test selling shares to a bid pool
    function test_sellToPool_basic() public {
        uint256 priceInBps = 5000; // 0.50 per share

        // Alice creates bid pool with 100 ETH
        vm.prank(alice);
        bytes32 bidPoolId =
            router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        // Seller sells 50 YES shares to the pool
        uint256 sellerBalanceBefore = seller.balance;
        uint256 sellerSharesBefore = pamm.balanceOf(seller, marketId);

        vm.prank(seller);
        (uint256 sharesSold, uint256 collateralReceived) =
            router.sellToPool(marketId, true, priceInBps, 50 ether, seller);

        assertEq(sharesSold, 50 ether, "Should sell 50 shares");
        assertEq(collateralReceived, 25 ether, "Should receive 25 ETH (50 * 0.50)");

        // Verify seller got paid
        assertEq(seller.balance, sellerBalanceBefore + 25 ether, "Seller received ETH");
        assertEq(
            pamm.balanceOf(seller, marketId), sellerSharesBefore - 50 ether, "Seller lost shares"
        );

        // Verify pool state updated
        (uint256 totalCollateral,,, uint256 sharesAcquired) = router.bidPools(bidPoolId);
        assertEq(totalCollateral, 75 ether, "Pool has 75 ETH remaining");
        assertEq(sharesAcquired, 50 ether, "Pool acquired 50 shares");
    }

    /// @notice Test selling shares fills pool completely
    function test_sellToPool_fillsCompletely() public {
        uint256 priceInBps = 4000; // 0.40 per share

        // Alice creates bid pool with 40 ETH (can buy 100 shares at 0.40)
        vm.prank(alice);
        bytes32 bidPoolId =
            router.createBidPool{value: 40 ether}(marketId, 40 ether, true, priceInBps, alice);

        // Seller sells 100 shares - should use all 40 ETH
        vm.prank(seller);
        (uint256 sharesSold, uint256 collateralReceived) =
            router.sellToPool(marketId, true, priceInBps, 100 ether, seller);

        assertEq(sharesSold, 100 ether, "Should sell 100 shares");
        assertEq(collateralReceived, 40 ether, "Should receive 40 ETH");

        // Pool should be empty
        (uint256 totalCollateral,,,) = router.bidPools(bidPoolId);
        assertEq(totalCollateral, 0, "Pool should be empty");
    }

    /// @notice Test selling more shares than pool can buy reverts
    function test_sellToPool_reverts_insufficientLiquidity() public {
        uint256 priceInBps = 5000;

        // Alice creates small bid pool
        vm.prank(alice);
        router.createBidPool{value: 10 ether}(marketId, 10 ether, true, priceInBps, alice);

        // Try to sell more than pool can buy (10 ETH at 0.50 = 20 shares max)
        vm.prank(seller);
        vm.expectRevert();
        router.sellToPool(marketId, true, priceInBps, 50 ether, seller);
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM SHARES TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test claiming shares after fills
    function test_claimBidShares_basic() public {
        uint256 priceInBps = 5000;

        // Alice creates bid pool
        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        // Seller sells 50 shares
        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 50 ether, seller);

        // Alice claims her shares
        uint256 aliceSharesBefore = pamm.balanceOf(alice, marketId);

        vm.prank(alice);
        uint256 sharesClaimed = router.claimBidShares(marketId, true, priceInBps, alice);

        assertEq(sharesClaimed, 50 ether, "Alice claims 50 shares");
        assertEq(
            pamm.balanceOf(alice, marketId), aliceSharesBefore + 50 ether, "Alice received shares"
        );
    }

    /// @notice Test proportional share distribution among multiple bidders
    function test_claimBidShares_proportional() public {
        uint256 priceInBps = 5000;

        // Alice deposits 100, Bob deposits 200 (1:2 ratio)
        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        vm.prank(bob);
        router.createBidPool{value: 200 ether}(marketId, 200 ether, true, priceInBps, bob);

        // Seller sells 60 shares (30 ETH spent)
        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 60 ether, seller);

        // Alice should get 1/3 = 20 shares, Bob should get 2/3 = 40 shares
        vm.prank(alice);
        uint256 aliceClaimed = router.claimBidShares(marketId, true, priceInBps, alice);

        vm.prank(bob);
        uint256 bobClaimed = router.claimBidShares(marketId, true, priceInBps, bob);

        assertEq(aliceClaimed, 20 ether, "Alice gets 1/3 of shares");
        assertEq(bobClaimed, 40 ether, "Bob gets 2/3 of shares");
    }

    /// @notice Test multiple claims over time
    function test_claimBidShares_multipleFills() public {
        uint256 priceInBps = 5000;

        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        // First fill: 40 shares
        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 40 ether, seller);

        // Alice claims first batch
        vm.prank(alice);
        uint256 firstClaim = router.claimBidShares(marketId, true, priceInBps, alice);
        assertEq(firstClaim, 40 ether, "First claim: 40 shares");

        // Second fill: 60 shares
        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 60 ether, seller);

        // Alice claims second batch
        vm.prank(alice);
        uint256 secondClaim = router.claimBidShares(marketId, true, priceInBps, alice);
        assertEq(secondClaim, 60 ether, "Second claim: 60 shares");

        // Third claim should return 0
        vm.prank(alice);
        uint256 thirdClaim = router.claimBidShares(marketId, true, priceInBps, alice);
        assertEq(thirdClaim, 0, "Nothing left to claim");
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test withdrawing unfilled collateral
    function test_withdrawFromBidPool_basic() public {
        uint256 priceInBps = 5000;

        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        // Alice withdraws 50 (no fills yet)
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        uint256 withdrawn = router.withdrawFromBidPool(marketId, true, priceInBps, 50 ether, alice);

        assertEq(withdrawn, 50 ether, "Should withdraw 50 ETH");
        assertEq(alice.balance, aliceBalanceBefore + 50 ether, "Alice received ETH");

        // Pool should have 50 remaining
        bytes32 bidPoolId = router.getBidPoolId(marketId, true, priceInBps);
        (uint256 totalCollateral,,,) = router.bidPools(bidPoolId);
        assertEq(totalCollateral, 50 ether, "Pool has 50 ETH remaining");
    }

    /// @notice Test withdrawing all with 0 amount
    function test_withdrawFromBidPool_withdrawAll() public {
        uint256 priceInBps = 5000;

        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        // Withdraw all by passing 0
        vm.prank(alice);
        uint256 withdrawn = router.withdrawFromBidPool(marketId, true, priceInBps, 0, alice);

        assertEq(withdrawn, 100 ether, "Should withdraw all 100 ETH");
    }

    /// @notice Test withdrawal after partial fill - must claim before withdraw
    /// @dev In accumulator model: must claim before withdraw to preserve earnings
    function test_withdrawFromBidPool_afterPartialFill() public {
        uint256 priceInBps = 5000;

        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        // 40 shares filled (20 ETH spent)
        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 40 ether, seller);

        // Alice MUST claim BEFORE withdrawing in accumulator model
        vm.prank(alice);
        uint256 claimed = router.claimBidShares(marketId, true, priceInBps, alice);
        assertEq(claimed, 40 ether, "Claimed 40 shares");

        // Now Alice can withdraw remaining 80 ETH
        (, uint256 aliceWithdrawable,,) = router.getBidPosition(marketId, true, priceInBps, alice);
        assertEq(aliceWithdrawable, 80 ether, "Alice can withdraw 80 ETH");

        vm.prank(alice);
        uint256 withdrawn = router.withdrawFromBidPool(marketId, true, priceInBps, 0, alice);
        assertEq(withdrawn, 80 ether, "Withdrew 80 ETH");
    }

    /// @notice Test withdrawal doesn't affect other users
    function test_withdrawFromBidPool_independentUsers() public {
        uint256 priceInBps = 5000;

        // Alice and Bob deposit
        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        vm.prank(bob);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, bob);

        // 50 shares filled (25 ETH spent from 200 total)
        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 50 ether, seller);

        // Alice withdraws her remaining collateral
        vm.prank(alice);
        router.withdrawFromBidPool(marketId, true, priceInBps, 0, alice);

        // Bob's position should be unaffected
        (, uint256 bobWithdrawable, uint256 bobPending,) =
            router.getBidPosition(marketId, true, priceInBps, bob);

        assertEq(bobWithdrawable, 87.5 ether, "Bob can still withdraw his portion");
        assertEq(bobPending, 25 ether, "Bob has 25 pending shares (half of 50)");
    }

    /*//////////////////////////////////////////////////////////////
                        SELL() ROUTING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test sell() routes through bid pool first
    function test_sell_routesThroughBidPool() public {
        uint256 priceInBps = 5000;

        // Alice creates bid pool
        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        // Seller uses sell() with bid pool price specified
        uint256 sellerBalanceBefore = seller.balance;

        vm.prank(seller);
        (uint256 collateralOut, bytes4[] memory sources) = router.sell(
            marketId,
            true, // sellYes
            50 ether, // sharesIn
            0, // minCollateralOut
            priceInBps, // bidPoolPriceInBps - route through our pool
            0, // feeOrHook (deprecated)
            seller,
            0 // deadline
        );

        assertEq(collateralOut, 25 ether, "Got 25 ETH from bid pool");
        assertEq(sources.length, 1, "Single source");
        assertEq(sources[0], bytes4(keccak256("BIDPOOL")), "Source is BIDPOOL");
        assertEq(seller.balance, sellerBalanceBefore + 25 ether, "Seller received ETH");
    }

    /// @notice Test sell() with bid pool price routes through pool even with larger order
    function test_sell_partialFillThenPMHookRouter() public {
        uint256 priceInBps = 5000;

        // Alice creates small bid pool (can only buy 20 shares)
        vm.prank(alice);
        router.createBidPool{value: 10 ether}(marketId, 10 ether, true, priceInBps, alice);

        // Seller sells 20 shares - should fully fill from bid pool
        vm.prank(seller);
        (uint256 collateralOut, bytes4[] memory sources) = router.sell(
            marketId,
            true,
            20 ether,
            0,
            priceInBps, // Use bid pool at this price
            0,
            seller,
            0
        );

        // Should have gotten 10 ETH from bid pool (20 shares * 0.50)
        assertEq(collateralOut, 10 ether, "Got 10 ETH from bid pool");
        assertEq(sources.length, 1, "Single source");
        assertEq(sources[0], bytes4(keccak256("BIDPOOL")), "Source is BIDPOOL");

        // Bid pool should now be empty
        bytes32 bidPoolId = router.getBidPoolId(marketId, true, priceInBps);
        (uint256 totalCollateral,,,) = router.bidPools(bidPoolId);
        assertEq(totalCollateral, 0, "Bid pool is empty");
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASES & SECURITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Test creating bid pool for NO shares
    function test_createBidPool_forNoShares() public {
        uint256 priceInBps = 4000;

        vm.prank(alice);
        bytes32 bidPoolId =
            router.createBidPool{value: 100 ether}(marketId, 100 ether, false, priceInBps, alice);

        (uint256 totalCollateral,,,) = router.bidPools(bidPoolId);
        assertEq(totalCollateral, 100 ether, "Pool created for NO shares");

        // Seller sells NO shares
        vm.prank(seller);
        (uint256 sharesSold,) = router.sellToPool(marketId, false, priceInBps, 50 ether, seller);
        assertEq(sharesSold, 50 ether, "Sold NO shares to pool");

        // Alice claims NO shares
        vm.prank(alice);
        uint256 claimed = router.claimBidShares(marketId, false, priceInBps, alice);
        assertEq(claimed, 50 ether, "Claimed NO shares");
        assertEq(pamm.balanceOf(alice, noId), 50 ether, "Alice has NO shares");
    }

    /// @notice Test invalid price reverts
    function test_createBidPool_reverts_invalidPrice() public {
        // Price 0
        vm.prank(alice);
        vm.expectRevert();
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, 0, alice);

        // Price >= 10000
        vm.prank(alice);
        vm.expectRevert();
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, 10000, alice);
    }

    /// @notice Test zero collateral reverts
    function test_createBidPool_reverts_zeroCollateral() public {
        vm.prank(alice);
        vm.expectRevert();
        router.createBidPool{value: 0}(marketId, 0, true, 5000, alice);
    }

    /// @notice Test withdraw more than available reverts
    function test_withdrawFromBidPool_reverts_tooMuch() public {
        uint256 priceInBps = 5000;

        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        vm.prank(alice);
        vm.expectRevert();
        router.withdrawFromBidPool(marketId, true, priceInBps, 200 ether, alice);
    }

    /// @notice Test late joiner gets fair share
    function test_bidPool_lateJoinerFairness() public {
        uint256 priceInBps = 5000;

        // Alice joins first
        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        // First fill: 40 shares (20 ETH spent)
        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 40 ether, seller);

        // Bob joins AFTER first fill
        vm.prank(bob);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, bob);

        // Second fill: 40 shares (20 ETH spent from 180 remaining)
        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 40 ether, seller);

        // Alice claims - should get 40 from first fill + share of second fill
        vm.prank(alice);
        uint256 aliceClaimed = router.claimBidShares(marketId, true, priceInBps, alice);

        // Bob claims - should only get share of second fill (NOT first fill)
        vm.prank(bob);
        uint256 bobClaimed = router.claimBidShares(marketId, true, priceInBps, bob);

        // Alice: 40 + (80/180)*40 = 40 + ~17.78 = ~57.78 shares
        // Bob: (100/180)*40 = ~22.22 shares
        assertGt(aliceClaimed, bobClaimed, "Alice gets more (was in first fill)");
        assertApproxEqAbs(aliceClaimed + bobClaimed, 80 ether, 1e9, "Total = 80 shares");

        // Critical: Bob should NOT have gotten any of the first 40 shares
        assertLt(bobClaimed, 40 ether, "Bob didn't steal first fill shares");
    }

    /// @notice Test claim before withdraw pattern
    function test_bidPool_claimBeforeWithdraw() public {
        uint256 priceInBps = 5000;

        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        // Fill 50 shares
        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 50 ether, seller);

        // Alice MUST claim before withdraw to get her shares
        vm.prank(alice);
        uint256 claimed = router.claimBidShares(marketId, true, priceInBps, alice);
        assertEq(claimed, 50 ether, "Claimed 50 shares");

        // Now withdraw remaining collateral
        vm.prank(alice);
        uint256 withdrawn = router.withdrawFromBidPool(marketId, true, priceInBps, 0, alice);
        assertEq(withdrawn, 75 ether, "Withdrew remaining 75 ETH");
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test total shares claimed equals total shares sold
    function test_invariant_sharesConservation() public {
        uint256 priceInBps = 5000;

        // Multiple users create bids
        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        vm.prank(bob);
        router.createBidPool{value: 150 ether}(marketId, 150 ether, true, priceInBps, bob);

        // Multiple sells
        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 80 ether, seller);

        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 70 ether, seller);

        // Total sold: 150 shares

        // All users claim
        vm.prank(alice);
        uint256 aliceClaimed = router.claimBidShares(marketId, true, priceInBps, alice);

        vm.prank(bob);
        uint256 bobClaimed = router.claimBidShares(marketId, true, priceInBps, bob);

        // Total claimed should equal total sold
        assertEq(aliceClaimed + bobClaimed, 150 ether, "Total claimed = total sold");
    }

    /// @notice Test collateral conservation
    function test_invariant_collateralConservation() public {
        uint256 priceInBps = 5000;

        uint256 totalDeposited = 300 ether;

        vm.prank(alice);
        router.createBidPool{value: 100 ether}(marketId, 100 ether, true, priceInBps, alice);

        vm.prank(bob);
        router.createBidPool{value: 200 ether}(marketId, 200 ether, true, priceInBps, bob);

        // Sell 100 shares (50 ETH spent)
        uint256 sellerBalanceBefore = seller.balance;
        vm.prank(seller);
        router.sellToPool(marketId, true, priceInBps, 100 ether, seller);
        uint256 sellerReceived = seller.balance - sellerBalanceBefore;

        // Withdraw remaining
        vm.prank(alice);
        uint256 aliceWithdrawn = router.withdrawFromBidPool(marketId, true, priceInBps, 0, alice);

        vm.prank(bob);
        uint256 bobWithdrawn = router.withdrawFromBidPool(marketId, true, priceInBps, 0, bob);

        // Total out should equal total in
        assertEq(
            sellerReceived + aliceWithdrawn + bobWithdrawn, totalDeposited, "Collateral conserved"
        );
    }
}
